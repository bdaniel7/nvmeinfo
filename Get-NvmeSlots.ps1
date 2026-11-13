#requires -Version 5.1
<#
.SYNOPSIS
    Reports NVMe drives and the motherboard PCIe/M.2 slots they are connected to.

.DESCRIPTION
    Reads the SMBIOS Type 9 slot table directly from firmware, walks the Windows
    Plug and Play device tree from every NVMe controller up to the PCIe root or
    switch port that feeds its slot, and matches that port to a physical
    motherboard slot label such as M.2_1 or PCIEX16_1.

    The script uses only components that ship with Windows 10. The PnpDevice and
    Storage PowerShell modules must be present (they are inbox modules).

.PARAMETER Html
    Write a self-contained HTML report to this path.

.PARAMETER Json
    Write the collected data as JSON to this path.

.PARAMETER Csv
    Write a flat slot/device table as CSV to this path.

.PARAMETER Open
    Open the HTML report after writing it. If -Html is not supplied,
    .\NvmeSlotReport.html is used.

.PARAMETER NoColor
    Disable colored console output.

.EXAMPLE
    .\Get-NvmeSlots.ps1

.EXAMPLE
    .\Get-NvmeSlots.ps1 -Html .\NvmeSlotReport.html -Open

.EXAMPLE
    .\Get-NvmeSlots.ps1 -Json .\nvme-slots.json -Csv .\nvme-slots.csv
