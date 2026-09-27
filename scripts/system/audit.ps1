<#
.SYNOPSIS
    audit.ps1 - Universal Complete Machine Audit for Windows 11
    Comprehensive, non-destructive system, hardware, security, software, and health audit.

.DESCRIPTION
    A complete, enterprise-grade audit script specifically designed for Windows 11
    (also backward-compatible with Windows 10 and Windows Server 2019/2022).
    Inspects OS identity, hardware topology, storage health, BitLocker, network,
    Windows Defender & Firewall, local accounts, UAC, Core Isolation/HVCI, services,
    recent event errors, software inventory (Registry, Winget, Chocolatey, Scoop),
    WSL2, Hyper-V, Docker, disk junk/cache reclaimable space, and developer environment.

.PARAMETER Quick
    Fast triage snapshot (< 5s), skips deep disk folder walking and long event log queries.

.PARAMETER SecurityOnly
    Run only security posture, accounts, firewall, Windows Defender, BitLocker, and secrets scan.

.PARAMETER CleanupOnly
    Run only disk junk, temporary files, Windows Update cache, and reclaimable space analysis.

.PARAMETER Output
    File path to write the clean audit report to (text, json, or html).

.PARAMETER ExportDir
    Directory path to export detailed individual inventory lists (installed apps, network, etc.).

.PARAMETER Format
    Report format when saving to file: Text (default), Json, or Html.

.PARAMETER NoColor
    Disable ANSI color sequences in console output.

.PARAMETER Version
    Display script version.

.EXAMPLE
    .\audit.ps1
    .\audit.ps1 -Quick
    .\audit.ps1 -Output C:\Temp\win11-audit.txt
    .\audit.ps1 -ExportDir C:\Temp\AuditExports
    .\audit.ps1 -SecurityOnly -NoColor
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter(Mandatory = $false, HelpMessage = 'Fast triage audit (< 5s)')]
    [switch]$Quick,

    [Parameter(Mandatory = $false, HelpMessage = 'Security posture only')]
    [switch]$SecurityOnly,

    [Parameter(Mandatory = $false, HelpMessage = 'Disk junk & cleanup audit only')]
    [switch]$CleanupOnly,

    [Parameter(Mandatory = $false, HelpMessage = 'Output file path')]
    [string]$Output,

    [Parameter(Mandatory = $false, HelpMessage = 'Directory path to export inventory lists')]
    [string]$ExportDir,

    [Parameter(Mandatory = $false, HelpMessage = 'Custom directory to scan for Git repositories')]
    [string]$RepoDir,

    [Parameter(Mandatory = $false, HelpMessage = 'Output format: Text, Json, or Html')]
    [ValidateSet('Text', 'Json', 'Html')]
    [string]$Format = 'Text',

    [Parameter(Mandatory = $false, HelpMessage = 'Disable ANSI console colors')]
    [switch]$NoColor,

    [Parameter(Mandatory = $false, HelpMessage = 'Do not prompt or request UAC elevation')]
    [switch]$NoElevation,

    [Parameter(Mandatory = $false, HelpMessage = 'Show version information')]
    [switch]$Version
)

$SCRIPT_VERSION = "2.0.0"
$SCRIPT_NAME    = "audit.ps1"

if ($Version) {
    Write-Output "$SCRIPT_NAME $SCRIPT_VERSION"
    exit 0
}

# Ensure Error Action does not abort entire audit on single unprivileged check
$ErrorActionPreference = 'Continue'
$StartTime = Get-Date

# =============================================================================
# PRIVILEGE & TARGET USER RESOLUTION
# Resolves the true desktop user and profile directory so elevated execution
# does not distort user-level audit results (cache, temp, git repos, secrets).
# =============================================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Require / Request Administrator Privileges from the start if needed
if (-not $IsAdmin -and -not $NoElevation) {
    if ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
        Write-Host "==========================================================================" -ForegroundColor Cyan
        Write-Host "[*] Complete Windows 11 Audit requires Administrator privileges to inspect" -ForegroundColor Yellow
        Write-Host "    physical disk health, BitLocker, Windows Defender, and Event Logs." -ForegroundColor Yellow
        Write-Host "    Requesting elevation via UAC..." -ForegroundColor Cyan
        Write-Host "==========================================================================" -ForegroundColor Cyan
        
        $scriptPath = $MyInvocation.MyCommand.Definition
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }

        if ($scriptPath) {
            $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"")
            if ($Quick) { $argList += "-Quick" }
            if ($SecurityOnly) { $argList += "-SecurityOnly" }
            if ($CleanupOnly) { $argList += "-CleanupOnly" }
            if ($NoColor) { $argList += "-NoColor" }
            if ($Output) { $argList += "-Output", "`"$Output`"" }
            if ($ExportDir) { $argList += "-ExportDir", "`"$ExportDir`"" }
            if ($Format -ne 'Text') { $argList += "-Format", $Format }
            $argList += "-NoElevation"

            try {
                $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -PassThru -Wait
                exit $proc.ExitCode
            } catch {
                Write-Warning "UAC elevation request was declined. Continuing with standard user privileges..."
            }
        }
    } else {
        Write-Warning "Running non-interactively without Administrator privileges. Proceeding with standard user checks..."
    }
}

# Target User Resolution (ensures elevated session still audits the real interactive user's environment)
$loggedUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
if ($loggedUser) {
    $TargetUser = $loggedUser
    $userBasename = ($loggedUser -split '\\')[-1]
    $userDir = Join-Path "C:\Users" $userBasename
    if (Test-Path $userDir) {
        $TargetUserProfile = $userDir
    } else {
        $TargetUserProfile = $env:USERPROFILE
    }
} else {
    $TargetUser = "$env:USERDOMAIN\$env:USERNAME"
    $TargetUserProfile = $env:USERPROFILE
}

# Color Formatting Definitions
$ESC = [char]27
if ($NoColor -or (-not [Console]::IsOutputRedirected -and $Host.UI.RawUI.ForegroundColor -eq $null)) {
    $C_TITLE  = ""
    $C_HEADER = ""
    $C_SEC    = ""
    $C_OK     = ""
    $C_WARN   = ""
    $C_INFO   = ""
    $C_BOLD   = ""
    $C_RESET  = ""
} else {
    $C_TITLE  = "$ESC[1;44;37m"
    $C_HEADER = "$ESC[1;36m"
    $C_SEC    = "$ESC[1;33m"
    $C_OK     = "$ESC[1;32m"
    $C_WARN   = "$ESC[1;31m"
    $C_INFO   = "$ESC[0;36m"
    $C_BOLD   = "$ESC[1m"
    $C_RESET  = "$ESC[0m"
}

