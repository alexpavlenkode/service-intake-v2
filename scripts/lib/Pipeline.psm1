<#
    Shared Service Intake message-processing pipeline (review items 18/19).

    Previously scripts\demo-pipeline.ps1 (CLI) and scripts\serve-live-console.ps1
    (Live Console web server) each had their OWN independent implementation
    of the exact same business logic (Ingest -> Parse -> Validate ->
    Duplicate Check -> Decision) - two places that could silently drift out
    of sync with each other and with the real rules. This module is now the
    ONE place that logic lives; both callers use it and differ only in how
    they PRESENT the result (animated console output vs a JSON stage list
    for the browser).

    Everything here goes through Invoke-DataverseApi (review item 24) - no
    caller of this module needs its own raw Invoke-WebRequest calls for
    "I need the created record back", since Invoke-DataverseApi now supports
    -ReturnRepresentation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# hsv_stage values (schema/choices.yaml hsv_Stage)
$script:StageIngest = 209710201
$script:StageParse = 209710202
$script:StageValidate = 209710203
$script:StageDupCheck = 209710204
$script:StageCreate = 209710205
# hsv_result values (schema/choices.yaml hsv_Result)
$script:ResultSuccess = 209710301
$script:ResultBusinessException = 209710302
$script:ResultSkipped = 209710304
# hsv_reasoncode values (schema/choices.yaml hsv_ReasonCode)
$script:ReasonMissingAddr = 209710401
$script:ReasonNotARequest = 209710403
$script:ReasonPossibleDup = 209710404
$script:ReasonTechnicalDuplicate = 209710410

function Get-OrCreateDemoAccount {
    param([Parameter(Mandatory)] [string] $OrgUrl, [Parameter(Mandatory)] [string] $Name)
    $safeName = Format-ODataFilterValue "DEMO $Name"
    $existing = Invoke-DataverseApi -OrgUrl $OrgUrl -Method GET -Path "accounts?`$select=accountid&`$filter=name eq '$safeName'"
    if ($existing.value.Count -gt 0) { return $existing.value[0].accountid }
    $created = Invoke-DataverseApi -OrgUrl $OrgUrl -Method POST -Path 'accounts' -ReturnRepresentation -Body @{ name = "DEMO $Name" }
    return $created.accountid
}

function Get-OrCreateDemoServiceObject {
    <#
        Review item 21: previously looked up by hsv_objectnumber ALONE,
        which is wrong even though today's demo data happens to use
        per-customer-prefixed numbers that don't collide - two different
        real customers legitimately CAN use the same internal object
        number, which is exactly why hsv_ServiceObject_AccountObjectNumber
        is a COMPOSITE alternate key (schema/keys.yaml) over
        [hsv_Account, hsv_ObjectNumber], not hsv_ObjectNumber alone. Fixed
        by filtering on BOTH.

        Review item 22 ("use the composite alternate key directly where
        possible") was attempted via PATCH-as-upsert against the key
        addressed directly in the URL - e.g.
        hsv_serviceobjects(hsv_Account=<guid>,hsv_ObjectNumber='X') - which
        is Dataverse's documented upsert mechanism and would have also
        fixed the GET-then-POST race for free. NOT possible in this
        environment: confirmed via raw curl (eliminating any PowerShell/
        Invoke-WebRequest client quirk) that alternate-key URL addressing is
        rejected outright even for the simplest possible case - a single-
        attribute string key on a different table
        (hsv_workorders(hsv_WorkOrderNumber='WO-00001')) fails identically:
        HTTP 400 "The key in the request URI is not valid... Ensure that
        the names and number of key properties match the declared or
        alternate key properties" - despite the name/count genuinely
        matching the key's own metadata (confirmed via EntityDefinitions/
        Keys). This looks like a platform/environment-level restriction on
        this feature, not a mistake in the request; not chased further.
    #>
    param([Parameter(Mandatory)] [string] $OrgUrl, [Parameter(Mandatory)] [string] $AccountId, [Parameter(Mandatory)] [string] $ObjectNumber, [string] $Street)
    $safeObjectNumber = Format-ODataFilterValue $ObjectNumber
    $existing = Invoke-DataverseApi -OrgUrl $OrgUrl -Method GET -Path "hsv_serviceobjects?`$select=hsv_serviceobjectid&`$filter=_hsv_account_value eq $AccountId and hsv_objectnumber eq '$safeObjectNumber'"
    if ($existing.value.Count -gt 0) { return $existing.value[0].hsv_serviceobjectid }
    $body = @{
        hsv_name = "DEMO Object $ObjectNumber"
        'hsv_Account@odata.bind' = "/accounts($AccountId)"
        hsv_objectnumber = $ObjectNumber
        hsv_street = $Street
        hsv_postalcode = '04109'
        hsv_city = 'Leipzig'
    }
    $created = Invoke-DataverseApi -OrgUrl $OrgUrl -Method POST -Path 'hsv_serviceobjects' -ReturnRepresentation -Body $body
    return $created.hsv_serviceobjectid
}

