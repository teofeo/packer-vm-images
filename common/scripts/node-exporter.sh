#!/usr/bin/env bash
# Installe Prometheus node_exporter (binaire officiel, version épinglée et
# somme SHA-256 vérifiée), identique sur toutes les distributions.
# Le service est installé mais NON activé : chaque VM l'active (cloud-init ou
# Ansible) et peut régler ses options dans /etc/default/node_exporter.
# Idempotent : ne retélécharge pas une version déjà installée.
set -euo pipefail

readonly VERSION="1.12.1"
readonly SHA256="b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63"
readonly ARCHIVE="node_exporter-${VERSION}.linux-amd64"
readonly URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${ARCHIVE}.tar.gz"
readonly BIN=/usr/local/bin/node_exporter
readonly UNIT=/etc/systemd/system/node_exporter.service
readonly DEFAULTS=/etc/default/node_exporter
readonly SERVICE_USER=node_exporter

log() { printf '==> [node-exporter] %s\n' "$*"; }

install_binary() {
  if [[ -x "${BIN}" ]] && "${BIN}" --version 2>&1 | grep -q "version ${VERSION} "; then
    log "node_exporter ${VERSION} déjà installé"
    return
  fi
  log "Installation de node_exporter ${VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/${ARCHIVE}.tar.gz" "${URL}"
  echo "${SHA256}  ${tmp}/${ARCHIVE}.tar.gz" | sha256sum -c --quiet
  tar -xzf "${tmp}/${ARCHIVE}.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/${ARCHIVE}/node_exporter" "${BIN}"
  rm -rf "${tmp}"
  # Contexte SELinux correct sur les distributions qui l'activent.
  if command -v restorecon >/dev/null; then
    restorecon "${BIN}"
  fi
}

create_user() {
  if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
    log "Création du compte système ${SERVICE_USER}"
    useradd --system --no-create-home --shell "$(command -v nologin)" "${SERVICE_USER}"
  fi
}

install_service() {
  log "Installation du service (désactivé)"
  if [[ ! -f "${DEFAULTS}" ]]; then
    cat >"${DEFAULTS}" <<'CONF'
# Options de node_exporter, ex. :
# NODE_EXPORTER_ARGS="--web.listen-address=10.10.10.15:9100"
NODE_EXPORTER_ARGS=""
CONF
  fi
  cat >"${UNIT}" <<CONF
# Géré par packer-vm-images (common/scripts/node-exporter.sh).
[Unit]
Description=Prometheus node_exporter
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
EnvironmentFile=-${DEFAULTS}
ExecStart=${BIN} \$NODE_EXPORTER_ARGS
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
CONF
  systemctl daemon-reload
}

main() {
  install_binary
  create_user
  install_service
  log "Terminé"
}

main "$@"
