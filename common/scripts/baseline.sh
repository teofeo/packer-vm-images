#!/usr/bin/env bash
# Socle commun à toutes les images, indépendant de la distribution :
# shell par défaut, durcissement SSH et journald.
# Les paquets (chrony, client FreeIPA, mises à jour automatiques…) sont
# installés par le provision.sh de chaque image.
# Idempotent : peut être rejoué sans effet de bord.
set -euo pipefail

readonly USERADD_DEFAULTS=/etc/default/useradd
readonly DEFAULT_SHELL=/bin/bash
readonly SSHD_HARDENING=/etc/ssh/sshd_config.d/10-hardening.conf
readonly JOURNALD_CONF=/etc/systemd/journald.conf.d/10-baseline.conf

log() { printf '==> [baseline] %s\n' "$*"; }

set_default_shell() {
  log "Shell par défaut des nouveaux utilisateurs : ${DEFAULT_SHELL}"
  if grep -Eq '^[[:space:]]*#?[[:space:]]*SHELL=' "${USERADD_DEFAULTS}"; then
    sed -Ei "s|^[[:space:]]*#?[[:space:]]*SHELL=.*|SHELL=${DEFAULT_SHELL}|" "${USERADD_DEFAULTS}"
  else
    echo "SHELL=${DEFAULT_SHELL}" >>"${USERADD_DEFAULTS}"
  fi
}

harden_sshd() {
  # sshd retient la PREMIÈRE valeur lue et charge sshd_config.d/*.conf par
  # ordre alphabétique : « 10- » l'emporte donc sur le « 50-cloud-init.conf »
  # généré par cloud-init. Seule l'authentification par clé (ou Kerberos,
  # configuré par ipa-client-install) est autorisée.
  # Non appliqué à chaud : la session Packer en cours n'est pas affectée.
  log "Durcissement de sshd (${SSHD_HARDENING})"
  install -d -m 0755 "$(dirname "${SSHD_HARDENING}")"
  cat >"${SSHD_HARDENING}" <<'CONF'
# Géré par packer-vm-images (common/scripts/baseline.sh).
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
CONF
  chmod 0644 "${SSHD_HARDENING}"
  sshd -t
}

configure_journald() {
  log "Journaux persistants et limités (${JOURNALD_CONF})"
  install -d -m 0755 "$(dirname "${JOURNALD_CONF}")"
  cat >"${JOURNALD_CONF}" <<'CONF'
# Géré par packer-vm-images (common/scripts/baseline.sh).
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=200M
CONF
  chmod 0644 "${JOURNALD_CONF}"
}

main() {
  set_default_shell
  harden_sshd
  configure_journald
  log "Terminé"
}

main "$@"