# String Builder for File Logging / Output Redirection
$Script:LogBuffer = [System.Text.StringBuilder]::new()
$Script:ReclaimableBytes = 0

function Write-Log {
    param([string]$Message)
    [void]$Script:LogBuffer.AppendLine($Message)
    Write-Host $Message
}

function Log-Title {
    param([string]$Text)
    Write-Log "`n$C_TITLE=== $Text ===$C_RESET"
}

function Log-Section {
    param([string]$Num, [string]$Title)
    Write-Log "`n$C_HEADER[$Num] $Title$C_RESET"
}

function Log-Sub {
    param([string]$Title)
    Write-Log "`n$C_SEC--- $Title ---$C_RESET"
}

function Log-Ok {
    param([string]$Text)
    Write-Log "$C_OK[OK]$C_RESET $Text"
}

function Log-Info {
    param([string]$Text)
    Write-Log "$C_INFO[*]$C_RESET $Text"
}

function Log-Warn {
    param([string]$Text)
    Write-Log "$C_WARN[!]$C_RESET $Text"
}

function Log-Rule {
    Write-Log "--------------------------------------------------------------------------"
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -lt 1KB) { return "{0:N0} B" -f $Bytes }
    if ($Bytes -lt 1MB) { return "{0:N2} KiB" -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return "{0:N2} MiB" -f ($Bytes / 1MB) }
    if ($Bytes -lt 1TB) { return "{0:N2} GiB" -f ($Bytes / 1GB) }
    return "{0:N2} TiB" -f ($Bytes / 1TB)
}

function Add-Reclaim {
    param([double]$Bytes)
    $Script:ReclaimableBytes += $Bytes
}

# Prepare Export Directory if specified
if ($ExportDir) {
    try {
        if (-not (Test-Path $ExportDir)) {
            New-Item -Path $ExportDir -ItemType Directory -Force | Out-Null
        }
    } catch {
        Log-Warn "Could not create Export Directory: $ExportDir"
    }
}

# Display Header Banner
Log-Title "UNIVERSAL WINDOWS 11 MACHINE AUDIT: $($env:COMPUTERNAME.ToUpper())"
Write-Log ("Version        : {0}" -f $SCRIPT_VERSION)
Write-Log ("Timestamp      : {0}" -f $StartTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))
Write-Log ("Audited User   : {0} [Profile: {1}]" -f $TargetUser, $TargetUserProfile)
Write-Log ("Privilege Mode : {0}" -f $(if ($IsAdmin) { "Elevated (Administrator)" } else { "Standard User (Non-elevated)" }))
Write-Log ("Audit Mode     : {0}" -f $(if ($Quick) { "Quick Triage (< 5s)" } elseif ($SecurityOnly) { "Security Posture Only" } elseif ($CleanupOnly) { "Disk Junk & Cleanup Only" } else { "Complete Machine Audit" }))
if ($Output)    { Write-Log ("Output File    : {0}" -f $Output) }
if ($ExportDir) { Write-Log ("Export Dir     : {0}" -f $ExportDir) }
Log-Rule

# =============================================================================
# MODULE 1: SYSTEM IDENTITY, OS BUILD & HARDWARE TOPOLOGY
# =============================================================================
function Audit-SystemHardware {
    Log-Section "1" "SYSTEM IDENTITY, WINDOWS 11 BUILD, HARDWARE & SENSORS"

    Log-Sub "Operating System Identity & Windows 11 Build"
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue

    $regCurrent = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $displayVer = if ($regCurrent.DisplayVersion) { $regCurrent.DisplayVersion } else { $regCurrent.ReleaseId }
    $ubr = $regCurrent.UBR

    Write-Log ("OS Caption     : {0}" -f $os.Caption)
    Write-Log ("Display Version: {0}" -f $displayVer)
    Write-Log ("Build Number   : {0}.{1}" -f $os.BuildNumber, $ubr)
    Write-Log ("Architecture   : {0}" -f $os.OSArchitecture)
    Write-Log ("Computer Name  : {0}" -f $env:COMPUTERNAME)
    Write-Log ("Domain/Group   : {0} ({1})" -f $cs.Domain, $(if ($cs.PartOfDomain) { "Domain" } else { "Workgroup" }))
    Write-Log ("Install Date   : {0}" -f $os.InstallDate)
    Write-Log ("Last Boot Time : {0}" -f $os.LastBootUpTime)
    
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Log ("System Uptime  : {0} days, {1} hours, {2} minutes" -f $uptime.Days, $uptime.Hours, $uptime.Minutes)

    # Firmware & Boot Mode
    $firmware = "Unknown"
    if ($env:firmware_type) {
        $firmware = $env:firmware_type
    } else {
        try {
            $regObj = Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control' -ErrorAction SilentlyContinue
            if ($regObj -and $regObj.PEFirmwareType) {
                if ($regObj.PEFirmwareType -eq 2) { $firmware = "UEFI" }
                elseif ($regObj.PEFirmwareType -eq 1) { $firmware = "Legacy BIOS" }
            }
        } catch {}
    }

    # Secure Boot
    $sb = $null
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        Write-Log ("Secure Boot    : {0}" -f $(if ($sb) { "Enabled [OK]" } else { "Disabled [!]" }))
        if ($firmware -eq "Unknown" -and $sb -ne $null) {
            $firmware = "UEFI"
        }
    } catch {
        Write-Log ("Secure Boot    : Not Supported / Access Denied")
    }

    Write-Log ("Firmware Type  : {0}" -f $firmware)


    # TPM 2.0 Status
    try {
        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        if ($tpm) {
            Write-Log ("TPM Present    : {0} | Ready: {1} | Enabled: {2}" -f $tpm.TpmPresent, $tpm.TpmReady, $tpm.TpmEnabled)
        } else {
            Write-Log ("TPM            : Not Detected / Query Restricted")
        }
    } catch {
        Write-Log ("TPM            : Query requires Administrator privileges")
    }

    Log-Sub "CPU Architecture & Utilization"
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Log ("Processor      : {0}" -f $cpu.Name.Trim())
    Write-Log ("Physical Cores : {0}" -f $cpu.NumberOfCores)
    Write-Log ("Logical Cores  : {0}" -f $cpu.NumberOfLogicalProcessors)
    Write-Log ("Max Clock Speed: {0} MHz" -f $cpu.MaxClockSpeed)
    Write-Log ("Current Load   : {0}%" -f $cpu.LoadPercentage)

    Log-Sub "Physical Memory & Pagefile"
    $totalRamBytes = [double]$os.TotalVisibleMemorySize * 1KB
    $freeRamBytes  = [double]$os.FreePhysicalMemory * 1KB
    $usedRamBytes  = $totalRamBytes - $freeRamBytes
    $ramPct = [Math]::Round(($usedRamBytes / $totalRamBytes) * 100, 1)

    Write-Log ("Total RAM      : {0}" -f (Format-Bytes $totalRamBytes))
    Write-Log ("Available RAM  : {0}" -f (Format-Bytes $freeRamBytes))
    Write-Log ("Memory Usage   : {0}% used" -f $ramPct)

    $pagefile = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($pagefile) {
        foreach ($pf in $pagefile) {
            Write-Log ("Pagefile [{0}]: Allocated {1} MB | Current Usage: {2} MB" -f $pf.Name, $pf.AllocatedBaseSize, $pf.CurrentUsage)
        }
    }

    Log-Sub "Motherboard & BIOS"
    Write-Log ("Motherboard    : {0} {1}" -f $bb.Manufacturer, $bb.Product)
    Write-Log ("BIOS Version   : {0} ({1})" -f $bios.SMBIOSBIOSVersion, $bios.ReleaseDate)

    Log-Sub "Graphics & Display Accelerators (GPU)"
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        Write-Log ("GPU Adapter    : {0}" -f $gpu.Name)
        Write-Log ("  Driver Version: {0}" -f $gpu.DriverVersion)
        if ($gpu.AdapterRAM -gt 0) {
            Write-Log ("  VRAM Dedicated: {0}" -f (Format-Bytes $gpu.AdapterRAM))
        }
        if ($gpu.VideoModeDescription) {
            Write-Log ("  Resolution    : {0}" -f $gpu.VideoModeDescription)
        }
    }

    # Check for NVIDIA-SMI
    if (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue) {
        Write-Log ("`nNVIDIA SMI Snapshot:")
        & nvidia-smi.exe --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu --format=csv,noheader 2>$null | ForEach-Object {
            Write-Log ("  GPU {0}" -f $_)
        }
    }

    Log-Sub "Battery & Power Configuration"
    $batteries = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($batteries) {
        foreach ($bat in $batteries) {
            Write-Log ("Battery        : {0}% charge | Status: {1}" -f $bat.EstimatedChargeRemaining, $bat.BatteryStatus)
        }
    } else {
        Write-Log ("Battery        : None detected (Desktop, VM, or Server)")
    }

    $activeScheme = (powercfg /getactivescheme 2>$null) -replace '^Power Scheme GUID:\s*', ''
    if ($activeScheme) {
        Write-Log ("Power Plan     : {0}" -f $activeScheme)
    }
}

