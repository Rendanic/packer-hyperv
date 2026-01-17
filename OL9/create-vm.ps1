# create-vm-dual-network.ps1
# Creates VMs with two network adapters: Default Switch (DHCP) + External Switch (Fixed IP)

param(
    [string]$OutputDir = "output-ol9",
    [string]$NewVMName = "ansible-oracle-1",
    [string]$Hostname = "ansible-oracle-1",
    [string]$ExternalSwitch = "intern_66",  # Name of your external switch
    [string]$FixedIP = "192.168.66.161",     # Fixed IP for Kubernetes
    [string]$Subnet = "24",                 # Subnet mask in CIDR notation
    [string]$DNS1 = "8.8.8.8",             # Primary DNS
    [string]$DNS2 = "8.8.4.4",             # Secondary DNS
    [int]$CPUs = 2,
    [int]$MemoryGB = 8,
    [string]$SSHKeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
)

# Use VM name as hostname if not specified
if ([string]::IsNullOrEmpty($Hostname)) {
    $Hostname = $NewVMName
}

Write-Host "Creating VM '$NewVMName' with dual network configuration" -ForegroundColor Cyan
Write-Host "  Default Switch: DHCP" -ForegroundColor Gray
Write-Host "  ExternalSwitch: $FixedIP/$Subnet" -ForegroundColor Gray

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

# Create VM with Default Switch first
Write-Host "Creating VM with Default Switch..." -ForegroundColor Yellow
$vm = New-VM -Name $NewVMName `
            -MemoryStartupBytes ($MemoryGB * 1GB) `
            -Generation 2 `
            -VHDPath $newVHDPath `
            -SwitchName "Default Switch"

# Configure VM
Set-VM -Name $NewVMName `
       -ProcessorCount $CPUs `
        -DynamicMemory `
        -MemoryStartupBytes (3GB) `
        -MemoryMinimumBytes (3GB) `
        -MemoryMaximumBytes ($MemoryGB * 2GB) `
       -CheckpointType Disabled

Set-VMFirmware -VMName $NewVMName -EnableSecureBoot Off

# Add second network adapter for External Switch
Write-Host "Adding External network adapter..." -ForegroundColor Yellow
Add-VMNetworkAdapter -VMName $NewVMName -SwitchName $ExternalSwitch -Name "External"

# Start the VM
Write-Host "Starting VM..." -ForegroundColor Yellow
Start-VM -Name $NewVMName

# Wait for Default Switch IP (for management)
Write-Host "Waiting for Default Switch IP..." -ForegroundColor Gray
$attempts = 0
$maxAttempts = 60
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

# Wait for SSH to be ready
Write-Host "Waiting for SSH..." -ForegroundColor Gray
Start-Sleep -Seconds 15

# Configure the second network interface with fixed IP via SSH
Write-Host "Configuring fixed IP on external network..." -ForegroundColor Yellow

# Create netplan configuration for the second interface
$netplanConfig = @"
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
    eth1:
      addresses:
        - $FixedIP/$Subnet
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
"@

# Create a temporary file with the netplan config
$tempFile = [System.IO.Path]::GetTempFileName()
$netplanConfig | Out-File -FilePath $tempFile -Encoding UTF8

try {
    # Copy netplan config to VM
    Write-Host "Copying network configuration..." -ForegroundColor Gray
    & scp -i $SSHKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $tempFile "ubuntu@${defaultIP}:/tmp/01-netcfg.yaml" 2>$null
    
    # Apply network configuration and set hostname
    Write-Host "Applying configuration..." -ForegroundColor Gray
    $commands = @(
        "sudo cp /tmp/01-netcfg.yaml /etc/netplan/01-netcfg.yaml",
        "sudo chmod 600 /etc/netplan/01-netcfg.yaml",
        "sudo netplan apply",
        "sudo hostnamectl set-hostname $Hostname",
        "echo '$FixedIP $Hostname' | sudo tee -a /etc/hosts",
        "sudo sed -i 's/127.0.1.1.*/127.0.1.1 $Hostname/' /etc/hosts"
    )
    
    $sshCommand = $commands -join " && "
    & ssh -i $SSHKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$defaultIP $sshCommand 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Network and hostname configured successfully!" -ForegroundColor Green
    } else {
        Write-Host "Configuration may have failed, please check manually" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Could not configure via SSH. Manual configuration needed." -ForegroundColor Yellow
} finally {
    # Clean up temp file
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
}

# Display summary
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "VM Created with Dual Network!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "VM Name:       $NewVMName" -ForegroundColor White
Write-Host "Hostname:      $Hostname" -ForegroundColor White
Write-Host "Default Switch: $defaultIP (DHCP)" -ForegroundColor Cyan
Write-Host "External:      $FixedIP/$Subnet (Fixed)" -ForegroundColor Cyan
Write-Host "DNS:           $DNS1, $DNS2" -ForegroundColor White
Write-Host "`nSSH Access:" -ForegroundColor Yellow
Write-Host "  Via Default: ssh -i $SSHKeyPath ubuntu@$defaultIP" -ForegroundColor Gray
Write-Host "  Via Fixed:   ssh -i $SSHKeyPath ubuntu@$FixedIP" -ForegroundColor Gray

Write-Host "`nKubernetes will use the fixed IP: $FixedIP" -ForegroundColor Green
