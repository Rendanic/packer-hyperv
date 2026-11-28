# create-vm.ps1
# Creates an Oracle Linux 10 VM from the packer template with two network adapters:
#   Default Switch (DHCP, management) + External Switch (fixed IP via NetworkManager)
# Optional additional data disks (e.g. for ASM) via -DataDiskGB:
#   -DataDiskGB 50       -> one dynamic 50 GB VHDX on SCSI 0:0 (/dev/sdb in the guest)
#   -DataDiskGB 50,50    -> two disks on SCSI 0:0 and 0:1
#   Existing data disks of the VM are deleted and recreated empty.

param(
    [string]$OutputDir = "output-ol10",
    [string]$NewVMName = "ansible-oracle-1",
    [string]$Hostname = "ansible-oracle-1", # Short name, FQDN becomes <Hostname>.<FixedIP>.nip.io
    [string]$ExternalSwitch = "intern_66",  # Name of your external switch
    [string]$FixedIP = "192.168.66.161",     # Fixed IP on the external switch
    [string]$Subnet = "24",                 # Subnet mask in CIDR notation
    [string]$DNS1 = "8.8.8.8",             # Primary DNS
    [string]$DNS2 = "8.8.4.4",             # Secondary DNS
    [int]$CPUs = 2,
    [int]$MemoryGB = 8,                     # Fixed (static) RAM, fully reserved at VM start
    [string]$SSHUser = "ol",                # User created by the kickstart
    [string]$SSHKeyPath = "$env:USERPROFILE\.ssh\id_ed25519",
    [int[]]$DataDiskGB = @(),               # Sizes in GB of additional data disks (SCSI), empty = none
    # Do not configure the guest via SSH; print the values for common/configure-guest.ps1 instead
    # (line "GUEST_CONFIG ..."), e.g. when the caller cannot use ssh (JEA virtual account).
    [switch]$SkipGuestConfig
)

$ErrorActionPreference = "Stop"

# Use VM name as hostname if not specified
if ([string]::IsNullOrEmpty($Hostname)) {
    $Hostname = $NewVMName
}

# Hostname is always a nip.io name derived from the fixed IP:
#   db1 + 192.168.66.162 -> db1.192-168-66-162.nip.io
$ipDashed = $FixedIP.Replace('.', '-')
$ShortName = ($Hostname -split '\.')[0]
if ($ShortName.EndsWith("-$ipDashed")) {
    $ShortName = $ShortName.Substring(0, $ShortName.Length - $ipDashed.Length - 1)
}
$Hostname = "$ShortName.$ipDashed.nip.io"

Write-Host "Creating VM '$NewVMName' with dual network configuration" -ForegroundColor Cyan
Write-Host "  Default Switch: DHCP" -ForegroundColor Gray
Write-Host "  $ExternalSwitch : $FixedIP/$Subnet" -ForegroundColor Gray

# Find the VHDX file
$vhdxFile = Get-ChildItem -Path $OutputDir -Filter "*.vhdx" -Recurse | Select-Object -First 1
if (-not $vhdxFile) {
    Write-Host "No VHDX file found in $OutputDir" -ForegroundColor Red
    exit 1
}

# Remove existing VM if present
if (Get-VM -Name $NewVMName -ErrorAction SilentlyContinue) {
    Stop-VM -Name $NewVMName -Force -TurnOff -ErrorAction SilentlyContinue
    Remove-VM -Name $NewVMName -Force
}

# Create VM directory and copy VHDX
$vmPath = Join-Path (Get-VMHost).VirtualMachinePath $NewVMName
New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
$newVHDPath = Join-Path $vmPath "$NewVMName.vhdx"
Write-Host "Copying VHDX..." -ForegroundColor Yellow
Copy-Item -Path $vhdxFile.FullName -Destination $newVHDPath -Force

# The packer template is built as Generation 1 (BIOS boot),
# so the VM must be Generation 1 as well - a Gen2 (UEFI) VM would not find a bootloader.
Write-Host "Creating VM with Default Switch..." -ForegroundColor Yellow
New-VM -Name $NewVMName `
       -MemoryStartupBytes ($MemoryGB * 1GB) `
       -Generation 1 `
       -VHDPath $newVHDPath `
       -SwitchName "Default Switch" | Out-Null

# Configure VM
# Static memory: a fixed reservation. With dynamic memory the guest RAM changes at runtime and
# the memlock limit derived from it (Oracle HugePages/limits) is not stable.
Set-VM -Name $NewVMName `
       -ProcessorCount $CPUs `
       -StaticMemory `
       -MemoryStartupBytes ($MemoryGB * 1GB) `
       -CheckpointType Disabled

# Add data disks on the SCSI controller.
# The boot disk stays on IDE 0:0 (Generation 1), the data disks appear in the guest as /dev/sdb, /dev/sdc, ...
$dataDisks = @()
if ($DataDiskGB.Count -gt 0) {
    if (-not (Get-VMScsiController -VMName $NewVMName)) {
        Add-VMScsiController -VMName $NewVMName
    }
    for ($i = 0; $i -lt $DataDiskGB.Count; $i++) {
        $diskPath = Join-Path $vmPath ("{0}-data{1}.vhdx" -f $NewVMName, ($i + 1))
        # Never reuse an old disk: leftover ASM headers would break a new installation
        if (Test-Path $diskPath) {
            Remove-Item -Path $diskPath -Force
        }
        Write-Host ("Adding data disk {0} GB (SCSI 0:{1})..." -f $DataDiskGB[$i], $i) -ForegroundColor Yellow
        New-VHD -Path $diskPath -SizeBytes ($DataDiskGB[$i] * 1GB) -Dynamic | Out-Null
        Add-VMHardDiskDrive -VMName $NewVMName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $i -Path $diskPath
        $dataDisks += [pscustomobject]@{ Path = $diskPath; SizeGB = $DataDiskGB[$i]; Location = "SCSI 0:$i" }
    }
}