#>
[CmdletBinding()]
param(
    [string]$Html,
    [string]$Json,
    [string]$Csv,
    [switch]$Open,
    [switch]$NoColor
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ScriptVersion = '1.1'
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:UseColor = -not $NoColor
if ([Console]::IsOutputRedirected) { $script:UseColor = $false }

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

function Write-ColorLine {
    param(
        [string]$Text = '',
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    if ($script:UseColor) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

function Format-Size {
    param([object]$Bytes)
    if ($null -eq $Bytes) { return '' }
    [double]$value = 0
    if (-not [double]::TryParse([string]$Bytes, [ref]$value)) { return '' }
    if ($value -le 0) { return '' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $index = 0
    while ($value -ge 1000 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1000
        $index++
    }
    if ($index -le 1) {
        return ('{0} {1}' -f $value.ToString('0', $script:Invariant), $units[$index])
    }
    return ('{0} {1}' -f $value.ToString('0.00', $script:Invariant), $units[$index])
}

function Format-PciAddress {
    param([object]$Bus, [object]$Device, [object]$Function)
    if ($null -eq $Bus -or $null -eq $Device -or $null -eq $Function) { return '' }
    return ('{0:X2}:{1:X2}.{2}' -f ([int]$Bus), ([int]$Device), ([int]$Function))
}

function Format-Link {
    param([object]$Speed, [object]$Width)
    if ($null -eq $Speed -and $null -eq $Width) { return '' }
    $gen = ''
    if ($null -ne $Speed) {
        switch ([int]$Speed) {
            1 { $gen = 'PCIe 1.0' }
            2 { $gen = 'PCIe 2.0' }
            3 { $gen = 'PCIe 3.0' }
            4 { $gen = 'PCIe 4.0' }
            5 { $gen = 'PCIe 5.0' }
            6 { $gen = 'PCIe 6.0' }
            default { $gen = 'PCIe ?' }
        }
    }
    $lanes = ''
    if ($null -ne $Width -and [int]$Width -gt 0) { $lanes = ('x{0}' -f [int]$Width) }
    return (($gen + ' ' + $lanes).Trim())
}

function Format-LinkComparison {
    param(
        [object]$CurrentSpeed,
        [object]$CurrentWidth,
        [object]$MaximumSpeed,
        [object]$MaximumWidth
    )

    $current = Format-Link $CurrentSpeed $CurrentWidth
    $maximum = Format-Link $MaximumSpeed $MaximumWidth
    if ([string]::IsNullOrWhiteSpace($current)) { $current = 'unavailable' }
    if ([string]::IsNullOrWhiteSpace($maximum)) { $maximum = 'unavailable' }
    return ('{0} / {1}' -f $current, $maximum)
}

function Format-Column {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) {
        if ($Width -le 3) { return $Text.Substring(0, $Width) }
        return $Text.Substring(0, $Width - 3) + '...'
    }
    return $Text.PadRight($Width)
}

function Get-BiosShortName {
    param([string]$BiosName)
    if ([string]::IsNullOrWhiteSpace($BiosName)) { return '' }
    $value = $BiosName.Trim()
    $value = $value -replace '^\\_SB\.PCI0\.', ''
    return $value
}

function Resolve-OutputPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $full = Resolve-OutputPath $Path
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($full, $Text, $encoding)
    return $full
}

function Html-Encode {
    param([object]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

# ---------------------------------------------------------------------------
# SMBIOS reader
# ---------------------------------------------------------------------------

if (-not ('NvmeSlotSmbiosReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NvmeSlotSmbiosReader
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetSystemFirmwareTable(
        uint FirmwareTableProviderSignature,
        uint FirmwareTableID,
        IntPtr pFirmwareTableBuffer,
        uint BufferSize);

    public static byte[] ReadRawTable()
    {
        const uint RSMB = 0x52534D42;
        uint size = GetSystemFirmwareTable(RSMB, 0, IntPtr.Zero, 0);
        if (size == 0)
            throw new InvalidOperationException("GetSystemFirmwareTable returned no SMBIOS data.");
        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            uint written = GetSystemFirmwareTable(RSMB, 0, buffer, size);
            if (written == 0)
                throw new InvalidOperationException("GetSystemFirmwareTable failed to return the SMBIOS table.");
            byte[] data = new byte[written];
            Marshal.Copy(buffer, data, 0, (int)written);
            return data;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@
}

$script:SlotTypeNames = @{
    0x01 = 'Other'
    0x02 = 'Unknown'
    0x03 = 'ISA'
    0x04 = 'MCA'
    0x05 = 'EISA'
    0x06 = 'PCI'
    0x07 = 'PC Card (PCMCIA)'
    0x08 = 'VLB'
    0x09 = 'Proprietary'
    0x0A = 'Processor Card'
    0x0B = 'Proprietary Memory Card'
    0x0C = 'I/O Riser Card'
    0x0D = 'NuBus'
    0x0E = 'PCI-66'
    0x0F = 'AGP'
    0x10 = 'AGP 2x'
    0x11 = 'AGP 4x'
    0x12 = 'PCI-X'
    0x13 = 'AGP 8x'
    0x14 = 'M.2 Socket 1-DP'
    0x15 = 'M.2 Socket 1-SD'
    0x16 = 'M.2 Socket 2'
    0x17 = 'M.2 Socket 3'
    0x18 = 'MXM Type I'
    0x19 = 'MXM Type II'
    0x1A = 'MXM Type III'
    0x1B = 'MXM Type III-HE'
    0x1C = 'MXM Type IV'
    0x1D = 'MXM 3.0 Type A'
    0x1E = 'MXM 3.0 Type B'
    0x1F = 'PCIe Gen 2 SFF-8639'
    0x20 = 'PCIe Gen 3 SFF-8639'
    0x21 = 'PCIe Mini 52-pin with keep-outs'
    0x22 = 'PCIe Mini 52-pin without keep-outs'
    0x23 = 'PCIe Mini 76-pin'
    0x24 = 'PCIe Gen 4 SFF-8639'
    0x25 = 'PCIe Gen 5 SFF-8639'
    0x26 = 'OCP NIC 3.0 SFF'
    0x27 = 'OCP NIC 3.0 LFF'
    0x28 = 'OCP NIC prior to 3.0'
    0x29 = 'CXL Flexbus 1.0'
    0x30 = 'PC-98/C20'
    0x31 = 'PC-98/C24'
    0x32 = 'PC-98/E'
    0x33 = 'PC-98/Local Bus'
    0x34 = 'PC-98/Card'
    0x35 = 'PCIe (Base)'
    0x36 = 'PCIe (x1)'
    0x37 = 'PCIe (x2)'
    0x38 = 'PCIe (x4)'
    0x39 = 'PCIe (x8)'
    0x3A = 'PCIe (x16)'
    0x3B = 'PCIe (x32)'
    0x3C = 'PCIe Gen 2 (Base)'
    0x3D = 'PCIe Gen 2 (x1)'
    0x3E = 'PCIe Gen 2 (x2)'
    0x3F = 'PCIe Gen 2 (x4)'
    0x40 = 'PCIe Gen 2 (x8)'
    0x41 = 'PCIe Gen 2 (x16)'
    0x42 = 'PCIe Gen 2 (x32)'
    0x43 = 'PCIe Gen 3 (Base)'
    0x44 = 'PCIe Gen 3 (x1)'
    0x45 = 'PCIe Gen 3 (x2)'
    0x46 = 'PCIe Gen 3 (x4)'
    0x47 = 'PCIe Gen 3 (x8)'
    0x48 = 'PCIe Gen 3 (x16)'
    0x49 = 'PCIe Gen 3 (x32)'
    0x4A = 'PCIe Gen 4 (Base)'
    0x4B = 'PCIe Gen 4 (x1)'
    0x4C = 'PCIe Gen 4 (x2)'
    0x4D = 'PCIe Gen 4 (x4)'
    0x4E = 'PCIe Gen 4 (x8)'
    0x4F = 'PCIe Gen 4 (x16)'
    0x50 = 'PCIe Gen 4 (x32)'
    0x51 = 'PCIe Gen 5 (Base)'
    0x52 = 'PCIe Gen 5 (x1)'
    0x53 = 'PCIe Gen 5 (x2)'
    0x54 = 'PCIe Gen 5 (x4)'
    0x55 = 'PCIe Gen 5 (x8)'
    0x56 = 'PCIe Gen 5 (x16)'
    0x57 = 'PCIe Gen 5 (x32)'
    0x58 = 'PCIe Gen 6 and Beyond'
    0x59 = 'EDSFF E1'
    0x5A = 'EDSFF E3'
    0xA5 = 'PCIe (Base)'
    0xA6 = 'PCIe (x1)'
    0xA7 = 'PCIe (x2)'
    0xA8 = 'PCIe (x4)'
    0xA9 = 'PCIe (x8)'
    0xAA = 'PCIe (x16)'
    0xAB = 'PCIe (x32)'
}

$script:SlotWidthNames = @{
    0x01 = 'Other'
    0x02 = 'Unknown'
    0x03 = '8-bit'
    0x04 = '16-bit'
    0x05 = '32-bit'
    0x06 = '64-bit'
    0x07 = '128-bit'
    0x08 = 'x1'
    0x09 = 'x2'
    0x0A = 'x4'
    0x0B = 'x8'
    0x0C = 'x12'
    0x0D = 'x16'
    0x0E = 'x32'
    0x0F = 'x64'
}

$script:SlotUsageNames = @{
    0x01 = 'Other'
    0x02 = 'Unknown'
    0x03 = 'Available'
    0x04 = 'In Use'
}

function Get-SmbiosString {
    param([object]$Strings, [int]$Index)
    if ($Index -le 0 -or $Index -gt $Strings.Count) { return '' }
    return [string]$Strings[$Index - 1]
}

function Read-SmbiosStringSet {
    param([byte[]]$Data, [int]$Offset, [int]$End)
    $list = New-Object System.Collections.ArrayList
    $position = $Offset
    if ($position -lt $End) {
        if ($Data[$position] -eq 0) {
            $position += 2
            if ($position -gt $End) { $position = $End }
        } else {
            while ($position -lt $End) {
                $start = $position
                while ($position -lt $End -and $Data[$position] -ne 0) { $position++ }
                if ($position -gt $start) {
                    [void]$list.Add([System.Text.Encoding]::ASCII.GetString($Data, $start, $position - $start))
                } else {
                    [void]$list.Add('')
                }
                $position++
                if ($position -ge $End -or $Data[$position] -eq 0) {
                    $position++
                    break
                }
            }
        }
    }
    return [pscustomobject]@{
        Strings    = $list
        NextOffset = $position
    }
}

function Test-IsM2SlotType {
    param([int]$TypeCode)

    return ($TypeCode -ge 0x14 -and $TypeCode -le 0x17)
}

function Read-SmbiosTable {
    $raw = [NvmeSlotSmbiosReader]::ReadRawTable()
    if ($raw.Length -lt 8) { throw 'The SMBIOS table returned by firmware is too small.' }

    $declaredLength = [BitConverter]::ToUInt32($raw, 4)
    $end = [Math]::Min([long]$raw.Length, [long](8 + $declaredLength))

    $result = [pscustomobject]@{
        Version = ('{0}.{1}' -f $raw[1], $raw[2])
        Major   = [int]$raw[1]
        Minor   = [int]$raw[2]
        Bios    = $null
        System  = $null
        Board   = $null
        Slots   = New-Object System.Collections.ArrayList
    }

    $offset = 8
    while ($offset + 4 -le $end) {
        $type = [int]$raw[$offset]
        $length = [int]$raw[$offset + 1]
        if ($length -lt 4) { break }
        if (($offset + $length) -gt $end) { break }

        $stringSet = Read-SmbiosStringSet -Data $raw -Offset ($offset + $length) -End $end
        $strings = $stringSet.Strings

        switch ($type) {
            0 {
                $result.Bios = [pscustomobject]@{
                    Vendor      = Get-SmbiosString $strings $(if ($length -gt 4) { [int]$raw[$offset + 4] } else { 0 })
                    Version     = Get-SmbiosString $strings $(if ($length -gt 5) { [int]$raw[$offset + 5] } else { 0 })
                    ReleaseDate = Get-SmbiosString $strings $(if ($length -gt 8) { [int]$raw[$offset + 8] } else { 0 })
                }
            }
            1 {
                $result.System = [pscustomobject]@{
                    Manufacturer = Get-SmbiosString $strings $(if ($length -gt 4) { [int]$raw[$offset + 4] } else { 0 })
                    Product      = Get-SmbiosString $strings $(if ($length -gt 5) { [int]$raw[$offset + 5] } else { 0 })
                    Version      = Get-SmbiosString $strings $(if ($length -gt 6) { [int]$raw[$offset + 6] } else { 0 })
                    Serial       = Get-SmbiosString $strings $(if ($length -gt 7) { [int]$raw[$offset + 7] } else { 0 })
                    SKU          = Get-SmbiosString $strings $(if ($length -gt 8) { [int]$raw[$offset + 8] } else { 0 })
                    Family       = Get-SmbiosString $strings $(if ($length -gt 9) { [int]$raw[$offset + 9] } else { 0 })
                }
            }
            2 {
                $result.Board = [pscustomobject]@{
                    Manufacturer = Get-SmbiosString $strings $(if ($length -gt 4) { [int]$raw[$offset + 4] } else { 0 })
                    Product      = Get-SmbiosString $strings $(if ($length -gt 5) { [int]$raw[$offset + 5] } else { 0 })
                    Version      = Get-SmbiosString $strings $(if ($length -gt 6) { [int]$raw[$offset + 6] } else { 0 })
                    Serial       = Get-SmbiosString $strings $(if ($length -gt 7) { [int]$raw[$offset + 7] } else { 0 })
                }
            }
            9 {
                if ($length -ge 0x11) {
                    $bus = [int]$raw[$offset + 0x0F]
                    $devFn = [int]$raw[$offset + 0x10]
                    $segment = [int][BitConverter]::ToUInt16($raw, $offset + 0x0D)
                    $slotId = 0
                    if ($length -ge 0x0B) {
                        $slotId = [int][BitConverter]::ToUInt16($raw, $offset + 0x09)
                    }
                    $typeCode = [int]$raw[$offset + 5]
                    $widthCode = [int]$raw[$offset + 6]
                    $usageCode = [int]$raw[$offset + 7]

                    $typeName = if ($script:SlotTypeNames.ContainsKey($typeCode)) { $script:SlotTypeNames[$typeCode] } else { ('Slot type 0x{0:X2}' -f $typeCode) }
                    $widthName = if ($script:SlotWidthNames.ContainsKey($widthCode)) { $script:SlotWidthNames[$widthCode] } else { ('Width 0x{0:X2}' -f $widthCode) }
                    $usageName = if ($script:SlotUsageNames.ContainsKey($usageCode)) { $script:SlotUsageNames[$usageCode] } else { ('Usage 0x{0:X2}' -f $usageCode) }

                    [void]$result.Slots.Add([pscustomobject]@{
                        Index         = $result.Slots.Count
                        Designation   = Get-SmbiosString $strings ([int]$raw[$offset + 4])
                        TypeCode      = $typeCode
                        TypeName      = $typeName
                        WidthCode     = $widthCode
                        WidthName     = $widthName
                        UsageCode     = $usageCode
                        UsageName     = $usageName
                        SlotId        = $slotId
                        Segment       = $segment
                        Bus           = $bus
                        DevFn         = $devFn
                        BusSpecified  = ($bus -ne 0 -and $bus -ne 0xFF)
                        DevFnSpecified = ($devFn -ne 0 -and $devFn -ne 0xFF)
                        IsM2          = (Test-IsM2SlotType -TypeCode $typeCode)
                        # Only connector types that explicitly describe PCI/PCIe-capable
                        # expansion interfaces participate in PCIe endpoint matching.
                        # Keep other Type 9 records in the inventory, but don't treat
                        # generic/legacy/unknown entries (e.g. a SIM card slot) as PCIe.
                        IsPcie        = (
                            $typeCode -in @(
                                0x06, 0x0E, 0x12,
                                0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25,
                                0x26, 0x27, 0x28, 0x29,
                                0x59, 0x5A
                            ) -or
                            ($typeCode -ge 0x14 -and $typeCode -le 0x17) -or
                            ($typeCode -ge 0x35 -and $typeCode -le 0x58) -or
                            ($typeCode -ge 0xA5 -and $typeCode -le 0xAB)
                        )
                        Occupants     = @()
                        Status        = ''
                        Confidence    = 'unmapped'
                        MatchReason   = ''
                        UsageMismatch = $false
                    })
                }
            }
            127 { break }
        }

        if ($type -eq 127) { break }
        $offset = [int]$stringSet.NextOffset
    }

    return $result
}

# ---------------------------------------------------------------------------
# Plug and Play device cache
# ---------------------------------------------------------------------------

$script:RawDevices = @{}
$script:DeviceCache = @{}
$script:PropertyCache = @{}

function Initialize-PnpCache {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        throw 'The PnpDevice module is required. It ships with Windows 10.'
    }
    if (-not (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) {
        throw 'The Get-PnpDeviceProperty cmdlet is required. It ships with Windows 10.'
    }

    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    foreach ($device in $devices) {
        if ($device.InstanceId) {
            $script:RawDevices[$device.InstanceId] = $device
        }
    }
}

function Get-DevicePropertySet {
    param(
        [string]$InstanceId,
        [bool]$IsPci
    )

    if ($script:PropertyCache.ContainsKey($InstanceId)) {
        return $script:PropertyCache[$InstanceId]
    }

    $set = [ordered]@{
        Parent       = ''
        Bus          = $null
        Address      = $null
        BiosName     = ''
        Location     = ''
        LocationPaths = @()
        DeviceDesc   = ''
        Service      = ''
        BaseClass    = $null
        SubClass     = $null
        ProgIf       = $null
        LinkSpeed    = $null
        LinkWidth    = $null
        MaxLinkSpeed = $null
        MaxLinkWidth = $null
    }

    if ($IsPci) {
        $keys = @(
            'DEVPKEY_Device_Parent',
            'DEVPKEY_Device_BusNumber',
            'DEVPKEY_Device_Address',
            'DEVPKEY_Device_BiosDeviceName',
            'DEVPKEY_Device_LocationInfo',
            'DEVPKEY_Device_LocationPaths',
            'DEVPKEY_Device_DeviceDesc',
            'DEVPKEY_Device_Service',
            'DEVPKEY_PciDevice_BaseClass',
            'DEVPKEY_PciDevice_SubClass',
            'DEVPKEY_PciDevice_ProgIf',
            'DEVPKEY_PciDevice_CurrentLinkSpeed',
            'DEVPKEY_PciDevice_CurrentLinkWidth',
            'DEVPKEY_PciDevice_MaxLinkSpeed',
            'DEVPKEY_PciDevice_MaxLinkWidth'
        )
    } else {
        $keys = @('DEVPKEY_Device_Parent')
    }

    try {
        $properties = @(Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $keys -ErrorAction SilentlyContinue)
        foreach ($property in $properties) {
            if (-not $property.KeyName) { continue }
            switch ($property.KeyName) {
                'DEVPKEY_Device_Parent' {
                    if ($null -ne $property.Data) { $set.Parent = [string]$property.Data }
                }
                'DEVPKEY_Device_BusNumber' {
                    if ($null -ne $property.Data) { $set.Bus = [int]$property.Data }
                }
                'DEVPKEY_Device_Address' {
                    if ($null -ne $property.Data) { $set.Address = [int]$property.Data }
                }
                'DEVPKEY_Device_BiosDeviceName' {
                    if ($null -ne $property.Data) { $set.BiosName = [string]$property.Data }
                }
                'DEVPKEY_Device_LocationInfo' {
                    if ($null -ne $property.Data) { $set.Location = [string]$property.Data }
                }
                'DEVPKEY_Device_LocationPaths' {
                    if ($null -ne $property.Data) {
                        $set.LocationPaths = @($property.Data | ForEach-Object { [string]$_ })
                    }
                }
                'DEVPKEY_Device_DeviceDesc' {
                    if ($null -ne $property.Data) { $set.DeviceDesc = [string]$property.Data }
                }
                'DEVPKEY_Device_Service' {
                    if ($null -ne $property.Data) { $set.Service = [string]$property.Data }
                }
                'DEVPKEY_PciDevice_BaseClass' {
                    if ($null -ne $property.Data) { $set.BaseClass = [int]$property.Data }
                }
                'DEVPKEY_PciDevice_SubClass' {
                    if ($null -ne $property.Data) { $set.SubClass = [int]$property.Data }
                }
                'DEVPKEY_PciDevice_ProgIf' {
                    if ($null -ne $property.Data) { $set.ProgIf = [int]$property.Data }
                }
                'DEVPKEY_PciDevice_CurrentLinkSpeed' {
                    if ($null -ne $property.Data) { $set.LinkSpeed = [int]$property.Data }
                }
                'DEVPKEY_PciDevice_CurrentLinkWidth' {
                    if ($null -ne $property.Data) { $set.LinkWidth = [int]$property.Data }
                }
                'DEVPKEY_PciDevice_MaxLinkSpeed' {
                    if ($null -ne $property.Data) { $set.MaxLinkSpeed = [int]$property.Data }
                }
                'DEVPKEY_PciDevice_MaxLinkWidth' {
                    if ($null -ne $property.Data) { $set.MaxLinkWidth = [int]$property.Data }
                }
            }
        }
    } catch {
        # Some devices do not expose every property. Partial data is still useful.
    }

    $script:PropertyCache[$InstanceId] = $set
    return $set
}

function Get-DeviceInfo {
    param([string]$InstanceId)

    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }
    if ($script:DeviceCache.ContainsKey($InstanceId)) {
        return $script:DeviceCache[$InstanceId]
    }

    $raw = $null
    if ($script:RawDevices.ContainsKey($InstanceId)) {
        $raw = $script:RawDevices[$InstanceId]
    } else {
        $raw = @(Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($raw) { $script:RawDevices[$InstanceId] = $raw }
    }

    if (-not $raw) {
        $script:DeviceCache[$InstanceId] = $null
        return $null
    }

    $isPci = $InstanceId.StartsWith('PCI\', [System.StringComparison]::OrdinalIgnoreCase)
    $properties = Get-DevicePropertySet -InstanceId $raw.InstanceId -IsPci $isPci

    $bus = $properties.Bus
    $deviceNumber = $null
    $functionNumber = $null
    $devFn = $null

    if ($null -ne $properties.Address) {
        $deviceNumber = [int](($properties.Address -shr 16) -band 0xFFFF)
        $functionNumber = [int]($properties.Address -band 0xFFFF)
        $devFn = [int](($deviceNumber -shl 3) -bor $functionNumber)
    } elseif ($null -ne $bus -and $properties.Location -match 'bus\s+(\d+).*?device\s+(\d+).*?function\s+(\d+)') {
        $bus = [int]$Matches[1]
        $deviceNumber = [int]$Matches[2]
        $functionNumber = [int]$Matches[3]
        $devFn = [int](($deviceNumber -shl 3) -bor $functionNumber)
    }

    $name = [string]$raw.FriendlyName
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$properties.DeviceDesc }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$raw.Description }

    $service = [string]$raw.Service
    if ([string]::IsNullOrWhiteSpace($service)) { $service = [string]$properties.Service }

    $info = [pscustomobject]@{
        InstanceId   = [string]$raw.InstanceId
        Name         = $name
        Class        = [string]$raw.Class
        Status       = [string]$raw.Status
        Service      = $service
        IsPci        = $isPci
        Parent       = [string]$properties.Parent
        Bus          = $bus
        DeviceNumber = $deviceNumber
        Function     = $functionNumber
        DevFn        = $devFn
        Address      = $properties.Address
        BiosName     = [string]$properties.BiosName
        Location     = [string]$properties.Location
        LocationPaths = @($properties.LocationPaths)
        BaseClass    = $properties.BaseClass
        SubClass     = $properties.SubClass
        ProgIf       = $properties.ProgIf
        LinkSpeed    = $properties.LinkSpeed
        LinkWidth    = $properties.LinkWidth
        MaxLinkSpeed = $properties.MaxLinkSpeed
        MaxLinkWidth = $properties.MaxLinkWidth
        IsBridge     = ($isPci -and $null -ne $properties.BaseClass -and [int]$properties.BaseClass -eq 6)
    }

    $script:DeviceCache[$InstanceId] = $info
    return $info
}

function Get-FirstPciAncestor {
    param([object]$Device)

    if (-not $Device) { return $null }
    $seen = @{}
    $current = $Device
    while ($current) {
        $parentId = [string]$current.Parent
        if ([string]::IsNullOrWhiteSpace($parentId) -or $seen.ContainsKey($parentId)) { break }
        $seen[$parentId] = $true
        $parent = Get-DeviceInfo $parentId
        if (-not $parent) { break }
        if ($parent.IsPci) { return $parent }
        $current = $parent
    }
    return $null
}

function Get-UpstreamPorts {
    param([object]$Device)

    $ports = New-Object System.Collections.ArrayList
    if (-not $Device) { return $ports }

    $seen = @{}
    $parentId = [string]$Device.Parent
    $distance = 0

    while (-not [string]::IsNullOrWhiteSpace($parentId) -and -not $seen.ContainsKey($parentId)) {
        $seen[$parentId] = $true
        $parent = Get-DeviceInfo $parentId
        if (-not $parent) { break }
        if ($parent.IsPci -and $parent.IsBridge) {
            [void]$ports.Add([pscustomobject]@{
                Device   = $parent
                Distance = $distance
            })
            $distance++
        }
        $parentId = [string]$parent.Parent
    }

    if ($ports.Count -eq 0 -and $Device.IsPci) {
        [void]$ports.Add([pscustomobject]@{
            Device   = $Device
            Distance = 0
        })
    }

    return $ports
}

function Test-NvmeController {
    param([object]$Device)

    if (-not $Device -or -not $Device.IsPci) { return $false }

    if (-not [string]::IsNullOrWhiteSpace($Device.Service)) {
        $service = [string]$Device.Service
        if ($service -eq 'stornvme' -or $service -eq 'nvme') { return $true }
    }
    if ($null -ne $Device.BaseClass -and [int]$Device.BaseClass -eq 1 -and $null -ne $Device.SubClass -and [int]$Device.SubClass -eq 8) {
        return $true
    }
    if ($Device.Name -match 'NVM Express|NVMe') { return $true }
    return $false
}

function Get-PciEndpoints {
    $endpoints = New-Object System.Collections.ArrayList

    foreach ($instanceId in @($script:RawDevices.Keys)) {
        if (-not $instanceId.StartsWith('PCI\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $device = Get-DeviceInfo $instanceId
        if (-not $device) { continue }
        if ($device.IsBridge) { continue }

        $endpoint = [pscustomobject]@{
            InstanceId     = $device.InstanceId
            Name           = $device.Name
            Class          = $device.Class
            Service        = $device.Service
            Bus            = $device.Bus
            DeviceNumber   = $device.DeviceNumber
            Function       = $device.Function
            DevFn          = $device.DevFn
            Address        = $device.Address
            PciAddress     = (Format-PciAddress $device.Bus $device.DeviceNumber $device.Function)
            Location       = $device.Location
            LocationPaths  = @($device.LocationPaths)
            BiosName       = $device.BiosName
            LinkSpeed      = $device.LinkSpeed
            LinkWidth      = $device.LinkWidth
            MaxLinkSpeed   = $device.MaxLinkSpeed
            MaxLinkWidth   = $device.MaxLinkWidth
            Link           = (Format-Link $device.LinkSpeed $device.LinkWidth)
            MaxLink        = (Format-Link $device.MaxLinkSpeed $device.MaxLinkWidth)
            IsNvme         = (Test-NvmeController $device)
            Ports          = @(Get-UpstreamPorts $device)
            Drive          = $null
            Slot           = $null
            Confidence     = 'unmapped'
            MatchReason    = ''
        }
        [void]$endpoints.Add($endpoint)
    }

    return $endpoints
}

# ---------------------------------------------------------------------------
# Slot matching
# ---------------------------------------------------------------------------

function Get-RoleBonus {
    param([object]$Slot, [object]$Endpoint)

    $bonus = 0
    $designation = [string]$Slot.Designation

    if ($Slot.IsM2) {
        if ($Endpoint.IsNvme) {
            $bonus += 12
        } elseif ($Endpoint.Class -eq 'Net' -and $Endpoint.Name -match 'Wi-?Fi|WLAN|Wireless') {
            $bonus += 10
        } elseif ($Endpoint.Class -ne 'Net') {
            $bonus -= 12
        }
    }
    if ($designation -match 'M\.2|NVME|U\.2') {
        if ($Endpoint.IsNvme) { $bonus += 8 }
    }
    if ($designation -match 'WIFI|WLAN|WIRELESS') {
        if ($Endpoint.Class -eq 'Net') { $bonus += 10 }
    }
    if ($designation -match 'PCIEX|PCIE|PCI-E') {
        if ($Endpoint.Class -eq 'Display') { $bonus += 4 }
    }
    return $bonus
}

function Get-MatchedConfidence {
    param([string]$Kind, [int]$Distance)

    if ($Kind -eq 'exact') {
        if ($Distance -le 0) { return 'exact' }
        return 'high'
    }
    if ($Kind -eq 'high') {
        if ($Distance -le 0) { return 'high' }
        return 'medium'
    }
    if ($Kind -eq 'medium') { return 'medium' }
    return 'inferred'
}

function Get-LowestConfidence {
    param([object[]]$Values)

    $order = @('inferred', 'medium', 'high', 'exact')
    $lowestIndex = $order.Count - 1
    $lowest = 'exact'
    foreach ($value in $Values) {
        $text = [string]$value
        $index = $order.IndexOf($text)
        if ($index -lt 0) { continue }
        if ($index -lt $lowestIndex) {
            $lowestIndex = $index
            $lowest = $text
        }
    }
    return $lowest
}

function Get-SlotCandidates {
    param([object[]]$Slots, [object[]]$Endpoints)

    $candidates = New-Object System.Collections.ArrayList

    foreach ($endpoint in $Endpoints) {
        foreach ($slot in $Slots) {
            if (-not $slot.IsPcie) { continue }
            foreach ($entry in $endpoint.Ports) {
                $port = $entry.Device
                if ($null -eq $port.Bus -or $null -eq $port.DevFn) { continue }

                $score = 0
                $kind = ''
                $reason = ''
                $distance = [int]$entry.Distance

                if ($slot.BusSpecified -and $slot.DevFnSpecified) {
                    if ([int]$port.Bus -eq [int]$slot.Bus -and [int]$port.DevFn -eq [int]$slot.DevFn) {
                        $score = 100 - [Math]::Min(20, ($distance * 3))
                        $kind = 'exact'
                        $reason = 'SMBIOS bus/device/function matches this PCIe port'
                    }
                } elseif ($slot.DevFnSpecified) {
                    if ([int]$port.DevFn -eq [int]$slot.DevFn) {
                        if ([int]$port.Bus -eq 0) {
                            $score = 85 - [Math]::Min(20, ($distance * 3))
                            $kind = 'high'
                        } else {
                            $score = 65 - [Math]::Min(20, ($distance * 3))
                            $kind = 'medium'
                        }
                        $reason = 'SMBIOS device/function matches this PCIe port (bus not reported)'
                    }
                } elseif ($slot.BusSpecified) {
                    if ([int]$port.Bus -eq [int]$slot.Bus) {
                        $score = 40 - [Math]::Min(15, ($distance * 2))
                        $kind = 'medium'
                        $reason = 'SMBIOS bus matches this PCIe port'
                    }
                }

                if ($score -le 0) { continue }

                $score += Get-RoleBonus -Slot $slot -Endpoint $endpoint

                [void]$candidates.Add([pscustomobject]@{
                    SlotIndex  = $slot.Index
                    Slot       = $slot
                    Endpoint   = $endpoint
                    EndpointId = $endpoint.InstanceId
                    Port       = $port
                    PortId     = $port.InstanceId
                    Distance   = $distance
                    Score      = $score
                    Kind       = $kind
                    Confidence = (Get-MatchedConfidence -Kind $kind -Distance $distance)
                    Reason     = $reason
                })
            }
        }
    }

    return $candidates
}

function Add-InferredAssignments {
    param(
        [object[]]$Slots,
        [object[]]$Endpoints,
        [hashtable]$Assignments,
        [hashtable]$SlotAssignments,
        [hashtable]$SlotPorts
    )

    $unmatchedNvme = @($Endpoints | Where-Object { $_.IsNvme -and -not $Assignments.ContainsKey($_.InstanceId) })
    $emptyM2 = @($Slots | Where-Object { $_.IsM2 -and -not $SlotAssignments.ContainsKey($_.Index) })

    if ($unmatchedNvme.Count -ne 1 -or $emptyM2.Count -ne 1) {
        return
    }

    $endpoint = $unmatchedNvme[0]
    $slot = $emptyM2[0]
    $candidate = [pscustomobject]@{
        SlotIndex  = $slot.Index
        Slot       = $slot
        Endpoint   = $endpoint
        EndpointId = $endpoint.InstanceId
        Port       = $null
        PortId     = ''
        Distance   = 99
        Score      = 30
        Kind       = 'inferred'
        Confidence = 'inferred'
        Reason     = 'Only remaining NVMe controller and empty M.2 slot'
    }

    $Assignments[$endpoint.InstanceId] = $candidate
    $SlotPorts[$slot.Index] = ''
    if (-not $SlotAssignments.ContainsKey($slot.Index)) {
        $SlotAssignments[$slot.Index] = New-Object System.Collections.ArrayList
    }
    [void]$SlotAssignments[$slot.Index].Add($candidate)
}

function Set-SlotOccupancy {
    param(
        [object[]]$Slots,
        [hashtable]$SlotAssignments
    )

    foreach ($slot in $Slots) {
        $slot.Occupants = @()
        if ($SlotAssignments.ContainsKey($slot.Index)) {
            $candidates = @($SlotAssignments[$slot.Index])
            $slot.Occupants = @($candidates | ForEach-Object { $_.Endpoint })
            $slot.Confidence = Get-LowestConfidence -Values @($candidates | ForEach-Object { $_.Confidence })
            $primary = $candidates | Sort-Object -Property Score -Descending | Select-Object -First 1
            $slot.MatchReason = [string]$primary.Reason
            $slot.Status = 'In Use'
            $slot.UsageMismatch = ($slot.UsageName -eq 'Available')
        } elseif ($slot.UsageName -eq 'Available') {
            $slot.Status = 'Available'
            $slot.Confidence = ''
            $slot.MatchReason = 'No device detected and SMBIOS reports the slot as available'
            $slot.UsageMismatch = $false
        } elseif ($slot.UsageName -eq 'In Use') {
            $slot.Status = 'In Use (no device found)'
            $slot.Confidence = 'unmapped'
            $slot.MatchReason = 'SMBIOS reports the slot in use, but no PCIe device was detected'
            $slot.UsageMismatch = $true
        } else {
            $slot.Status = 'No device detected'
            $slot.Confidence = ''
            $slot.MatchReason = 'No device detected'
            $slot.UsageMismatch = $false
        }
    }
}

# ---------------------------------------------------------------------------
# NVMe inventory
# ---------------------------------------------------------------------------

function Get-NvmeDrives {
    param(
        [object[]]$Endpoints,
        [hashtable]$Assignments
    )

    $physicalDisks = @{}
    try {
        foreach ($disk in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $idText = [string]$disk.DeviceId
            if ($idText -match '^\d+$') {
                $physicalDisks[[int]$idText] = $disk
            }
        }
    } catch {
        # The Storage module is optional for the core report.
    }

    $controllers = @{}
    foreach ($endpoint in $Endpoints) {
        if ($endpoint.IsNvme) {
            $controllers[$endpoint.InstanceId] = $endpoint
        }
    }

    $drives = New-Object System.Collections.ArrayList

    try {
        $diskDrives = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)
    } catch {
        return $drives
    }

    foreach ($diskDrive in $diskDrives) {
        $number = $null
        if ([string]$diskDrive.DeviceID -match 'PHYSICALDRIVE(\d+)') {
            $number = [int]$Matches[1]
        }
        if ($null -eq $number) { continue }

        $pnpId = [string]$diskDrive.PNPDeviceID
        if ([string]::IsNullOrWhiteSpace($pnpId)) { continue }

        $diskDevice = Get-DeviceInfo $pnpId
        if (-not $diskDevice) { continue }

        $controller = Get-FirstPciAncestor -Device $diskDevice
        if (-not $controller) { continue }
        if (-not $controllers.ContainsKey($controller.InstanceId)) { continue }

        $endpoint = $controllers[$controller.InstanceId]
        $physical = $physicalDisks[$number]

        $model = [string]$diskDrive.Model
        if ([string]::IsNullOrWhiteSpace($model) -and $physical) { $model = [string]$physical.FriendlyName }
        if ([string]::IsNullOrWhiteSpace($model)) { $model = $endpoint.Name }

        $serial = [string]$diskDrive.SerialNumber
        $firmware = [string]$diskDrive.FirmwareRevision
        $size = $diskDrive.Size
        $health = ''
        $operational = ''
        $mediaType = [string]$diskDrive.MediaType

        if ($physical) {
            if ($physical.SerialNumber) { $serial = [string]$physical.SerialNumber }
            if ($physical.FirmwareVersion) { $firmware = [string]$physical.FirmwareVersion }
            if ($physical.Size) { $size = $physical.Size }
            $health = [string]$physical.HealthStatus
            $operational = [string]$physical.OperationalStatus
            if ($physical.MediaType) { $mediaType = [string]$physical.MediaType }
        }
        if ([string]::IsNullOrWhiteSpace($health)) {
            $health = [string]$diskDrive.Status
        }

        $temperature = $null
        $wear = $null
        $powerOnHours = $null
        if ($physical) {
            try {
                $counter = $physical | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($counter) {
                    if ($null -ne $counter.Temperature -and [int]$counter.Temperature -gt 0) { $temperature = [int]$counter.Temperature }
                    if ($null -ne $counter.Wear -and [int]$counter.Wear -gt 0) { $wear = [int]$counter.Wear }
                    if ($null -ne $counter.PowerOnHours -and [long]$counter.PowerOnHours -gt 0) { $powerOnHours = [long]$counter.PowerOnHours }
                }
            } catch {
                # Reliability counters are not available on every controller.
            }
        }

        $assignment = $Assignments[$endpoint.InstanceId]
        $slot = $null
        $port = $null
        $confidence = 'unmapped'
        $reason = 'No SMBIOS slot matched this PCIe port'

        if ($assignment) {
            $slot = $assignment.Slot
            $port = $assignment.Port
            $confidence = [string]$assignment.Confidence
            $reason = [string]$assignment.Reason
        }

        $portAddress = ''
        $portBiosName = ''
        if ($port) {
            $portAddress = Format-PciAddress $port.Bus $port.DeviceNumber $port.Function
            $portBiosName = Get-BiosShortName $port.BiosName
        }

        $slotName = ''
        if ($slot) { $slotName = [string]$slot.Designation }

        $drive = [pscustomobject]@{
            DriveNumber      = $number
            Model            = $model
            Serial           = $serial
            Firmware         = $firmware
            SizeBytes        = $size
            Size             = (Format-Size $size)
            Health           = $health
            OperationalStatus = $operational
            MediaType        = $mediaType
            Temperature      = $temperature
            Wear             = $wear
            PowerOnHours     = $powerOnHours
            Controller       = $endpoint
            ControllerName   = $endpoint.Name
            ControllerAddress = $endpoint.PciAddress
            Link             = $endpoint.Link
            MaxLink          = $endpoint.MaxLink
            Port             = $port
            PortAddress      = $portAddress
            PortBiosName     = $portBiosName
            Slot             = $slot
            SlotName         = $slotName
            Confidence       = $confidence
            MatchReason      = $reason
        }

        $endpoint.Drive = $drive
        $endpoint.Slot = $slot
        $endpoint.Confidence = $confidence
        $endpoint.MatchReason = $reason
        [void]$drives.Add($drive)
    }

    return $drives
}

function Get-SlotAnalysis {
    param([object]$Smbios)

    $slots = @($Smbios.Slots)
    $endpoints = @(Get-PciEndpoints)

    $assignments = @{}
    $slotAssignments = @{}
    $slotPorts = @{}

    $candidates = @(Get-SlotCandidates -Slots $slots -Endpoints $endpoints)
    $ordered = @($candidates | Sort-Object -Property `
        @{ Expression = 'Score'; Descending = $true }, `
        @{ Expression = 'Distance'; Descending = $false })

    foreach ($candidate in $ordered) {
        if ($assignments.ContainsKey($candidate.EndpointId)) { continue }
        if ($slotPorts.ContainsKey($candidate.SlotIndex) -and $slotPorts[$candidate.SlotIndex] -ne $candidate.PortId) { continue }

        $assignments[$candidate.EndpointId] = $candidate
        $slotPorts[$candidate.SlotIndex] = $candidate.PortId
        if (-not $slotAssignments.ContainsKey($candidate.SlotIndex)) {
            $slotAssignments[$candidate.SlotIndex] = New-Object System.Collections.ArrayList
        }
        [void]$slotAssignments[$candidate.SlotIndex].Add($candidate)
    }

    Add-InferredAssignments -Slots $slots -Endpoints $endpoints -Assignments $assignments -SlotAssignments $slotAssignments -SlotPorts $slotPorts

    Set-SlotOccupancy -Slots $slots -SlotAssignments $slotAssignments

    $drives = @(Get-NvmeDrives -Endpoints $endpoints -Assignments $assignments)

    $osCaption = ''
    $osVersion = [System.Environment]::OSVersion.VersionString
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os.Caption) { $osCaption = [string]$os.Caption }
        if ($os.Version) { $osVersion = [string]$os.Version }
    } catch { }

    return [pscustomobject]@{
        Generated = Get-Date
        Computer  = $env:COMPUTERNAME
        User      = $env:USERNAME
        OsCaption = $osCaption
        OsVersion = $osVersion
        Smbios    = $Smbios
        Slots     = $slots
        Endpoints = $endpoints
        Drives    = $drives
    }
}

# ---------------------------------------------------------------------------
# Console report
# ---------------------------------------------------------------------------

function Get-ConfidenceColor {
    param([string]$Confidence)
    switch ($Confidence) {
        'exact'    { return [ConsoleColor]::Green }
        'high'     { return [ConsoleColor]::Green }
        'medium'   { return [ConsoleColor]::Yellow }
        'inferred' { return [ConsoleColor]::Yellow }
        default    { return [ConsoleColor]::Red }
    }
}

function Write-ConsoleReport {
    param([object]$Analysis)

    $smbios = $Analysis.Smbios
    $systemProduct = ''
    $boardText = ''
    $biosText = ''

    if ($smbios.System -and $smbios.System.Product) { $systemProduct = [string]$smbios.System.Product }
    if ($smbios.Board) {
        $boardText = (([string]$smbios.Board.Manufacturer + ' ' + [string]$smbios.Board.Product).Trim())
        if ($smbios.Board.Version) { $boardText += ' ' + [string]$smbios.Board.Version }
    }
    if ([string]::IsNullOrWhiteSpace($systemProduct) -or $systemProduct -match '^(System Product Name|Default string|To be filled by O\.E\.M\.)$') {
        if ($smbios.Board -and -not [string]::IsNullOrWhiteSpace([string]$smbios.Board.Product)) {
            $systemProduct = [string]$smbios.Board.Product
        }
    }
    if ($smbios.Bios) {
        $parts = @()
        if ($smbios.Bios.Version) { $parts += [string]$smbios.Bios.Version }
        if ($smbios.Bios.Vendor) { $parts += '(' + [string]$smbios.Bios.Vendor + ')' }
        if ($smbios.Bios.ReleaseDate) { $parts += [string]$smbios.Bios.ReleaseDate }
        $biosText = $parts -join ' '
    }

    $osText = $Analysis.OsCaption
    if ([string]::IsNullOrWhiteSpace($osText)) { $osText = 'Windows' }
    if ($Analysis.OsVersion) { $osText += ' ' + $Analysis.OsVersion }

    $drives = @($Analysis.Drives | Sort-Object DriveNumber)
    $slots = @($Analysis.Slots)
    $mapped = @($drives | Where-Object { $_.Confidence -ne 'unmapped' }).Count
    $pcieSlots = @($slots | Where-Object { $_.IsPcie })
    $occupied = @($pcieSlots | Where-Object { $_.Occupants.Count -gt 0 }).Count
    $nonPcieSlots = $slots.Count - $pcieSlots.Count

    Write-ColorLine ('=' * 114) Cyan
    Write-ColorLine ' NVMe Slot Report' Cyan
    Write-ColorLine ('=' * 114) Cyan
    Write-ColorLine (' Computer  : {0}' -f $Analysis.Computer)
    Write-ColorLine (' System    : {0}' -f $systemProduct)
    Write-ColorLine (' Board     : {0}' -f $boardText)
    Write-ColorLine (' BIOS      : {0}' -f $biosText)
    Write-ColorLine (' SMBIOS    : {0}' -f $smbios.Version)
    Write-ColorLine (' OS        : {0}' -f $osText)
    Write-ColorLine (' Generated : {0}' -f $Analysis.Generated.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-ColorLine (' Summary   : {0} NVMe drive(s), {1} mapped, {2} of {3} PCIe-capable slots occupied' -f $drives.Count, $mapped, $occupied, $pcieSlots.Count)
    if ($nonPcieSlots -gt 0) {
        Write-ColorLine ('             {0} non-PCIe/unknown SMBIOS Type 9 entr(y/ies) excluded from PCIe matching' -f $nonPcieSlots) DarkGray
    }

    Write-ColorLine ''
    Write-ColorLine ('NVMe drives ({0})' -f $drives.Count) Cyan
    Write-ColorLine ('-' * 114) Cyan

    if ($drives.Count -eq 0) {
        Write-ColorLine '  No NVMe drives were detected.' DarkGray
    } else {
        $header = '  {0}  {1}  {2}  {3}  {4}  {5}  {6}  {7}' -f `
            (Format-Column '#' 3), `
            (Format-Column 'Model' 28), `
            (Format-Column 'Size' 9), `
            (Format-Column 'Slot' 18), `
            (Format-Column 'Address' 9), `
            (Format-Column 'Current / max' 28), `
            (Format-Column 'Match' 9), `
            (Format-Column 'Health' 9)
        Write-ColorLine $header DarkGray

        foreach ($drive in $drives) {
            $slotText = [string]$drive.SlotName
            if ([string]::IsNullOrWhiteSpace($slotText)) { $slotText = '(unmapped)' }
            $line = '  {0}  {1}  {2}  {3}  {4}  {5}  {6}  {7}' -f `
                (Format-Column ([string]$drive.DriveNumber) 3), `
                (Format-Column ([string]$drive.Model) 28), `
                (Format-Column ([string]$drive.Size) 9), `
                (Format-Column $slotText 18), `
                (Format-Column ([string]$drive.ControllerAddress) 9), `
                (Format-Column (Format-LinkComparison $drive.Controller.LinkSpeed $drive.Controller.LinkWidth $drive.Controller.MaxLinkSpeed $drive.Controller.MaxLinkWidth) 28), `
                (Format-Column ([string]$drive.Confidence) 9), `
                (Format-Column ([string]$drive.Health) 9)
            Write-ColorLine $line (Get-ConfidenceColor $drive.Confidence)
        }

        Write-ColorLine ''
        Write-ColorLine 'Connection paths' Cyan
        Write-ColorLine ('-' * 130) Cyan

        foreach ($drive in $drives) {
            $serialText = 'SN not reported'
            if (-not [string]::IsNullOrWhiteSpace([string]$drive.Serial)) { $serialText = 'SN ' + [string]$drive.Serial }
            $firmwareText = 'FW not reported'
            if (-not [string]::IsNullOrWhiteSpace([string]$drive.Firmware)) { $firmwareText = 'FW ' + [string]$drive.Firmware }

            $path = '  PCI {0}' -f $drive.ControllerAddress
            if ($drive.PortAddress) {
                $path += '  ->  port ' + $drive.PortAddress
                if ($drive.PortBiosName) { $path += ' [' + $drive.PortBiosName + ']' }
            }
            if ($drive.SlotName) {
                $path += '  ->  ' + $drive.SlotName
            } else {
                $path += '  ->  (no slot match)'
            }

            Write-ColorLine ('  [{0}] {1}' -f $drive.DriveNumber, $drive.Model) Gray
            Write-ColorLine $path (Get-ConfidenceColor $drive.Confidence)
            foreach ($locationPath in @($drive.Controller.LocationPaths)) {
                Write-ColorLine ('      PnP location: ' + $locationPath) DarkGray
            }
            Write-ColorLine ('      {0} | {1} | {2} | {3}' -f $serialText, $firmwareText, $drive.Size, $drive.Health) DarkGray
            if (-not [string]::IsNullOrWhiteSpace([string]$drive.MatchReason)) {
                Write-ColorLine ('      match: ' + $drive.MatchReason) DarkGray
            }
        }
    }

    Write-ColorLine ''
    Write-ColorLine ('Slot occupancy ({0} slots)' -f $slots.Count) Cyan
    Write-ColorLine ('-' * 114) Cyan

    if ($slots.Count -eq 0) {
        Write-ColorLine '  Firmware did not provide any SMBIOS Type 9 slot records.' DarkGray
    } else {
        foreach ($slot in $slots) {
            $designation = [string]$slot.Designation
            if ([string]::IsNullOrWhiteSpace($designation)) { $designation = '(unnamed slot)' }

            $addressText = ''
            if ($slot.BusSpecified) { $addressText += ('bus {0:X2}' -f $slot.Bus) }
            if ($slot.BusSpecified -and $slot.DevFnSpecified) { $addressText += ' ' }
            if ($slot.DevFnSpecified) {
                $addressText += ('dev {0} fn {1}' -f ($slot.DevFn -shr 3), ($slot.DevFn -band 7))
            }
            if ([string]::IsNullOrWhiteSpace($addressText)) { $addressText = 'no PCI address' }

            Write-ColorLine ('  {0}  [{1}, {2}, {3}; {4}]' -f $designation, $slot.TypeName, $slot.WidthName, $slot.UsageName, $addressText) Cyan

            if ($slot.Occupants.Count -eq 0) {
                $emptyText = [string]$slot.Status
                if ($slot.UsageName -eq 'Available') { $emptyText = 'empty - ' + $emptyText }
                Write-ColorLine ('      ({0})' -f $emptyText) DarkGray
            } else {
                foreach ($endpoint in $slot.Occupants) {
                    $label = [string]$endpoint.Name
                    if ($endpoint.IsNvme -and $endpoint.Drive) {
                        $label = '{0} ({1}, NVMe)' -f $endpoint.Drive.Model, $endpoint.Drive.Size
                    }
                    $line = '      {0}  [{1}]  {2}' -f $label, $endpoint.Class, $endpoint.PciAddress
                    if ($endpoint.Link) { $line += '  ' + $endpoint.Link }
                    Write-ColorLine $line (Get-ConfidenceColor $slot.Confidence)
                }
                Write-ColorLine ('      match: {0} ({1})' -f $slot.Confidence, $slot.MatchReason) (Get-ConfidenceColor $slot.Confidence)
            }

            if ($slot.UsageMismatch) {
                Write-ColorLine '      note: actual occupancy differs from the SMBIOS usage value' Yellow
            }
        }
    }

    $unmapped = @($drives | Where-Object { $_.Confidence -eq 'unmapped' })
    $unmatchedSlots = @($slots | Where-Object { $_.Occupants.Count -eq 0 -and $_.UsageName -eq 'In Use' })

    if ($unmapped.Count -gt 0 -or $unmatchedSlots.Count -gt 0) {
        Write-ColorLine ''
        Write-ColorLine 'Unmatched' Cyan
        Write-ColorLine ('-' * 114) Cyan

        foreach ($drive in $unmapped) {
            Write-ColorLine ('  NVMe {0} at {1}: no slot matched ({2})' -f $drive.Model, $drive.ControllerAddress, $drive.MatchReason) Red
        }
        foreach ($slot in $unmatchedSlots) {
            Write-ColorLine ('  Slot {0}: firmware says in use, but no PCIe device was found' -f $slot.Designation) Yellow
        }
    }

    Write-ColorLine ''
    Write-ColorLine 'Match confidence' Cyan
    Write-ColorLine ('-' * 114) Cyan
    Write-ColorLine ('  {0,-9} {1}' -f 'exact', 'SMBIOS bus/device/function matched the PCIe slot port')
    Write-ColorLine ('  {0,-9} {1}' -f 'high', 'device/function matched a CPU root port (bus not reported)')
    Write-ColorLine ('  {0,-9} {1}' -f 'medium', 'matched an upstream port, or only the bus matched')
    Write-ColorLine ('  {0,-9} {1}' -f 'inferred', 'only remaining plausible slot (conservative guess)')
    Write-ColorLine ('  {0,-9} {1}' -f 'unmapped', 'no slot information could be matched')
}

# ---------------------------------------------------------------------------
# HTML report
# ---------------------------------------------------------------------------

function Get-HtmlBadge {
    param([string]$Confidence)

    $value = 'unmapped'
    if (-not [string]::IsNullOrWhiteSpace($Confidence)) { $value = $Confidence.ToLowerInvariant() }
    $class = 'unmapped'
    switch ($value) {
        'exact'    { $class = 'exact' }
        'high'     { $class = 'high' }
        'medium'   { $class = 'medium' }
        'inferred' { $class = 'inferred' }
        default    { $class = 'unmapped' }
    }
    return ('<span class="badge {0}">{1}</span>' -f $class, (Html-Encode $value))
}

function New-HtmlReport {
    param([object]$Analysis)

    $smbios = $Analysis.Smbios
    $systemProduct = 'Unknown system'
    $boardText = ''
    $biosText = ''

    if ($smbios.System -and -not [string]::IsNullOrWhiteSpace([string]$smbios.System.Product)) {
        $systemProduct = [string]$smbios.System.Product
    }
    if ($smbios.Board) {
        $boardText = (([string]$smbios.Board.Manufacturer + ' ' + [string]$smbios.Board.Product).Trim())
        if ($smbios.Board.Version) { $boardText += ' ' + [string]$smbios.Board.Version }
    }
    if ([string]::IsNullOrWhiteSpace($systemProduct) -or $systemProduct -match '^(System Product Name|Default string|To be filled by O\.E\.M\.)$') {
        if ($smbios.Board -and -not [string]::IsNullOrWhiteSpace([string]$smbios.Board.Product)) {
            $systemProduct = [string]$smbios.Board.Product
        }
    }
    if ($smbios.Bios) {
        $parts = @()
        if ($smbios.Bios.Version) { $parts += [string]$smbios.Bios.Version }
        if ($smbios.Bios.Vendor) { $parts += '(' + [string]$smbios.Bios.Vendor + ')' }
        if ($smbios.Bios.ReleaseDate) { $parts += [string]$smbios.Bios.ReleaseDate }
        $biosText = $parts -join ' '
    }

    $osText = $Analysis.OsCaption
    if ([string]::IsNullOrWhiteSpace($osText)) { $osText = 'Windows' }
    if ($Analysis.OsVersion) { $osText += ' ' + $Analysis.OsVersion }

    $drives = @($Analysis.Drives | Sort-Object DriveNumber)
    $slots = @($Analysis.Slots)
    $mappedCount = @($drives | Where-Object { $_.Confidence -ne 'unmapped' }).Count
    $pcieSlots = @($slots | Where-Object { $_.IsPcie })
    $occupiedCount = @($pcieSlots | Where-Object { $_.Occupants.Count -gt 0 }).Count
    $unmappedDrives = @($drives | Where-Object { $_.Confidence -eq 'unmapped' })
    $unmatchedSlots = @($slots | Where-Object { $_.Occupants.Count -eq 0 -and $_.UsageName -eq 'In Use' })

    $nvmeRows = New-Object System.Text.StringBuilder
    if ($drives.Count -eq 0) {
        [void]$nvmeRows.AppendLine('<tr><td colspan="7" class="empty">No NVMe drives detected.</td></tr>')
    } else {
        foreach ($drive in $drives) {
            $serial = [string]$drive.Serial
            if ([string]::IsNullOrWhiteSpace($serial)) { $serial = 'Serial not reported' }

            $slotCell = Get-HtmlBadge 'unmapped'
            if (-not [string]::IsNullOrWhiteSpace([string]$drive.SlotName)) {
                $slotCell = '<div class="slotname">' + (Html-Encode $drive.SlotName) + '</div>' + (Get-HtmlBadge $drive.Confidence)
            }

            $pathParts = @()
            if ($drive.PortAddress) { $pathParts += 'port ' + $drive.PortAddress }
            if ($drive.PortBiosName) { $pathParts += $drive.PortBiosName }
            $pathText = $pathParts -join ' / '
            $locationPaths = @($drive.Controller.LocationPaths)
            if ($locationPaths.Count -gt 0) { $pathText += ' / PnP: ' + ($locationPaths -join '; ') }
            if ([string]::IsNullOrWhiteSpace($pathText)) { $pathText = 'not available' }

            $health = [string]$drive.Health
            if ([string]::IsNullOrWhiteSpace($health)) { $health = '-' }
            $currentLink = [string]$drive.Link
            if ([string]::IsNullOrWhiteSpace($currentLink)) { $currentLink = 'unavailable' }
            $maximumLink = [string]$drive.MaxLink
            if ([string]::IsNullOrWhiteSpace($maximumLink)) { $maximumLink = 'unavailable' }

            [void]$nvmeRows.AppendLine('<tr>')
            [void]$nvmeRows.AppendLine('  <td class="num">' + (Html-Encode ([string]$drive.DriveNumber)) + '</td>')
            [void]$nvmeRows.AppendLine('  <td><div class="name">' + (Html-Encode $drive.Model) + '</div><div class="muted mono">' + (Html-Encode $serial) + '</div></td>')
            [void]$nvmeRows.AppendLine('  <td>' + (Html-Encode $drive.Size) + '</td>')
            [void]$nvmeRows.AppendLine('  <td>' + (Html-Encode $health) + '</td>')
            [void]$nvmeRows.AppendLine('  <td>' + $slotCell + '</td>')
            [void]$nvmeRows.AppendLine('  <td><div class="mono">' + (Html-Encode $drive.ControllerAddress) + '</div><div class="muted">Current: ' + (Html-Encode $currentLink) + '</div><div class="muted">Maximum: ' + (Html-Encode $maximumLink) + '</div></td>')
            [void]$nvmeRows.AppendLine('  <td><div class="mono">' + (Html-Encode $pathText) + '</div><div class="muted">' + (Html-Encode $drive.MatchReason) + '</div></td>')
            [void]$nvmeRows.AppendLine('</tr>')
        }
    }

    $slotRows = New-Object System.Text.StringBuilder
    foreach ($slot in $slots) {
        $designation = [string]$slot.Designation
        if ([string]::IsNullOrWhiteSpace($designation)) { $designation = '(unnamed)' }

        $addressText = ''
        if ($slot.BusSpecified) { $addressText += ('bus {0:X2}' -f $slot.Bus) }
        if ($slot.BusSpecified -and $slot.DevFnSpecified) { $addressText += ' ' }
        if ($slot.DevFnSpecified) {
            $addressText += ('dev {0} fn {1}' -f ($slot.DevFn -shr 3), ($slot.DevFn -band 7))
        }
        if ([string]::IsNullOrWhiteSpace($addressText)) { $addressText = 'no PCI address' }

        $devices = New-Object System.Text.StringBuilder
        if ($slot.Occupants.Count -eq 0) {
            [void]$devices.Append('<span class="empty">No device detected</span>')
        } else {
            foreach ($endpoint in $slot.Occupants) {
                $name = [string]$endpoint.Name
                if ($endpoint.IsNvme -and $endpoint.Drive) { $name = [string]$endpoint.Drive.Model }
                $meta = @()
                if ($endpoint.Class) { $meta += [string]$endpoint.Class }
                if ($endpoint.PciAddress) { $meta += [string]$endpoint.PciAddress }
                if ($endpoint.Link) { $meta += [string]$endpoint.Link }
                $metaText = $meta -join ' | '

                $nameClass = 'name'
                if ($endpoint.IsNvme) { $nameClass = 'name nvme' }
                [void]$devices.Append('<div class="device"><span class="' + $nameClass + '">' + (Html-Encode $name) + '</span>')
                if (-not [string]::IsNullOrWhiteSpace($metaText)) {
                    [void]$devices.Append('<div class="muted">' + (Html-Encode $metaText) + '</div>')
                }
                [void]$devices.Append('</div>')
            }
        }

        $usageCell = Html-Encode $slot.UsageName
        if ($slot.UsageMismatch) {
            $usageCell += '<div class="note">' + (Html-Encode $slot.MatchReason) + '</div>'
        }

        $confidenceCell = '<span class="muted">-</span>'
        if (-not [string]::IsNullOrWhiteSpace([string]$slot.Confidence)) {
            $confidenceCell = Get-HtmlBadge $slot.Confidence
            if (-not [string]::IsNullOrWhiteSpace([string]$slot.MatchReason)) {
                $confidenceCell += '<div class="muted">' + (Html-Encode $slot.MatchReason) + '</div>'
            }
        }

        [void]$slotRows.AppendLine('<tr>')
        [void]$slotRows.AppendLine('  <td><div class="slotname">' + (Html-Encode $designation) + '</div><div class="muted mono">' + (Html-Encode $addressText) + '</div></td>')
        [void]$slotRows.AppendLine('  <td>' + (Html-Encode $slot.TypeName) + '</td>')
        [void]$slotRows.AppendLine('  <td>' + (Html-Encode $slot.WidthName) + '</td>')
        [void]$slotRows.AppendLine('  <td>' + $usageCell + '</td>')
        [void]$slotRows.AppendLine('  <td>' + (Html-Encode $slot.Status) + '</td>')
        [void]$slotRows.AppendLine('  <td>' + $devices.ToString() + '</td>')
        [void]$slotRows.AppendLine('  <td>' + $confidenceCell + '</td>')
        [void]$slotRows.AppendLine('</tr>')
    }

    if ($slots.Count -eq 0) {
        [void]$slotRows.AppendLine('<tr><td colspan="7" class="empty">Firmware did not provide any SMBIOS Type 9 slot records.</td></tr>')
    }

    $unmatchedHtml = New-Object System.Text.StringBuilder
    if ($unmappedDrives.Count -gt 0 -or $unmatchedSlots.Count -gt 0) {
        [void]$unmatchedHtml.AppendLine('<section>')
        [void]$unmatchedHtml.AppendLine('<h2>Unmatched</h2>')
        if ($unmappedDrives.Count -gt 0) {
            [void]$unmatchedHtml.AppendLine('<h3>NVMe drives without a slot match</h3><ul>')
            foreach ($drive in $unmappedDrives) {
                [void]$unmatchedHtml.AppendLine('<li><strong>' + (Html-Encode $drive.Model) + '</strong> <span class="mono muted">' + (Html-Encode $drive.ControllerAddress) + '</span> - ' + (Html-Encode $drive.MatchReason) + '</li>')
            }
            [void]$unmatchedHtml.AppendLine('</ul>')
        }
        if ($unmatchedSlots.Count -gt 0) {
            [void]$unmatchedHtml.AppendLine('<h3>Slots reported in use but not matched</h3><ul>')
            foreach ($slot in $unmatchedSlots) {
                [void]$unmatchedHtml.AppendLine('<li><strong>' + (Html-Encode $slot.Designation) + '</strong> - ' + (Html-Encode $slot.MatchReason) + '</li>')
            }
            [void]$unmatchedHtml.AppendLine('</ul>')
        }
        [void]$unmatchedHtml.AppendLine('</section>')
    }

    $css = @'
:root { color-scheme: light; }
* { box-sizing: border-box; }
body { margin: 0; font-family: "Segoe UI", system-ui, -apple-system, Arial, sans-serif; background: #f4f6f8; color: #1c2430; line-height: 1.45; }
header { background: linear-gradient(135deg, #132a43, #1f4d78); color: #fff; padding: 28px 32px; }
header h1 { margin: 0; font-size: 26px; font-weight: 650; letter-spacing: .01em; }
header .sub { opacity: .85; margin-top: 6px; font-size: 13px; }
main { max-width: 1180px; margin: 0 auto; padding: 24px 20px 48px; }
section { background: #fff; border: 1px solid #dde3ea; border-radius: 10px; padding: 18px 20px; margin: 18px 0; box-shadow: 0 1px 2px rgba(16, 24, 40, .04); }
h2 { font-size: 15px; text-transform: uppercase; letter-spacing: .07em; color: #33475f; margin: 0 0 14px; }
h3 { font-size: 13px; color: #33475f; margin: 16px 0 8px; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th { text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: .05em; color: #5b6b7d; border-bottom: 2px solid #e3e8ee; padding: 8px 10px; white-space: nowrap; }
td { padding: 9px 10px; border-bottom: 1px solid #edf0f3; vertical-align: top; }
tr:last-child td { border-bottom: none; }
.mono { font-family: Consolas, "Cascadia Mono", monospace; }
.muted { color: #6b7a8c; font-size: 12px; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
.name { font-weight: 550; }
.nvme { color: #11643a; }
.slotname { font-weight: 650; color: #173a5e; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; letter-spacing: .02em; text-transform: uppercase; white-space: nowrap; }
.badge.exact { background: #d9f2e3; color: #11643a; }
.badge.high { background: #e2f1fb; color: #10567f; }
.badge.medium { background: #fdf1cf; color: #7a5a0a; }
.badge.inferred { background: #fde7cf; color: #8a4b08; }
.badge.unmapped { background: #fadcdc; color: #8a1c1c; }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin: 0; }
.card { flex: 1 1 170px; background: #fff; border: 1px solid #dde3ea; border-radius: 10px; padding: 14px 16px; }
.card .label { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #6b7a8c; }
.card .value { font-size: 22px; font-weight: 650; margin-top: 4px; }
.card .value.small { font-size: 16px; }
.device { padding: 2px 0; }
.empty { color: #8a97a7; font-style: italic; }
.note { background: #fff8e6; border-left: 3px solid #d9a406; padding: 6px 10px; border-radius: 4px; color: #6b4f00; font-size: 12px; margin-top: 8px; }
.info { display: grid; grid-template-columns: 130px 1fr; gap: 6px 14px; font-size: 13px; margin: 0; }
.info dt { color: #6b7a8c; }
.info dd { margin: 0; }
.legend { font-size: 12px; color: #4c5b6c; }
.legend div { padding: 3px 0; }
footer { color: #7a8797; font-size: 12px; text-align: center; padding: 8px; }
@media (max-width: 760px) {
  header { padding: 20px; }
  main { padding: 16px 10px 32px; }
  section { padding: 14px; overflow-x: auto; }
  .info { grid-template-columns: 1fr; }
}
'@

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<title>NVMe Slot Report - ' + (Html-Encode $Analysis.Computer) + '</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine($css)
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine('<header>')
    [void]$sb.AppendLine('<h1>NVMe Slot Report</h1>')
    [void]$sb.AppendLine('<div class="sub">' + (Html-Encode $Analysis.Computer) + ' &middot; ' + (Html-Encode $systemProduct) + ' &middot; ' + (Html-Encode $Analysis.Generated.ToString('yyyy-MM-dd HH:mm:ss')) + '</div>')
    [void]$sb.AppendLine('</header>')
    [void]$sb.AppendLine('<main>')

    [void]$sb.AppendLine('<section>')
    [void]$sb.AppendLine('<h2>System</h2>')
    [void]$sb.AppendLine('<dl class="info">')
    [void]$sb.AppendLine('<dt>Computer</dt><dd>' + (Html-Encode $Analysis.Computer) + '</dd>')
    [void]$sb.AppendLine('<dt>System</dt><dd>' + (Html-Encode $systemProduct) + '</dd>')
    [void]$sb.AppendLine('<dt>Motherboard</dt><dd>' + (Html-Encode $boardText) + '</dd>')
    [void]$sb.AppendLine('<dt>BIOS</dt><dd>' + (Html-Encode $biosText) + '</dd>')
    [void]$sb.AppendLine('<dt>SMBIOS</dt><dd>' + (Html-Encode $smbios.Version) + '</dd>')
    [void]$sb.AppendLine('<dt>Operating system</dt><dd>' + (Html-Encode $osText) + '</dd>')
    [void]$sb.AppendLine('<dt>Generated</dt><dd>' + (Html-Encode $Analysis.Generated.ToString('yyyy-MM-dd HH:mm:ss')) + '</dd>')
    [void]$sb.AppendLine('</dl>')
    [void]$sb.AppendLine('</section>')

    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine('<div class="card"><div class="label">NVMe drives</div><div class="value">' + $drives.Count + '</div></div>')
    [void]$sb.AppendLine('<div class="card"><div class="label">Mapped to a slot</div><div class="value">' + $mappedCount + '</div></div>')
    [void]$sb.AppendLine('<div class="card"><div class="label">PCIe slots occupied</div><div class="value">' + $occupiedCount + ' <span class="muted">of ' + $pcieSlots.Count + '</span></div></div>')
    [void]$sb.AppendLine('<div class="card"><div class="label">Unmapped drives</div><div class="value">' + $unmappedDrives.Count + '</div></div>')
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<section>')
    [void]$sb.AppendLine('<h2>NVMe drives</h2>')
    [void]$sb.AppendLine('<table>')
    [void]$sb.AppendLine('<thead><tr><th>#</th><th>Drive</th><th>Size</th><th>Health</th><th>Slot</th><th>PCIe controller</th><th>Connection</th></tr></thead>')
    [void]$sb.AppendLine('<tbody>')
    [void]$sb.Append($nvmeRows.ToString())
    [void]$sb.AppendLine('</tbody>')
    [void]$sb.AppendLine('</table>')
    [void]$sb.AppendLine('</section>')

    [void]$sb.AppendLine('<section>')
    [void]$sb.AppendLine('<h2>Slot occupancy</h2>')
    [void]$sb.AppendLine('<table>')
    [void]$sb.AppendLine('<thead><tr><th>Slot</th><th>Type</th><th>Width</th><th>SMBIOS usage</th><th>Status</th><th>Devices</th><th>Match</th></tr></thead>')
    [void]$sb.AppendLine('<tbody>')
    [void]$sb.Append($slotRows.ToString())
    [void]$sb.AppendLine('</tbody>')
    [void]$sb.AppendLine('</table>')
    [void]$sb.AppendLine('</section>')

    [void]$sb.Append($unmatchedHtml.ToString())

    [void]$sb.AppendLine('<section>')
    [void]$sb.AppendLine('<h2>Match confidence</h2>')
    [void]$sb.AppendLine('<div class="legend">')
    [void]$sb.AppendLine('<div><strong>exact</strong> - SMBIOS bus/device/function matched the PCIe slot port.</div>')
    [void]$sb.AppendLine('<div><strong>high</strong> - device/function matched a CPU root port; SMBIOS did not report a bus.</div>')
    [void]$sb.AppendLine('<div><strong>medium</strong> - matched an upstream port, or only the bus matched.</div>')
    [void]$sb.AppendLine('<div><strong>inferred</strong> - only remaining plausible slot; treated as a conservative guess.</div>')
    [void]$sb.AppendLine('<div><strong>unmapped</strong> - no slot information could be matched.</div>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</section>')

    [void]$sb.AppendLine('</main>')
    [void]$sb.AppendLine('<footer>Generated by Get-NvmeSlots.ps1 v' + (Html-Encode $script:ScriptVersion) + '. Slot labels come from the firmware SMBIOS Type 9 table.</footer>')
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')

    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# JSON and CSV exports
# ---------------------------------------------------------------------------

function Get-JsonModel {
    param([object]$Analysis)

    $smbios = $Analysis.Smbios
    $slotModels = @()

    foreach ($slot in @($Analysis.Slots)) {
        $occupants = @()
        foreach ($endpoint in $slot.Occupants) {
            $driveModel = ''
            if ($endpoint.Drive) { $driveModel = [string]$endpoint.Drive.Model }
            $occupants += [ordered]@{
                name       = [string]$endpoint.Name
                class      = [string]$endpoint.Class
                pciAddress    = [string]$endpoint.PciAddress
                locationPaths = @($endpoint.LocationPaths)
                link          = [string]$endpoint.Link
                isNvme     = [bool]$endpoint.IsNvme
                driveModel = $driveModel
            }
        }

        $slotModels += [ordered]@{
            designation    = [string]$slot.Designation
            type           = [string]$slot.TypeName
            typeCode       = $slot.TypeCode
            isPcie         = [bool]$slot.IsPcie
            isM2           = [bool]$slot.IsM2
            width          = [string]$slot.WidthName
            widthCode      = $slot.WidthCode
            usage          = [string]$slot.UsageName
            usageCode      = $slot.UsageCode
            bus            = $slot.Bus
            devFn          = $slot.DevFn
            busSpecified   = [bool]$slot.BusSpecified
            devFnSpecified = [bool]$slot.DevFnSpecified
            status         = [string]$slot.Status
            confidence     = [string]$slot.Confidence
            matchReason    = [string]$slot.MatchReason
            occupants      = $occupants
        }
    }

    $driveModels = @()
    foreach ($drive in @($Analysis.Drives | Sort-Object DriveNumber)) {
        $driveModels += [ordered]@{
            driveNumber       = $drive.DriveNumber
            model             = [string]$drive.Model
            serial            = [string]$drive.Serial
            firmware          = [string]$drive.Firmware
            sizeBytes         = $drive.SizeBytes
            size              = [string]$drive.Size
            health            = [string]$drive.Health
            operationalStatus = [string]$drive.OperationalStatus
            mediaType         = [string]$drive.MediaType
            temperature       = $drive.Temperature
            wear              = $drive.Wear
            powerOnHours      = $drive.PowerOnHours
            controllerAddress      = [string]$drive.ControllerAddress
            controllerLocationPaths = @($drive.Controller.LocationPaths)
            link                    = [string]$drive.Link
            maxLink           = [string]$drive.MaxLink
            portAddress       = [string]$drive.PortAddress
            portBiosName      = [string]$drive.PortBiosName
            slot              = [string]$drive.SlotName
            confidence        = [string]$drive.Confidence
            matchReason       = [string]$drive.MatchReason
        }
    }

    $biosModel = [ordered]@{ vendor = ''; version = ''; releaseDate = '' }
    if ($smbios.Bios) {
        $biosModel = [ordered]@{
            vendor      = [string]$smbios.Bios.Vendor
            version     = [string]$smbios.Bios.Version
            releaseDate = [string]$smbios.Bios.ReleaseDate
        }
    }
    $systemModel = [ordered]@{ manufacturer = ''; product = ''; version = ''; serial = ''; sku = ''; family = '' }
    if ($smbios.System) {
        $systemModel = [ordered]@{
            manufacturer = [string]$smbios.System.Manufacturer
            product      = [string]$smbios.System.Product
            version      = [string]$smbios.System.Version
            serial       = [string]$smbios.System.Serial
            sku          = [string]$smbios.System.SKU
            family       = [string]$smbios.System.Family
        }
    }
    $boardModel = [ordered]@{ manufacturer = ''; product = ''; version = ''; serial = '' }
    if ($smbios.Board) {
        $boardModel = [ordered]@{
            manufacturer = [string]$smbios.Board.Manufacturer
            product      = [string]$smbios.Board.Product
            version      = [string]$smbios.Board.Version
            serial       = [string]$smbios.Board.Serial
        }
    }

    return [ordered]@{
        generated   = $Analysis.Generated.ToString('o')
        script      = 'Get-NvmeSlots.ps1'
        version     = $script:ScriptVersion
        computer    = [string]$Analysis.Computer
        user        = [string]$Analysis.User
        os          = [string]$Analysis.OsCaption
        osVersion   = [string]$Analysis.OsVersion
        smbios      = [ordered]@{
            version = [string]$smbios.Version
            bios    = $biosModel
            system  = $systemModel
            board   = $boardModel
        }
        slots       = $slotModels
        nvmeDrives  = $driveModels
        unmappedNvme = @($driveModels | Where-Object { $_.confidence -eq 'unmapped' })
    }
}

function Get-CsvRows {
    param([object]$Analysis)

    $rows = New-Object System.Collections.ArrayList

    foreach ($slot in @($Analysis.Slots)) {
        if ($slot.Occupants.Count -eq 0) {
            [void]$rows.Add([pscustomobject]@{
                Slot         = [string]$slot.Designation
                SlotType     = [string]$slot.TypeName
                Width        = [string]$slot.WidthName
                Usage        = [string]$slot.UsageName
                SlotBus      = $slot.Bus
                SlotDevFn    = $slot.DevFn
                Status       = [string]$slot.Status
                DeviceClass  = ''
                DeviceName   = ''
                PciAddress   = ''
                Link         = ''
                IsNvme       = $false
                DriveModel   = ''
                DriveSerial  = ''
                DriveSize    = ''
                DriveHealth  = ''
                Confidence   = [string]$slot.Confidence
                MatchReason  = [string]$slot.MatchReason
            })
        } else {
            foreach ($endpoint in $slot.Occupants) {
                $drive = $endpoint.Drive
                $driveModel = ''
                $driveSerial = ''
                $driveSize = ''
                $driveHealth = ''
                if ($drive) {
                    $driveModel = [string]$drive.Model
                    $driveSerial = [string]$drive.Serial
                    $driveSize = [string]$drive.Size
                    $driveHealth = [string]$drive.Health
                }
                [void]$rows.Add([pscustomobject]@{
                    Slot         = [string]$slot.Designation
                    SlotType     = [string]$slot.TypeName
                    Width        = [string]$slot.WidthName
                    Usage        = [string]$slot.UsageName
                    SlotBus      = $slot.Bus
                    SlotDevFn    = $slot.DevFn
                    Status       = [string]$slot.Status
                    DeviceClass  = [string]$endpoint.Class
                    DeviceName   = [string]$endpoint.Name
                    PciAddress   = [string]$endpoint.PciAddress
                    Link         = [string]$endpoint.Link
                    IsNvme       = [bool]$endpoint.IsNvme
                    DriveModel   = $driveModel
                    DriveSerial  = $driveSerial
                    DriveSize    = $driveSize
                    DriveHealth  = $driveHealth
                    Confidence   = [string]$slot.Confidence
                    MatchReason  = [string]$slot.MatchReason
                })
            }
        }
    }

    foreach ($drive in @($Analysis.Drives | Where-Object { $_.Confidence -eq 'unmapped' } | Sort-Object DriveNumber)) {
        [void]$rows.Add([pscustomobject]@{
            Slot         = '(unmapped)'
            SlotType     = ''
            Width        = ''
            Usage        = ''
            SlotBus      = ''
            SlotDevFn    = ''
            Status       = 'Unmapped'
            DeviceClass  = 'SCSIAdapter'
            DeviceName   = [string]$drive.ControllerName
            PciAddress   = [string]$drive.ControllerAddress
            Link         = [string]$drive.Link
            IsNvme       = $true
            DriveModel   = [string]$drive.Model
            DriveSerial  = [string]$drive.Serial
            DriveSize    = [string]$drive.Size
            DriveHealth  = [string]$drive.Health
            Confidence   = 'unmapped'
            MatchReason  = [string]$drive.MatchReason
        })
    }

    return $rows
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    if ($Open -and [string]::IsNullOrWhiteSpace($Html)) {
        $Html = 'NvmeSlotReport.html'
    }

    Write-ColorLine 'Querying disks, stand by...' Cyan
    Write-ColorLine ''

    Write-Verbose 'Reading the SMBIOS slot table from firmware...'
    $smbios = Read-SmbiosTable
    if ($smbios.Slots.Count -eq 0) {
        Write-Warning 'Firmware did not provide any SMBIOS Type 9 slot records. Slot labels cannot be matched.'
    }

    Write-Verbose 'Enumerating Plug and Play devices...'
    Initialize-PnpCache

    Write-Verbose 'Walking PCIe parent chains and matching slots...'
    $analysis = Get-SlotAnalysis -Smbios $smbios

    Write-ConsoleReport -Analysis $analysis

    if (-not [string]::IsNullOrWhiteSpace($Html)) {
        $htmlPath = Write-TextFile -Path $Html -Text (New-HtmlReport -Analysis $analysis)
        Write-Host ''
        Write-Host ('HTML report: ' + $htmlPath) -ForegroundColor Cyan
        if ($Open) {
            Start-Process -FilePath $htmlPath | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Json)) {
        $jsonText = Get-JsonModel -Analysis $analysis | ConvertTo-Json -Depth 8
        $jsonPath = Write-TextFile -Path $Json -Text ($jsonText + [Environment]::NewLine)
        Write-Host ('JSON data  : ' + $jsonPath) -ForegroundColor Cyan
    }

    if (-not [string]::IsNullOrWhiteSpace($Csv)) {
        $rows = @(Get-CsvRows -Analysis $analysis)
        $csvText = ($rows | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine
        $csvPath = Write-TextFile -Path $Csv -Text ($csvText + [Environment]::NewLine)
        Write-Host ('CSV data   : ' + $csvPath) -ForegroundColor Cyan
    }
} catch {
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Verbose $_.ScriptStackTrace
    exit 1
}
