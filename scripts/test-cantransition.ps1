<#
    .SYNOPSIS
        Integration test for the CanTransition plugin (Hsv.ServiceIntake.Plugins.CanTransitionPlugin).
        Proves the invalid-transition block is enforced by Dataverse itself
        (a direct Web API PATCH, bypassing any flow/UI), not just described.

    .DESCRIPTION
        On hsv_workorder: creates a record at Neu, attempts the invalid
        direct jump Neu -> Abgeschlossen (must be rejected), then the valid
        Neu -> Zugewiesen (must succeed).

        On hsv_inboundmessage: creates a record at Received, attempts the
        invalid jump Received -> Converted (must be rejected), then the
        valid Received -> Parsed (must succeed).

        Cleans up all test records it created (plain data, not metadata -
        the one kind of deletion this project allows).

        Writes tests/cantransition-report.md.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force

$config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

$report = New-Object System.Collections.Generic.List[string]
function Log($line) { Write-Output $line; $report.Add($line) | Out-Null }
$overallPass = $true

Log "# CanTransition Plugin Integration Test"
Log ""
Log "Run: $(Get-Date -Format 'yyyy-MM-dd HH:mm') (local)"
Log ""
Log "Tests Hsv.ServiceIntake.Plugins.CanTransitionPlugin, a Pre-Operation"
Log "Update plugin on hsv_workorder and hsv_inboundmessage. Every call here"
Log "is a direct Web API PATCH - proving the block is enforced by Dataverse"
Log "itself for any channel, not just a flow that a direct write could skip."
Log ""

function Get-Headers {
    @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
}

# --- Work Order: Neu -> Abgeschlossen (invalid), Neu -> Zugewiesen (valid) ---
Log "## hsv_workorder"
Log ""
$acct = Invoke-WebRequest -Uri "$org/api/data/v9.2/accounts" -Method Post -Headers (Get-Headers) -Body (@{ name='CANTRANSITION-TEST Account' } | ConvertTo-Json) -UseBasicParsing | ForEach-Object { $_.Content | ConvertFrom-Json }
$so = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_serviceobjects" -Method Post -Headers (Get-Headers) -Body (@{ hsv_name='CANTRANSITION-TEST Object'; 'hsv_Account@odata.bind'="/accounts($($acct.accountid))"; hsv_objectnumber='CANTRANSITION-TEST-001'; hsv_street='X'; hsv_postalcode='0'; hsv_city='X' } | ConvertTo-Json) -UseBasicParsing | ForEach-Object { $_.Content | ConvertFrom-Json }
$wo = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_workorders" -Method Post -Headers (Get-Headers) -Body (@{ hsv_title='CANTRANSITION-TEST WO'; 'hsv_Account@odata.bind'="/accounts($($acct.accountid))"; 'hsv_ServiceObject@odata.bind'="/hsv_serviceobjects($($so.hsv_serviceobjectid))"; hsv_trade=209710505; hsv_priority=209710601; hsv_status=209710101 } | ConvertTo-Json) -UseBasicParsing | ForEach-Object { $_.Content | ConvertFrom-Json }
$woId = $wo.hsv_workorderid
Log "[INFO] Test Work Order created at status Neu."

try {
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_workorders($woId)" -Body @{ hsv_status = 209710104 } | Out-Null
    Log "[FAIL] Invalid transition Neu -> Abgeschlossen was NOT blocked."
    $overallPass = $false
} catch {
    if ($_.Exception.Message -match 'INVALID_TRANSITION') {
        Log "[PASS] Invalid transition Neu -> Abgeschlossen blocked by the plugin (HTTP 400, Reason: INVALID_TRANSITION)."
    } else {
        Log "[FAIL] Blocked, but not for the expected reason: $($_.Exception.Message)"
        $overallPass = $false
    }
}

try {
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_workorders($woId)" -Body @{ hsv_status = 209710102 } | Out-Null
    Log "[PASS] Valid transition Neu -> Zugewiesen succeeded."
} catch {
    Log "[FAIL] Valid transition Neu -> Zugewiesen was blocked: $($_.Exception.Message)"
    $overallPass = $false
}

# --- Inbound Message: Received -> Converted (invalid), Received -> Parsed (valid) ---
Log ""
Log "## hsv_inboundmessage"
Log ""
$msgBody = @{
    hsv_name='CANTRANSITION-TEST Message'; hsv_providermessageid='CANTRANSITION-TEST-MSG-001'; hsv_correlationid=[guid]::NewGuid().ToString()
    hsv_receivedon=(Get-Date).ToUniversalTime().ToString('o'); hsv_fromaddress='cantransition-test@example.invalid'; hsv_hasattachments=$false
    hsv_status=209710001; hsv_extractionsource=209710701; hsv_requiresreview=$false; hsv_retrycount=0
}
$msg = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_inboundmessages" -Method Post -Headers (Get-Headers) -Body ($msgBody | ConvertTo-Json) -UseBasicParsing | ForEach-Object { $_.Content | ConvertFrom-Json }
$msgId = $msg.hsv_inboundmessageid
Log "[INFO] Test Inbound Message created at status Received."

try {
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($msgId)" -Body @{ hsv_status = 209710009 } | Out-Null
    Log "[FAIL] Invalid transition Received -> Converted was NOT blocked."
    $overallPass = $false
} catch {
    if ($_.Exception.Message -match 'INVALID_TRANSITION') {
        Log "[PASS] Invalid transition Received -> Converted blocked by the plugin (HTTP 400, Reason: INVALID_TRANSITION)."
    } else {
        Log "[FAIL] Blocked, but not for the expected reason: $($_.Exception.Message)"
        $overallPass = $false
    }
}

try {
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_inboundmessages($msgId)" -Body @{ hsv_status = 209710002 } | Out-Null
    Log "[PASS] Valid transition Received -> Parsed succeeded."
} catch {
    Log "[FAIL] Valid transition Received -> Parsed was blocked: $($_.Exception.Message)"
    $overallPass = $false
}

# --- Cleanup ---------------------------------------------------------------
Log ""
Log "## Cleanup"
Log ""
try {
    Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "hsv_inboundmessages($msgId)" | Out-Null
    Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "hsv_workorders($woId)" | Out-Null
    Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "hsv_serviceobjects($($so.hsv_serviceobjectid))" | Out-Null
    Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "accounts($($acct.accountid))" | Out-Null
    Log "[INFO] All test records deleted."
} catch {
    Log "[WARNING] Cleanup failed - remove test records manually. $($_.Exception.Message)"
}

Log ""
Log $(if ($overallPass) { "Result: PASS" } else { "Result: FAIL" })

$outPath = Join-Path $PSScriptRoot '..\tests\cantransition-report.md'
$report -join "`n" | Set-Content -Path $outPath -Encoding utf8
Write-Output ""
Write-Output "Report written to $outPath"
if (-not $overallPass) { exit 1 }
