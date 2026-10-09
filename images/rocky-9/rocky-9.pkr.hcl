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
  image_name = "rocky-9"

  # Compte temporaire créé par le seed cloud-init (cloud-init/user-data) et
  # supprimé par la shutdown_command : il n'existe que pendant le build.
  ssh_username = "packer"
  ssh_password = "packer"

  # Suppression du compte de build, exécutée HORS de la session SSH (dans une
  # unité systemd transitoire) : la commande rend la main immédiatement, puis
  # les processus du compte sont terminés AVANT le userdel, ce qui évite de
  # supprimer un utilisateur encore connecté (userdel -f).
  remove_build_user = join("; ", [
    "sleep 2",
    "loginctl terminate-user ${local.ssh_username}",
    "i=0",
    "while pgrep -u ${local.ssh_username} >/dev/null && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done",
    "pkill -KILL -u ${local.ssh_username}",
    "sleep 1",
    "userdel ${local.ssh_username}",
    "rm -rf /home/${local.ssh_username} /etc/sudoers.d/90-cloud-init-users",
    "shutdown -P now",
  ])

  common_scripts = "${path.root}/../../common/scripts"
}

source "qemu" "rocky-9" {
  # Image source : image cloud officielle, vérifiée via le fichier CHECKSUM publié.
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
  # Sans -cpu, QEMU émule un « qemu64 » trop ancien pour les distributions
  # récentes (x86-64-v2 minimum pour EL9).
  cpu_model = var.accelerator == "kvm" ? "host" : "max"
  cpus      = var.cpus
  memory    = var.memory
  headless  = true

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

  # Le compte de build est supprimé au tout dernier moment (voir
  # local.remove_build_user), la session SSH courante l'utilisant encore.
  shutdown_command = "sudo systemd-run --quiet --no-block --collect --unit=remove-build-user /bin/sh -c '${local.remove_build_user}'"
}

build {
  name    = local.image_name
  sources = ["source.qemu.rocky-9"]

  provisioner "shell" {
    execute_command = "sudo env {{ .Vars }} bash '{{ .Path }}'"
    scripts = [
      # Spécifique à l'image : paquets et services.
      "${path.root}/scripts/provision.sh",
      # Socle commun à toutes les images.
      "${local.common_scripts}/baseline.sh",
      "${local.common_scripts}/node-exporter.sh",
      "${local.common_scripts}/cleanup.sh",
    ]
  }
}
