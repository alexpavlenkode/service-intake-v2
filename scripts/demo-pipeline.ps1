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

function Animate-Stage {
    param([string[]] $StatusArray, [int] $Index, [string] $FinalStatus, [string] $Detail)
    $StatusArray[$Index] = 'Active'
    Write-Pipeline $StatusArray
    Start-Sleep -Milliseconds 500
    $StatusArray[$Index] = $FinalStatus
    Write-Pipeline $StatusArray
    if ($Detail) { Write-Host "    -> $Detail" -ForegroundColor Gray }
    Start-Sleep -Milliseconds 300
}

# --- Demo master data (idempotent - reused across runs) --------------------
function Get-OrCreateDemoAccount {
    param([string] $Name)
    $existing = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "accounts?`$select=accountid&`$filter=name eq 'DEMO $Name'"
    if ($existing.value.Count -gt 0) { return $existing.value[0].accountid }
    $headers = @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
    $r = Invoke-WebRequest -Uri "$org/api/data/v9.2/accounts" -Method Post -Headers $headers -Body (@{ name = "DEMO $Name" } | ConvertTo-Json) -UseBasicParsing
    return ($r.Content | ConvertFrom-Json).accountid
}

function Get-OrCreateDemoServiceObject {
    param([string] $AccountId, [string] $ObjectNumber, [string] $Street)
    $existing = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_serviceobjects?`$select=hsv_serviceobjectid&`$filter=hsv_objectnumber eq '$ObjectNumber'"
    if ($existing.value.Count -gt 0) { return $existing.value[0].hsv_serviceobjectid }
    $headers = @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
    $body = @{ hsv_name = "DEMO Object $ObjectNumber"; 'hsv_Account@odata.bind' = "/accounts($AccountId)"; hsv_objectnumber = $ObjectNumber; hsv_street = $Street; hsv_postalcode = '04109'; hsv_city = 'Leipzig' }
    $r = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_serviceobjects" -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -UseBasicParsing
    return ($r.Content | ConvertFrom-Json).hsv_serviceobjectid
}

$DemoCustomers = @(
    @{ Name = 'Hausverwaltung Nord';  ObjectNumber = 'N-01'; Street = 'Ludwigstr. 12' }
    @{ Name = 'Hausverwaltung Nord';  ObjectNumber = 'N-02'; Street = 'Ludwigstr. 30' }
    @{ Name = 'Gewerbepark Sued';     ObjectNumber = 'S-01'; Street = 'Suedring 4' }
)

$Trades = @(
    @{ Value = 209710501; Label = 'Sanitaer' }
    @{ Value = 209710502; Label = 'Elektro' }
    @{ Value = 209710503; Label = 'Heizung' }
)