# =============================================================================
# MODULE 2: STORAGE, PHYSICAL DRIVES, PARTITIONS & BITLOCKER
# =============================================================================
function Audit-Storage {
    Log-Section "2" "STORAGE, PHYSICAL DRIVES, PARTITIONS & BITLOCKER"

    Log-Sub "Physical Disk Drives & Health Status"
    try {
        $pDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        if ($pDisks) {
            foreach ($pd in $pDisks) {
                Write-Log ("Drive [{0}]: {1} | Media: {2} | Bus: {3} | Health: {4} | Size: {5}" -f `
                    $pd.DeviceId, $pd.FriendlyName, $pd.MediaType, $pd.BusType, $pd.HealthStatus, (Format-Bytes $pd.Size))
            }
        } else {
            Get-CimInstance Win32_DiskDrive | ForEach-Object {
                Write-Log ("Drive [{0}]: {1} | Size: {2} | Status: {3}" -f $_.Index, $_.Model, (Format-Bytes $_.Size), $_.Status)
            }
        }
    } catch {
        Write-Log ("Physical disk query restricted.")
    }

    Log-Sub "Mounted Volumes & Capacity"
    $volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -ne $null -and $_.Size -gt 0 }
    if ($volumes) {
        foreach ($v in $volumes) {
            $freePct = [Math]::Round(($v.SizeRemaining / $v.Size) * 100, 1)
            $label = if ($v.FileSystemLabel) { "({0})" -f $v.FileSystemLabel } else { "" }
            Write-Log ("Drive {0}: {1} | {2} | Total: {3} | Free: {4} ({5}%)" -f `
                $v.DriveLetter, $label, $v.FileSystem, (Format-Bytes $v.Size), (Format-Bytes $v.SizeRemaining), $freePct)

            if ($freePct -lt 15) {
                Log-Warn ("CRITICAL: Drive {0}: has only {1}% free space remaining!" -f $v.DriveLetter, $freePct)
            }
        }
    } else {
        Get-PSDrive -PSProvider FileSystem | ForEach-Object {
            Write-Log ("Drive {0}: | Free: {1}" -f $_.Name, (Format-Bytes $_.Free))
        }
    }

    Log-Sub "BitLocker Drive Encryption Status"
    try {
        $blVolumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
        if ($blVolumes) {
            foreach ($bl in $blVolumes) {
                $statusStr = if ($bl.ProtectionStatus -eq 'On') { "PROTECTED [OK]" } else { "UNPROTECTED [!]" }
                Write-Log ("Volume {0}: {1} | Encryption: {2} ({3}%) | Method: {4}" -f `
                    $bl.MountPoint, $statusStr, $bl.VolumeStatus, $bl.EncryptionPercentage, $bl.EncryptionMethod)
            }
        } else {
            Write-Log ("BitLocker: No BitLocker volumes or cmdlet unavailable.")
        }
    } catch {
        Write-Log ("BitLocker query requires Administrator privileges.")
    }

    if (-not $Quick) {
        Log-Sub "Volume Shadow Copies (VSS)"
        try {
            $shadows = Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue
            if ($shadows) {
                Write-Log ("Detected {0} Volume Shadow Copy snapshot(s)." -f ($shadows | Measure-Object).Count)
            } else {
                Write-Log ("No active Volume Shadow Copies.")
            }
        } catch {
            Write-Log ("Shadow copy query restricted.")
        }
    }
}

# =============================================================================
# MODULE 3: NETWORK INTERFACES, ROUTES, DNS, PORTS & WI-FI
# =============================================================================
function Audit-Network {
    Log-Section "3" "NETWORK ADAPTERS, ADDRESSES, DNS, PORTS & WI-FI"

    Log-Sub "Network Adapters & Link Speeds"
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        foreach ($na in $adapters) {
            Write-Log ("Adapter [{0}]: {1} | Speed: {2} | MAC: {3}" -f $na.InterfaceAlias, $na.InterfaceDescription, $na.LinkSpeed, $na.MacAddress)
        }
    } catch {
        Get-CimInstance Win32_NetworkAdapter -Filter "NetConnectionStatus=2" | ForEach-Object {
            Write-Log ("Adapter: {0} | Speed: {1}" -f $_.Name, $_.Speed)
        }
    }

    Log-Sub "IP Addresses & Default Gateway"
    try {
        $ipConfigs = Get-NetIPConfiguration -ErrorAction SilentlyContinue
        foreach ($ipc in $ipConfigs) {
            if ($ipc.IPv4Address) {
                $gw = if ($ipc.IPv4DefaultGateway) { $ipc.IPv4DefaultGateway.NextHop } else { "None" }
                Write-Log ("Interface: {0}" -f $ipc.InterfaceAlias)
                Write-Log ("  IPv4 Address   : {0}" -f ($ipc.IPv4Address.IPAddress -join ', '))
                Write-Log ("  Default Gateway: {0}" -f $gw)
            }
        }
    } catch {
        ipconfig /all | Select-String -Pattern 'IPv4 Address|Default Gateway|Subnet Mask' | ForEach-Object {
            Write-Log ("  {0}" -f $_.Line.Trim())
        }
    }

    Log-Sub "Configured DNS Servers"
    try {
        $dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses.Count -gt 0 }
        foreach ($ds in $dnsServers) {
            Write-Log ("Interface [{0}]: DNS = {1}" -f $ds.InterfaceAlias, ($ds.ServerAddresses -join ', '))
        }
    } catch {
        Write-Log ("DNS query restricted.")
    }

    Log-Sub "Listening TCP Ports & Owning Processes"
    try {
        $tcpListeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
        if ($tcpListeners) {
            $tcpGrouped = $tcpListeners | Group-Object LocalPort | Sort-Object { [int]$_.Name }
            Write-Log ("{0,-8} {1,-20} {2,-30}" -f "PORT", "PROCESS", "LOCAL ADDRESS")
            Log-Rule
            foreach ($grp in $tcpGrouped | Select-Object -First 25) {
                $first = $grp.Group[0]
                $procName = "Unknown"
                try {
                    $p = Get-Process -Id $first.OwningProcess -ErrorAction SilentlyContinue
                    if ($p) { $procName = "{0} ({1})" -f $p.ProcessName, $first.OwningProcess }
                } catch {}
                Write-Log ("{0,-8} {1,-20} {2,-30}" -f $first.LocalPort, $procName, $first.LocalAddress)
            }
        }
    } catch {
        netstat -ano | Select-String "LISTENING" | Select-Object -First 20 | ForEach-Object {
            Write-Log ("  {0}" -f $_.Line.Trim())
        }
    }

    Log-Sub "Saved Wi-Fi Profiles (WLAN)"
    try {
        $wlanProfiles = netsh wlan show profiles 2>$null | Select-String "All User Profile"
        if ($wlanProfiles) {
            Write-Log ("Detected {0} saved Wi-Fi profile(s):" -f $wlanProfiles.Count)
            foreach ($wp in $wlanProfiles | Select-Object -First 10) {
                $ssid = ($wp.Line -split ':\s*')[1]
                Write-Log ("  - {0}" -f $ssid)
            }
            if ($wlanProfiles.Count -gt 10) {
                Write-Log ("  ... and {0} more profiles." -f ($wlanProfiles.Count - 10))
            }
        } else {
            Write-Log ("No Wi-Fi profiles found or WLAN interface inactive.")
        }
    } catch {}

    Log-Sub "Tailscale / VPN Connections"
    if (Get-Command tailscale.exe -ErrorAction SilentlyContinue) {
        & tailscale.exe status 2>$null | Select-Object -First 10 | ForEach-Object {
            Write-Log ("  {0}" -f $_)
        }
    } else {
        Write-Log ("Tailscale not installed.")
    }
}

# =============================================================================
# MODULE 4: SECURITY POSTURE, DEFENDER, FIREWALL & SECRETS SCAN
# =============================================================================
function Audit-Security {
    Log-Section "4" "SECURITY POSTURE, DEFENDER, FIREWALL & CREDENTIALS"

    Log-Sub "Windows Defender Antivirus Status"
    try {
        $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($mp) {
            Write-Log ("Real-Time Protection : {0}" -f $(if ($mp.RealTimeProtectionEnabled) { "ENABLED [OK]" } else { "DISABLED [!]" }))
            Write-Log ("Antivirus Enabled    : {0}" -f $(if ($mp.AntivirusEnabled) { "ENABLED [OK]" } else { "DISABLED [!]" }))
            Write-Log ("Antispyware Enabled  : {0}" -f $mp.AntispywareEnabled)
            Write-Log ("Signature Version    : {0}" -f $mp.AntivirusSignatureVersion)
            Write-Log ("Signature Age (Days) : {0}" -f $mp.AntivirusSignatureAge)
            Write-Log ("Behavior Monitor     : {0}" -f $mp.BehaviorMonitorEnabled)
            Write-Log ("IOAV Protection      : {0}" -f $mp.IoavProtectionEnabled)
        } else {
            Write-Log ("Windows Defender status query returned empty or Defender is managed by third-party AV.")
        }
    } catch {
        Write-Log ("Defender query restricted.")
    }

    # Third-Party Antivirus Detection via WMI SecurityCenter2
    try {
        $avProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
        if ($avProducts) {
            Write-Log ("Registered Antivirus Engine(s):")
            foreach ($av in $avProducts) {
                Write-Log ("  - {0} (State: {1})" -f $av.displayName, $av.productState)
            }
        }
    } catch {}

    Log-Sub "Windows Firewall Profiles"
    try {
        $fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        foreach ($fwp in $fwProfiles) {
            $stateStr = if ($fwp.Enabled) { "ENABLED [OK]" } else { "DISABLED [!]" }
            Write-Log ("Profile [{0}]: {1} | Inbound: {2} | Outbound: {3}" -f `
                $fwp.Name, $stateStr, $fwp.DefaultInboundAction, $fwp.DefaultOutboundAction)
        }
    } catch {
        Write-Log ("Firewall profile query restricted.")
    }

    Log-Sub "Local Administrators & Users"
    try {
        $admins = Get-LocalGroupMember -Group Administrators -ErrorAction SilentlyContinue
        if ($admins) {
            Write-Log ("Members of Local Administrators Group:")
            foreach ($adm in $admins) {
                Write-Log ("  - {0} ({1})" -f $adm.Name, $adm.ObjectClass)
            }
        } else {
            net localgroup administrators | Select-Object -Skip 6 | Where-Object { $_ -match '\S' -and $_ -notmatch 'command completed' } | ForEach-Object {
                Write-Log ("  - {0}" -f $_.Trim())
            }
        }
    } catch {
        Write-Log ("Local group enumeration restricted.")
    }

    Log-Sub "User Account Control (UAC) & Windows 11 Protections"
    $uac = $null
    try {
        $uac = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
    } catch {}
    Write-Log ("UAC Enabled          : {0}" -f $(if ($uac -eq 1) { "YES [OK]" } else { "NO (DISABLED) [!]" }))

    # Virtualization-Based Security (VBS) & HVCI
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
        if ($dg) {
            $vbsRunning = if ($dg.VirtualizationBasedSecurityStatus -eq 2) { "Running [OK]" } else { "Not Running [!]" }
            Write-Log ("VBS (Virtualization) : {0}" -f $vbsRunning)
            Write-Log ("Core Isolation/HVCI  : {0}" -f $(if ($dg.SecurityServicesRunning -contains 1) { "Running [OK]" } else { "Not Running" }))
        }
    } catch {}

    # Developer Mode & Sudo for Windows
    $devMode = $null
    try {
        $devMode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
    } catch {}
    Write-Log ("Developer Mode       : {0}" -f $(if ($devMode -eq 1) { "ENABLED" } else { "Disabled" }))

    $sudoReg = $null
    try {
        $sudoReg = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' -ErrorAction SilentlyContinue).Enabled
    } catch {}
    if ($sudoReg -ne $null) {
        Write-Log ("Sudo for Windows     : {0}" -f $(if ($sudoReg -eq 1) { "Enabled" } else { "Disabled" }))
    }

    if (-not $Quick) {
        Log-Sub "Sensitive Files & Credentials Scan ($TargetUser Profile)"
        $scanRoot = $TargetUserProfile
        $secretPatterns = @("*.env*", "*.pem", "*.key", "id_rsa*", "*token*", "*.tfvars", "*secret*.yaml", "*secret*.yml")
        $foundSecrets = @()

        try {
            # Search user folders, skipping heavy binaries/temp/caches
            $candidateFolders = @("Desktop", "Documents", "source", "Projects", "main", ".ssh")
            foreach ($folder in $candidateFolders) {
                $targetPath = Join-Path $scanRoot $folder
                if (Test-Path $targetPath) {
                    $files = Get-ChildItem -Path $targetPath -Include $secretPatterns -Recurse -File -Depth 3 -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.venv|\.cache|AppData)\\' }
                    if ($files) {
                        $foundSecrets += $files
                    }
                }
            }

            if ($foundSecrets.Count -gt 0) {
                Log-Warn ("Detected {0} sensitive file(s) (private keys, tokens, .env):" -f $foundSecrets.Count)
                foreach ($sf in $foundSecrets | Select-Object -First 10) {
                    Write-Log ("  - {0}" -f $sf.FullName)
                }
                if ($foundSecrets.Count -gt 10) {
                    Write-Log ("  ... and {0} more files." -f ($foundSecrets.Count - 10))
                }
            } else {
                Log-Ok "No unencrypted sensitive files or keys detected in primary user directories."
            }
        } catch {
            Write-Log ("Secrets scan encountered restrictions.")
        }
    }
}

