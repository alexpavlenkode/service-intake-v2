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
Import-Module (Join-Path $ScriptDir 'lib\EmailGenerator.psm1') -Force
Import-Module (Join-Path $ScriptDir 'lib\Pipeline.psm1') -Force

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

# The actual pipeline logic (Ingest/Parse/Validate/DupCheck/Decision) lives
# in lib\Pipeline.psm1, shared with scripts\demo-pipeline.ps1 (review items
# 18/19) - this used to be an entirely separate, independently-maintained
# implementation here (different duplicate-check wording, no
# hsv_processingattempt logging at all, its own NOT_A_REQUEST keyword list
# instead of the real hsv_status=209710007 rule, and the technical-duplicate
# ProviderMessageId bug fixed below). Invoke-RealMessage is now a thin
# adapter: call the shared pipeline, then translate its neutral result shape
# into the exact { stages[].result: pass/warn/fail, finalStatus (display
# text), finalClass } shape live-console-page.html already expects, so the
# frontend needed no changes.
$FinalStatusDisplay = @{
    Converted = 'Converted'; NotRelevant = 'Not Relevant'; NeedsClarification = 'Needs Clarification'
    PotentialDuplicate = 'Potential Duplicate'; Duplicate = 'Duplicate'
}
$FinalStatusClass = @{
    Converted = 'pass'; NotRelevant = 'warn'; NeedsClarification = 'warn'
    PotentialDuplicate = 'warn'; Duplicate = 'fail'
}
$StageResultClass = @{ Pass = 'pass'; Warn = 'warn'; Duplicate = 'fail'; Fail = 'fail' }

# Only used for manually-composed /api/send messages (New-RealisticMessage's
# 'not_a_request' scenario already covers the /api/random path) - lets a
# human typing "out of office" etc. into the console see it correctly
# classified without needing NLP.
$NotARequestWords = @('out of office', 'abwesend', 'urlaub', 'unsubscribe', 'newsletter', 'werbung', 'spam', 'gewinnspiel')
function Test-IsNotARequest {
    param([string] $Subject, [string] $Body)
    $lowerAll = "$Subject $Body".ToLower()
    foreach ($w in $NotARequestWords) { if ($lowerAll.Contains($w)) { return $true } }
    return $false
}

function ConvertTo-JsonSafe {
    # PowerShell 5.1's ConvertTo-Json collapses a 1-element array into a
    # bare JSON object instead of a single-element JSON array WHEN THAT
    # ARRAY IS PIPED IN (pipeline enumeration invokes it once per element,
    # so it never sees "an array" at all for a 1-item input) - this is what
    # broke the browser with "results is not iterable" whenever exactly one
    # message was sent via /api/random. -InputObject avoids the pipeline
    # collapse for the TOP-LEVEL value, which is the only place this
    # function is used (nested array properties inside an object are
    # serialized correctly regardless of element count - the bug is
    # specifically a pipeline-enumeration artifact, not a general
    # single-element-array problem).
    param([Parameter(Mandatory)] $InputObject, [int] $Depth = 10)
    ConvertTo-Json -InputObject $InputObject -Depth $Depth
}

function Invoke-RealMessage {
    param([hashtable] $Msg)
    $result = Invoke-ServiceIntakeMessage -OrgUrl $org -Msg $Msg
    # @(...) forces this to stay a real array even when $result.stages has
    # exactly one element (the Duplicate outcome always does) - ForEach-Object
    # assigned straight to a variable otherwise unwraps a single output into
    # a bare hashtable, which would then serialize as a JSON object instead
    # of a one-item array for the frontend's per-stage rendering.
    $stages = @($result.stages | ForEach-Object { @{ name = $_.name; result = $StageResultClass[$_.result]; detail = $_.detail } })
    return @{
        stages = $stages
        finalStatus = $FinalStatusDisplay[$result.finalStatus]
        finalClass = $FinalStatusClass[$result.finalStatus]
        finalDetail = $result.finalDetail
        inboundId = $result.inboundId
        woId = $result.woId
    }
}

# --- Random message generator: scripts\lib\EmailGenerator.psm1 -------------
# Was a 3-customer/3-problem inline generator - moved to a shared module with
# real template variety (10 customers, 8-10 complaint bodies per trade,
# varied greetings/closings) so 100 generated messages don't read as an
# obvious repeated loop. Shared with demo-pipeline.ps1's -Random mode.
$script:generatedMessages = New-Object System.Collections.Generic.List[hashtable]

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
                $msg = @{
                    FromAddress = $body.From; Subject = $body.Subject; Body = $body.Body
                    CustomerName = $body.CustomerName; ObjectNumber = $body.ObjectNumber; Street = $body.Street
                    TradeValue = 209710505; NotARequest = (Test-IsNotARequest -Subject $body.Subject -Body $body.Body)
                }
                Set-StampedProviderMessageId -Msg $msg -Prefix 'LIVE' | Out-Null
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
                $count = [Math]::Max(1, [Math]::Min(200, [int]$body.count))
                $results = New-Object System.Collections.Generic.List[object]
                $cleanCount = 0
                for ($i = 0; $i -lt $count; $i++) {
                    $scenario = Get-ScenarioForIndex -Index $i -PreviousCleanCount $cleanCount
                    $rm = New-RealisticMessage -Scenario $scenario -PreviousMessages $script:generatedMessages
                    if ($rm.Scenario -eq 'clean') { $cleanCount++ }
                    $script:generatedMessages.Add($rm)

                    # Review item 20: 'technical_duplicate' returns the SAME
                    # hashtable reference as an earlier generated message -
                    # Set-StampedProviderMessageId is what makes that reuse
                    # actually collide against the alternate key instead of
                    # each turn inventing its own fresh id (the bug: this
                    # loop used to pass $rm straight into Invoke-RealMessage,
                    # which had no ProviderMessageId field to find and so
                    # always generated a new random one, silently defeating
                    # the whole point of the duplicate scenario).
                    $providerMessageId = Set-StampedProviderMessageId -Msg $rm -Prefix 'LIVE'

                    $m = @{
                        FromAddress = $rm.From; Subject = $rm.Subject; Body = $rm.Body
                        CustomerName = $rm.CustomerName; ObjectNumber = $rm.ObjectNumber; Street = $rm.Street
                        TradeValue = $rm.TradeValue; TradeLabel = $rm.TradeLabel
                        ProviderMessageId = $providerMessageId
                        NotARequest = ($scenario -eq 'not_a_request')
                    }
                    $r = Invoke-RealMessage -Msg $m
                    $r['input'] = $m
                    $results.Add($r)
                }
                $json = ConvertTo-JsonSafe -InputObject $results.ToArray()
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
