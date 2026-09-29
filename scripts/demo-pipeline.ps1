<#
    .SYNOPSIS
        Demo/visualization tool: sends one or more synthetic "emails" through
        the REAL Service Intake pipeline (genuine Dataverse calls at every
        stage - idempotency via the actual alternate key, business-key
        duplicate lookup, hsv_processingattempt logging), with an animated
        console visualization of the message flying through each node.

    .DESCRIPTION
        There is no AI/NLP email parser in this project (out of scope) - the
        "Parse" stage here is the deterministic path docs/01-prozessbeschreibung.md
        §4 describes for structured input, working off the fields you provide
        rather than free text. Everything downstream (idempotency, validation,
        business-key duplicate detection, work order creation, processing-
        attempt logging) is 100% real: it calls the same Dataverse tables and
        keys as the rest of this project, not a mockup.

        The actual pipeline logic lives in scripts\lib\Pipeline.psm1, shared
        with scripts\serve-live-console.ps1's Live Console (review items
        18/19) - this script is now only the console-animation presentation
        layer plus message-list building (Interactive/Random) and trace-file
        writing.

        Every run writes a JSON trace to logs\demo-traces\ that
        scripts\generate-demo-report.ps1 turns into a clickable HTML
        visualization.

    .PARAMETER Interactive
        Prompts you to compose one message by hand.

    .PARAMETER Random
        Generates this many synthetic messages, deliberately exercising
        different branches (clean success, technical duplicate, business
        duplicate, missing required field, not-a-request).

    .PARAMETER ConfigPath
        Defaults to SI-DEV.
    #>
