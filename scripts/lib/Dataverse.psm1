<#
    Dataverse Web API helpers for Service Intake V2.

    Auth method (see docs/deployment.md for the full story):
    Az.Accounts, interactive browser login (NOT device code — device code
    flow is blocked by this tenant's Conditional Access / Security Defaults,
    confirmed via AADSTS530035). WAM is disabled per-process to avoid a
    separate WAM-related failure mode seen during setup.

    The access token is never written to disk, .env, git, or logs. Only its
    expiry and audience may be logged.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Connect-DataverseOrg {
    <#
        Ensures there is a live Az.Accounts session. Safe to call repeatedly;
        does nothing if already connected. Uses interactive browser auth,
        never -UseDeviceAuthentication.
    #>
    param(
        [Parameter(Mandatory)] [string] $TenantId
    )

    Import-Module Az.Accounts -ErrorAction Stop

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Update-AzConfig -EnableLoginByWam $false -Scope Process | Out-Null
        Connect-AzAccount -Tenant $TenantId -ErrorAction Stop | Out-Null
    }
}

function Get-DataverseToken {
    <#
        Returns a plain-string access token scoped to the given Dataverse
        organization URL. Caller must not persist this value.
    #>
    param(
        [Parameter(Mandatory)] [string] $OrgUrl
    )

    $tok = Get-AzAccessToken -ResourceUrl $OrgUrl -ErrorAction Stop
    $token = $tok.Token
    if ($token -is [System.Security.SecureString]) {
        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
        )
    }
    return $token
}

function Invoke-DataverseApi {
    <#
        Thin wrapper around the Dataverse Web API (v9.2) with:
          - bearer auth via Get-DataverseToken
          - required OData headers
          - optional MSCRM.SolutionUniqueName / MSCRM.MergeLabels headers
          - optional CallerObjectId header for impersonation (requires the
            calling user to hold "Act on Behalf of Another User")
          - bounded retry on HTTP 429 honoring Retry-After

        -Path is relative to /api/data/v9.2/, e.g. "solutions" or
        "EntityDefinitions(LogicalName='hsv_workorder')/Attributes".
    #>
    param(
        [Parameter(Mandatory)] [string] $OrgUrl,
        [Parameter(Mandatory)] [ValidateSet('GET','POST','PATCH','PUT','DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [object] $Body,
        [string] $SolutionUniqueName,
        [switch] $MergeLabels,
        [string] $CallerObjectId,
        [hashtable] $AdditionalHeaders,
        [int] $MaxRetries = 4
    )

    if ($Method -eq 'DELETE' -and $Path -match '(EntityDefinitions|Attributes|Keys|RelationshipDefinitions|GlobalOptionSetDefinitions)') {
        throw "Refusing DELETE against a metadata endpoint ('$Path'). This is a hard rule for this project, not a configurable option."
    }

    $uri = "$OrgUrl/api/data/v9.2/$Path"

    $headers = @{
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        'Accept'           = 'application/json'
        'Content-Type'     = 'application/json; charset=utf-8'
    }
    if ($SolutionUniqueName) { $headers['MSCRM.SolutionUniqueName'] = $SolutionUniqueName }
    if ($MergeLabels)        { $headers['MSCRM.MergeLabels'] = 'true' }
    if ($CallerObjectId)     { $headers['CallerObjectId'] = $CallerObjectId }
    if ($AdditionalHeaders)  { foreach ($k in $AdditionalHeaders.Keys) { $headers[$k] = $AdditionalHeaders[$k] } }

    $attempt = 0
    while ($true) {
        $attempt++
        $headers['Authorization'] = "Bearer $(Get-DataverseToken -OrgUrl $OrgUrl)"
        try {
            $params = @{
                Uri             = $uri
                Method          = $Method
                Headers         = $headers
                UseBasicParsing = $true
            }
            if ($null -ne $Body) {
                # Windows PowerShell 5.1's Invoke-WebRequest encodes a
                # [string] -Body using the SYSTEM default codepage, not the
                # UTF-8 declared in the Content-Type header above - setting
                # that header via -Headers (rather than the -ContentType
                # parameter) does not make it charset-aware. Any non-ASCII
                # character (e.g. German "ß", "ü") silently got mangled into
                # a single wrong byte, which Dataverse then rejected/decoded
                # as U+FFFD. Confirmed empirically: "Schließanlage" round-
                # tripped as "Schlie<FFFD>anlage". Fix: convert to UTF-8
                # bytes ourselves - a byte[] -Body bypasses string encoding
                # entirely.
                $json = $Body | ConvertTo-Json -Depth 20 -Compress
                $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes($json)
            }
            $resp = Invoke-WebRequest @params
            if ($resp.Content) {
                return $resp.Content | ConvertFrom-Json
            }
            return $null
        }
        catch {
            $we = $_.Exception
            $status = $null
            if ($we.Response) { $status = [int]$we.Response.StatusCode }

            if ($status -eq 429 -and $attempt -le $MaxRetries) {
                $retryAfter = 5
                if ($we.Response.Headers -and $we.Response.Headers['Retry-After']) {
                    $retryAfter = [int]$we.Response.Headers['Retry-After']
                }
                Write-Warning "[WARNING] 429 from Dataverse, retrying in ${retryAfter}s (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds $retryAfter
                continue
            }

            $bodyText = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $bodyText = $_.ErrorDetails.Message
            } else {
                try {
                    $stream = $we.Response.GetResponseStream()
                    $stream.Position = 0
                    $reader = New-Object System.IO.StreamReader($stream)
                    $bodyText = $reader.ReadToEnd()
                } catch {}
            }

            $msg = "Dataverse API call failed: $Method $uri (HTTP $status)"
            if ($bodyText) { $msg += "`n$bodyText" }
            throw $msg
        }
    }
}

function Get-DataverseBaseLanguageCode {
    param([Parameter(Mandatory)] [string] $OrgUrl)
    $orgs = Invoke-DataverseApi -OrgUrl $OrgUrl -Method GET -Path "organizations?`$select=languagecode,basecurrencyid"
    return $orgs.value[0].languagecode
}

function New-DataverseLabel {
    param([Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [int] $LanguageCode)
    return @{
        '@odata.type'     = 'Microsoft.Dynamics.CRM.Label'
        LocalizedLabels   = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = $Text; LanguageCode = $LanguageCode })
    }
}

