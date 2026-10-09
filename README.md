# packer-vm-images

[![Build images](https://github.com/teofeo/packer-vm-images/actions/workflows/build.yml/badge.svg)](https://github.com/teofeo/packer-vm-images/actions/workflows/build.yml)

Construction d'images de VM **qcow2** avec [Packer](https://developer.hashicorp.com/packer)
(plugin [QEMU](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu)),
publiées automatiquement en **GitHub Release** par GitHub Actions.

Les images sont génériques : elles ne contiennent **aucun utilisateur ni clé SSH**.
Tout est injecté au premier boot via **cloud-init**. Elles sont prévues pour être
consommées par Terraform + libvirt (dans un autre dépôt), mais fonctionnent avec
n'importe quel hyperviseur KVM/QEMU.

## Pipeline

```
 git tag v1.2.0 ──push──▶ GitHub Actions (ubuntu-latest + KVM)
                              │
                              ├─ build (matrice, un job par image)
                              │    packer init → fmt -check → validate → build
                              │    └─▶ artefact <image>.qcow2
                              │
                              └─ release (job unique)
                                   download-artifact → SHA256SUMS
                                   └─▶ gh release create v1.2.0
                                          ├─ debian-13.qcow2
                                          └─ SHA256SUMS
```

Sur une **pull request**, seuls `packer fmt -check` et `packer validate` sont
exécutés (ni build, ni release).

## Images disponibles

| Image       | Base                                         | Fichier publié    |
|-------------|----------------------------------------------|-------------------|
| `debian-13` | Debian 13 « trixie » `genericcloud` amd64    | `debian-13.qcow2` |

Contenu commun :

- système à jour (`apt-get upgrade`) ;
- `qemu-guest-agent`, `curl`, `vim`, `htop`, `ca-certificates` ;
- shell par défaut des nouveaux utilisateurs : `/bin/bash` ;
- image généralisée : cloud-init réinitialisé, `machine-id` vidé, clés hôtes SSH
  supprimées (régénérées au premier boot), journaux et caches nettoyés ;
- disque de 10 Gio (étendu automatiquement à la taille du disque de la VM par
  cloud-init `growpart`).

## Arborescence

```
.
├── .github/workflows/build.yml   # CI : validation (PR) et build + release (tag)
├── images/
│   └── debian-13/
│       ├── debian-13.pkr.hcl     # source QEMU + build
│       ├── variables.pkr.hcl     # variables documentées
│       ├── cloud-init/           # seed NoCloud utilisé pendant le build uniquement
│       └── scripts/              # provision.sh, cleanup.sh
└── Makefile                      # construction locale
```

## Construire en local

Prérequis (Debian/Ubuntu) :

```bash
# Packer : https://developer.hashicorp.com/packer/install
sudo apt-get install qemu-system-x86 qemu-utils xorriso
ls -l /dev/kvm          # KVM doit être disponible et accessible (groupe kvm)
```

Commandes :

```bash
make help                       # liste les cibles et les images
make init IMAGE=debian-13       # installe le plugin QEMU (version épinglée)
make fmt                        # formate les fichiers HCL
make validate IMAGE=debian-13   # fmt -check + validate
make build IMAGE=debian-13      # => output/debian-13/debian-13.qcow2
make clean                      # supprime output/ et packer_cache/
```

Sans KVM (VM imbriquée, macOS…), l'émulation logicielle reste possible, mais
beaucoup plus lente :

```bash
packer build -var accelerator=tcg -var ssh_timeout=60m images/debian-13
```

Les autres variables (`disk_size`, `cpus`, `memory`, URL de l'image source…) sont
décrites dans [`variables.pkr.hcl`](images/debian-13/variables.pkr.hcl).

## Publier une version

```bash
git tag v1.0.0
git push --tags
```

Le workflow construit toutes les images de la matrice puis crée la release
`v1.0.0` avec les qcow2, le fichier `SHA256SUMS` et des notes générées
automatiquement. Aucun secret n'est nécessaire (`github.token`).

## Consommer une image

URL de téléchargement :

```
https://github.com/teofeo/packer-vm-images/releases/download/<tag>/<image>.qcow2
```

Téléchargement et vérification :

```bash
TAG=v1.0.0
BASE=https://github.com/teofeo/packer-vm-images/releases/download/$TAG
curl -fLO "$BASE/debian-13.qcow2"
curl -fLO "$BASE/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
```

Exemple de démarrage rapide avec un cloud-init utilisateur (`cloud-localds` est
fourni par le paquet `cloud-image-utils`) :

```bash
cat > user-data <<'EOF'
#cloud-config
hostname: demo
users:
  - name: admin
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... moi@workstation
EOF
cloud-localds seed.iso user-data

qemu-img create -f qcow2 -F qcow2 -b debian-13.qcow2 demo.qcow2 20G
qemu-system-x86_64 -accel kvm -m 2048 -smp 2 -nographic \
  -drive file=demo.qcow2,if=virtio \
  -drive file=seed.iso,media=cdrom \
  -nic user,hostfwd=tcp::2222-:22
# ssh -p 2222 admin@localhost
```

Avec Terraform + libvirt, le principe est identique : un volume basé sur le qcow2
publié et un disque `cloudinit` contenant la configuration utilisateur.

> **Rappel :** l'image ne contient aucun utilisateur ni clé SSH. Sans cloud-init
> fournissant au moins un utilisateur avec une clé ou un mot de passe, la VM
> n'est pas accessible.

## Ajouter une image

1. Copier un dossier existant : `cp -r images/debian-13 images/ubuntu-24.04`.
2. Adapter `local.image_name`, le nom du bloc `source` et le `build`, les URLs de
   l'image source et de ses sommes de contrôle, ainsi que les scripts.
3. Ajouter une ligne à la matrice du workflow :

   ```yaml
   image:
     - debian-13
     - ubuntu-24.04
   ```

4. Vérifier en local : `make validate IMAGE=ubuntu-24.04 && make build IMAGE=ubuntu-24.04`.

Convention à respecter : le dossier, `local.image_name` et le fichier produit
(`output/<image>/<image>.qcow2`) portent le même nom.

## Fonctionnement du build

1. Packer télécharge l'image cloud officielle et la vérifie avec le `SHA512SUMS`
   publié par Debian, puis la redimensionne à `disk_size`.
2. La VM démarre avec un CD-ROM NoCloud (`cidata`) qui crée un compte temporaire
   `packer` (mot de passe, sudo sans mot de passe) pour la connexion SSH.
3. `provision.sh` met à jour et personnalise le système ; `cleanup.sh` le
   généralise.
4. La `shutdown_command` supprime le compte `packer` et son fichier sudoers puis
   éteint la VM ; Packer compresse le disque en qcow2.
