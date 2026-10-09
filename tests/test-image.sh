#!/usr/bin/env bash
# Teste une image produite par Packer : démarre une VM jetable à partir du
# qcow2 (via un overlay, l'image n'est jamais modifiée) avec un cloud-init de
# test, puis exécute les tests goss de l'image (images/<image>/tests/goss.yaml,
# qui inclut le socle commun common/tests/goss.yaml).
#
# Usage : tests/test-image.sh <image>
#
# Variables d'environnement :
#   IMAGE_FILE    qcow2 à tester    (défaut : output/<image>/<image>.qcow2)
#   ACCEL         kvm | tcg         (défaut : kvm)
#   BOOT_TIMEOUT  attente SSH, en s (défaut : 300)
#   SSH_PORT      port local        (défaut : 2222)
set -euo pipefail

readonly GOSS_VERSION="v0.4.9"
readonly GOSS_SHA256="87dd36cfa1b8b50554e6e2ca29168272e26755b19ba5438341f7c66b36decc19"

readonly IMAGE="${1:?usage: $0 <image>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# Chemin absolu : il sert de backing file à l'overlay.
IMAGE_FILE="$(realpath -m "${IMAGE_FILE:-${ROOT_DIR}/output/${IMAGE}/${IMAGE}.qcow2}")"
readonly IMAGE_FILE
readonly GOSSFILE="${ROOT_DIR}/images/${IMAGE}/tests/goss.yaml"
readonly COMMON_GOSSFILE="${ROOT_DIR}/common/tests/goss.yaml"
readonly ACCEL="${ACCEL:-kvm}"
readonly BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
readonly SSH_PORT="${SSH_PORT:-2222}"

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
INSTANCE_ID="image-test-$(date +%s)"
readonly INSTANCE_ID
readonly SSH_OPTS=(
  -i "${WORK_DIR}/id_ed25519"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5
)

log() { printf '==> [test] %s\n' "$*"; }
die() { printf '==> [test] ERREUR : %s\n' "$*" >&2; exit 1; }

cleanup() {
  local rc=$?
  if [[ -f "${WORK_DIR}/qemu.pid" ]]; then
    kill "$(cat "${WORK_DIR}/qemu.pid")" 2>/dev/null || true
  fi
  if ((rc != 0)) && [[ -f "${WORK_DIR}/console.log" ]]; then
    log "Échec : fin de la console série de la VM"
    tail -n 50 "${WORK_DIR}/console.log" || true
  fi
  rm -rf "${WORK_DIR}"
  exit "${rc}"
}
trap cleanup EXIT

vm_ssh() { ssh "${SSH_OPTS[@]}" -p "${SSH_PORT}" tester@127.0.0.1 "$@"; }

check_prerequisites() {
  [[ -f "${IMAGE_FILE}" ]] || die "image introuvable : ${IMAGE_FILE} (lancer « make build IMAGE=${IMAGE} »)"
  [[ -f "${GOSSFILE}" ]] || die "tests introuvables : ${GOSSFILE}"
  [[ -f "${COMMON_GOSSFILE}" ]] || die "tests introuvables : ${COMMON_GOSSFILE}"
  local cmd
  for cmd in qemu-system-x86_64 qemu-img xorriso ssh scp ssh-keygen curl python3; do
    command -v "${cmd}" >/dev/null || die "commande manquante : ${cmd}"
  done
}

fetch_goss() {
  log "Téléchargement de goss ${GOSS_VERSION}"
  curl -fsSL -o "${WORK_DIR}/goss" \
    "https://github.com/goss-org/goss/releases/download/${GOSS_VERSION}/goss-linux-amd64"
  echo "${GOSS_SHA256}  ${WORK_DIR}/goss" | sha256sum -c --quiet
  chmod +x "${WORK_DIR}/goss"
}