# =============================================================================
# MODULE 5: PROCESSES, SERVICES & SYSTEM RELIABILITY
# =============================================================================
function Audit-ProcessesServices {
    Log-Section "5" "PROCESSES, SERVICES & EVENT LOG ERRORS"

    $procs = Get-Process
    Write-Log ("Running Processes    : {0}" -f $procs.Count)

    Log-Sub "Top 10 Processes by Memory Usage (Working Set)"
    Write-Log ("{0,-8} {1,-28} {2,12} {3,12}" -f "PID", "PROCESS NAME", "MEM (WS)", "PRIVATE MEM")
    Log-Rule
    $topMem = $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 10
    foreach ($p in $topMem) {
        Write-Log ("{0,-8} {1,-28} {2,12} {3,12}" -f $p.Id, $p.ProcessName, (Format-Bytes $p.WorkingSet64), (Format-Bytes $p.PrivateMemorySize64))
    }

    Log-Sub "Top 10 Processes by CPU Time"
    Write-Log ("{0,-8} {1,-28} {2,12}" -f "PID", "PROCESS NAME", "CPU (SEC)")
    Log-Rule
    $topCpu = $procs | Where-Object { $_.CPU -gt 0 } | Sort-Object CPU -Descending | Select-Object -First 10
    foreach ($p in $topCpu) {
        Write-Log ("{0,-8} {1,-28} {2,12:N1}" -f $p.Id, $p.ProcessName, $p.CPU)
    }

    Log-Sub "Services Set to Automatic but Currently Stopped"
    try {
        $stoppedAuto = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }
        if ($stoppedAuto) {
            Write-Log ("Detected {0} Automatic service(s) currently stopped:" -f $stoppedAuto.Count)
            foreach ($s in $stoppedAuto | Select-Object -First 15) {
                Write-Log ("  - {0,-25} ({1})" -f $s.Name, $s.DisplayName)
            }
        } else {
            Log-Ok "All Automatic services are currently running."
        }
    } catch {
        Write-Log ("Service enumeration restricted.")
    }

    if (-not $Quick) {
        Log-Sub "Recent Critical & Error Events (System & Application - Last 24 Hours)"
        try {
            $yesterday = (Get-Date).AddDays(-1)
            $events = Get-WinEvent -FilterHashtable @{LogName = @('System', 'Application'); Level = 1, 2; StartTime = $yesterday} -MaxEvents 15 -ErrorAction SilentlyContinue
            if ($events) {
                Write-Log ("Found {0} critical/error event(s) in the last 24h:" -f $events.Count)
                foreach ($evt in $events) {
                    $msg = ($evt.Message -split "`r?`n")[0]
                    if ($msg.Length -gt 70) { $msg = $msg.Substring(0, 67) + "..." }
                    Write-Log ("  [{0:HH:mm:ss}] [{1}] Provider: {2} | ID: {3} | {4}" -f $evt.TimeCreated, $evt.LogName, $evt.ProviderName, $evt.Id, $msg)
                }
            } else {
                Log-Ok "Zero critical or error events recorded in the last 24 hours."
            }
        } catch {
            Write-Log ("Event log query restricted (requires elevation).")
        }
    }
}

