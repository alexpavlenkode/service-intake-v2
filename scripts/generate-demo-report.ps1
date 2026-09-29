<#
    .SYNOPSIS
        Turns a scripts\demo-pipeline.ps1 JSON trace into a self-contained,
        clickable HTML "flight report" (scripts\demo-report-template.html
        with the trace data substituted in).

    .PARAMETER TraceFile
        Path to a trace JSON file under logs\demo-traces\. Defaults to the
        most recent one.

    .PARAMETER OutFile
        Where to write the generated HTML. Defaults next to the trace file.
#>
[CmdletBinding()]
param(
    [string] $TraceFile,
    [string] $OutFile
)

$ErrorActionPreference = 'Stop'

if (-not $TraceFile) {
    $traceDir = Join-Path $PSScriptRoot '..\logs\demo-traces'
    $latest = Get-ChildItem -Path $traceDir -Filter 'trace-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No trace files found in $traceDir - run scripts\demo-pipeline.ps1 first." }
    $TraceFile = $latest.FullName
}
if (-not (Test-Path $TraceFile)) { throw "Trace file not found: $TraceFile" }

if (-not $OutFile) {
    $OutFile = [System.IO.Path]::ChangeExtension($TraceFile, '.html')
}

$json = Get-Content -Path $TraceFile -Raw -Encoding UTF8
$template = Get-Content -Path "$PSScriptRoot\demo-report-template.html" -Raw -Encoding UTF8

$html = $template.Replace('__TRACE_JSON__', $json.Trim()).Replace('__TRACE_FILE__', [System.IO.Path]::GetFileName($TraceFile))
[System.IO.File]::WriteAllText($OutFile, $html, [System.Text.UTF8Encoding]::new($false))

Write-Output "Report written to $OutFile"
Write-Output "Open it directly in a browser, or ask Claude to publish it as an Artifact."