# Add second network adapter for External Switch
Write-Host "Adding External network adapter..." -ForegroundColor Yellow
Add-VMNetworkAdapter -VMName $NewVMName -SwitchName $ExternalSwitch -Name "External"

# Start the VM
Write-Host "Starting VM..." -ForegroundColor Yellow
Start-VM -Name $NewVMName

# Wait for Default Switch IP (reported by hypervkvpd from hyperv-daemons)
Write-Host "Waiting for Default Switch IP..." -ForegroundColor Gray
$attempts = 0
$maxAttempts = 90
$defaultIP = $null

while ($attempts -lt $maxAttempts -and -not $defaultIP) {
    Start-Sleep -Seconds 2
    $defaultAdapter = Get-VMNetworkAdapter -VMName $NewVMName | Where-Object { $_.SwitchName -eq "Default Switch" }
    if ($defaultAdapter.IPAddresses.Count -gt 0) {
        $defaultIP = $defaultAdapter.IPAddresses |
                     Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.254\.' } |
                     Select-Object -First 1
    }
    $attempts++
}

if (-not $defaultIP) {
    Write-Host "Failed to get Default Switch IP" -ForegroundColor Red
    exit 1
}

Write-Host "Default Switch IP: $defaultIP" -ForegroundColor Green

# Wait for SSH port to be reachable
Write-Host "Waiting for SSH..." -ForegroundColor Gray
$sshReady = $false
for ($i = 0; $i -lt 60 -and -not $sshReady; $i++) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.Connect($defaultIP, 22)
        $sshReady = $true
    } catch {
        Start-Sleep -Seconds 2
    } finally {
        $tcp.Dispose()
    }
}
if (-not $sshReady) {
    Write-Host "SSH on $defaultIP not reachable" -ForegroundColor Red
    exit 1
}

# MAC address of the external adapter (Hyper-V format 00155D010203 -> 00:15:5d:01:02:03),
# used to find the matching interface inside the guest regardless of its name
$extMac = (Get-VMNetworkAdapter -VMName $NewVMName -Name "External").MacAddress
$extMac = ($extMac -split '(..)' -ne '' -join ':').ToLower()

if ($SkipGuestConfig) {
    Write-Host "Guest configuration skipped (-SkipGuestConfig), run common/configure-guest.ps1 with:" -ForegroundColor Yellow
    # machine-readable, one line, no spaces in the values
    Write-Output ("GUEST_CONFIG DefaultIP=$defaultIP Mac=$extMac FixedIP=$FixedIP Subnet=$Subnet " +
                  "DNS1=$DNS1 DNS2=$DNS2 Hostname=$Hostname ShortName=$ShortName")
} else {
    # Same code for all templates: common/configure-guest.ps1 (failure = warning, as before)
    & (Join-Path $PSScriptRoot "..\common\configure-guest.ps1") -DefaultIP $defaultIP -Mac $extMac `
        -FixedIP $FixedIP -Subnet $Subnet -DNS1 $DNS1 -DNS2 $DNS2 -Hostname $Hostname -ShortName $ShortName `
        -SSHUser $SSHUser -SSHKeyPath $SSHKeyPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Manual configuration needed." -ForegroundColor Yellow
    }
}

# Show the block devices of the guest, so the device names of the data disks are visible
$guestDisks = $null
if ($dataDisks.Count -gt 0 -and -not $SkipGuestConfig) {
    $guestDisks = & ssh @sshOpts "${SSHUser}@${defaultIP}" "lsblk -dno NAME,SIZE,TYPE"
    if ($LASTEXITCODE -ne 0) { $guestDisks = $null }
}

# Display summary
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "VM Created with Dual Network!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "VM Name:        $NewVMName" -ForegroundColor White
Write-Host "Hostname:       $Hostname" -ForegroundColor White
Write-Host "Default Switch: $defaultIP (DHCP)" -ForegroundColor Cyan
Write-Host "External:       $FixedIP/$Subnet (Fixed)" -ForegroundColor Cyan
Write-Host "DNS:            $DNS1, $DNS2" -ForegroundColor White
foreach ($d in $dataDisks) {
    Write-Host ("Data disk:      {0} GB {1} {2}" -f $d.SizeGB, $d.Location, $d.Path) -ForegroundColor White
}
if ($guestDisks) {
    Write-Host "`nBlock devices in the guest (lsblk):" -ForegroundColor Yellow
    $guestDisks | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}
Write-Host "`nSSH Access:" -ForegroundColor Yellow
Write-Host "  Via Default: ssh -i $SSHKeyPath $SSHUser@$defaultIP" -ForegroundColor Gray
Write-Host "  Via Fixed:   ssh -i $SSHKeyPath $SSHUser@$FixedIP" -ForegroundColor Gray
Write-Host "  Via nip.io:  ssh -i $SSHKeyPath $SSHUser@$Hostname" -ForegroundColor Gray
