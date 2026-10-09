# packer-vm-images

[![Build images](https://github.com/teofeo/packer-vm-images/actions/workflows/build.yml/badge.svg)](https://github.com/teofeo/packer-vm-images/actions/workflows/build.yml)

Construction d'images de VM **qcow2** avec [Packer](https://developer.hashicorp.com/packer)
(plugin [QEMU](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu)),
publiées automatiquement en **GitHub Release** par GitHub Actions.

Les images sont génériques : elles ne contiennent **aucun utilisateur ni clé SSH**.
Tout est injecté au premier boot via **cloud-init**. Elles fournissent un **socle
d'entreprise** commun (durcissement SSH, synchronisation horaire, mises à jour de
sécurité automatiques, client FreeIPA, agent de supervision) et sont prévues pour
être consommées par Terraform + libvirt (dans un autre dépôt), mais fonctionnent
avec n'importe quel hyperviseur KVM/QEMU.

### Rôle de ce dépôt dans le homelab

| Dépôt | Responsabilité |
|---|---|
| **packer-vm-images** (ici) | Images OS durcies, testées et versionnées : le *socle* commun à toutes les VMs |
| `terraform-homelab` | Réseaux libvirt (zones), VMs, disques, cloud-init minimal (réseau, compte d'automatisation) |
| `ansible-homelab` | Rôles (pare-feu, FreeIPA, bastion, supervision…), inscription au domaine, politique d'accès |

Règle de partage : l'image contient ce qui est **commun, lent à installer et
stable** ; tout ce qui est **propre à une VM ou à un rôle** (nom, IP, clés,
règles de pare-feu, inscription FreeIPA, secrets) est ajouté au déploiement.

## Pipeline

Chaque image est versionnée **indépendamment** : un tag `<image>/vX.Y.Z`
construit, teste et publie cette image, et seulement elle.

```
 git tag debian-13/v1.2.0 ──push──▶ GitHub Actions (ubuntu-latest + KVM)
                                       │
                                       ├─ prepare : tag → image=debian-13, version=v1.2.0
                                       │            (vérifie que images/debian-13/ existe)
                                       │
                                       ├─ build : packer init → fmt -check → validate → build
                                       │          → test (VM jetable + goss)
                                       │          └─▶ artefact debian-13.qcow2
                                       │
                                       └─ release : SHA256SUMS + notes
                                                    └─▶ release « debian-13 v1.2.0 »
                                                           ├─ debian-13.qcow2
                                                           └─ SHA256SUMS
```

Sur une **pull request**, `prepare` sélectionne automatiquement **tous** les
dossiers de `images/`, et seuls `packer fmt -check` et `packer validate` sont
exécutés (ni build, ni release).

Les notes de chaque release contiennent les commandes de téléchargement, les
commits ayant modifié `images/<image>/` ou le socle `common/` depuis la release
précédente **de la même image**, puis la liste des PR fusionnées générée par GitHub.

## Images disponibles

| Image       | Base                                              | Usage type                                   | Fichier publié    |
|-------------|---------------------------------------------------|----------------------------------------------|-------------------|
| `debian-13` | Debian 13 « trixie » `genericcloud` amd64         | serveurs génériques, pare-feu, bastion       | `debian-13.qcow2` |
| `rocky-9`   | Rocky Linux 9 `GenericCloud-Base` x86_64 (EL9)    | serveur FreeIPA, environnements « RHEL »     | `rocky-9.qcow2`   |

### Socle commun (toutes les images)

| Domaine | Contenu | Où |
|---|---|---|
| Système | à jour au moment du build ; `qemu-guest-agent`, `curl`, `vim`, `htop`, `ca-certificates` | `provision.sh` |
| Heure | `chrony` actif (requis par Kerberos/FreeIPA) | `provision.sh` |
| Mises à jour | correctifs de **sécurité** appliqués automatiquement (`unattended-upgrades` / `dnf-automatic`) | `provision.sh` |
| Identité | client FreeIPA installé (`freeipa-client` / `ipa-client`, SSSD) : prêt pour `ipa-client-install` | `provision.sh` |
| SSH | **clés uniquement** : pas de mot de passe, pas de root, `MaxAuthTries 3`… (`sshd_config.d/10-hardening.conf`) | `common/scripts/baseline.sh` |
| Journaux | journald persistant, limité à 200 Mio | `common/scripts/baseline.sh` |
| Utilisateurs | shell par défaut des nouveaux comptes : `/bin/bash` | `common/scripts/baseline.sh` |
| Supervision | `node_exporter` installé (version épinglée) mais **désactivé** | `common/scripts/node-exporter.sh` |
| Généralisation | cloud-init, `machine-id`, clés hôtes SSH et journaux réinitialisés ; aucun compte de build | `common/scripts/cleanup.sh` |
| Disque | 10 Gio, étendu automatiquement à la taille du disque de la VM (cloud-init `growpart`) | `disk_size` |

Spécificités : `rocky-9` active EPEL (pour `htop`) et conserve SELinux en mode
`Enforcing`. Le **pare-feu n'est volontairement pas configuré** dans l'image :
ses règles dépendent du rôle de la VM et sont gérées par Ansible.

### Ce qui reste à faire au déploiement

| Besoin | Comment |
|---|---|
| Se connecter | fournir une **clé SSH** via cloud-init (les mots de passe SSH sont refusés) |
| Inscrire la VM au domaine | `ipa-client-install` (Ansible, rôle `freeipa.ansible_freeipa.ipaclient`) |
| Activer la supervision | `systemctl enable --now node_exporter` ; options dans `/etc/default/node_exporter` (ex. `NODE_EXPORTER_ARGS="--web.listen-address=10.10.10.15:9100"`) |
| Serveur NTP interne | surcharger la configuration de chrony |

## Arborescence

```
.
├── .github/workflows/build.yml   # CI : validation (PR) et build + release (tag <image>/vX.Y.Z)
├── common/                       # socle partagé par toutes les images
│   ├── scripts/
│   │   ├── baseline.sh           # shell par défaut, durcissement SSH, journald
│   │   ├── node-exporter.sh      # agent de supervision (désactivé)
│   │   └── cleanup.sh            # généralisation (APT ou DNF)
│   └── tests/goss.yaml           # tests du socle, inclus par chaque image
├── images/
│   ├── debian-13/
│   │   ├── debian-13.pkr.hcl     # source QEMU + build
│   │   ├── variables.pkr.hcl     # variables documentées
│   │   ├── cloud-init/           # seed NoCloud utilisé pendant le build uniquement
│   │   ├── scripts/provision.sh  # paquets et services propres à la distribution
│   │   └── tests/goss.yaml       # tests propres à l'image (+ inclusion du socle)
│   └── rocky-9/                  # même structure
├── tests/test-image.sh           # démarre l'image dans une VM jetable et lance goss
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
make test IMAGE=debian-13       # teste l'image produite (voir « Tests de l'image »)
make clean                      # supprime output/ et packer_cache/
make tag IMAGE=debian-13 VERSION=v1.0.0   # crée le tag de release (local)
```

Sans KVM (VM imbriquée, macOS…), l'émulation logicielle reste possible, mais
beaucoup plus lente :

```bash
packer build -var accelerator=tcg -var ssh_timeout=60m images/debian-13
```

Les autres variables (`disk_size`, `cpus`, `memory`, URL de l'image source…) sont
décrites dans le `variables.pkr.hcl` de chaque image. Le modèle de CPU suit
l'accélérateur (`host` avec KVM, `max` avec TCG) : le `qemu64` par défaut de
QEMU est trop ancien pour Rocky Linux 9 (x86-64-v2 minimum).

## Tests de l'image

Avant d'être publiée, chaque image est **démarrée et testée** comme le serait une
vraie VM. [`tests/test-image.sh`](tests/test-image.sh) :

1. crée un overlay qcow2 jetable (l'image testée n'est jamais modifiée) ;
2. génère une clé SSH et un seed cloud-init de test qui crée l'utilisateur
   `tester` **sans préciser de shell** ;
3. démarre la VM avec QEMU, avec un canal `virtio-serial` pour le guest agent ;
4. attend SSH et la fin de cloud-init, puis interroge le `qemu-guest-agent`
   **depuis l'hôte** (`guest-ping`), comme le ferait libvirt ;
5. copie [goss](https://goss.rocks) (version épinglée, somme SHA-256 vérifiée)
   dans la VM et exécute `images/<image>/tests/goss.yaml`, qui inclut les tests
   du socle (`common/tests/goss.yaml`).

Les tests vérifient notamment :

| Domaine          | Vérification                                                                 |
|------------------|------------------------------------------------------------------------------|
| Personnalisation | paquets installés, services actifs (`ssh`, `chrony`, guest agent), version de la distribution, SELinux `Enforcing` (Rocky) |
| Sécurité         | configuration **effective** de sshd (`sshd -T`) : ni mot de passe, ni root ; mises à jour de sécurité automatiques actives |
| Socle            | client FreeIPA présent, `node_exporter` installé mais désactivé, journald persistant |
| Shell par défaut | `/etc/default/useradd` **et** shell réel de `tester` = `/bin/bash`           |
| Généralisation   | plus de compte `packer` (ni home, ni sudoers)                                |
| Premier boot     | cloud-init exécuté avec le seed **de test** (instance-id), `machine-id` et clés hôtes SSH **régénérés au boot** |
| Disque           | partition racine étendue à la taille du disque                               |

En CI, l'étape `Test image` s'exécute juste après le build : une image qui échoue
n'est ni uploadée ni publiée. En local :

```bash
make build IMAGE=debian-13 && make test IMAGE=debian-13
ACCEL=tcg BOOT_TIMEOUT=900 make test IMAGE=debian-13   # sans KVM
```

## Publier une version

Les tags suivent le format `<image>/vX.Y.Z` ([SemVer](https://semver.org/lang/fr/)) :

```bash
make tag IMAGE=debian-13 VERSION=v1.0.0   # vérifie le format et l'image
git push origin debian-13/v1.0.0
```

(équivalent à `git tag -a debian-13/v1.0.0 -m "debian-13 v1.0.0"`.)

Conventions proposées :

- **patch** (`v1.0.1`) : simple reconstruction pour embarquer les mises à jour
  de sécurité de la distribution ;
- **mineure** (`v1.1.0`) : ajout de paquets ou de réglages compatibles ;
- **majeure** (`v2.0.0`) : changement cassant (taille de disque, partitionnement,
  comportement par défaut…).

Le workflow construit l'image, puis crée la release avec le qcow2 et le fichier
`SHA256SUMS`. Aucun secret n'est nécessaire (`github.token`). Un tag dont le
préfixe ne correspond à aucun dossier de `images/` fait échouer le workflow.

## Consommer une image

URL de téléchargement :

```
https://github.com/teofeo/packer-vm-images/releases/download/<image>/<version>/<image>.qcow2
```

Téléchargement et vérification :

```bash
BASE=https://github.com/teofeo/packer-vm-images/releases/download/debian-13/v1.0.0
curl -fLO "$BASE/debian-13.qcow2"
curl -fLO "$BASE/SHA256SUMS"
sha256sum -c SHA256SUMS
```

> **Toujours épingler une version.** L'URL `releases/latest/download/…` désigne
> la dernière release *du dépôt*, toutes images confondues : elle peut pointer
> vers la release d'une autre image.

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

1. Copier l'image la plus proche : `cp -r images/debian-13 images/ubuntu-24.04`
   (famille Debian) ou `images/rocky-9` (famille Red Hat).
2. Adapter `local.image_name`, le nom du bloc `source` et le `build`, les URLs de
   l'image source et de ses sommes de contrôle, `provision.sh` (paquets du socle
   sous leurs noms dans la distribution) et `tests/goss.yaml` (obligatoire, en
   gardant l'inclusion de `common.yaml`). Le socle `common/` s'applique sans
   modification.
3. Vérifier en local : `make validate build test IMAGE=ubuntu-24.04`.
4. Ouvrir une PR : la CI détecte le nouveau dossier et le valide automatiquement,
   **sans aucune modification du workflow**.
5. Après fusion, publier la première version : `make tag IMAGE=ubuntu-24.04 VERSION=v1.0.0`.

Convention à respecter : le dossier, `local.image_name`, le préfixe des tags et
le fichier produit (`output/<image>/<image>.qcow2`) portent le même nom.

## Fonctionnement du build

1. Packer télécharge l'image cloud officielle et la vérifie avec le fichier de
   sommes de contrôle publié par la distribution (`SHA512SUMS` pour Debian,
   `CHECKSUM` pour Rocky), puis la redimensionne à `disk_size`.
2. La VM démarre avec un CD-ROM NoCloud (`cidata`) qui crée un compte temporaire
   `packer` (mot de passe, sudo sans mot de passe) pour la connexion SSH.
3. `provision.sh` installe les paquets propres à la distribution, puis les
   scripts de `common/` appliquent le socle (`baseline.sh`, `node-exporter.sh`)
   et généralisent le système (`cleanup.sh`).
4. La `shutdown_command` lance une unité systemd transitoire qui, une fois la
   session SSH terminée, supprime le compte `packer` et son fichier sudoers puis
   éteint la VM ; Packer compresse le disque en qcow2.
