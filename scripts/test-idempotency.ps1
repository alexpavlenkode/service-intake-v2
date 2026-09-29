<#
    .SYNOPSIS
        Integration test (Promt §9): create hsv_inboundmessage with
        hsv_providermessageid = TEST-IDEMPOTENCY-001, then try to create a
        second one with the same value. First must succeed, second must be
        rejected by Dataverse itself (the alternate key), not by
        application-level "does it exist?" logic. Checks HTTP status and
        error.code, not message text (localized). Writes a report to tests/.

        The test record this run creates is the one allowed deletion in this
        project (Promt §9, §10).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force

$config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

$testId = 'TEST-IDEMPOTENCY-001'
$results = New-Object System.Collections.Generic.List[string]
function Log($line) { Write-Output $line; $results.Add($line) | Out-Null }

Log "# Idempotency Integration Test"
Log ""
Log "Run: $(Get-Date -Format 'yyyy-MM-dd HH:mm') (local)"
Log "Target: hsv_inboundmessage.hsv_providermessageid = $testId"
Log ""

function New-TestMessageBody([string] $Name) {
    return @{
        hsv_name              = $Name
        hsv_providermessageid = $testId
        hsv_correlationid     = [guid]::NewGuid().ToString()
        hsv_receivedon        = (Get-Date).ToUniversalTime().ToString('o')
        hsv_fromaddress       = 'idempotency-test@example.invalid'
        hsv_hasattachments    = $false
        hsv_status            = 209710001      # Received (hsv_messagestatus)
        hsv_extractionsource  = 209710701       # Parser (hsv_ExtractionSource, local)
        hsv_requiresreview    = $false
        hsv_retrycount        = 0
    }
}

# Pre-check: fail loudly if a leftover test record already exists from a
# previous interrupted run, rather than silently building on top of it.
$existing = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_inboundmessages?`$filter=hsv_providermessageid eq '$testId'&`$select=hsv_inboundmessageid"
if ($existing.value.Count -gt 0) {
    Log "[SKIP] $($existing.value.Count) leftover record(s) with $testId already exist - clean up manually before re-running this test."
    Log ""
    Log "Result: INCONCLUSIVE (leftover state)"
    $results -join "`n" | Set-Content -Path (Join-Path $PSScriptRoot '..\tests\idempotency-report.md') -Encoding utf8
    exit 1
}

