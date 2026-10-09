#!/usr/bin/env bash
# Personnalisation de l'image Debian 13.
# Idempotent : peut être rejoué sans effet de bord sur une image déjà provisionnée.
set -euo pipefail

readonly PACKAGES=(qemu-guest-agent curl vim htop ca-certificates)
readonly USERADD_DEFAULTS=/etc/default/useradd
readonly DEFAULT_SHELL=/bin/bash

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

enable_guest_agent() {
  # Sous Debian, l'unité est généralement « static » : elle est démarrée par
  # udev dès que le canal virtio-serial org.qemu.guest_agent.0 est présent.
  local state
  state="$(systemctl is-enabled qemu-guest-agent 2>/dev/null || true)"
  case "${state}" in
    enabled | static | indirect)
      log "qemu-guest-agent déjà activé (${state})"
      ;;
    *)
      log "Activation de qemu-guest-agent"
      systemctl enable qemu-guest-agent
      ;;
  esac
}

set_default_shell() {
  log "Shell par défaut des nouveaux utilisateurs : ${DEFAULT_SHELL}"
  if grep -Eq '^[[:space:]]*#?[[:space:]]*SHELL=' "${USERADD_DEFAULTS}"; then
    sed -Ei "s|^[[:space:]]*#?[[:space:]]*SHELL=.*|SHELL=${DEFAULT_SHELL}|" "${USERADD_DEFAULTS}"
  else
    echo "SHELL=${DEFAULT_SHELL}" >>"${USERADD_DEFAULTS}"
  fi
  grep '^SHELL=' "${USERADD_DEFAULTS}"
}

main() {
  wait_for_cloud_init
  upgrade_system
  install_packages
  enable_guest_agent
  set_default_shell
  log "Terminé"
}

main "$@"
