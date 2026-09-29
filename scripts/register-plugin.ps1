<#
    .SYNOPSIS
        Registers Hsv.ServiceIntake.Plugins.CanTransitionPlugin as a
        Pre-Operation Update step (with a hsv_status Pre-Image) on
        hsv_workorder and hsv_inboundmessage. Idempotent: re-running updates
        the assembly content if the dll changed, and skips steps/images that
        already exist by name.

    .PARAMETER DryRun
        Plan only. No writes.

    .PARAMETER Apply
        Actually register/update in SI-DEV.
#>
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter(ParameterSetName = 'DryRun')] [switch] $DryRun,
    [Parameter(ParameterSetName = 'Apply')] [switch] $Apply,
    [string] $ConfigPath = "$PSScriptRoot\config.psd1",
    [string] $DllPath = "$PSScriptRoot\..\plugins\Hsv.ServiceIntake.Plugins\bin\Release\net462\Hsv.ServiceIntake.Plugins.dll"
)

$ErrorActionPreference = 'Stop'
if (-not $DryRun -and -not $Apply) { throw "Specify either -DryRun or -Apply." }
if (-not (Test-Path $DllPath)) { throw "DLL not found at $DllPath - build the plugin project first (dotnet build -c Release)." }

Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

$assemblyName = 'Hsv.ServiceIntake.Plugins'
$typeName     = 'Hsv.ServiceIntake.Plugins.CanTransitionPlugin'
$dllBytes     = [System.IO.File]::ReadAllBytes($DllPath)
$dllBase64    = [System.Convert]::ToBase64String($dllBytes)

Write-Output "[INFO] DLL: $DllPath ($($dllBytes.Length) bytes)"

# --- 1. Plugin assembly ---------------------------------------------------
$existingAssembly = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "pluginassemblies?`$select=pluginassemblyid,version&`$filter=name eq '$assemblyName'"

if ($existingAssembly.value.Count -eq 0) {
    Write-Output "[CREATE] Plugin assembly '$assemblyName'."
    if ($Apply) {
        $body = @{
            name          = $assemblyName
            content       = $dllBase64
            isolationmode = 2   # Sandbox
            sourcetype    = 0   # Database
        }
        Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'pluginassemblies' -Body $body | Out-Null
        $existingAssembly = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "pluginassemblies?`$select=pluginassemblyid&`$filter=name eq '$assemblyName'"
    }
} else {
    Write-Output "[CREATE] Plugin assembly '$assemblyName' exists - updating content (redeploy)."
    if ($Apply) {
        $asmId = $existingAssembly.value[0].pluginassemblyid
        $body = @{ content = $dllBase64 }
        Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "pluginassemblies($asmId)" -Body $body | Out-Null
    }
}

if (-not $Apply) {
    Write-Output "[DRY RUN] Stopping here - plugin type / step / image creation needs the real assembly id."
    return
}

$assemblyId = $existingAssembly.value[0].pluginassemblyid
Write-Output "[INFO] Assembly id: $assemblyId"

# --- 2. Plugin type ---------------------------------------------------------
$existingType = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "plugintypes?`$select=plugintypeid&`$filter=typename eq '$typeName'"
if ($existingType.value.Count -eq 0) {
    $body = @{
        typename    = $typeName
        friendlyname = 'CanTransitionPlugin'
        'pluginassemblyid@odata.bind' = "/pluginassemblies($assemblyId)"
    }
    Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'plugintypes' -Body $body | Out-Null
    $existingType = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "plugintypes?`$select=plugintypeid&`$filter=typename eq '$typeName'"
    Write-Output "[CREATE] Plugin type '$typeName'."
} else {
    Write-Output "[VERIFY] Plugin type '$typeName' already exists."
}
$typeId = $existingType.value[0].plugintypeid

# --- 3. SDK message (Update) and per-entity filters ------------------------
$updateMsg = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "sdkmessages?`$select=sdkmessageid&`$filter=name eq 'Update'"
$updateMsgId = $updateMsg.value[0].sdkmessageid

function Register-StepForEntity {
    param([string] $EntityLogicalName)

    $filter = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "sdkmessagefilters?`$select=sdkmessagefilterid&`$filter=primaryobjecttypecode eq '$EntityLogicalName' and _sdkmessageid_value eq $updateMsgId"
    if ($filter.value.Count -eq 0) {
        throw "No sdkmessagefilter found for Update on '$EntityLogicalName' - unexpected, check the entity is fully published."
    }
    $filterId = $filter.value[0].sdkmessagefilterid

    $stepName = "CanTransitionPlugin: Update of $EntityLogicalName (Pre-Operation)"
    $existingStep = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "sdkmessageprocessingsteps?`$select=sdkmessageprocessingstepid&`$filter=name eq '$stepName'"

    if ($existingStep.value.Count -gt 0) {
        Write-Output "[VERIFY] Step '$stepName' already exists."
        $stepId = $existingStep.value[0].sdkmessageprocessingstepid
    } else {
        $stepBody = @{
            name                    = $stepName
            'sdkmessageid@odata.bind'          = "/sdkmessages($updateMsgId)"
            'sdkmessagefilterid@odata.bind'    = "/sdkmessagefilters($filterId)"
            'plugintypeid@odata.bind'          = "/plugintypes($typeId)"
            stage                   = 20   # Pre-Operation
            mode                    = 0    # Synchronous
            rank                    = 1
            filteringattributes     = 'hsv_status'
            supporteddeployment     = 0    # Server Only
            invocationsource        = 0
        }
        Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'sdkmessageprocessingsteps' -Body $stepBody | Out-Null
        $lookup = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "sdkmessageprocessingsteps?`$select=sdkmessageprocessingstepid&`$filter=name eq '$stepName'"
        $stepId = $lookup.value[0].sdkmessageprocessingstepid
        Write-Output "[CREATE] Step '$stepName' created."
    }

    $existingImage = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "sdkmessageprocessingstepimages?`$select=sdkmessageprocessingstepimageid&`$filter=name eq 'PreImage' and _sdkmessageprocessingstepid_value eq $stepId"
    if ($existingImage.value.Count -gt 0) {
        Write-Output "[VERIFY] Pre-Image on '$stepName' already exists."
    } else {
        $imageBody = @{
            name                            = 'PreImage'
            entityalias                     = 'PreImage'
            imagetype                       = 0   # Pre-Image
            attributes                      = 'hsv_status'
            messagepropertyname             = 'Target'
            'sdkmessageprocessingstepid@odata.bind' = "/sdkmessageprocessingsteps($stepId)"
        }
        Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'sdkmessageprocessingstepimages' -Body $imageBody | Out-Null
        Write-Output "[CREATE] Pre-Image on '$stepName' created."
    }
}

Register-StepForEntity 'hsv_workorder'
Register-StepForEntity 'hsv_inboundmessage'

Write-Output ""
Write-Output "=== DONE ==="
