packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

variable "iso_url" {
  type    = string
  default = "https://yum.oracle.com/ISOS/OracleLinux/OL9/u5/x86_64/OracleLinux-R9-U5-x86_64-dvd.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:c2fa76c502cf1d93dfbd084d494d963ab7ea0a6f5535a083b8547b34037e88e1"
}

variable "ssh_public_key_path" {
  type    = string
  default = "c:\\Users\\TBR\\.ssh\\id_ed25519.pub"
}

source "hyperv-iso" "ol9" {
  vm_name          = "ol9-template"
  generation       = 1
  cpus             = 2
  memory           = 4096
  disk_size        = 81920
  
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  
  switch_name      = "Default Switch"
  
  boot_wait        = "10s"
  boot_command     = [
    "<wait5>",
    "<tab>",
    "<wait3>",
    " inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg",
    "<enter>",
    "<wait>"
  ]
  http_directory   = "http"
  
  communicator = "ssh"
  ssh_username     = "ol"
  ssh_password     = "packer123"
  ssh_timeout      = "60m"
  
  shutdown_command = "sudo /sbin/shutdown -h now"
  
  output_directory = "output-ol9"
}

build {
  sources = ["source.hyperv-iso.ol9"]
  
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

  provisioner "shell" {
    inline = [
      "cat /tmp/id_rsa.pub >> ~/.ssh/authorized_keys",
      "rm /tmp/id_rsa.pub",
      "sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config"
    ]
  }
  
  provisioner "shell" {
    inline = [
      "sudo dnf -y update",
      "sudo dnf -y install cloud-init cloud-utils-growpart hyperv-daemons",
      "sudo systemctl enable hypervkvpd hypervvssd hypervfcopyd",
      "sudo dnf clean all",
      "sudo rm -rf /var/cache/dnf",
      "sudo rm -f /root/anaconda-ks.cfg"
    ]
  }
}