function New-CorrelationLog {
    param([string] $MessageId, [string] $CorrelationId, [int] $AttemptNumber, [int] $Stage, [int] $Result, [string] $ReasonCode)
    $body = @{
        hsv_inboundmessage = $MessageId
        'hsv_InboundMessage@odata.bind' = "/hsv_inboundmessages($MessageId)"
        hsv_correlationid = $CorrelationId
        hsv_attemptnumber = $AttemptNumber
        hsv_stage = $Stage
        hsv_result = $Result
        hsv_retryable = $false
        hsv_triggeredby = 209710721  # Event
        hsv_componentversion = '1.0.0.0'
        hsv_startedon = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($ReasonCode) { $body['hsv_reasoncode'] = $ReasonCode }
    $body.Remove('hsv_inboundmessage')
    Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'hsv_processingattempts' -Body $body | Out-Null
}

# hsv_stage values
$StageIngest = 209710201; $StageParse = 209710202; $StageValidate = 209710203; $StageDupCheck = 209710204; $StageCreate = 209710205
# hsv_result values
$ResultSuccess = 209710301; $ResultBusinessException = 209710302
# hsv_reasoncode values
$ReasonMissingAddr = 209710401; $ReasonUnknownCustomer = 209710402; $ReasonNotARequest = 209710403; $ReasonPossibleDup = 209710404

function Invoke-DemoMessage {
    param([hashtable] $Msg, [int] $Index, [int] $Total)

    $trace = [ordered]@{
        index = $Index
        input = $Msg
        stages = @()
        finalStatus = $null
        finalDetail = $null
    }

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host " Nachricht $Index/$Total : von $($Msg.FromAddress)" -ForegroundColor White
    Write-Host " Betreff: $($Msg.Subject)" -ForegroundColor White
    Write-Host ("=" * 70) -ForegroundColor DarkCyan

    $status = @('Pending','Pending','Pending','Pending','Pending')
    $correlationId = [guid]::NewGuid().ToString()

    # --- Stage 0: Ingest ----------------------------------------------------
    Animate-Stage $status 0 'Active' $null
    $headers = @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
    $msgBody = @{
        hsv_name = $Msg.Subject
        hsv_providermessageid = $Msg.ProviderMessageId
        hsv_correlationid = $correlationId
        hsv_receivedon = (Get-Date).ToUniversalTime().ToString('o')
        hsv_fromaddress = $Msg.FromAddress
        hsv_subject = $Msg.Subject
        hsv_body = $Msg.Body
        hsv_hasattachments = $false
        hsv_status = 209710001  # Received
        hsv_extractionsource = 209710701  # Parser
        hsv_requiresreview = $false
        hsv_retrycount = 0
    }

    $inboundId = $null
    try {
        $r = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_inboundmessages" -Method Post -Headers $headers -Body ($msgBody | ConvertTo-Json) -UseBasicParsing
        $inboundId = ($r.Content | ConvertFrom-Json).hsv_inboundmessageid
        $status[0] = 'Pass'
        Write-Pipeline $status
        Write-Host "    -> Nachricht angelegt (ID $inboundId), ProviderMessageId=$($Msg.ProviderMessageId)" -ForegroundColor Gray
        $trace.stages += @{ name = 'Ingest'; result = 'Pass'; detail = "hsv_inboundmessage created ($inboundId)" }
        New-CorrelationLog -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $StageIngest -Result $ResultSuccess
    } catch {
        $status[0] = 'Fail'
        Write-Pipeline $status
        $existing = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_inboundmessages?`$filter=hsv_providermessageid eq '$($Msg.ProviderMessageId)'&`$select=hsv_inboundmessageid"
        $existingId = if ($existing.value.Count -gt 0) { $existing.value[0].hsv_inboundmessageid } else { '(unknown)' }
        Write-Host "    -> TECHNISCHES DUPLIKAT: ProviderMessageId '$($Msg.ProviderMessageId)' bereits verarbeitet (Record $existingId)." -ForegroundColor Yellow
        Write-Host "    -> Dataverse selbst hat abgelehnt (Alternate Key) - keine Anwendungslogik noetig." -ForegroundColor DarkGray
        $trace.stages += @{ name = 'Ingest'; result = 'Duplicate'; detail = "Rejected by alternate key - already exists as $existingId" }
        $trace.finalStatus = 'Duplicate'
        $trace.finalDetail = "Provider-ID bereits verarbeitet ($existingId)"
        return $trace
    }

    # --- Stage 1: Parse ------------------------------------------------------
    Animate-Stage $status 1 'Active' $null
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710002 } | Out-Null  # Parsed
    New-CorrelationLog -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $StageParse -Result $ResultSuccess
    $status[1] = 'Pass'
    Write-Pipeline $status
    Write-Host "    -> Kunde='$($Msg.CustomerName)' Objekt='$($Msg.ObjectNumber)' Gewerk=$($Msg.TradeLabel)" -ForegroundColor Gray
    $trace.stages += @{ name = 'Parse'; result = 'Pass'; detail = "Customer=$($Msg.CustomerName), Object=$($Msg.ObjectNumber), Trade=$($Msg.TradeLabel)" }

    # --- Stage 2: Validate -----------------------------------------------------
    Animate-Stage $status 2 'Active' $null
    if ($Msg.NotARequest) {
        Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710007 } | Out-Null  # Not Relevant
        New-CorrelationLog -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $StageValidate -Result $ResultBusinessException -ReasonCode $ReasonNotARequest
        $status[2] = 'Warn'
        Write-Pipeline $status
        Write-Host "    -> NICHT ZUSTAENDIG: keine Auftragsanfrage (Reason: NOT_A_REQUEST)" -ForegroundColor Yellow
        $trace.stages += @{ name = 'Validate'; result = 'NotRelevant'; detail = 'NOT_A_REQUEST' }
        $trace.finalStatus = 'Not Relevant'
        $trace.finalDetail = 'Nachricht ist keine Auftragsanfrage.'
        return $trace
    }
    if (-not $Msg.ObjectNumber) {
        Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710004 } | Out-Null  # Needs Clarification
        New-CorrelationLog -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $StageValidate -Result $ResultBusinessException -ReasonCode $ReasonMissingAddr
        $status[2] = 'Warn'
        Write-Pipeline $status
        Write-Host "    -> KLAERUNGSQUEUE: Objektadresse fehlt (Reason: MISSING_OBJECT_ADDRESS)" -ForegroundColor Yellow
        $trace.stages += @{ name = 'Validate'; result = 'NeedsClarification'; detail = 'MISSING_OBJECT_ADDRESS' }
        $trace.finalStatus = 'Needs Clarification'
        $trace.finalDetail = 'Objektadresse fehlt - Rueckfrage an den Kunden noetig.'
        return $trace
    }
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710003 } | Out-Null  # Validated
    New-CorrelationLog -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $StageValidate -Result $ResultSuccess
    $status[2] = 'Pass'
    Write-Pipeline $status
    $trace.stages += @{ name = 'Validate'; result = 'Pass'; detail = 'All required fields present' }

    # --- Stage 3: Duplicate check (business key) ------------------------------
    Animate-Stage $status 3 'Active' $null
    $businessKey = "$($Msg.CustomerName)|$($Msg.ObjectNumber)|$($Msg.Problem.ToLower().Trim())"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($businessKey))
    $businessKeyHash = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()

    $cutoff = (Get-Date).ToUniversalTime().AddHours(-72).ToString('o')
    $dupCheck = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_inboundmessages?`$filter=hsv_businesskeyhash eq '$businessKeyHash' and hsv_inboundmessageid ne $inboundId and hsv_receivedon gt $cutoff&`$select=hsv_inboundmessageid,hsv_name&`$top=1"

    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_businesskey = $businessKey; hsv_businesskeyhash = $businessKeyHash } | Out-Null

    if ($dupCheck.value.Count -gt 0) {
        $matchId = $dupCheck.value[0].hsv_inboundmessageid
        Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710005; hsv_matchreason = "Gleicher Kunde/Objekt/Inhalt wie Nachricht $matchId innerhalb 72h" } | Out-Null  # Potential Duplicate
        New-CorrelationLog -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $StageDupCheck -Result $ResultBusinessException -ReasonCode $ReasonPossibleDup
        $status[3] = 'Warn'
        Write-Pipeline $status
        Write-Host "    -> POTENZIELLE DUBLETTE: aehnlich zu Nachricht $matchId (Reason: POSSIBLE_DUPLICATE)" -ForegroundColor Yellow
        Write-Host "    -> Wartet auf Entscheidung des Disponenten - wird NICHT automatisch verworfen." -ForegroundColor DarkGray
        $trace.stages += @{ name = 'Duplicate Check'; result = 'PotentialDuplicate'; detail = "Matches $matchId - POSSIBLE_DUPLICATE" }
        $trace.finalStatus = 'Potential Duplicate'
        $trace.finalDetail = "Aehnlich zu Nachricht $matchId - wartet auf menschliche Entscheidung."
        return $trace
    }
    $status[3] = 'Pass'
    Write-Pipeline $status
    Write-Host "    -> keine fachliche Dublette im 72h-Fenster gefunden" -ForegroundColor Gray
    $trace.stages += @{ name = 'Duplicate Check'; result = 'Pass'; detail = 'No business-key match in 72h window' }

    # --- Stage 4: Decision / Create Work Order --------------------------------
    Animate-Stage $status 4 'Active' $null
    $accountId = Get-OrCreateDemoAccount -Name $Msg.CustomerName
    $soId = Get-OrCreateDemoServiceObject -AccountId $accountId -ObjectNumber $Msg.ObjectNumber -Street $Msg.Street

    $woHeaders = @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
    $woBody = @{
        hsv_title = $Msg.Subject
        hsv_description = $Msg.Body
        'hsv_Account@odata.bind' = "/accounts($accountId)"
        'hsv_ServiceObject@odata.bind' = "/hsv_serviceobjects($soId)"
        hsv_trade = $Msg.TradeValue
        hsv_priority = 209710601  # Standard
        hsv_status = 209710101    # Neu
    }
    $wr = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_workorders" -Method Post -Headers $woHeaders -Body ($woBody | ConvertTo-Json) -UseBasicParsing
    $woId = ($wr.Content | ConvertFrom-Json).hsv_workorderid

    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710009; 'hsv_WorkOrder@odata.bind' = "/hsv_workorders($woId)" } | Out-Null  # Converted
    New-CorrelationLog -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $StageCreate -Result $ResultSuccess

    $status[4] = 'Pass'
    Write-Pipeline $status
    Write-Host "    -> AUFTRAG ANGELEGT: Work Order $woId (Status: Neu)" -ForegroundColor Green
    $trace.stages += @{ name = 'Decision'; result = 'Converted'; detail = "Work Order $woId created" }
    $trace.finalStatus = 'Converted'
    $trace.finalDetail = "Work Order $woId (Neu) - bereit fuer Zuweisung."

    return $trace
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
        ObjectNumber = $objNum; Street = 'Teststrasse'; Problem = $body
        TradeValue = $trade.Value; TradeLabel = $trade.Label
        ProviderMessageId = "DEMO-$([guid]::NewGuid().ToString().Substring(0,8))"
        NotARequest = $false
    })
} else {
    $scenarios = @('clean', 'clean', 'missing_field', 'potential_duplicate', 'technical_duplicate', 'not_a_request')
    $lastCleanKey = $null
    for ($i = 0; $i -lt $Random; $i++) {
        $cust = $DemoCustomers[(Get-Random -Minimum 0 -Maximum $DemoCustomers.Count)]
        $trade = $Trades[(Get-Random -Minimum 0 -Maximum $Trades.Count)]
        $scenario = $scenarios[(Get-Random -Minimum 0 -Maximum $scenarios.Count)]
        $problem = "$($trade.Label) Problem im Objekt $($cust.ObjectNumber)"

        $msg = @{
            FromAddress = "kunde$i@example.invalid"
            Subject = "Reparaturanfrage: $($trade.Label)"
            Body = $problem
            CustomerName = $cust.Name
            ObjectNumber = $cust.ObjectNumber
            Street = $cust.Street
            Problem = $problem
            TradeValue = $trade.Value
            TradeLabel = $trade.Label
            ProviderMessageId = "DEMO-$([guid]::NewGuid().ToString().Substring(0,8))"
            NotARequest = $false
        }

        switch ($scenario) {
            'missing_field' { $msg.ObjectNumber = $null }
            'not_a_request' { $msg.NotARequest = $true; $msg.Subject = 'Out of Office'; $msg.Body = 'Ich bin bis naechste Woche nicht erreichbar.' }
            'technical_duplicate' {
                if ($lastCleanKey) { $msg.ProviderMessageId = $lastCleanKey }
            }
            'potential_duplicate' {
                # Same customer/object/problem as a previous clean message -> business-key match, different provider id.
                if ($lastCleanKey) {
                    $msg.CustomerName = $script:lastCleanCustomer
                    $msg.ObjectNumber = $script:lastCleanObject
                    $msg.Problem = $script:lastCleanProblem
                    $msg.Body = $script:lastCleanProblem
                }
            }
        }
        if ($scenario -eq 'clean') {
            $lastCleanKey = $msg.ProviderMessageId
            $script:lastCleanCustomer = $msg.CustomerName
            $script:lastCleanObject = $msg.ObjectNumber
            $script:lastCleanProblem = $msg.Problem
        }
        $messages.Add($msg)
    }
}

# --- Run ---------------------------------------------------------------------
$traces = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($m in $messages) {
    $i++
    $traces.Add((Invoke-DemoMessage -Msg $m -Index $i -Total $messages.Count))
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
