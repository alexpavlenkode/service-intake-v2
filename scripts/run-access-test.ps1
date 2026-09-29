<#
    .SYNOPSIS
        Row-level security access test (item 13 of the roadmap). Proves the
        HSV Techniker role's User-depth scoping on hsv_workorder, and its
        "kein Zugriff" on hsv_inboundmessage, are actually enforced by
        Dataverse - not just configured.

    .DESCRIPTION
        SI-DEV is a Developer Plan environment with exactly one licensed
        interactive human user, so a second real user session isn't
        available. This test proves the same security boundary via
        CallerObjectId impersonation of a Dataverse Application User
        ("Test Techniker B", created by scripts/create-test-appuser.ps1)
        instead of two browser sessions. What CallerObjectId impersonation
        DOES prove: the exact same security-privilege evaluation path
        Dataverse uses for every caller, API or UI, runs for this identity
        too - it is not a UI-only or API-only check. What it can NOT show:
        an actual second browser session hitting a direct record URL (no
        second license available) - flagged, not glossed over, in the
        report.

        Steps:
          1. Create a throwaway Account + hsv_serviceobject + hsv_workorder,
             owned by the caller (Alex, System Administrator).
          2. As Techniker B (CallerObjectId): GET the work order by GUID -
             expect denial (404, not a silent empty success).
          3. As Techniker B: GET hsv_workorders filtered to that GUID -
             expect an empty result set (not an error - Dataverse applies
             security filtering silently to list queries).
          4. As Techniker B: GET hsv_inboundmessages (any) - expect empty,
             the role has zero privileges on this entity at all.
          5. Reassign the work order's owner to Techniker B (an Assign
             operation, which is exactly why HSV Disponent's role includes
             the inferred Assign privilege - see schema/security.yaml).
          6. As Techniker B: GET the same work order by GUID again - expect
             success this time.
          6b. As Techniker B (now owner): perform the valid transition
              Neu -> Zugewiesen - expect success. This specifically caught a
              real bug: CanTransitionPlugin originally queried
              hsv_statustransition as the calling user, and Techniker has
              zero privileges on that table - so even a VALID transition by
              the record's own owner failed with an access-rights error
              before the plugin could evaluate the actual rule. Fixed by
              running that internal lookup as SYSTEM (see
              docs/architecture.md).
          6c. As Techniker B: attempt the invalid transition
              Zugewiesen -> Abgeschlossen (skipping In Arbeit) - expect it
              blocked for the business rule (INVALID_TRANSITION), not an
              access-rights error.
          7. Clean up the test data (Account/hsv_serviceobject/hsv_workorder
             - plain records, not metadata, so deletion is fine here).

        Writes tests/access-test-report.md.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force

$config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

$callerObjectId = 'aaaf39cf-3e02-4415-b3e0-f5ce9d7a5301'  # Test Techniker B's service principal object id
$technikerBSystemUserId = '05c39ff0-8ebb-f111-aaad-002248d8a892'

$report = New-Object System.Collections.Generic.List[string]
function Log($line) { Write-Output $line; $report.Add($line) | Out-Null }

Log "# Row-Level Security Access Test"
Log ""
Log "Run: $(Get-Date -Format 'yyyy-MM-dd HH:mm') (local)"
Log ""
Log "**Setup note**: SI-DEV is a Developer Plan environment with exactly one"
Log "licensed interactive human user. A second real browser session isn't"
Log "available, so this test impersonates a Dataverse Application User"
Log "('Test Techniker B', role HSV Techniker) via the Web API's"
Log "\`CallerObjectId\` header instead. This exercises the identical"
Log "privilege-evaluation path Dataverse uses for every caller - it does"
Log "NOT demonstrate an actual second browser hitting a direct record URL,"
Log "since no second license exists to do that with."
Log ""

