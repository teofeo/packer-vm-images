#!/usr/bin/env bash
# Personnalisation propre à Rocky Linux 9 : paquets et services.
# Le socle commun (SSH, journald, node_exporter…) est appliqué ensuite par
# common/scripts/*.sh.
# Idempotent : peut être rejoué sans effet de bord sur une image déjà provisionnée.
set -euo pipefail

readonly PACKAGES=(
  # Outils (htop vient d'EPEL)
  qemu-guest-agent curl vim-enhanced htop ca-certificates
  # Synchronisation horaire (requise par Kerberos/FreeIPA)
  chrony
  # Mises à jour de sécurité automatiques
  dnf-automatic
  # Client FreeIPA (SSSD, Kerberos, certmonger) : l'inscription est faite par Ansible
  ipa-client
)
readonly DNF_AUTOMATIC_CONF=/etc/dnf/automatic.conf

log() { printf '==> [provision] %s\n' "$*"; }

wait_for_cloud_init() {
  log "Attente de la fin de cloud-init"
  local rc=0
  cloud-init status --wait >/dev/null || rc=$?
  # 2 = terminé avec des avertissements non bloquants (cloud-init >= 23.4).
  if ((rc != 0 && rc != 2)); then
    log "cloud-init a échoué (code ${rc})"
    cloud-init status --long || true
    exit "${rc}"
  fi
}

upgrade_system() {
  log "Mise à jour du système"
  dnf -y -q upgrade
}

install_packages() {
  log "Activation d'EPEL"
  dnf -y -q install epel-release
  log "Installation des paquets : ${PACKAGES[*]}"
  dnf -y -q install "${PACKAGES[@]}"
}

enable_services() {
  # qemu-guest-agent est « static » : il est démarré par udev dès que le canal
  # virtio-serial org.qemu.guest_agent.0 est présent.
  local unit state
  for unit in qemu-guest-agent chronyd; do
    state="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
    case "${state}" in
      enabled | static | indirect)
        log "${unit} déjà activé (${state})"
        ;;
      *)
        log "Activation de ${unit}"
        systemctl enable "${unit}"
        ;;
    esac
  done
}

enable_auto_upgrades() {
  log "Mises à jour de sécurité automatiques (${DNF_AUTOMATIC_CONF})"
  sed -Ei \
    -e 's|^[[:space:]]*#?[[:space:]]*upgrade_type[[:space:]]*=.*|upgrade_type = security|' \
    -e 's|^[[:space:]]*#?[[:space:]]*apply_updates[[:space:]]*=.*|apply_updates = yes|' \
    "${DNF_AUTOMATIC_CONF}"
  grep -Eq '^upgrade_type = security$' "${DNF_AUTOMATIC_CONF}"
  grep -Eq '^apply_updates = yes$' "${DNF_AUTOMATIC_CONF}"
  systemctl enable dnf-automatic.timer
}

main() {
  wait_for_cloud_init
  upgrade_system
  install_packages
  enable_services
  enable_auto_upgrades
  log "Terminé"
}

main "$@"
