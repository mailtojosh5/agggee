<#
.SYNOPSIS
  Local "Squish Agent" — each user runs this on their own Windows machine
  (where squishrunner.exe is installed). It exposes a small local HTTP API
  on 127.0.0.1 that a GitHub Pages website can call (via fetch) to trigger
  squishrunner.exe locally, which then connects out to a remote
  squishserver.exe and runs the suite.

  This does NOT serve the HTML page itself — that lives on GitHub Pages.
  This only answers API calls from that page: /ping, /suites, /run, /status.

.USAGE
  .\squish-agent.ps1 -RemoteHost 10.20.30.40 -RemotePort 4322 `
                      -SquishDir "C:\Squish" -SuiteRootDir "C:\TestSuites" `
                      -AllowedOrigin "https://yourorg.github.io"

  Leave the window open. The GitHub Pages "Run" button will call into it.
  Ctrl+C to stop.
#>

param(
    [string]$SquishDir     = "C:\Squish",
    [string]$SuiteRootDir  = "C:\TestSuites",
    [string]$RemoteHost    = "10.20.30.40",
    [int]   $RemotePort    = 4322,
    [string]$AuthKey       = "",
    [int]   $ListenPort    = 8765,
    # The exact origin of your GitHub Pages site, e.g. https://yourorg.github.io
    # Use "*" only for local testing — browsers reject "*" combined with
    # credentials, but we don't use credentials here so "*" also works.
    [string]$AllowedOrigin = "https://yourorg.github.io",
    [string]$LogDir        = "$env:TEMP\squish-run-logs"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

$jobs = @{}

function Add-CorsHeaders($response) {
    $response.Headers.Add("Access-Control-Allow-Origin", $AllowedOrigin)
    $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
    # Required by Chrome's Private Network Access checks when a public HTTPS
    # page (github.io) calls a private/loopback address (127.0.0.1).
    $response.Headers.Add("Access-Control-Allow-Private-Network", "true")
}

function Send-Json($response, $obj, $statusCode = 200) {
    Add-CorsHeaders $response
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json"
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

$prefix = "http://127.0.0.1:${ListenPort}/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Host "Squish local agent listening at: $prefix"
Write-Host "Allowed page origin  : $AllowedOrigin"
Write-Host "Local Squish install : $SquishDir"
Write-Host "Suite root dir       : $SuiteRootDir"
Write-Host "Remote squishserver  : ${RemoteHost}:${RemotePort}"
Write-Host "Leave this window open. Ctrl+C to stop."

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request  = $context.Request
    $response = $context.Response

    try {
        # Handle CORS preflight requests
        if ($request.HttpMethod -eq "OPTIONS") {
            Add-CorsHeaders $response
            $response.StatusCode = 204
            $response.Close()
            continue
        }

        switch -Regex ($request.Url.AbsolutePath) {

            '^/ping$' {
                Send-Json $response @{
                    status     = "ok"
                    remoteHost = $RemoteHost
                    remotePort = $RemotePort
                }
            }

            '^/suites$' {
                $suites = @()
                if (Test-Path $SuiteRootDir) {
                    $suites = Get-ChildItem -Path $SuiteRootDir -Directory |
                              Where-Object { $_.Name -like 'suite_*' } |
                              Select-Object -ExpandProperty Name
                }
                Send-Json $response @{ suites = $suites; remoteHost = $RemoteHost; remotePort = $RemotePort }
            }

            '^/run$' {
                $suite  = $request.QueryString["suite"]
                $format = $request.QueryString["format"]
                if (-not $format) { $format = "xml3" }

                if (-not $suite) {
                    Send-Json $response @{ error = "No suite specified" } 400
                    break
                }

                $jobId = [guid]::NewGuid().ToString("N").Substring(0,8)
                $logFile = Join-Path $LogDir "$jobId.log"
                $suitePath = Join-Path $SuiteRootDir $suite
                $reportDir = Join-Path $LogDir "$jobId-report"
                New-Item -ItemType Directory -Path $reportDir | Out-Null

                $exe = Join-Path $SquishDir "bin\squishrunner.exe"
                $argList = @(
                    "--host", $RemoteHost,
                    "--port", $RemotePort,
                    "--testsuite", $suitePath,
                    "--reportgen", "$format,$reportDir"
                )
                if ($AuthKey) { $argList += @("--authkey", $AuthKey) }

                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $exe
                $psi.Arguments = ($argList | ForEach-Object { '"' + $_ + '"' }) -join ' '
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true

                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $psi
                $proc.Start() | Out-Null

                $jobs[$jobId] = @{ Process = $proc; LogFile = $logFile; ReportDir = $reportDir }

                Start-Job -ScriptBlock {
                    param($proc, $logFile)
                    $out = $proc.StandardOutput.ReadToEnd()
                    $err = $proc.StandardError.ReadToEnd()
                    $proc.WaitForExit()
                    ($out + "`n" + $err) | Out-File -FilePath $logFile -Encoding utf8
                    "EXITCODE:$($proc.ExitCode)" | Out-File -FilePath "$logFile.exit" -Encoding utf8
                } -ArgumentList $proc, $logFile | Out-Null

                Send-Json $response @{ jobId = $jobId }
            }

            '^/status$' {
                $jobId = $request.QueryString["id"]
                if (-not $jobs.ContainsKey($jobId)) {
                    Send-Json $response @{ state = "unknown" } 404
                    break
                }
                $job = $jobs[$jobId]
                $logContent = ""
                if (Test-Path $job.LogFile) { $logContent = Get-Content $job.LogFile -Raw }

                $exitFile = "$($job.LogFile).exit"
                if (Test-Path $exitFile) {
                    $exitLine = Get-Content $exitFile -Raw
                    $exitCode = ($exitLine -replace 'EXITCODE:', '').Trim()
                    $state = if ($exitCode -eq "0") { "passed" } else { "failed" }
                    Send-Json $response @{ state = $state; exitCode = $exitCode; log = $logContent }
                } else {
                    Send-Json $response @{ state = "running"; log = $logContent }
                }
            }

            default {
                Add-CorsHeaders $response
                $response.StatusCode = 404
                $response.Close()
            }
        }
    } catch {
        try { Send-Json $response @{ error = $_.Exception.Message } 500 } catch { }
    }
}