# --- 1. Create test data as the caller (System Administrator, owner A) ---
$accountBody = @{ name = 'ACCESS-TEST Account' }
$account = $null
try {
    $token = Get-DataverseToken -OrgUrl $org
    $headers = @{ Authorization = "Bearer $token"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
    $resp = Invoke-WebRequest -Uri "$org/api/data/v9.2/accounts" -Method Post -Headers $headers -Body ($accountBody | ConvertTo-Json) -UseBasicParsing
    $account = $resp.Content | ConvertFrom-Json
    Log "[INFO] Test Account created: $($account.accountid)"
} catch {
    Log "[FAIL] Could not create test Account: $($_.Exception.Message)"
    $report -join "`n" | Set-Content -Path (Join-Path $PSScriptRoot '..\tests\access-test-report.md') -Encoding utf8
    exit 1
}

$soBody = @{
    hsv_name = 'ACCESS-TEST Object'
    'hsv_Account@odata.bind' = "/accounts($($account.accountid))"
    hsv_objectnumber = 'ACCESS-TEST-001'
    hsv_street = 'Teststrasse 1'
    hsv_postalcode = '00000'
    hsv_city = 'Testort'
}
$headers2 = @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
$soResp = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_serviceobjects" -Method Post -Headers $headers2 -Body ($soBody | ConvertTo-Json) -UseBasicParsing
$serviceObject = $soResp.Content | ConvertFrom-Json
Log "[INFO] Test Service Object created: $($serviceObject.hsv_serviceobjectid)"

$woBody = @{
    hsv_title = 'ACCESS-TEST Work Order'
    'hsv_Account@odata.bind' = "/accounts($($account.accountid))"
    'hsv_ServiceObject@odata.bind' = "/hsv_serviceobjects($($serviceObject.hsv_serviceobjectid))"
    hsv_trade = 209710505      # Sonstiges
    hsv_priority = 209710601   # Standard
    hsv_status = 209710101     # Neu
}
$headers3 = @{ Authorization = "Bearer $(Get-DataverseToken -OrgUrl $org)"; Accept='application/json'; 'OData-MaxVersion'='4.0'; 'OData-Version'='4.0'; 'Content-Type'='application/json'; Prefer='return=representation' }
$woResp = Invoke-WebRequest -Uri "$org/api/data/v9.2/hsv_workorders" -Method Post -Headers $headers3 -Body ($woBody | ConvertTo-Json) -UseBasicParsing
$workOrder = $woResp.Content | ConvertFrom-Json
$woId = $workOrder.hsv_workorderid
Log "[INFO] Test Work Order created: $woId (owned by System Administrator, owner A)"
Log ""

# --- 2. As Techniker B: GET by GUID before reassignment - expect denial --
Log "## Before reassignment (Work Order owned by Owner A)"
Log ""
try {
    Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_workorders($woId)" -CallerObjectId $callerObjectId | Out-Null
    Log "[FAIL] Techniker B could read the work order by GUID before owning it - expected denial."
} catch {
    if ($_.Exception.Message -match 'HTTP (403|404)') {
        Log "[PASS] Techniker B denied reading the work order by GUID directly (HTTP $($Matches[1]) - explicit access-rights denial, not a silent empty success)."
    } else {
        Log "[FAIL] Unexpected error reading by GUID: $($_.Exception.Message)"
    }
}

# --- 3. As Techniker B: filtered list query - expect empty, not an error -
try {
    $filtered = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_workorders?`$filter=hsv_workorderid eq $woId" -CallerObjectId $callerObjectId
    if ($filtered.value.Count -eq 0) {
        Log "[PASS] Techniker B's filtered list query for the same GUID returns 0 rows (silent security filtering, not an error)."
    } else {
        Log "[FAIL] Techniker B's filtered list query unexpectedly returned $($filtered.value.Count) row(s)."
    }
} catch {
    Log "[FAIL] Filtered list query threw instead of returning empty: $($_.Exception.Message)"
}

# --- 4. As Techniker B: hsv_inboundmessage - expect zero access at all ---
try {
    $msgs = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_inboundmessages?`$select=hsv_inboundmessageid&`$top=1" -CallerObjectId $callerObjectId
    if ($msgs.value.Count -eq 0) {
        Log "[PASS] Techniker B sees 0 hsv_inboundmessage rows (role has no privilege on this table at all)."
    } else {
        Log "[FAIL] Techniker B unexpectedly saw $($msgs.value.Count) hsv_inboundmessage row(s)."
    }
} catch {
    # A hard denial (403/404) is also an acceptable proof of zero access,
    # not just an empty list - both outcomes mean "cannot see the data".
    if ($_.Exception.Message -match 'HTTP (403|404)') {
        Log "[PASS] Techniker B denied outright on hsv_inboundmessage (HTTP $($Matches[1]) - role has no privilege on this table)."
    } else {
        Log "[FAIL] Unexpected error querying hsv_inboundmessage: $($_.Exception.Message)"
    }
}

# --- 5. Reassign the work order to Techniker B (Assign operation) --------
Log ""
Log "## Reassigning Owner: A -> Techniker B"
Log ""
$reassignBody = @{ 'ownerid@odata.bind' = "/systemusers($technikerBSystemUserId)" }
Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_workorders($woId)" -Body $reassignBody | Out-Null
Log "[INFO] Owner changed to Techniker B."

# --- 6. As Techniker B: GET by GUID after reassignment - expect success --
try {
    $afterReassign = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_workorders($woId)?`$select=hsv_title" -CallerObjectId $callerObjectId
    if ($afterReassign.hsv_title -eq 'ACCESS-TEST Work Order') {
        Log "[PASS] Techniker B can now read the work order by GUID after becoming its owner."
    } else {
        Log "[FAIL] Unexpected response reading the reassigned work order."
    }
} catch {
    Log "[FAIL] Techniker B still denied after becoming owner: $($_.Exception.Message)"
}

# --- 6b. As Techniker B (now owner): valid transition Neu -> Zugewiesen --
Log ""
Log "## Status transitions, as Techniker B (now the owner)"
Log ""
try {
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_workorders($woId)" -Body @{ hsv_status = 209710102 } -CallerObjectId $callerObjectId | Out-Null
    Log "[PASS] Techniker B (owner) can perform the valid transition Neu -> Zugewiesen on their own record."
} catch {
    Log "[FAIL] Valid transition Neu -> Zugewiesen was blocked for the owning Techniker: $($_.Exception.Message)"
    Log "       (If this says 'missing prvReadhsv_StatusTransition privilege', CanTransitionPlugin is"
    Log "       querying hsv_statustransition as the caller instead of as SYSTEM - see docs/architecture.md.)"
}

# --- 6c. As Techniker B: invalid transition Zugewiesen -> Abgeschlossen --
try {
    Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_workorders($woId)" -Body @{ hsv_status = 209710104 } -CallerObjectId $callerObjectId | Out-Null
    Log "[FAIL] Invalid transition Zugewiesen -> Abgeschlossen (skipping In Arbeit) was NOT blocked."
} catch {
    if ($_.Exception.Message -match 'INVALID_TRANSITION') {
        Log "[PASS] Invalid transition Zugewiesen -> Abgeschlossen correctly blocked for the owning Techniker (business rule, not an access-rights error)."
    } else {
        Log "[FAIL] Blocked, but not for the expected reason: $($_.Exception.Message)"
    }
}

Log ""
Log "**Note on 'access disappears for Owner A'**: the caller used to create"
Log "and own this record (Alex) is System Administrator, with Organization-"
Log "level access to every table regardless of ownership - that's the only"
Log "real identity available in this Developer Plan environment. A"
Log "genuine 'disappears for A' check needs A to be scoped to User-depth"
Log "access too (i.e. also a Techniker), which isn't demonstrable without a"
Log "second real user or a second Application User configured with a"
Log "*non*-admin role - not done here, flagged rather than assumed."

# --- 7. Cleanup -------------------------------------------------------
Log ""
Log "## Cleanup"
Log ""
try {
    Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "hsv_workorders($woId)" | Out-Null
    Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "hsv_serviceobjects($($serviceObject.hsv_serviceobjectid))" | Out-Null
    Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "accounts($($account.accountid))" | Out-Null
    Log "[INFO] Test Work Order, Service Object, and Account deleted."
} catch {
    Log "[WARNING] Cleanup failed - remove test records manually. $($_.Exception.Message)"
}

$outPath = Join-Path $PSScriptRoot '..\tests\access-test-report.md'
$report -join "`n" | Set-Content -Path $outPath -Encoding utf8
Write-Output ""
Write-Output "Report written to $outPath"