make_seed() {
  log "Génération du seed cloud-init de test (instance-id ${INSTANCE_ID})"
  ssh-keygen -q -t ed25519 -N '' -C image-test -f "${WORK_DIR}/id_ed25519"
  mkdir "${WORK_DIR}/seed"
  # Pas de « shell: » : le shell par défaut de l'image est testé.
  cat >"${WORK_DIR}/seed/user-data" <<USERDATA
#cloud-config
users:
  - name: tester
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - $(cat "${WORK_DIR}/id_ed25519.pub")
USERDATA
  cat >"${WORK_DIR}/seed/meta-data" <<METADATA
instance-id: ${INSTANCE_ID}
local-hostname: image-test
METADATA
  xorriso -as mkisofs -quiet -volid cidata -joliet -rock \
    -output "${WORK_DIR}/seed.iso" "${WORK_DIR}/seed"
}

start_vm() {
  log "Démarrage de la VM (accélérateur ${ACCEL})"
  qemu-img create -q -f qcow2 -F qcow2 -b "${IMAGE_FILE}" "${WORK_DIR}/disk.qcow2"
  local cpu=max
  [[ "${ACCEL}" == "kvm" ]] && cpu=host
  qemu-system-x86_64 \
    -name image-test -accel "${ACCEL}" -cpu "${cpu}" -smp 2 -m 2048 \
    -drive file="${WORK_DIR}/disk.qcow2",if=virtio,format=qcow2 \
    -drive file="${WORK_DIR}/seed.iso",media=cdrom,format=raw \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -chardev socket,id=qga0,path="${WORK_DIR}/qga.sock",server=on,wait=off \
    -device virtio-serial -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -display none -serial file:"${WORK_DIR}/console.log" \
    -daemonize -pidfile "${WORK_DIR}/qemu.pid"
}

wait_for_ssh() {
  log "Attente de SSH (max ${BOOT_TIMEOUT}s)"
  local deadline=$((SECONDS + BOOT_TIMEOUT))
  until vm_ssh true 2>/dev/null; do
    ((SECONDS < deadline)) || die "SSH injoignable après ${BOOT_TIMEOUT}s"
    sleep 5
  done
  log "Attente de la fin de cloud-init"
  local rc=0
  vm_ssh cloud-init status --wait >/dev/null || rc=$?
  ((rc == 0 || rc == 2)) || die "cloud-init a échoué dans la VM (code ${rc})"
}

check_guest_agent() {
  # Vérification depuis l'hôte, comme le ferait libvirt/Terraform.
  log "Ping du qemu-guest-agent depuis l'hôte"
  local _
  for _ in {1..12}; do
    if python3 - "${WORK_DIR}/qga.sock" <<'PY'
import json, socket, sys
with socket.socket(socket.AF_UNIX) as s:
    s.settimeout(5)
    s.connect(sys.argv[1])
    s.sendall(b'{"execute": "guest-ping"}\n')
    sys.exit(0 if json.loads(s.recv(4096)) == {"return": {}} else 1)
PY
    then
      log "qemu-guest-agent répond"
      return
    fi
    sleep 5
  done
  die "qemu-guest-agent ne répond pas"
}

run_goss() {
  log "Exécution des tests goss"
  mkdir "${WORK_DIR}/goss-tests"
  cp "${WORK_DIR}/goss" "${GOSSFILE}" "${WORK_DIR}/goss-tests/"
  cp "${COMMON_GOSSFILE}" "${WORK_DIR}/goss-tests/common.yaml"
  scp "${SSH_OPTS[@]}" -P "${SSH_PORT}" -q -r "${WORK_DIR}/goss-tests" tester@127.0.0.1:/tmp/
  vm_ssh sudo /tmp/goss-tests/goss --gossfile /tmp/goss-tests/goss.yaml \
    --vars-inline "'{\"instance_id\": \"${INSTANCE_ID}\"}'" \
    validate --retry-timeout 60s --sleep 5s --format documentation --no-color
}

main() {
  check_prerequisites
  fetch_goss
  make_seed
  start_vm
  wait_for_ssh
  check_guest_agent
  run_goss
  log "Tous les tests de ${IMAGE} sont passés"
}

main "$@"