# =============================================================================
# MODULE 6: SOFTWARE INVENTORY & PACKAGE MANAGERS
# =============================================================================
function Audit-SoftwareInventory {
    Log-Section "6" "SOFTWARE INVENTORY, WINGET, CHOCO & STARTUP APPS"

    Log-Sub "Installed Applications (Registry 64-bit & 32-bit)"
    $regPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and $_.ParentKeyName -eq $null } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
        Sort-Object DisplayName -Unique

    Write-Log ("Installed Desktop Applications: {0}" -f $apps.Count)
    foreach ($app in $apps | Select-Object -First 15) {
        $ver = if ($app.DisplayVersion) { $app.DisplayVersion } else { "N/A" }
        Write-Log ("  - {0,-40} | Version: {1}" -f $app.DisplayName, $ver)
    }
    if ($apps.Count -gt 15) {
        Write-Log ("  ... and {0} more applications." -f ($apps.Count - 15))
    }

    if ($ExportDir) {
        $appsExport = Join-Path $ExportDir "installed_software.txt"
        $apps | Out-File -FilePath $appsExport -Encoding utf8 -ErrorAction SilentlyContinue
        Log-Ok ("Exported software inventory to {0}" -f $appsExport)
    }

    Log-Sub "Modern Package Managers (Winget / Chocolatey / Scoop)"
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Log ("Winget CLI detected.")
        if (-not $Quick) {
            $wingetPkgs = & winget.exe list --accept-source-agreements 2>$null | Select-Object -Skip 3 | Select-Object -First 10
            if ($wingetPkgs) {
                Write-Log ("Winget Packages Sample:")
                $wingetPkgs | ForEach-Object { Write-Log ("  {0}" -f $_) }
            }
        }
    } else {
        Write-Log ("Winget CLI not available.")
    }

    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        $chocoPkgs = & choco.exe list --local-only 2>$null | Select-String 'packages installed'
        Write-Log ("Chocolatey: {0}" -f $chocoPkgs)
    }
    if (Get-Command scoop.exe -ErrorAction SilentlyContinue) {
        Write-Log ("Scoop package manager detected.")
    }

    Log-Sub "Windows Optional Features (Hyper-V, WSL, Sandbox, Containers)"
    try {
        $features = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.FeatureName -match 'Hyper-V|Microsoft-Windows-Subsystem-Linux|Containers|Windows-Sandbox' -and $_.State -eq 'Enabled' }
        if ($features) {
            Write-Log ("Enabled Platform Features:")
            foreach ($f in $features) {
                Write-Log ("  [OK] {0}" -f $f.FeatureName)
            }
        } else {
            Write-Log ("No advanced virtualization optional features enabled.")
        }
    } catch {
        Write-Log ("Optional feature query restricted.")
    }

    Log-Sub "Startup Applications (Registry & Startup Folder)"
    $runPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($rp in $runPaths) {
        $props = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
        if ($props) {
            $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                Write-Log ("  [Startup] {0,-22} = {1}" -f $_.Name, $_.Value)
            }
        }
    }
}

