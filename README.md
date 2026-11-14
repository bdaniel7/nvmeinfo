It turns out that I have a NVME disk that shares the PCIEX lane with my GPU, thus halving the card's bandwidth.
After fumbling about with HWinfo, GPU-Z, msinfo and disk manager to find out which drive is that, in order to move it, I set out to fix the situation.


Thus I give you **nvmeinfo**:

# NVMe Slot Info

A dependency-free Windows 10 tool that shows which physical motherboard slot
each NVMe drive is connected to.

It reads the **SMBIOS Type 9 slot table directly from firmware**, walks each
NVMe controller's Plug and Play parent chain to its PCIe root or switch port,
and matches that port to the slot label printed on the motherboard, for example
`M.2_1(SOCKET3)` or `PCIEX16_1`.

It also shows the other PCIe devices that occupy slots, such as graphics cards,
network adapters, and storage controllers, so the slot list reflects the whole
machine.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 (included with Windows) or PowerShell 7+.
- No installer, .NET download, external module, or internet connection.
- Administrator rights are **not** required for the normal report.

The native executables in `dist\` are compiled with .NET 10 Native AOT, so they
do not need the .NET runtime installed. They still use the inbox Windows
PowerShell 5.1, which is part of Windows 10/11.

The script uses these inbox components:

- `GetSystemFirmwareTable` from `kernel32.dll` for the SMBIOS table.
- The `PnpDevice` module (`Get-PnpDevice`, `Get-PnpDeviceProperty`).
- The `Storage` module (`Get-PhysicalDisk`) when available.
- WMI/CIM (`Win32_DiskDrive`, `Win32_OperatingSystem`).

## Files

| File | Purpose |
| --- | --- |
| `Get-NvmeSlots.ps1` | Main PowerShell script. |
| `Run-NvmeSlots.cmd` | Double-click launcher for the console report. |
| `Run-NvmeSlots-Report.cmd` | Generates `NvmeSlotReport.html` in the current folder and opens it. |
| `build.ps1` | Builds the standalone native executables in `dist\`. |
| `src\Directory.Build.props` | Shared .NET 10 Native AOT project settings. |
| `src\Launcher\Program.cs` | Launcher that embeds and runs the script. |
| `src\Launcher\NvmeSlots.csproj` | Console executable project. |
| `src\Report\NvmeSlots-Report.csproj` | Report executable project (same launcher, report defaults). |
| `dist\NvmeSlots.exe` | Standalone console report (build output). |
| `dist\NvmeSlots-Report.exe` | Standalone HTML report (build output). |
| `README.md` | This document. |

## Usage

Open PowerShell in this folder and run:

```powershell
.\Get-NvmeSlots.ps1
```

Or double-click `Run-NvmeSlots.cmd`.

### Executables

The `dist` folder contains two standalone console programs:

| Executable | Behaviour |
| --- | --- |
| `NvmeSlots.exe` | Same as `Get-NvmeSlots.ps1`. Accepts `-Html`, `-Json`, `-Csv`, `-Open`, `-NoColor`, and `-Verbose`. |
| `NvmeSlots-Report.exe` | Writes `NvmeSlotReport.html` in the current folder and opens it. Other options pass through; add `-NoOpen` to skip opening the browser. |

```powershell
.\dist\NvmeSlots.exe
.\dist\NvmeSlots.exe -Html .\report.html -Json .\report.json -Csv .\report.csv
.\dist\NvmeSlots-Report.exe
.\dist\NvmeSlots-Report.exe -NoOpen -Json .\report.json
```

The executables are native x64 programs built with .NET 10 Native AOT. They
have no .NET runtime dependency: the import table contains only Windows
components. The PowerShell script is embedded as a resource; at launch it is
written to a unique temporary file, run with the inbox Windows PowerShell 5.1
(`-NoProfile -ExecutionPolicy Bypass`), and deleted afterward. Exit codes are
passed through, and when started by double-click the window stays open at the
end.

The executables are not digitally signed, so SmartScreen or antivirus software
may warn the first time. Build them locally with:

```powershell
.\build.ps1
```

Building needs:

- The .NET 10 SDK.
- Visual Studio 2022 with the **Desktop development with C++** workload (for the
  MSVC linker).
- A Windows SDK. If it is not installed, `build.ps1` downloads the
  hash-verified `Microsoft.Windows.SDK.CPP.x64` NuGet package once (~51 MB) and
  caches the import libraries under `%LOCALAPPDATA%\NvmeSlotInfo`. No
  administrator rights or SDK installer are needed.

The build writes both files to `dist\`. Rerun it after changing the PowerShell
script so the embedded copy stays current.

### HTML report

```powershell
.\Get-NvmeSlots.ps1 -Html .\NvmeSlotReport.html -Open
```

`-Html` writes a single self-contained file: all CSS is embedded, and there are
no external fonts, scripts, or images. `-Open` opens it in the default browser.

Double-clicking `Run-NvmeSlots-Report.cmd` does the same and puts the report in
the folder where the command was started.

### JSON and CSV

```powershell
.\Get-NvmeSlots.ps1 -Json .\nvme-slots.json -Csv .\nvme-slots.csv
```

- **JSON** contains the system/SMBIOS information, every slot with its
  occupants and PCIe/M.2 classification, every NVMe drive, and the unmapped-drive list.
- Console and HTML drive reports distinguish the negotiated PCIe link from the maximum link capability reported by Windows/device firmware. Either value is shown as unavailable when the corresponding properties are not exposed.
- **CSV** contains one row per slot occupant, plus one row per empty slot and
  one row per unmapped NVMe drive.

### Options

| Option | Description |
| --- | --- |
| `-Html <path>` | Write the self-contained HTML report. |
| `-Json <path>` | Write the collected data as JSON. |
| `-Csv <path>` | Write a flat slot/device table as CSV. |
| `-Open` | Open the HTML report after writing it. If `-Html` is omitted, `.\NvmeSlotReport.html` is used. |
| `-NoColor` | Disable colored console output. |

`-Verbose` prints progress messages.

Examples:

```powershell
# Console only
.\Get-NvmeSlots.ps1