function New-ProcessingAttemptLog {
    param(
        [Parameter(Mandatory)] [string] $OrgUrl, [Parameter(Mandatory)] [string] $MessageId,
        [Parameter(Mandatory)] [string] $CorrelationId, [Parameter(Mandatory)] [int] $AttemptNumber,
        [Parameter(Mandatory)] [int] $Stage, [Parameter(Mandatory)] [int] $Result,
        [string] $ReasonCode, [string] $PreviousAttemptId
    )
    $body = @{
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
    if ($PreviousAttemptId) { $body['hsv_PreviousAttempt@odata.bind'] = "/hsv_processingattempts($PreviousAttemptId)" }
    # Deliberately NOT named $result - that collides case-insensitively with
    # the [int] $Result PARAMETER above (PowerShell variable names are
    # case-insensitive), which made PowerShell try to coerce this whole
    # response object back into an int and throw. Cost real debugging time
    # to track down - named distinctly here as a warning to the next editor.
    $apiResponse = Invoke-DataverseApi -OrgUrl $OrgUrl -Method POST -Path 'hsv_processingattempts' -ReturnRepresentation -Body $body
    return $apiResponse.hsv_processingattemptid
}

function Get-NextAttemptNumber {
    # AttemptNumber counts processing attempts against a specific
    # hsv_inboundmessage record, not against a single delivery's own
    # CorrelationId (each delivery/webhook call gets its own CorrelationId -
    # review item 26). Used when a technical duplicate delivery needs to be
    # logged against the ALREADY-EXISTING message.
    param([Parameter(Mandatory)] [string] $OrgUrl, [Parameter(Mandatory)] [string] $MessageId)
    $prior = Invoke-DataverseApi -OrgUrl $OrgUrl -Method GET -Path "hsv_processingattempts?`$filter=_hsv_inboundmessage_value eq $MessageId&`$select=hsv_attemptnumber,hsv_processingattemptid&`$orderby=hsv_attemptnumber desc&`$top=1"
    if ($prior.value.Count -eq 0) { return @{ Number = 1; PreviousId = $null } }
    return @{ Number = $prior.value[0].hsv_attemptnumber + 1; PreviousId = $prior.value[0].hsv_processingattemptid }
}

function Set-StampedProviderMessageId {
    <#
        Review item 20: EmailGenerator.psm1's 'technical_duplicate' scenario
        returns the SAME hashtable reference as an earlier generated message
        (by design - that's what makes it a genuine repeat). But neither
        caller used to actually give that shared hashtable a
        ProviderMessageId that survives across the two turns: each call
        into the per-message pipeline just invented a fresh random id
        whether or not the message was a "repeat", which meant the
        duplicate scenario never actually exercised the alternate key at
        all in scripts\serve-live-console.ps1 (scripts\demo-pipeline.ps1 had
        its own inline version of exactly this fix already; it's now here
        so both callers share it instead of one of them silently lacking
        it).

        Call this on every generated message BEFORE processing it: the
        first time (a 'clean' message, say), it stamps a fresh id onto the
        hashtable and returns it; the second time (a 'technical_duplicate'
        reuse of that same hashtable reference), the stamp from the first
        call is still there, so the same id is returned and genuinely
        collides against the alternate key.
    #>
    param([Parameter(Mandatory)] [hashtable] $Msg, [Parameter(Mandatory)] [string] $Prefix)
    if (-not $Msg.ContainsKey('AssignedProviderId') -or -not $Msg['AssignedProviderId']) {
        $Msg['AssignedProviderId'] = "$Prefix-$([guid]::NewGuid().ToString().Substring(0,8))"
    }
    return $Msg['AssignedProviderId']
}

function Invoke-ServiceIntakeMessage {
    <#
        Runs one message through the full pipeline: Ingest -> Parse ->
        Validate -> Duplicate Check -> Decision. Returns:
            @{
                stages = @(@{ name; result; detail }, ...)   # result: Pass/Warn/Fail/Duplicate
                finalStatus  # Converted/NotRelevant/NeedsClarification/PotentialDuplicate/Duplicate
                finalDetail
                inboundId    # $null if the Ingest stage itself failed (technical duplicate)
                woId         # $null unless finalStatus = Converted
            }
        Pure logic, no console/HTTP-response presentation - callers render
        the returned stage list however fits their own UI.
    #>
    param([Parameter(Mandatory)] [string] $OrgUrl, [Parameter(Mandatory)] [hashtable] $Msg)

    $stages = New-Object System.Collections.Generic.List[object]
    $correlationId = [guid]::NewGuid().ToString()
    $providerMessageId = if ($Msg['ProviderMessageId']) { $Msg['ProviderMessageId'] } else { $Msg['AssignedProviderId'] }
    if (-not $providerMessageId) { throw "Msg needs either ProviderMessageId or AssignedProviderId (see Set-StampedProviderMessageId)." }

    # --- Ingest ---------------------------------------------------------
    $msgBody = @{
        hsv_name = if ($Msg['Subject']) { $Msg['Subject'] } else { '(kein Betreff)' }
        hsv_providermessageid = $providerMessageId
        hsv_correlationid = $correlationId
        hsv_receivedon = (Get-Date).ToUniversalTime().ToString('o')
        hsv_fromaddress = $Msg['FromAddress']
        hsv_subject = $Msg['Subject']
        hsv_body = $Msg['Body']
        hsv_hasattachments = $false
        hsv_status = 209710001  # Received
        hsv_extractionsource = 209710701  # Parser
        hsv_requiresreview = $false
        hsv_retrycount = 0
    }

    $inboundId = $null
    try {
        $created = Invoke-DataverseApi -OrgUrl $OrgUrl -Method POST -Path 'hsv_inboundmessages' -ReturnRepresentation -Body $msgBody
        $inboundId = $created.hsv_inboundmessageid
        $stages.Add(@{ name = 'Ingest'; result = 'Pass'; detail = "hsv_inboundmessage created ($inboundId), ProviderMessageId=$providerMessageId" })
        New-ProcessingAttemptLog -OrgUrl $OrgUrl -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $script:StageIngest -Result $script:ResultSuccess | Out-Null
    } catch {
        # Review items 25/26: a second hsv_inboundmessage can never exist
        # for this ProviderMessageId (the alternate key already refused
        # it), so there is no second record to mark Duplicate. What
        # actually happened - a repeat delivery of an already-processed
        # message - is recorded as a new hsv_processingattempt against the
        # ORIGINAL message instead of being silently dropped.
        $existing = Invoke-DataverseApi -OrgUrl $OrgUrl -Method GET -Path "hsv_inboundmessages?`$filter=hsv_providermessageid eq '$providerMessageId'&`$select=hsv_inboundmessageid"
        $existingId = if ($existing.value.Count -gt 0) { $existing.value[0].hsv_inboundmessageid } else { $null }
        if ($existingId) {
            $next = Get-NextAttemptNumber -OrgUrl $OrgUrl -MessageId $existingId
            New-ProcessingAttemptLog -OrgUrl $OrgUrl -MessageId $existingId -CorrelationId $correlationId -AttemptNumber $next.Number -Stage $script:StageIngest -Result $script:ResultSkipped -ReasonCode $script:ReasonTechnicalDuplicate -PreviousAttemptId $next.PreviousId | Out-Null
        }
        $stages.Add(@{ name = 'Ingest'; result = 'Duplicate'; detail = "Rejected by alternate key - already exists as $existingId; logged as a new ProcessingAttempt (Skipped/TECHNICAL_DUPLICATE) against it" })
        return @{ stages = $stages; finalStatus = 'Duplicate'; finalDetail = "Provider-ID bereits verarbeitet ($existingId)."; inboundId = $null; woId = $null }
    }

    # --- Parse ------------------------------------------------------------
    Invoke-DataverseApi -OrgUrl $OrgUrl -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710002 } | Out-Null  # Parsed
    New-ProcessingAttemptLog -OrgUrl $OrgUrl -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $script:StageParse -Result $script:ResultSuccess | Out-Null
    $stages.Add(@{ name = 'Parse'; result = 'Pass'; detail = "Customer=$($Msg['CustomerName']), Object=$($Msg['ObjectNumber']), Trade=$($Msg['TradeLabel'])" })

    # --- Validate -----------------------------------------------------------
    if ($Msg['NotARequest']) {
        Invoke-DataverseApi -OrgUrl $OrgUrl -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710007 } | Out-Null  # Not Relevant
        New-ProcessingAttemptLog -OrgUrl $OrgUrl -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $script:StageValidate -Result $script:ResultBusinessException -ReasonCode $script:ReasonNotARequest | Out-Null
        $stages.Add(@{ name = 'Validate'; result = 'Warn'; detail = 'NOT_A_REQUEST' })
        return @{ stages = $stages; finalStatus = 'NotRelevant'; finalDetail = 'Nachricht ist keine Auftragsanfrage.'; inboundId = $inboundId; woId = $null }
    }
    if (-not $Msg['ObjectNumber'] -or -not $Msg['CustomerName']) {
        Invoke-DataverseApi -OrgUrl $OrgUrl -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710004 } | Out-Null  # Needs Clarification
        New-ProcessingAttemptLog -OrgUrl $OrgUrl -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $script:StageValidate -Result $script:ResultBusinessException -ReasonCode $script:ReasonMissingAddr | Out-Null
        $stages.Add(@{ name = 'Validate'; result = 'Warn'; detail = 'MISSING_OBJECT_ADDRESS' })
        return @{ stages = $stages; finalStatus = 'NeedsClarification'; finalDetail = 'Objektadresse fehlt - Rueckfrage an den Kunden noetig.'; inboundId = $inboundId; woId = $null }
    }
    Invoke-DataverseApi -OrgUrl $OrgUrl -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710003 } | Out-Null  # Validated
    New-ProcessingAttemptLog -OrgUrl $OrgUrl -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $script:StageValidate -Result $script:ResultSuccess | Out-Null
    $stages.Add(@{ name = 'Validate'; result = 'Pass'; detail = 'All required fields present' })

    # --- Duplicate check (business key) --------------------------------------
    $businessKey = "$($Msg['CustomerName'])|$($Msg['ObjectNumber'])|$($Msg['Body'].ToLower().Trim())"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($businessKey))
    $businessKeyHash = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()

    $cutoff = (Get-Date).ToUniversalTime().AddHours(-72).ToString('o')
    $dupCheck = Invoke-DataverseApi -OrgUrl $OrgUrl -Method GET -Path "hsv_inboundmessages?`$filter=hsv_businesskeyhash eq '$businessKeyHash' and hsv_inboundmessageid ne $inboundId and hsv_receivedon gt $cutoff&`$select=hsv_inboundmessageid&`$top=1"
    Invoke-DataverseApi -OrgUrl $OrgUrl -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_businesskey = $businessKey; hsv_businesskeyhash = $businessKeyHash } | Out-Null

    if ($dupCheck.value.Count -gt 0) {
        $matchId = $dupCheck.value[0].hsv_inboundmessageid
        Invoke-DataverseApi -OrgUrl $OrgUrl -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710005; hsv_matchreason = "Gleicher Kunde/Objekt/Inhalt wie Nachricht $matchId innerhalb 72h" } | Out-Null  # Potential Duplicate
        New-ProcessingAttemptLog -OrgUrl $OrgUrl -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $script:StageDupCheck -Result $script:ResultBusinessException -ReasonCode $script:ReasonPossibleDup | Out-Null
        $stages.Add(@{ name = 'Duplicate Check'; result = 'Warn'; detail = "Matches $matchId - POSSIBLE_DUPLICATE" })
        return @{ stages = $stages; finalStatus = 'PotentialDuplicate'; finalDetail = "Aehnlich zu Nachricht $matchId - wartet auf menschliche Entscheidung."; inboundId = $inboundId; woId = $null }
    }
    $stages.Add(@{ name = 'Duplicate Check'; result = 'Pass'; detail = 'No business-key match in 72h window' })

    # --- Decision / Create Work Order ------------------------------------
    $accountId = Get-OrCreateDemoAccount -OrgUrl $OrgUrl -Name $Msg['CustomerName']
    $street = if ($Msg['Street']) { $Msg['Street'] } else { 'Unbekannt' }
    $soId = Get-OrCreateDemoServiceObject -OrgUrl $OrgUrl -AccountId $accountId -ObjectNumber $Msg['ObjectNumber'] -Street $street

    $woBody = @{
        hsv_title = if ($Msg['Subject']) { $Msg['Subject'] } else { 'Auftrag' }
        hsv_description = $Msg['Body']
        'hsv_Account@odata.bind' = "/accounts($accountId)"
        'hsv_ServiceObject@odata.bind' = "/hsv_serviceobjects($soId)"
        hsv_trade = if ($Msg['TradeValue']) { $Msg['TradeValue'] } else { 209710505 }
        hsv_priority = 209710601  # Standard
        hsv_status = 209710101    # Neu
    }
    $wo = Invoke-DataverseApi -OrgUrl $OrgUrl -Method POST -Path 'hsv_workorders' -ReturnRepresentation -Body $woBody
    $woId = $wo.hsv_workorderid

    Invoke-DataverseApi -OrgUrl $OrgUrl -Method PATCH -Path "hsv_inboundmessages($inboundId)" -Body @{ hsv_status = 209710009; 'hsv_WorkOrder@odata.bind' = "/hsv_workorders($woId)" } | Out-Null  # Converted
    New-ProcessingAttemptLog -OrgUrl $OrgUrl -MessageId $inboundId -CorrelationId $correlationId -AttemptNumber 1 -Stage $script:StageCreate -Result $script:ResultSuccess | Out-Null
    $stages.Add(@{ name = 'Decision'; result = 'Pass'; detail = "Work Order $woId created" })

    return @{ stages = $stages; finalStatus = 'Converted'; finalDetail = "Work Order $woId (Neu) - bereit fuer Zuweisung."; inboundId = $inboundId; woId = $woId }
}

Export-ModuleMember -Function Get-OrCreateDemoAccount, Get-OrCreateDemoServiceObject, New-ProcessingAttemptLog, Get-NextAttemptNumber, Set-StampedProviderMessageId, Invoke-ServiceIntakeMessage
