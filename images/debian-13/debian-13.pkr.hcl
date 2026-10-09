packer {
  required_version = ">= 1.10.0"

  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "= 1.1.7"
    }
  }
}

locals {
  image_name = "debian-13"

  # Compte temporaire créé par le seed cloud-init (cloud-init/user-data) et
  # supprimé par la shutdown_command : il n'existe que pendant le build.
  ssh_username = "packer"
  ssh_password = "packer"
}

source "qemu" "debian-13" {
  # Image source : image cloud officielle, vérifiée via le SHA512SUMS publié.
  iso_url      = var.source_image_url
  iso_checksum = "file:${var.source_checksum_url}"
  disk_image   = true

  # Image produite.
  vm_name          = "${local.image_name}.qcow2"
  output_directory = "output/${local.image_name}"
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_compression = true

  # VM de build.
  accelerator = var.accelerator
  cpus        = var.cpus
  memory      = var.memory
  headless    = true

  # Seed cloud-init NoCloud, exposé à la VM sous forme de CD-ROM « cidata ».
  cd_files = [
    "${path.root}/cloud-init/user-data",
    "${path.root}/cloud-init/meta-data",
  ]
  cd_label = "cidata"

  communicator = "ssh"
  ssh_username = local.ssh_username
  ssh_password = local.ssh_password
  ssh_timeout  = var.ssh_timeout

  # Le compte de build est supprimé au tout dernier moment, la session SSH
  # courante l'utilisant encore jusque-là.
  shutdown_command = "sudo sh -c 'rm -f /etc/sudoers.d/90-cloud-init-users && userdel -rf ${local.ssh_username}; shutdown -P now'"
}

build {
  name    = local.image_name
  sources = ["source.qemu.debian-13"]

  provisioner "shell" {
    execute_command = "sudo env {{ .Vars }} bash '{{ .Path }}'"
    scripts = [
      "${path.root}/scripts/provision.sh",
      "${path.root}/scripts/cleanup.sh",
    ]
  }
}