[CmdletBinding(DefaultParameterSetName = 'Random')]
param(
    [Parameter(ParameterSetName = 'Interactive')] [switch] $Interactive,
    [Parameter(ParameterSetName = 'Random')] [int] $Random = 3,
    [string] $ConfigPath = "$PSScriptRoot\config.psd1"
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force
Import-Module "$PSScriptRoot\lib\EmailGenerator.psm1" -Force
Import-Module "$PSScriptRoot\lib\Pipeline.psm1" -Force

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

# --- Console visualization helpers -----------------------------------------
$Stages = @('Ingest', 'Parse', 'Validate', 'Duplicate Check', 'Decision')

function Write-Pipeline {
    param([string[]] $StageStatus)  # one of Pending/Active/Pass/Fail/Warn per stage, same order as $Stages
    $symbols = @{ Pending = '  '; Active = '>>'; Pass = [char]0x2714; Fail = [char]0x2716; Warn = '!!' }
    $colors  = @{ Pending = 'DarkGray'; Active = 'Cyan'; Pass = 'Green'; Fail = 'Red'; Warn = 'Yellow' }
    Write-Host ""
    for ($i = 0; $i -lt $Stages.Count; $i++) {
        $st = $StageStatus[$i]
        Write-Host -NoNewline "[ " -ForegroundColor DarkGray
        Write-Host -NoNewline "$($symbols[$st]) $($Stages[$i])" -ForegroundColor $colors[$st]
        Write-Host -NoNewline " ]" -ForegroundColor DarkGray
        if ($i -lt $Stages.Count - 1) { Write-Host -NoNewline " -> " -ForegroundColor DarkGray }
    }
    Write-Host ""
}

$Trades = @(
    @{ Value = 209710501; Label = 'Sanitaer' }
    @{ Value = 209710502; Label = 'Elektro' }
    @{ Value = 209710503; Label = 'Heizung' }
)

# Maps Pipeline.psm1's neutral per-stage result (Pass/Warn/Duplicate) and
# finalStatus onto this console's animation. The shared module returns the
# WHOLE stage list at once (it isn't interactive/animated internally), so
# the "live" per-stage animation here is played back stage-by-stage from
# that list rather than driven by callbacks into the module - keeps
# Pipeline.psm1 free of any console-specific concerns.
function Show-AnimatedResult {
    param([hashtable] $Result, [int] $Index, [int] $Total, [hashtable] $Msg)

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host " Nachricht $Index/$Total : von $($Msg['FromAddress'])" -ForegroundColor White
    Write-Host " Betreff: $($Msg['Subject'])" -ForegroundColor White
    Write-Host ("=" * 70) -ForegroundColor DarkCyan

    $status = @('Pending') * $Stages.Count
    $stageIndexByName = @{ 'Ingest' = 0; 'Parse' = 1; 'Validate' = 2; 'Duplicate Check' = 3; 'Decision' = 4 }

    foreach ($s in $Result.stages) {
        $idx = $stageIndexByName[$s.name]
        $status[$idx] = 'Active'
        Write-Pipeline $status
        Start-Sleep -Milliseconds 400
        $status[$idx] = switch ($s.result) { 'Pass' { 'Pass' }; 'Warn' { 'Warn' }; 'Duplicate' { 'Fail' }; default { 'Fail' } }
        Write-Pipeline $status
        $color = switch ($s.result) { 'Pass' { 'Gray' }; 'Warn' { 'Yellow' }; default { 'Yellow' } }
        Write-Host "    -> $($s.detail)" -ForegroundColor $color
        Start-Sleep -Milliseconds 250
    }

    $finalColor = switch ($Result.finalStatus) { 'Converted' { 'Green' }; 'Duplicate' { 'Red' }; default { 'Yellow' } }
    Write-Host "    -> $($Result.finalDetail)" -ForegroundColor $finalColor
}

# --- Build the message list -------------------------------------------------
$messages = New-Object System.Collections.Generic.List[hashtable]

if ($Interactive) {
    Write-Host "=== Neue Nachricht verfassen ===" -ForegroundColor Cyan
    $from = Read-Host "Von (E-Mail-Adresse)"
    $subject = Read-Host "Betreff"
    $body = Read-Host "Text"
    $customer = Read-Host "Kunde (z.B. 'Hausverwaltung Nord')"
    $objNum = Read-Host "Objektnummer (leer lassen fuer 'Adresse fehlt'-Szenario)"
    $trade = $Trades[(Get-Random -Minimum 0 -Maximum $Trades.Count)]
    $messages.Add(@{
        FromAddress = $from; Subject = $subject; Body = $body; CustomerName = $customer
        ObjectNumber = $objNum; Street = 'Teststrasse'
        TradeValue = $trade.Value; TradeLabel = $trade.Label
        ProviderMessageId = "DEMO-$([guid]::NewGuid().ToString().Substring(0,8))"
        NotARequest = $false
    })
} else {
    # Realistic content (varied customers, complaint bodies, tone) comes from
    # the shared module - was a 3-customer/3-problem inline pool here, which
    # made anything above ~10 messages look obviously repeated.
    $generated = New-Object System.Collections.Generic.List[hashtable]
    $cleanCount = 0
    for ($i = 0; $i -lt $Random; $i++) {
        $scenario = Get-ScenarioForIndex -Index $i -PreviousCleanCount $cleanCount
        $rm = New-RealisticMessage -Scenario $scenario -PreviousMessages $generated
        if ($rm.Scenario -eq 'clean') { $cleanCount++ }
        $generated.Add($rm)

        # 'technical_duplicate' returns the SAME hashtable reference as an
        # earlier generated message (by design, see EmailGenerator.psm1);
        # Set-StampedProviderMessageId (review item 20) is what makes that
        # reuse actually exercise the alternate key - it stamps a fresh id
        # the first time and returns the SAME id on every later reuse of
        # that same hashtable reference.
        $providerMessageId = Set-StampedProviderMessageId -Msg $rm -Prefix 'DEMO'

        $msg = @{
            FromAddress = $rm.From; Subject = $rm.Subject; Body = $rm.Body
            CustomerName = $rm.CustomerName; ObjectNumber = $rm.ObjectNumber; Street = $rm.Street
            TradeValue = $rm.TradeValue; TradeLabel = $rm.TradeLabel
            ProviderMessageId = $providerMessageId
            NotARequest = ($scenario -eq 'not_a_request')
        }
        $messages.Add($msg)
    }
}

# --- Run ---------------------------------------------------------------------
$traces = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($m in $messages) {
    $i++
    $result = Invoke-ServiceIntakeMessage -OrgUrl $org -Msg $m
    Show-AnimatedResult -Result $result -Index $i -Total $messages.Count -Msg $m
    $traces.Add([ordered]@{
        index = $i
        input = $m
        stages = $result.stages
        finalStatus = $result.finalStatus
        finalDetail = $result.finalDetail
    })
}

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor DarkCyan
Write-Host " ZUSAMMENFASSUNG" -ForegroundColor White
Write-Host ("=" * 70) -ForegroundColor DarkCyan
foreach ($t in $traces) {
    $color = switch ($t.finalStatus) { 'Converted' { 'Green' }; 'Duplicate' { 'Red' }; default { 'Yellow' } }
    Write-Host ("  #{0}: {1,-20} {2}" -f $t.index, $t.finalStatus, $t.finalDetail) -ForegroundColor $color
}

$traceDir = Join-Path $PSScriptRoot '..\logs\demo-traces'
New-Item -ItemType Directory -Force -Path $traceDir | Out-Null
$traceFile = Join-Path $traceDir "trace-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$traces | ConvertTo-Json -Depth 10 | Set-Content -Path $traceFile -Encoding utf8
Write-Host ""
Write-Host "Trace gespeichert: $traceFile" -ForegroundColor DarkGray
Write-Output $traceFile