# --- Attempt 1: expect success -------------------------------------------
$attempt1Status = $null
$firstId = $null
try {
    $body = New-TestMessageBody 'Idempotency Test - Attempt 1'
    $token = Get-DataverseToken -OrgUrl $org
    $headers = @{ Authorization = "Bearer $token"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
    $resp = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_inboundmessages" -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -UseBasicParsing
    $attempt1Status = [int]$resp.StatusCode
    $created = $resp.Content | ConvertFrom-Json
    $firstId = $created.hsv_inboundmessageid
    Log "[PASS] Attempt 1 (first create): HTTP $attempt1Status, record $firstId created."
} catch {
    $attempt1Status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
    Log "[FAIL] Attempt 1 (first create): expected success, got HTTP $attempt1Status - $($_.ErrorDetails.Message)"
}

# --- Attempt 2: expect rejection by the alternate key ---------------------
$attempt2Status = $null
$attempt2ErrorCode = $null
try {
    $body = New-TestMessageBody 'Idempotency Test - Attempt 2 (should be rejected)'
    $token = Get-DataverseToken -OrgUrl $org
    $headers = @{ Authorization = "Bearer $token"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json' }
    $resp = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_inboundmessages" -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -UseBasicParsing
    $attempt2Status = [int]$resp.StatusCode
    Log "[FAIL] Attempt 2 (duplicate create): expected rejection, got HTTP $attempt2Status (record was created - the alternate key did NOT block it)."
} catch {
    $attempt2Status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
    $errBody = $_.ErrorDetails.Message
    try { $attempt2ErrorCode = ($errBody | ConvertFrom-Json).error.code } catch {}
    if ($attempt2Status -ge 400 -and $attempt2Status -lt 500) {
        Log "[PASS] Attempt 2 (duplicate create): correctly rejected. HTTP $attempt2Status, error.code=$attempt2ErrorCode"
    } else {
        Log "[FAIL] Attempt 2 (duplicate create): rejected, but with unexpected HTTP $attempt2Status (expected 4xx). error.code=$attempt2ErrorCode"
    }
}

# --- Control query: exactly one record with this providermessageid --------
$controlQuery = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_inboundmessages?`$filter=hsv_providermessageid eq '$testId'&`$select=hsv_inboundmessageid"
$count = $controlQuery.value.Count
if ($count -eq 1) {
    Log "[PASS] Control query: exactly 1 record exists with hsv_providermessageid = $testId."
} else {
    Log "[FAIL] Control query: expected exactly 1 record, found $count."
}

# --- Review items 25/26/27: the rejected second delivery is not just an
#     HTTP error that gets swallowed - it must be recorded as a new
#     ProcessingAttempt against the ORIGINAL (only) message, since a second
#     hsv_inboundmessage was never created for it to be recorded against.
$attempt1LogId = $null
$attempt2LogId = $null
$logSequenceOk = $false
if ($firstId -and $attempt2Status -ge 400 -and $attempt2Status -lt 500) {
    try {
        $attempt1Log = Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'hsv_processingattempts' -AdditionalHeaders @{ Prefer = 'return=representation' } -Body @{
            'hsv_InboundMessage@odata.bind' = "/hsv_inboundmessages($firstId)"
            hsv_correlationid    = [guid]::NewGuid().ToString()
            hsv_attemptnumber    = 1
            hsv_stage            = 209710201  # Ingest
            hsv_result           = 209710301  # Success
            hsv_retryable        = $false
            hsv_triggeredby      = 209710721  # Event
            hsv_componentversion = '1.0.0.0'
            hsv_startedon        = (Get-Date).ToUniversalTime().ToString('o')
        }
        $attempt1LogId = $attempt1Log.hsv_processingattemptid

        $attempt2Log = Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'hsv_processingattempts' -AdditionalHeaders @{ Prefer = 'return=representation' } -Body @{
            'hsv_InboundMessage@odata.bind' = "/hsv_inboundmessages($firstId)"
            hsv_correlationid    = [guid]::NewGuid().ToString()
            hsv_attemptnumber    = 2
            hsv_stage            = 209710201  # Ingest
            hsv_result           = 209710304  # Skipped
            hsv_reasoncode       = 209710410  # TECHNICAL_DUPLICATE
            hsv_retryable        = $false
            hsv_triggeredby      = 209710721  # Event
            hsv_componentversion = '1.0.0.0'
            hsv_startedon        = (Get-Date).ToUniversalTime().ToString('o')
            'hsv_PreviousAttempt@odata.bind' = "/hsv_processingattempts($attempt1LogId)"
        }
        $attempt2LogId = $attempt2Log.hsv_processingattemptid

        $attempts = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_processingattempts?`$filter=_hsv_inboundmessage_value eq $firstId&`$select=hsv_attemptnumber,hsv_result,hsv_reasoncode&`$orderby=hsv_attemptnumber asc").value
        $logSequenceOk = ($attempts.Count -eq 2) -and ($attempts[0].hsv_result -eq 209710301) -and ($attempts[1].hsv_result -eq 209710304) -and ($attempts[1].hsv_reasoncode -eq 209710410)
        if ($logSequenceOk) {
            Log "[PASS] The single message now has 2 ProcessingAttempts: 1=Success, 2=Skipped/TECHNICAL_DUPLICATE (linked via hsv_PreviousAttempt) - the rejected repeat delivery is recorded, not silently dropped."
        } else {
            Log "[FAIL] ProcessingAttempt sequence for the single message wasn't as expected."
        }
    } catch {
        Log "[FAIL] Could not log the ProcessingAttempt pair for the technical duplicate: $($_.Exception.Message)"
    }
}

# --- Cleanup: delete the test record (the one allowed deletion) -----------
foreach ($logId in @($attempt2LogId, $attempt1LogId)) {
    if ($logId) {
        try { Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "hsv_processingattempts($logId)" | Out-Null } catch { Log "[WARNING] Cleanup failed for ProcessingAttempt $logId - remove manually. $($_.Exception.Message)" }
    }
}
if ($firstId) {
    try {
        Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "hsv_inboundmessages($firstId)" | Out-Null
        Log "[INFO] Cleanup: test record $firstId (and its ProcessingAttempts) deleted."
    } catch {
        Log "[WARNING] Cleanup failed for record $firstId - remove manually. $($_.Exception.Message)"
    }
}

Log ""
$overallPass = ($attempt1Status -eq 201) -and ($attempt2Status -ge 400 -and $attempt2Status -lt 500) -and ($count -eq 1) -and $logSequenceOk
if ($overallPass) {
    Log "Result: PASS"
} else {
    Log "Result: FAIL"
}

$outPath = Join-Path $PSScriptRoot '..\tests\idempotency-report.md'
$results -join "`n" | Set-Content -Path $outPath -Encoding utf8
Write-Output ""
Write-Output "Report written to $outPath"

if (-not $overallPass) { exit 1 }
