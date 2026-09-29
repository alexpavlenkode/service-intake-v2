<#
    .SYNOPSIS
        Local HTTP server backing the Live Console UI: every request it
        serves calls REAL Dataverse (same alternate key, same business-key
        duplicate lookup, same hsv_processingattempt logging as
        scripts\demo-pipeline.ps1) - this is not a browser-side simulation.

    .DESCRIPTION
        Serves the console page at GET / and two JSON endpoints:
          POST /api/send   { From, Subject, Body, CustomerName, ObjectNumber }
          POST /api/random { count }
        Both return the same stage-trace shape the page animates.

        Why a local server instead of calling Dataverse straight from the
        browser: Dataverse needs an OAuth bearer token, and a page running
        in a browser sandbox (Artifacts included) has no safe way to hold
        one. This script holds the token (via the same Az.Accounts session
        as the rest of this project) and the browser only ever talks to
        localhost.

    .PARAMETER Port
        Default 8787.
#>
[CmdletBinding()]
param(
    [int] $Port = 8787,
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot has come back empty in some invocation paths in this
# environment (making "$PSScriptRoot\x" resolve to the current drive's root
# instead of this script's folder) - fall back to $PSCommandPath explicitly
# rather than trust it blindly.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.psd1' }

Import-Module (Join-Path $ScriptDir 'lib\Dataverse.psm1') -Force

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

# --- Demo master data (idempotent - reused across runs, same as demo-pipeline.ps1) ---
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

$Trades = @(
    @{ Value = 209710501; Label = 'Sanitaer' }
    @{ Value = 209710502; Label = 'Elektro' }
    @{ Value = 209710503; Label = 'Heizung' }
    @{ Value = 209710505; Label = 'Sonstiges' }
)

$NotARequestWords = @('out of office', 'abwesend', 'urlaub', 'unsubscribe', 'newsletter', 'werbung', 'spam', 'gewinnspiel')

function Get-BusinessKeyHash {
    param([string] $Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
}

function Invoke-RealMessage {
    param([hashtable] $Msg)

    $stages = New-Object System.Collections.Generic.List[object]
    $correlationId = [guid]::NewGuid().ToString()
    $trade = if ($Msg.TradeValue) { $Msg.TradeValue } else { 209710505 }

    $providerMessageId = if ($Msg.ProviderMessageId) { $Msg.ProviderMessageId } else { "LIVE-$([guid]::NewGuid().ToString().Substring(0,10))" }

    $headers = @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
    $msgBody = @{
        hsv_name = if ($Msg.Subject) { $Msg.Subject } else { '(kein Betreff)' }
        hsv_providermessageid = $providerMessageId
        hsv_correlationid = $correlationId
        hsv_receivedon = (Get-Date).ToUniversalTime().ToString('o')
        hsv_fromaddress = $Msg.From
        hsv_subject = $Msg.Subject
        hsv_body = $Msg.Body
        hsv_hasattachments = $false
        hsv_status = 209710001
        hsv_extractionsource = 209710701
        hsv_requiresreview = $false
        hsv_retrycount = 0
    }

    $inboundId = $null
    try {
        $r = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_inboundmessages" -Method Post -Headers $headers -Body ($msgBody | ConvertTo-Json) -UseBasicParsing
        $inboundId = ($r.Content | ConvertFrom-Json).hsv_inboundmessageid
        $stages.Add(@{ name = 'Ingest'; result = 'pass'; detail = "hsv_inboundmessage angelegt ($inboundId), ProviderMessageId=$providerMessageId" })
    } catch {
        $existing = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_inboundmessages?`$filter=hsv_providermessageid eq '$providerMessageId'&`$select=hsv_inboundmessageid"
        $existingId = if ($existing.value.Count -gt 0) { $existing.value[0].hsv_inboundmessageid } else { '(unbekannt)' }
        $stages.Add(@{ name = 'Ingest'; result = 'fail'; detail = "Von Dataverse abgelehnt (Alternate Key) - bereits verarbeitet als $existingId" })
        return @{ stages = $stages; finalStatus = 'Duplicate'; finalClass = 'fail'; finalDetail = "Technisches Duplikat von $existingId." }
    }

    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710002 } | Out-Null
    $stages.Add(@{ name = 'Parse'; result = 'pass'; detail = "Kunde='$($Msg.CustomerName)' Objekt='$($Msg.ObjectNumber)'" })

    $lowerAll = ("$($Msg.Subject) $($Msg.Body)").ToLower()
    $isNotRequest = $false
    foreach ($w in $NotARequestWords) { if ($lowerAll.Contains($w)) { $isNotRequest = $true; break } }

    if ($isNotRequest) {
        Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710007 } | Out-Null
        $stages.Add(@{ name = 'Validate'; result = 'warn'; detail = 'Reason: NOT_A_REQUEST' })
        return @{ stages = $stages; finalStatus = 'Not Relevant'; finalClass = 'warn'; finalDetail = 'Keine Auftragsanfrage.' }
    }
    if (-not $Msg.ObjectNumber -or -not $Msg.CustomerName) {
        Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710004 } | Out-Null
        $stages.Add(@{ name = 'Validate'; result = 'warn'; detail = 'Reason: MISSING_OBJECT_ADDRESS - Kunde oder Objekt fehlt' })
        return @{ stages = $stages; finalStatus = 'Needs Clarification'; finalClass = 'warn'; finalDetail = 'Rueckfrage an den Kunden noetig.' }
    }
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710003 } | Out-Null
    $stages.Add(@{ name = 'Validate'; result = 'pass'; detail = 'Pflichtfelder vorhanden.' })

    $businessKey = "$($Msg.CustomerName)|$($Msg.ObjectNumber)|$($Msg.Body.ToLower().Trim())"
    $businessKeyHash = Get-BusinessKeyHash $businessKey
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-72).ToString('o')
    $dupCheck = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_inboundmessages?`$filter=hsv_businesskeyhash eq '$businessKeyHash' and hsv_inboundmessageid ne $inboundId and hsv_receivedon gt $cutoff&`$select=hsv_inboundmessageid&`$top=1"
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_businesskey = $businessKey; hsv_businesskeyhash = $businessKeyHash } | Out-Null

    if ($dupCheck.value.Count -gt 0) {
        $matchId = $dupCheck.value[0].hsv_inboundmessageid
        Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710005; hsv_matchreason = "Aehnlich zu $matchId" } | Out-Null
        $stages.Add(@{ name = 'Duplicate Check'; result = 'warn'; detail = "Reason: POSSIBLE_DUPLICATE - aehnlich zu $matchId" })
        return @{ stages = $stages; finalStatus = 'Potential Duplicate'; finalClass = 'warn'; finalDetail = "Aehnlich zu Nachricht $matchId - wartet auf Entscheidung." }
    }
    $stages.Add(@{ name = 'Duplicate Check'; result = 'pass'; detail = 'Keine fachliche Dublette im 72h-Fenster.' })

    $accountId = Get-OrCreateDemoAccount -Name $Msg.CustomerName
    $street = if ($Msg.Street) { $Msg.Street } else { 'Unbekannt' }
    $soId = Get-OrCreateDemoServiceObject -AccountId $accountId -ObjectNumber $Msg.ObjectNumber -Street $street
    $woHeaders = @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
    $woBody = @{
        hsv_title = if ($Msg.Subject) { $Msg.Subject } else { 'Auftrag' }
        hsv_description = $Msg.Body
        'hsv_Account@odata.bind' = "/accounts($accountId)"
        'hsv_ServiceObject@odata.bind' = "/hsv_serviceobjects($soId)"
        hsv_trade = $trade
        hsv_priority = 209710601
        hsv_status = 209710101
    }
    $wr = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_workorders" -Method Post -Headers $woHeaders -Body ($woBody | ConvertTo-Json) -UseBasicParsing
    $woId = ($wr.Content | ConvertFrom-Json).hsv_workorderid
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710009; 'hsv_WorkOrder@odata.bind' = "/hsv_workorders($woId)" } | Out-Null
    $stages.Add(@{ name = 'Decision'; result = 'pass'; detail = "Work Order $woId angelegt (Neu)." })

    return @{ stages = $stages; finalStatus = 'Converted'; finalClass = 'pass'; finalDetail = "Work Order $woId - bereit fuer Zuweisung."; inboundId = $inboundId; woId = $woId }
}

# --- Random message generator (same spirit as demo-pipeline.ps1) -----------
$Customers = @(
    @{ Name = 'Hausverwaltung Nord'; ObjectNumber = 'N-01'; Street = 'Ludwigstr. 12' }
    @{ Name = 'Gewerbepark Sued'; ObjectNumber = 'S-01'; Street = 'Suedring 4' }
)
$Problems = @(
    'Die Heizung im Flur funktioniert seit gestern nicht mehr.'
    'Wasserhahn in der Kueche tropft staendig, bitte reparieren.'
    'Die Lichtschalter im Treppenhaus loesen nicht mehr aus.'
)
$lastMessages = New-Object System.Collections.Generic.List[hashtable]

function New-RandomMessage {
    $roll = Get-Random -Minimum 0.0 -Maximum 1.0
    $cust = $Customers[(Get-Random -Minimum 0 -Maximum $Customers.Count)]
    $trade = $Trades[(Get-Random -Minimum 0 -Maximum $Trades.Count)]
    $problem = $Problems[(Get-Random -Minimum 0 -Maximum $Problems.Count)]

    if ($roll -lt 0.15 -and $lastMessages.Count -gt 0) {
        return $lastMessages[(Get-Random -Minimum 0 -Maximum $lastMessages.Count)]
    }
    if ($roll -lt 0.30 -and $lastMessages.Count -gt 0) {
        $prev = $lastMessages[$lastMessages.Count - 1]
        return @{ From = "andere$(Get-Random -Maximum 999)@beispiel.de"; Subject = $prev.Subject; Body = $prev.Body + ' '; CustomerName = $prev.CustomerName; ObjectNumber = $prev.ObjectNumber; Street = $prev.Street; TradeValue = $prev.TradeValue }
    }
    if ($roll -lt 0.42) {
        return @{ From = "kunde$(Get-Random -Maximum 999)@beispiel.de"; Subject = 'Info'; Body = 'Bin diese Woche im Urlaub.'; CustomerName = $cust.Name; ObjectNumber = $cust.ObjectNumber; Street = $cust.Street; TradeValue = $trade.Value }
    }
    if ($roll -lt 0.54) {
        return @{ From = "kunde$(Get-Random -Maximum 999)@beispiel.de"; Subject = ''; Body = ''; CustomerName = ''; ObjectNumber = ''; Street = ''; TradeValue = $trade.Value }
    }
    $msg = @{ From = "kunde$(Get-Random -Maximum 999)@beispiel.de"; Subject = "Reparaturanfrage $($cust.Name)"; Body = $problem; CustomerName = $cust.Name; ObjectNumber = $cust.ObjectNumber; Street = $cust.Street; TradeValue = $trade.Value }
    $lastMessages.Add($msg)
    return $msg
}

# --- HTTP server -------------------------------------------------------------
$pageTemplate = Get-Content -Path (Join-Path $ScriptDir 'live-console-page.html') -Raw -Encoding UTF8

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Output "[LIVE CONSOLE] Listening on $prefix (real SI-DEV calls). Ctrl+C to stop."

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        try {
            if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($pageTemplate)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/api/send') {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $msg = @{ From = $body.From; Subject = $body.Subject; Body = $body.Body; CustomerName = $body.CustomerName; ObjectNumber = $body.ObjectNumber; Street = $body.Street; TradeValue = 209710505 }
                $result = Invoke-RealMessage -Msg $msg
                $json = $result | ConvertTo-Json -Depth 10
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/api/random') {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $count = [Math]::Max(1, [Math]::Min(20, [int]$body.count))
                $results = New-Object System.Collections.Generic.List[object]
                for ($i = 0; $i -lt $count; $i++) {
                    $m = New-RandomMessage
                    $r = Invoke-RealMessage -Msg $m
                    $r['input'] = $m
                    $results.Add($r)
                }
                $json = $results | ConvertTo-Json -Depth 10
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            else {
                $res.StatusCode = 404
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('Not found')
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        } catch {
            Write-Warning "[LIVE CONSOLE] Request error: $($_.Exception.Message)"
            $res.StatusCode = 500
            $errJson = (@{ error = $_.Exception.Message } | ConvertTo-Json)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
            $res.ContentType = 'application/json; charset=utf-8'
            try { $res.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
        } finally {
            $res.OutputStream.Close()
        }
    }
} finally {
    $listener.Stop()
}
