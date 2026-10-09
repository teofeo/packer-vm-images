#!/usr/bin/env bash
# Généralisation de l'image : supprime tout état propre à la VM de build afin
# que chaque VM créée à partir de l'image soit initialisée comme neuve.
# L'utilisateur « packer » est supprimé ensuite par la shutdown_command.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { printf '==> [cleanup] %s\n' "$*"; }

log "Nettoyage d'APT"
apt-get -y -q autoremove --purge
apt-get -y -q clean
rm -rf /var/lib/apt/lists/*

log "Réinitialisation de cloud-init (relancé au premier boot)"
cloud-init clean --logs --seed

log "Réinitialisation du machine-id"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

log "Suppression des clés hôtes SSH (régénérées au premier boot)"
rm -f /etc/ssh/ssh_host_*

log "Nettoyage des journaux"
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
find /var/log -type f -exec truncate -s 0 {} +

log "Nettoyage des fichiers temporaires et historiques"
find /tmp /var/tmp -mindepth 1 -maxdepth 1 ! -name 'script_*.sh' -exec rm -rf {} +
rm -f /root/.bash_history

sync
log "Terminé"
