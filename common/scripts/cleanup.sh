#!/usr/bin/env bash
# Généralisation de l'image : supprime tout état propre à la VM de build afin
# que chaque VM créée à partir de l'image soit initialisée comme neuve.
# Commun à toutes les images (APT ou DNF).
# L'utilisateur « packer » est supprimé ensuite par la shutdown_command.
set -euo pipefail

log() { printf '==> [cleanup] %s\n' "$*"; }

clean_packages() {
  if command -v apt-get >/dev/null; then
    log "Nettoyage d'APT"
    DEBIAN_FRONTEND=noninteractive apt-get -y -q autoremove --purge
    apt-get -y -q clean
    rm -rf /var/lib/apt/lists/*
  elif command -v dnf >/dev/null; then
    log "Nettoyage de DNF"
    dnf -y -q autoremove
    dnf -y -q clean all
    rm -rf /var/cache/dnf/*
  fi
}

main() {
  clean_packages

  log "Réinitialisation de cloud-init (relancé au premier boot)"
  cloud-init clean --logs --seed
  # Généré pendant le build à cause de « ssh_pwauth: true » (seed Packer).
  rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf

  log "Réinitialisation du machine-id"
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id

  log "Suppression des clés hôtes SSH (régénérées au premier boot)"
  rm -f /etc/ssh/ssh_host_*

  log "Nettoyage des journaux"
  journalctl --rotate >/dev/null 2>&1 || true
  journalctl --vacuum-time=1s >/dev/null 2>&1 || true
  # Le journal est rangé par machine-id : celui du build ne doit pas subsister.
  find /var/log/journal -mindepth 1 -delete 2>/dev/null || true
  find /var/log -path /var/log/journal -prune -o -type f \
    \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -print0 | xargs -0r rm -f
  find /var/log -path /var/log/journal -prune -o -type f -print0 | xargs -0r truncate -s 0

  log "Nettoyage des fichiers temporaires et historiques"
  find /tmp /var/tmp -mindepth 1 -maxdepth 1 ! -name 'script_*.sh' -exec rm -rf {} +
  rm -f /root/.bash_history

  sync
  log "Terminé"
}

main "$@"