function New-DataverseRequiredLevel {
    # Maps schema/tables.yaml's requiredLevel ("Required"/"None") to Dataverse's enum.
    param([Parameter(Mandatory)] [string] $Level)
    $value = if ($Level -eq 'Required') { 'ApplicationRequired' } else { 'None' }
    return @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.AttributeRequiredLevelManagedProperty'
        Value         = $value
        CanBeChanged  = $true
        ManagedPropertyLogicalName = 'canmodifyrequirementlevelsettings'
    }
}

function ConvertTo-DataverseDisplayName {
    # "ObjectNumber" -> "Object Number". Schema names in tables.yaml carry no
    # separate display name, so we derive a readable one deterministically
    # rather than inventing prose per column.
    param([Parameter(Mandatory)] [string] $SchemaName, [string] $Prefix = 'hsv_')
    $bare = $SchemaName -replace "^$Prefix", ''
    return ($bare -creplace '([a-z0-9])([A-Z])', '$1 $2')
}

function Format-ODataFilterValue {
    <#
        Makes an arbitrary string safe to embed inside an OData $filter
        string literal built via plain string interpolation (as every
        script in this project does, rather than a query builder library).

        Two independent problems, both real (hit live: a customer name with
        "&" broke the query outright with a cryptic 400 "query parameter not
        supported" - "&" is the query-string parameter separator, so an
        unescaped one splits the URL wherever it appears):
          1. OData string literal syntax: a literal single quote inside the
             value must be doubled ('' ), or it closes the string early.
          2. URL encoding: the whole query string segment must be percent-
             encoded, or characters like &, #, %, space break URL parsing
             before the request even reaches OData.

        Order matters: double the quotes FIRST (so the server's OData parser
        sees the escaping after url-decoding), then percent-encode the
        result.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
    $odataEscaped = $Value -replace "'", "''"
    return [System.Uri]::EscapeDataString($odataEscaped)
}

Export-ModuleMember -Function Connect-DataverseOrg, Get-DataverseToken, Invoke-DataverseApi, Get-DataverseBaseLanguageCode, New-DataverseLabel, New-DataverseRequiredLevel, ConvertTo-DataverseDisplayName, Format-ODataFilterValue
