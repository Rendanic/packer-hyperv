# create-vm.ps1
# Creates an Oracle Linux 9 VM from the packer template with two network adapters:
#   Default Switch (DHCP, management) + External Switch (fixed IP via NetworkManager)

param(
    [string]$OutputDir = "output-ol9",
    [string]$NewVMName = "ansible-oracle-1",
    [string]$Hostname = "ansible-oracle-1", # Short name, FQDN becomes <Hostname>.<FixedIP>.nip.io
    [string]$ExternalSwitch = "intern_66",  # Name of your external switch
    [string]$FixedIP = "192.168.66.161",     # Fixed IP on the external switch
    [string]$Subnet = "24",                 # Subnet mask in CIDR notation
    [string]$DNS1 = "8.8.8.8",             # Primary DNS
    [string]$DNS2 = "8.8.4.4",             # Secondary DNS
    [int]$CPUs = 2,
    [int]$MemoryGB = 8,                     # Dynamic memory maximum = 2 x MemoryGB
    [int]$StartupMemoryGB = 3,              # RAM assigned at boot (also the dynamic memory minimum)
    [string]$SSHUser = "ol",                # User created by the kickstart
    [string]$SSHKeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
)

$ErrorActionPreference = "Stop"
$sshOpts = @("-i", $SSHKeyPath, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR")

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
       -MemoryStartupBytes ($StartupMemoryGB * 1GB) `
       -Generation 1 `
       -VHDPath $newVHDPath `
       -SwitchName "Default Switch" | Out-Null

# Configure VM
Set-VM -Name $NewVMName `
       -ProcessorCount $CPUs `
       -DynamicMemory `
       -MemoryStartupBytes ($StartupMemoryGB * 1GB) `
       -MemoryMinimumBytes ($StartupMemoryGB * 1GB) `
       -MemoryMaximumBytes ([math]::Max($MemoryGB * 2, $StartupMemoryGB) * 1GB) `
       -CheckpointType Disabled

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

Write-Host "Configuring fixed IP on external network (MAC $extMac)..." -ForegroundColor Yellow

# Configuration script executed inside the guest (NetworkManager / nmcli)
$guestScript = @"
#!/bin/bash
set -euo pipefail

IFACE=`$(ip -o link | awk -v mac='$extMac' 'tolower(`$0) ~ mac { sub(":", "", `$2); print `$2; exit }')
if [ -z "`$IFACE" ]; then
  echo "No interface with MAC $extMac found" >&2
  exit 1
fi
echo "External interface: `$IFACE"

# Remove auto-generated connections bound to that interface
for uuid in `$(nmcli -g UUID,DEVICE connection show | awk -F: -v dev="`$IFACE" '`$2 == dev { print `$1 }'); do
  nmcli connection delete "`$uuid"
done
nmcli connection delete external 2>/dev/null || true

nmcli connection add type ethernet con-name external ifname "`$IFACE" \
  ipv4.method manual \
  ipv4.addresses $FixedIP/$Subnet \
  ipv4.dns "$DNS1 $DNS2" \
  ipv4.never-default yes \
  ipv6.method disabled \
  connection.autoconnect yes
nmcli connection up external

hostnamectl set-hostname $Hostname
sed -i '/[[:space:]]$Hostname\([[:space:]]\|`$\)/d' /etc/hosts
echo "$FixedIP $Hostname $ShortName" >> /etc/hosts
"@

# Write with LF line endings and without BOM, otherwise bash fails
$tempFile = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tempFile, ($guestScript -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))

try {
    Write-Host "Copying network configuration script..." -ForegroundColor Gray
    & scp @sshOpts $tempFile "${SSHUser}@${defaultIP}:/tmp/configure-network.sh"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }

    Write-Host "Applying configuration..." -ForegroundColor Gray
    & ssh @sshOpts "${SSHUser}@${defaultIP}" "sudo bash /tmp/configure-network.sh && rm -f /tmp/configure-network.sh"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Network and hostname configured successfully!" -ForegroundColor Green
    } else {
        Write-Host "Configuration may have failed, please check manually" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Could not configure via SSH ($_). Manual configuration needed." -ForegroundColor Yellow
} finally {
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
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
Write-Host "`nSSH Access:" -ForegroundColor Yellow
Write-Host "  Via Default: ssh -i $SSHKeyPath $SSHUser@$defaultIP" -ForegroundColor Gray
Write-Host "  Via Fixed:   ssh -i $SSHKeyPath $SSHUser@$FixedIP" -ForegroundColor Gray
Write-Host "  Via nip.io:  ssh -i $SSHKeyPath $SSHUser@$Hostname" -ForegroundColor Gray
