#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'Get-NvmeSlots.ps1'

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message })
    throw ("Get-NvmeSlots.ps1 failed to parse: " + ($messages -join '; '))
}

function Get-ScriptFunctionText {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$Name
    )

    $functions = @($Ast.FindAll({
        param($node)
        return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst])
    }, $true) | Where-Object { $_.Name -eq $Name })

    if ($functions.Count -eq 0) {
        throw ($Name + ' was not found in Get-NvmeSlots.ps1.')
    }

    return $functions[0].Extent.Text
}

# Load only the pure functions. Dot-sourcing the full script would enumerate
# hardware and is intentionally avoided in this test.
. ([scriptblock]::Create((Get-ScriptFunctionText -Ast $ast -Name 'Test-IsM2SlotType')))
. ([scriptblock]::Create((Get-ScriptFunctionText -Ast $ast -Name 'Get-SlotAddressFlags')))
. ([scriptblock]::Create((Get-ScriptFunctionText -Ast $ast -Name 'Get-RoleBonus')))
. ([scriptblock]::Create((Get-ScriptFunctionText -Ast $ast -Name 'Get-MatchedConfidence')))
. ([scriptblock]::Create((Get-ScriptFunctionText -Ast $ast -Name 'Get-SlotCandidates')))

# --- M.2 connector classification -----------------------------------------

foreach ($typeCode in @(0x14, 0x15, 0x16, 0x17)) {
    if (-not (Test-IsM2SlotType -TypeCode $typeCode)) {
        throw ('Expected SMBIOS slot type 0x{0:X2} to be classified as M.2.' -f $typeCode)
    }
}

foreach ($typeCode in @(0x01, 0x02, 0x03, 0x09, 0x0A, 0x0B, 0x0C, 0x35, 0x36, 0x3A)) {
    if (Test-IsM2SlotType -TypeCode $typeCode) {
        throw ('Expected SMBIOS slot type 0x{0:X2} not to be classified as M.2.' -f $typeCode)
    }
}

# --- SMBIOS Type 9 bus address semantics ----------------------------------
# Regression: a devfn of 0 on bus 4 (04:00.0) is a specified address. Only
# 0xFF means "unknown"; an all-zero pair is treated as unpopulated firmware.

$addressCases = @(
    @{ Label = 'bus 4, devfn 0 (04:00.0)'; Bus = 4; DevFn = 0; BusSpecified = $true; DevFnSpecified = $true },
    @{ Label = 'bus 7, devfn 64 (07:40.0)'; Bus = 7; DevFn = 64; BusSpecified = $true; DevFnSpecified = $true },
    @{ Label = 'bus 4, devfn 0xFF (bus only)'; Bus = 4; DevFn = 0xFF; BusSpecified = $true; DevFnSpecified = $false },
    @{ Label = 'bus 0, devfn 10 (devfn only)'; Bus = 0; DevFn = 10; BusSpecified = $false; DevFnSpecified = $true },
    @{ Label = 'bus 0, devfn 0 (unpopulated)'; Bus = 0; DevFn = 0; BusSpecified = $false; DevFnSpecified = $false },
    @{ Label = 'bus 0xFF, devfn 0xFF (unknown)'; Bus = 0xFF; DevFn = 0xFF; BusSpecified = $false; DevFnSpecified = $false }
)

foreach ($case in $addressCases) {
    $flags = Get-SlotAddressFlags -Bus $case.Bus -DevFn $case.DevFn
    if ($flags.BusSpecified -ne $case.BusSpecified -or $flags.DevFnSpecified -ne $case.DevFnSpecified) {
        throw ('Unexpected address flags for {0}: busSpecified={1}, devFnSpecified={2}' -f
            $case.Label, $flags.BusSpecified, $flags.DevFnSpecified)
    }
}

# --- Slot candidate matching ----------------------------------------------
# Regression: an exact bus/device/function match must be the only candidate for
# a fully specified slot, so a sibling switch port on the same bus cannot claim
# the slot. Bus-only matching remains available when firmware reports 0xFF.

function New-FakePort {
    param([int]$Bus, [int]$DevFn)

    return [pscustomobject]@{
        Device = [pscustomobject]@{
            InstanceId = ('PCI\FAKE\PORT\{0:X2}{1:X2}' -f $Bus, $DevFn)
            Bus        = $Bus
            DevFn      = $DevFn
        }
        Distance = 0
    }
}

function New-FakeEndpoint {
    param([string]$Name, [string]$Class, [bool]$IsNvme, [object[]]$Ports)

    return [pscustomobject]@{
        InstanceId = ('PCI\FAKE\ENDPOINT\' + $Name)
        Name       = $Name
        Class      = $Class
        IsNvme     = $IsNvme
        Ports      = @($Ports)
    }
}

function New-FakeSlot {
    param([int]$Bus, [int]$DevFn)

    $flags = Get-SlotAddressFlags -Bus $Bus -DevFn $DevFn
    return [pscustomobject]@{
        Index          = 0
        Designation    = 'PCIEX16_3'
        Bus            = $Bus
        DevFn          = $DevFn
        BusSpecified   = $flags.BusSpecified
        DevFnSpecified = $flags.DevFnSpecified
        IsPcie         = $true
        IsM2           = $false
    }
}

$nvme = New-FakeEndpoint -Name 'Standard NVM Express Controller' -Class 'SCSIAdapter' -IsNvme $true -Ports @(New-FakePort -Bus 4 -DevFn 0)
$sata = New-FakeEndpoint -Name 'Standard SATA AHCI Controller' -Class 'HDC' -IsNvme $false -Ports @(New-FakePort -Bus 4 -DevFn 13)

$exactCandidates = @(Get-SlotCandidates -Slots @(New-FakeSlot -Bus 4 -DevFn 0) -Endpoints @($nvme, $sata))
if ($exactCandidates.Count -ne 1) {
    throw ('Expected one exact candidate for bus 4 devfn 0, got {0}.' -f $exactCandidates.Count)
}
if ($exactCandidates[0].Endpoint.InstanceId -ne $nvme.InstanceId) {
    throw 'Expected the NVMe endpoint to own the exact bus/device/function match.'
}
if ($exactCandidates[0].Kind -ne 'exact' -or $exactCandidates[0].Port.DevFn -ne 0) {
    throw ('Expected an exact match on port devfn 0, got kind={0} devfn={1}.' -f
        $exactCandidates[0].Kind, $exactCandidates[0].Port.DevFn)
}

$busOnlyCandidates = @(Get-SlotCandidates -Slots @(New-FakeSlot -Bus 4 -DevFn 0xFF) -Endpoints @($nvme, $sata))
if ($busOnlyCandidates.Count -ne 2) {
    throw ('Expected two bus-only candidates when devfn is unknown, got {0}.' -f $busOnlyCandidates.Count)
}
foreach ($candidate in $busOnlyCandidates) {
    if ($candidate.Kind -ne 'medium') {
        throw ('Expected bus-only fallback to use medium confidence, got {0}.' -f $candidate.Kind)
    }
}

$unpopulatedCandidates = @(Get-SlotCandidates -Slots @(New-FakeSlot -Bus 0 -DevFn 0) -Endpoints @($nvme, $sata))
if ($unpopulatedCandidates.Count -ne 0) {
    throw ('Expected no candidates for an unpopulated address, got {0}.' -f $unpopulatedCandidates.Count)
}

Write-Host 'PowerShell compatibility and SMBIOS slot classification checks passed.'
