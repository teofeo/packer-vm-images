#!/usr/bin/env bash
# Personnalisation propre à Debian 13 : paquets et services.
# Le socle commun (SSH, journald, node_exporter…) est appliqué ensuite par
# common/scripts/*.sh.
# Idempotent : peut être rejoué sans effet de bord sur une image déjà provisionnée.
set -euo pipefail

readonly PACKAGES=(
  # Outils
  qemu-guest-agent curl vim htop ca-certificates
  # Synchronisation horaire (requise par Kerberos/FreeIPA ; remplace systemd-timesyncd)
  chrony
  # Mises à jour de sécurité automatiques
  unattended-upgrades
  # Client FreeIPA (SSSD, Kerberos, certmonger) : l'inscription est faite par Ansible
  freeipa-client
)
readonly AUTO_UPGRADES=/etc/apt/apt.conf.d/20auto-upgrades

export DEBIAN_FRONTEND=noninteractive
readonly APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

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
  apt-get update -q
  apt-get "${APT_OPTS[@]}" upgrade
}

install_packages() {
  log "Installation des paquets : ${PACKAGES[*]}"
  apt-get "${APT_OPTS[@]}" install --no-install-recommends "${PACKAGES[@]}"
}

enable_services() {
  # Sous Debian, qemu-guest-agent est généralement « static » : il est démarré
  # par udev dès que le canal virtio-serial org.qemu.guest_agent.0 est présent.
  local unit state
  for unit in qemu-guest-agent chrony; do
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
  # Origines par défaut d'unattended-upgrades : dépôts de sécurité Debian.
  log "Mises à jour de sécurité automatiques (${AUTO_UPGRADES})"
  cat >"${AUTO_UPGRADES}" <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
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