# =============================================================================
# MODULE 7: VIRTUALIZATION, WSL2 & CONTAINERS
# =============================================================================
function Audit-Virtualization {
    Log-Section "7" "VIRTUALIZATION, WSL2 & CONTAINERS"

    Log-Sub "Windows Subsystem for Linux (WSL)"
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $wslList = & wsl.exe -l -v 2>$null | Out-String
        if ($wslList -and $wslList.Trim().Length -gt 0) {
            Write-Log ("WSL Distributions Detected:")
            $wslList.Trim() -split "`r?`n" | ForEach-Object {
                Write-Log ("  {0}" -f $_)
            }
        } else {
            Write-Log ("WSL is installed but no distributions are registered.")
        }
    } else {
        Write-Log ("WSL CLI not installed.")
    }

    Log-Sub "Hyper-V Virtual Machines"
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        try {
            $vms = Get-VM -ErrorAction SilentlyContinue
            if ($vms) {
                Write-Log ("Hyper-V VMs Detected:")
                foreach ($vm in $vms) {
                    Write-Log ("  - {0,-20} | State: {1} | CPU: {2}% | RAM: {3}" -f `
                        $vm.Name, $vm.State, $vm.CPUUsage, (Format-Bytes $vm.MemoryAssigned))
                }
            } else {
                Write-Log ("Zero Hyper-V VMs registered.")
            }
        } catch {
            Write-Log ("Hyper-V query restricted.")
        }
    } else {
        Write-Log ("Hyper-V module not available.")
    }

    Log-Sub "Docker & Container Daemons"
    if (Get-Command docker.exe -ErrorAction SilentlyContinue) {
        try {
            $dockerInfo = & docker.exe info --format '{{.ServerVersion}}|{{.ContainersRunning}}|{{.ContainersStopped}}|{{.Images}}' 2>$null
            if ($dockerInfo) {
                $dParts = $dockerInfo -split '\|'
                Write-Log ("Docker Engine Version : {0}" -f $dParts[0])
                Write-Log ("Containers Running    : {0}" -f $dParts[1])
                Write-Log ("Containers Stopped    : {0}" -f $dParts[2])
                Write-Log ("Total Docker Images   : {0}" -f $dParts[3])
            } else {
                Write-Log ("Docker CLI installed; Docker Desktop daemon not currently running.")
            }
        } catch {
            Write-Log ("Docker daemon check failed.")
        }
    } else {
        Write-Log ("Docker CLI not installed.")
    }
}

# =============================================================================
# MODULE 8: DISK JUNK, CACHES & RECLAIMABLE SPACE ANALYSIS
# =============================================================================
function Audit-JunkCleanup {
    Log-Section "8" "DISK JUNK, CACHES & RECLAIMABLE SPACE"

    Log-Sub "User Temporary Directory ($TargetUser Profile)"
    $userTempPath = Join-Path $TargetUserProfile "AppData\Local\Temp"
    if (-not (Test-Path $userTempPath)) { $userTempPath = $env:TEMP }
    if (Test-Path $userTempPath) {
        try {
            $tempFiles = Get-ChildItem -Path $userTempPath -Recurse -File -ErrorAction SilentlyContinue
            $tempBytes = ($tempFiles | Measure-Object -Property Length -Sum).Sum
            Write-Log ("User Temp Size       : {0} ({1})" -f (Format-Bytes $tempBytes), $userTempPath)
            Add-Reclaim $tempBytes
        } catch {}
    }

    Log-Sub "Windows System Temp (C:\Windows\Temp)"
    if (Test-Path "C:\Windows\Temp") {
        try {
            $winTempFiles = Get-ChildItem -Path "C:\Windows\Temp" -Recurse -File -ErrorAction SilentlyContinue
            $winTempBytes = ($winTempFiles | Measure-Object -Property Length -Sum).Sum
            Write-Log ("System Temp Size     : {0}" -f (Format-Bytes $winTempBytes))
            Add-Reclaim $winTempBytes
        } catch {}
    }

    Log-Sub "Windows Update Cache (SoftwareDistribution\Download)"
    $softDist = "C:\Windows\SoftwareDistribution\Download"
    if (Test-Path $softDist) {
        try {
            $wuFiles = Get-ChildItem -Path $softDist -Recurse -File -ErrorAction SilentlyContinue
            $wuBytes = ($wuFiles | Measure-Object -Property Length -Sum).Sum
            Write-Log ("Update Cache Size    : {0}" -f (Format-Bytes $wuBytes))
            Add-Reclaim $wuBytes
        } catch {}
    }

    Log-Sub "Recycle Bin Size"
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(0xA)
        $binSize = 0
        foreach ($item in $bin.Items()) {
            $binSize += $item.Size
        }
        Write-Log ("Recycle Bin Size     : {0}" -f (Format-Bytes $binSize))
        Add-Reclaim $binSize
    } catch {
        Write-Log ("Recycle Bin size calculation skipped.")
    }

    Log-Sub "Crash Dumps & Minidumps"
    $dumpFiles = @("C:\Windows\MEMORY.DMP")
    if (Test-Path "C:\Windows\Minidump") {
        $dumpFiles += (Get-ChildItem -Path "C:\Windows\Minidump" -Filter "*.dmp" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
    $totalDumpBytes = 0
    foreach ($df in $dumpFiles) {
        if (Test-Path $df) {
            $sz = (Get-Item $df).Length
            $totalDumpBytes += $sz
            Write-Log ("  Found dump: {0} ({1})" -f $df, (Format-Bytes $sz))
        }
    }
    if ($totalDumpBytes -gt 0) {
        Write-Log ("Crash Dumps Total    : {0}" -f (Format-Bytes $totalDumpBytes))
        Add-Reclaim $totalDumpBytes
    } else {
        Write-Log ("Zero memory crash dump files detected.")
    }

    Log-Sub "Estimated Safe Reclaimable Space Summary"
    Log-Ok ("Estimated Safe Reclaimable Space (Temp + Cache + Bin): ~{0}" -f (Format-Bytes $Script:ReclaimableBytes))
    Write-Log ("`nRecommended safe cleanup options on Windows 11:")
    Write-Log ("  1. Settings -> System -> Storage -> Cleanup recommendations / Storage Sense")
    Write-Log ("  2. Cleanmgr.exe (Disk Cleanup tool)")
    Write-Log ("  3. DISM /Online /Cleanup-Image /StartComponentCleanup (Cleans old WinSxS updates)")
}

# =============================================================================
# MODULE 9: DEVELOPER ENVIRONMENT & GIT REPOSITORIES
# =============================================================================
function Audit-DevEnvironment {
    Log-Section "9" "DEVELOPER ENVIRONMENT & TOOLCHAIN"

    Log-Sub "Developer Toolchain Detection"
    $devCommands = @("git", "node", "npm", "pnpm", "yarn", "python", "pip", "cargo", "rustc", "go", "code", "docker", "podman", "kubectl", "terraform", "aws", "az", "gh")
    Write-Log ("{0,-15} {1,-12} {2}" -f "TOOL", "INSTALLED", "VERSION / PATH")
    Log-Rule
    foreach ($cmd in $devCommands) {
        $c = Get-Command "$cmd.exe" -ErrorAction SilentlyContinue
        if (-not $c) { $c = Get-Command "$cmd.cmd" -ErrorAction SilentlyContinue }
        if (-not $c) { $c = Get-Command $cmd -ErrorAction SilentlyContinue }

        if ($c) {
            $ver = "Detected"
            try {
                $rawVer = & $cmd --version 2>$null | Select-Object -First 1
                if ($rawVer) { $ver = $rawVer.Trim() }
            } catch {}
            Write-Log ("{0,-15} {1,-12} {2}" -f $cmd, "[YES]", $ver)
        }
    }

    Log-Sub "PATH Environment Variable Hygiene"
    $pathEntries = ($env:PATH -split ';') | Where-Object { $_ -match '\S' }
    $deadPaths = @()
    foreach ($p in $pathEntries) {
        if (-not (Test-Path $p)) {
            $deadPaths += $p
            Write-Log ("  [STALE / DEAD PATH] {0}" -f $p)
        }
    }
    if ($deadPaths.Count -eq 0) {
        Log-Ok "All PATH entries resolve to valid directories."
    }

    if (-not $Quick) {
        Log-Sub "Git Repositories Status Scan"
        $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($gitCmd) {
            $repoCandidates = @(
                (Join-Path $TargetUserProfile "source"),
                (Join-Path $TargetUserProfile "Projects"),
                (Join-Path $TargetUserProfile "projects"),
                (Join-Path $TargetUserProfile "main"),
                (Join-Path $TargetUserProfile "repos")
            )

            # Add user-specified repo directory if provided
            if ($RepoDir -and (Test-Path $RepoDir)) {
                $repoCandidates += (Resolve-Path $RepoDir).Path
            }

            # Automatically scan secondary drives (D:\projects, D:\repos, D:\source, etc.)
            try {
                $fixedDrives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 -and $_.Root }
                foreach ($drv in $fixedDrives) {
                    foreach ($sub in @("projects", "Projects", "source", "repos", "workspace", "main", "git")) {
                        $cPath = Join-Path $drv.Root $sub
                        if (Test-Path $cPath) {
                            $repoCandidates += $cPath
                        }
                    }
                }
            } catch {}

            # Also include current working directory if not root of system drive
            $currentLoc = (Get-Location).Path
            if (Test-Path $currentLoc) {
                $repoCandidates += $currentLoc
            }

            $repoCandidates = $repoCandidates | Select-Object -Unique

            $totalRepos = 0
            $dirtyRepos = 0
            $unpushedRepos = 0

            foreach ($rc in $repoCandidates) {
                if (Test-Path $rc) {
                    $gitDirs = Get-ChildItem -Path $rc -Filter ".git" -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue
                    foreach ($gd in $gitDirs) {
                        $repoPath = $gd.Parent.FullName
                        $totalRepos++

                        $status = & git.exe -C $repoPath status --porcelain 2>$null
                        $branch = & git.exe -C $repoPath branch --show-current 2>$null

                        if ($status) {
                            $dirtyRepos++
                            Log-Warn ("DIRTY REPO (Uncommitted changes): {0} [{1}]" -f $repoPath, $branch)
                            $status | Select-Object -First 3 | ForEach-Object { Write-Log ("    {0}" -f $_) }
                        }

                        $upstream = & git.exe -C $repoPath rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
                        if ($upstream) {
                            $unpushed = & git.exe -C $repoPath log "$upstream..HEAD" --oneline 2>$null
                            if ($unpushed) {
                                $unpushedRepos++
                                Log-Warn ("UNPUSHED COMMITS: {0} [{1}]" -f $repoPath, $branch)
                                $unpushed | Select-Object -First 3 | ForEach-Object { Write-Log ("    {0}" -f $_) }
                            }
                        }
                    }
                }
            }

            Write-Log ("`nGit Repositories Scan Summary:")
            Write-Log ("  Total Repositories Scanned : {0}" -f $totalRepos)
            Write-Log ("  Repositories with Uncommitted Changes : {0}" -f $dirtyRepos)
            Write-Log ("  Repositories with Unpushed Commits    : {0}" -f $unpushedRepos)
        }
    }
}

# =============================================================================
# MODULE 10: AUDIT SUMMARY & SCORECARD
# =============================================================================
function Audit-Summary {
    Log-Section "10" "EXECUTIVE AUDIT SUMMARY SCORECARD"

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $totalRamBytes = [double]$os.TotalVisibleMemorySize * 1KB
    $freeRamBytes  = [double]$os.FreePhysicalMemory * 1KB

    $cDrive = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
    $cFreeStr = if ($cDrive) {
        "{0:N1}% used ({1} free)" -f (100 - ($cDrive.SizeRemaining / $cDrive.Size * 100)), (Format-Bytes $cDrive.SizeRemaining)
    } else { "N/A" }

    $listeningCount = 0
    try {
        $listeningCount = (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count
    } catch {}

    Write-Log ("{0,-25} : {1}" -f "Computer Name", $env:COMPUTERNAME)
    Write-Log ("{0,-25} : {1}" -f "Operating System", $os.Caption)
    Write-Log ("{0,-25} : {1}.{2}" -f "Windows Build", $os.BuildNumber, (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)
    Write-Log ("{0,-25} : {1}" -f "Total Memory", (Format-Bytes $totalRamBytes))
    Write-Log ("{0,-25} : {1}" -f "Available Memory", (Format-Bytes $freeRamBytes))
    Write-Log ("{0,-25} : {1}" -f "System Drive (C:)", $cFreeStr)
    Write-Log ("{0,-25} : {1} TCP Ports" -f "Listening Sockets", $listeningCount)
    Write-Log ("{0,-25} : ~{1}" -f "Reclaimable Disk Space", (Format-Bytes $Script:ReclaimableBytes))

    $EndTime = Get-Date
    $Duration = [Math]::Round(($EndTime - $StartTime).TotalSeconds, 1)

    Log-Rule
    Write-Log ("Audit Finished : {0}" -f $EndTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))
    Write-Log ("Execution Time : {0} seconds" -f $Duration)

    # Save Output to File if requested
    if ($Output) {
        try {
            $outDir = Split-Path -Path $Output -Parent
            if ($outDir -and (-not (Test-Path $outDir))) {
                New-Item -Path $outDir -ItemType Directory -Force | Out-Null
            }

            if ($Format -eq 'Json') {
                # Convert structured summary to JSON
                $summaryObj = [PSCustomObject]@{
                    ComputerName       = $env:COMPUTERNAME
                    OperatingSystem    = $os.Caption
                    BuildNumber        = $os.BuildNumber
                    TotalMemoryBytes   = $totalRamBytes
                    FreeMemoryBytes    = $freeRamBytes
                    ReclaimableBytes   = $Script:ReclaimableBytes
                    ExecutionSeconds   = $Duration
                    Timestamp          = $EndTime.ToString('o')
                }
                $summaryObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $Output -Encoding utf8
            } elseif ($Format -eq 'Html') {
                $cleanText = $Script:LogBuffer.ToString() -replace '\x1B\[[0-9;]*[a-zA-Z]', ''
                $html = "<html><head><title>Windows 11 Audit Report</title><style>body{font-family:monospace;background:#1e1e1e;color:#d4d4d4;padding:20px;}pre{white-space:pre-wrap;}</style></head><body><pre>$cleanText</pre></body></html>"
                $html | Out-File -FilePath $Output -Encoding utf8
            } else {
                # Clean Plain Text (Strip ANSI sequences)
                $cleanText = $Script:LogBuffer.ToString() -replace '\x1B\[[0-9;]*[a-zA-Z]', ''
                $cleanText | Out-File -FilePath $Output -Encoding utf8
            }
            Log-Ok ("Report successfully saved to {0} (Format: {1})" -f $Output, $Format)
        } catch {
            Log-Warn ("Failed to write report to {0}: {1}" -f $Output, $_.Exception.Message)
        }
    }

    if ($ExportDir) {
        Log-Ok ("All inventory exports saved in {0}" -f $ExportDir)
    }

    Log-Title "AUDIT COMPLETE"
}

# =============================================================================
# MAIN DISPATCHER
# =============================================================================
if ($CleanupOnly) {
    Audit-JunkCleanup
    Audit-Summary
} elseif ($SecurityOnly) {
    Audit-Security
    Audit-Summary
} elseif ($Quick) {
    Audit-SystemHardware
    Audit-Storage
    Audit-Network
    Audit-ProcessesServices
    Audit-Security
    Audit-Summary
} else {
    Audit-SystemHardware
    Audit-Storage
    Audit-Network
    Audit-Security
    Audit-ProcessesServices
    Audit-SoftwareInventory
    Audit-Virtualization
    Audit-JunkCleanup
    Audit-DevEnvironment
    Audit-Summary
}

