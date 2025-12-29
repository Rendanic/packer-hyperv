# ubuntu-k8s-hyperv.pkr.hcl

packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

# Variables
variable "iso_url" {
  type    = string
  default = "https://ftp.halifax.rwth-aachen.de/ubuntu-releases/24.04.3/ubuntu-24.04.3-live-server-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:c3514bf0056180d09376462a7a1b4f213c1d6e8ea67fae5c25099c6fd3d8274b"
}

variable "ssh_username" {
  type    = string
  default = "ubuntu"
}

variable "ssh_password" {
  type    = string
  default = "TempPass123!"
}

variable "ssh_public_key_path" {
  type    = string
  default = "c:\\Users\\TBR\\.ssh\\id_ed25519.pub"
}

variable "vm_cpus" {
  type    = number
  default = 2
}

variable "vm_memory" {
  type    = number
  default = 4096
}

variable "vm_disk_size" {
  type    = number
  default = 40960
}

variable "switch_name" {
  type    = string
  default = "Default Switch"
}

# Source block for base VM
source "hyperv-iso" "ubuntu-base" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum
  # VM Configuration
  vm_name              = "packer-ubuntu-k8s-base"
  generation           = 2
  enable_secure_boot   = false
  enable_tpm           = false
  cpus                 = var.vm_cpus
  memory               = var.vm_memory
  disk_size            = var.vm_disk_size
  switch_name          = var.switch_name
  enable_dynamic_memory = true
  enable_virtualization_extensions = true

  floppy_files = []
  floppy_dirs  = []
  
  # SSH Configuration
  ssh_handshake_attempts = 100
  ssh_port             = 22
  ssh_wait_timeout     = "30m"
  
  # Shutdown
  shutdown_command     = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
  shutdown_timeout     = "15m"
  
  # Boot configuration for Ubuntu 24.04 autoinstall
  # Using proper escape sequence for editing GRUB
  boot_wait           = "5s"
  boot_command        = [
    "c<wait>",
    "linux /casper/vmlinuz --- vnet.ifnames=0 ip=dhcp biosdevname=0 autoinstall \"ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\" console=tty0 debug nosplash",
#    "linux /casper/vmlinuz --- vnet.ifnames=0 biosdevname=0 ip=192.168.69.10::192.168.69.1:255.255.255.0:test:eth0::8.8.8.8 ipv6.disable=1  autoinstall \"ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\"",
#    "linux /casper/vmlinuz --- vnet.ifnames=0 biosdevname=0 ip=${var.host_net_ip}::${var.host_net_gateway}:${var.host_net_netmask}:${var.vm_name}:eth0::8.8.8.8 ipv6.disable=1  autoinstall \"ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\"",
    "<enter><wait>",
    "initrd /casper/initrd",
    "<enter><wait>",
    "boot",
    "<enter>"
  ]
  
  # SSH Configuration
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"
  # HTTP server for cloud-init
  http_directory = "http"
  
  # Output Configuration
  output_directory = "output-{{build_name}}"
  
  # Hyper-V specific
  use_fixed_vhd_format = false
  skip_compaction     = false
  # differencing_disk   = false
  
  # # Timeouts
  # boot_keygroup_interval = "500ms"

}

# Build block
build {
  name = "kubernetes-base"
  
  sources = ["source.hyperv-iso.ubuntu-base"]
  
  # Update and install basic packages
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y curl wget apt-transport-https ca-certificates software-properties-common gnupg lsb-release",
      "sudo apt-get install -y net-tools vim htop jq tree",
      "sudo apt autoremove -y"
    ]
  }
  
  # Disable swap for Kubernetes
  provisioner "shell" {
    inline = [
      "sudo swapoff -a",
      "sudo sed -i '/ swap / s/^/#/' /etc/fstab"
    ]
  }
  
  # Setup SSH directory
  provisioner "shell" {
    inline = [
      "mkdir -p ~/.ssh",
      "chmod 700 ~/.ssh",
      "touch ~/.ssh/authorized_keys",
      "chmod 600 ~/.ssh/authorized_keys"
    ]
  }
  
  # Copy SSH public key
  provisioner "file" {
    source      = var.ssh_public_key_path
    destination = "/tmp/id_rsa.pub"
  }
  
  # Install SSH key
  provisioner "shell" {
    inline = [
      "cat /tmp/id_rsa.pub >> ~/.ssh/authorized_keys",
      "rm /tmp/id_rsa.pub",
      "sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config"
    ]
  }
  
  # Disable firewall
  provisioner "shell" {
    inline = [
      "sudo systemctl disable --now ufw || true",
      "sudo systemctl disable --now firewalld || true"
    ]
  }
  
  # Clean up
  provisioner "shell" {
    inline = [
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo cloud-init clean --logs --seed",
      "sudo rm -rf /var/lib/cloud/instances/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed"
      # "history -c"
    ]
  }
}