# All three formats
.\Get-NvmeSlots.ps1 -Html report.html -Json report.json -Csv report.csv

# Redirect-friendly plain text
.\Get-NvmeSlots.ps1 -NoColor > report.txt
```

## Reading the output

The console report has three main parts:

1. **NVMe drives** - drive number, model, size, matched slot, PCI address,
   negotiated link, match confidence, and health.
2. **Connection paths** - the PCI address of the controller, the upstream port
   and its firmware (ACPI) name, and the final slot label.
3. **Slot occupancy** - every SMBIOS Type 9 entry, including non-PCIe entries;
   only recognized PCI/PCIe-capable connector types participate in PCIe matching
   and the PCIe occupancy summary.

### Confidence levels

| Level | Meaning |
| --- | --- |
| `exact` | The slot's SMBIOS bus/device/function matched the PCIe port exactly. |
| `high` | The SMBIOS device/function matched a CPU root port; firmware did not report a bus, which is common for CPU-attached M.2 and PCIe slots. |
| `medium` | The match came from a farther upstream port, or only the bus matched. |
| `inferred` | No direct match was found, but only one plausible NVMe controller and one empty M.2 slot remained. This is a conservative guess. |
| `unmapped` | No slot information could be matched. |

## How the matching works

1. The firmware SMBIOS table is read with `GetSystemFirmwareTable('RSMB')`, and
   each Type 9 record is decoded: designation, slot type, bus width, usage, bus
   number, and the device/function byte.
2. Every present PCI device is collected through the PnP API. The parent chain
   for each NVMe controller is walked upward through root ports and PCIe switch
   ports.
3. A slot matches when its SMBIOS bus/device/function equals one of those ports.
   The nearest port wins. If firmware stores `0xFF` for an unknown bus or
   device/function, that part is ignored. A device/function value of `0` is a
   valid address (for example `04:00.0`), not a missing value; when both bus and
   device/function are available, only an exact match is accepted, so a different
   port on the same bus cannot claim the slot.
4. Multiple functions of one card (for example, a graphics card plus its HDMI
   audio function) are grouped under the same slot when they share the same
   upstream port.
5. NVMe drives are found through `stornvme` controllers and `Win32_DiskDrive`.
   `Get-PhysicalDisk` supplies health, serial, and size details when available.

The script does **not** use `Win32_SystemSlot`. On many boards that class
misparses the bus/device/function fields, while the raw Type 9 records are what
the firmware actually reported.

## Limitations and notes

- Slot labels exist only if the motherboard firmware publishes SMBIOS Type 9
  records. Some boards publish only a subset, or publish generic labels. All Type 9
  entries remain visible, but generic, unknown, and non-PCIe connector types are
  excluded from PCIe endpoint matching and PCIe occupancy totals.
- Firmware may report the PCIe **port** address (as this ASUS board does) or the
  **endpoint** address. The script prefers the upstream-port interpretation and
  falls back to the port chain; unusual firmware layouts can therefore produce
  `medium` or `unmapped` results.
- Empty slots usually have bus `0x00` and device/function `0xFF`. Slots that
  share lanes through PCIe bifurcation may not all be individually reported.
- M.2 slots wired through a chipset switch are matched against the immediate
  switch port, which is why they can still show `exact` while CPU-attached M.2
  slots show `high`.
- `Get-StorageReliabilityCounter` is optional. Temperature, wear, and power-on
  hours are shown only when the controller and driver expose them.
- Health comes from `Get-PhysicalDisk` / `Win32_DiskDrive` status. It is a
  summary, not a replacement for the drive vendor's SMART tool.
- The tool reports what Windows and the firmware expose. It cannot detect a
  drive that is physically installed but disabled in firmware or has no driver.
- PnP location paths are diagnostic evidence of the Windows device topology. They do not, by themselves, identify a physical motherboard connector or prove which M.2 slot contains a drive.
- In a virtual machine, SMBIOS slot records and PCI passthrough addresses are
  usually not meaningful.

## Troubleshooting

**"The PnpDevice module is required"**

The inbox `PnpDevice` module is missing or blocked by policy. Run the script in
a normal Windows PowerShell 5.1 session, not in a stripped-down PowerShell
host.

**No slots are listed**

The firmware did not publish Type 9 records. Check with:

```powershell
Get-CimInstance Win32_SystemSlot
```

If that also returns nothing useful, the board does not expose slot labels to
the operating system.

**All drives are `unmapped`**

The slot table may use a layout this heuristic does not recognize. Run with
`-Json` and compare the `bus`/`devFn` values in the `slots` array with the
`controllerAddress` values of the drives. The SMBIOS bus/device/function is the
raw firmware value.

**HTML report opens but looks plain**

The report intentionally has no external assets. Any modern browser renders it.
If styles are missing, make sure the file was written completely and the browser
is not opening a cached older copy.

**The executable says PowerShell could not be started**

The EXE is native, but it delegates the report to the inbox Windows PowerShell
5.1. Check that
`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` exists and is not
blocked by policy or antivirus software.

**The build cannot find `kernel32.lib` or the platform linker**

Install the Visual Studio **Desktop development with C++** workload. The Windows
SDK import libraries are downloaded automatically by `build.ps1`; if that
download is blocked, allow access to `api.nuget.org` or place the
`Microsoft.Windows.SDK.CPP.x64` package in
`%LOCALAPPDATA%\NvmeSlotInfo\cache`.

## Notes for developers

The script is intentionally a single file and ASCII-only for Windows PowerShell
5.1 compatibility. It uses:

- `Add-Type` with a small C# P/Invoke wrapper for `GetSystemFirmwareTable`.
- `Get-PnpDeviceProperty` for `DEVPKEY_Device_BusNumber` and
  `DEVPKEY_Device_Address`; the address is decoded as
  `(device << 16) | function`. `DEVPKEY_Device_LocationPaths` is retained as
  additional PnP topology evidence.
- `DEVPKEY_Device_BiosDeviceName` for the firmware/ACPI path, which is useful
  when explaining a match.

Slot type, width, and usage codes follow the SMBIOS specification and the
dmidecode decoding tables.

The launcher is a .NET 10 Native AOT console application. It embeds the script
as a managed resource, slices arguments with `ProcessStartInfo.ArgumentList`
(no manual command-line quoting), and forwards the PowerShell exit code. It uses
no reflection beyond `GetManifestResourceStream`, which keeps the AOT trimmer
happy. The two executables share `src\Launcher\Program.cs`; only the report build
defines `REPORT_MODE`.

### Tests

`tests\Compatibility.Tests.ps1` parses the complete script and checks the pure
SMBIOS M.2 slot-classification function without enumerating hardware:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Compatibility.Tests.ps1
```

The `powershell-compatibility.yml` GitHub Actions workflow runs the same test
under Windows PowerShell 5.1 and PowerShell 7.

## Version

1.1
