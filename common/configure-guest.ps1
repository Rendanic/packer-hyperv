# configure-guest.ps1
# Sets the fixed IP on the external adapter and the host name inside an Oracle Linux guest via SSH
# (NetworkManager / nmcli). Called by <template>/create-vm.ps1; can also run on its own, e.g. by an
# account without Hyper-V rights (create-vm.ps1 -SkipGuestConfig prints the values it needs).
# Needs only the OpenSSH client (ssh, scp) and network access to DefaultIP (Default Switch).
# Exit code 0 = configured, 1 = failed (the messages of ssh/scp are shown).

param(
    [Parameter(Mandatory)][string]$DefaultIP,  # DHCP address on the Default Switch (reachable from the host)
    [Parameter(Mandatory)][string]$Mac,        # MAC of the external adapter, format 00:15:5d:01:02:03
    [Parameter(Mandatory)][string]$FixedIP,    # fixed IP on the external switch
    [string]$Subnet = "24",
    [string]$DNS1 = "8.8.8.8",
    [string]$DNS2 = "8.8.4.4",
    [Parameter(Mandatory)][string]$Hostname,   # FQDN, e.g. db1.192-168-66-162.nip.io
    [Parameter(Mandatory)][string]$ShortName,  # e.g. db1
    [string]$SSHUser = "ol",
    [string]$SSHKeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
)

$ErrorActionPreference = "Stop"
$sshOpts = @("-i", $SSHKeyPath, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR")
$extMac = $Mac.ToLower()

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
    & scp @sshOpts $tempFile "${SSHUser}@${DefaultIP}:/tmp/configure-network.sh"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }

    Write-Host "Applying configuration..." -ForegroundColor Gray
    & ssh @sshOpts "${SSHUser}@${DefaultIP}" "sudo bash /tmp/configure-network.sh && rm -f /tmp/configure-network.sh"
    if ($LASTEXITCODE -ne 0) { throw "ssh failed (exit code $LASTEXITCODE)" }

    Write-Host "Network and hostname configured successfully!" -ForegroundColor Green
} catch {
    Write-Host "Could not configure via SSH ($_)." -ForegroundColor Red
    exit 1
} finally {
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
}
exit 0
