variable "source_image_url" {
  type        = string
  description = "URL de l'image cloud Debian 13 (genericcloud, amd64) servant de base."
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

variable "source_checksum_url" {
  type        = string
  description = "URL du fichier SHA512SUMS publié avec l'image source."
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
}

variable "disk_size" {
  type        = string
  description = "Taille virtuelle du disque de l'image produite (suffixes K, M, G, T acceptés)."
  default     = "10G"
}

variable "accelerator" {
  type        = string
  description = "Accélérateur QEMU : `kvm` (par défaut) ou `tcg` (émulation logicielle, lente) si KVM est indisponible."
  default     = "kvm"

  validation {
    condition     = contains(["kvm", "tcg"], var.accelerator)
    error_message = "L'accélérateur doit valoir \"kvm\" ou \"tcg\"."
  }
}

variable "cpus" {
  type        = number
  description = "Nombre de vCPU alloués à la VM de build."
  default     = 2
}

variable "memory" {
  type        = number
  description = "Mémoire (en Mio) allouée à la VM de build."
  default     = 2048
}

variable "ssh_timeout" {
  type        = string
  description = "Délai maximal d'attente de la connexion SSH (à augmenter avec l'accélérateur `tcg`)."
  default     = "15m"
}
