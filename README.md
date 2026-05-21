# Rep-Dem

[

![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)

](LICENSE)
[

![Bash](https://img.shields.io/badge/bash-4.0%2B-green.svg)

](repdem.sh)
[

![Version](https://img.shields.io/badge/version-2.2.0-orange.svg)

](repdem.sh)
[

![Télécharger](https://img.shields.io/badge/télécharger-repdem.sh-brightgreen)

](https://raw.githubusercontent.com/ps81frt/repdem/main/repdem.sh)

**Version:** 2.2.0 · **Licence:** MIT · **Auteur:** ps81frt

Script Bash de réparation du bootloader Linux, sans interface graphique.  
Fonctionne sur le système en cours d'exécution ou depuis un Live ISO (avec `--live-chroot`).

Distributions testées : `Debian` · `Ubuntu` · `Linux Mint` · `Fedora` · `RHEL` · `Rocky Linux` · `AlmaLinux` · `Arch Linux` · `Manjaro` · `openSUSE` · `Void Linux` · `Gentoo` · `Alpine Linux`

---

## Prérequis

- Kernel **3.14+** minimum — testé sur **5.10+**
- Bash **4.0+**
- Privilèges root
- `grub-install` ou `grub2-install` selon la distribution

### Dépendances

Installées automatiquement si absentes :

| Usage | Paquets |
|---|---|
| GRUB BIOS | `grub-pc` |
| GRUB UEFI | `grub-efi-amd64`, `grub-efi-amd64-signed`, `shim-signed`, `efibootmgr` |
| systemd-boot | `bootctl` (inclus dans `systemd`), `kernel-install` (optionnel) |
| initramfs | `update-initramfs` (Debian), `dracut` (RHEL), `mkinitcpio` (Arch) |
| Rapport | `curl`, `hexdump`, `sgdisk`, `sfdisk`, `parted`, `mdadm`, `lvm2` |
| Chroot | `mount`, `chroot`, `findmnt`, `blkid` |
| Windows MBR | `ms-sys` |

## Bootloaders supportés

- **GRUB 2** — BIOS/Legacy et UEFI (x86\_64, aarch64, armv7l)
- **systemd-boot** — UEFI uniquement
- Détection automatique via `grub.cfg`, `loader.conf`, binaires EFI, `efibootmgr`, ID distro

---

## Installation

**Sans `git` (Live USB) :**
```bash
wget https://raw.githubusercontent.com/ps81frt/repdem/main/repdem.sh
chmod +x repdem.sh
sudo ./repdem.sh
```

**Avec `git` :**
```bash
git clone https://github.com/ps81frt/repdem.git
cd repdem
chmod +x repdem.sh
sudo ./repdem.sh
```

> Le script n'est pas installé dans `$PATH` par défaut. Il faut toujours le lancer avec `sudo ./repdem.sh`  
> (et non `sudo repdem.sh`, qui échoue si le répertoire courant n'est pas dans `$PATH`).  
> `su -c` ne fonctionne pas sur Ubuntu/Debian car le compte root est désactivé — utiliser `sudo`.

---

## Utilisation

```
sudo ./repdem.sh [OPTION]
```

| Option | Description |
|---|---|
| *(aucune)* | Menu interactif principal |
| `--recommended` | Réparation automatique en 7 étapes sécurisées |
| `--boot` | Réparation GRUB interactive avec confirmations |
| `--advanced` | Menu avancé 12 options |
| `--boot-info [FILE]` | Génère un rapport Boot-Info complet |
| `--analyze` | Rapport brut système en lecture seule (stdout) |
| `--output FILE` | Exporte le rapport brut vers FILE |
| `--live-chroot` | Scan auto + chroot depuis un Live ISO |
| `--help` | Affiche l'aide complète |
| `--version` | Affiche la version |

---

## Mode `--boot`

Réparation GRUB interactive avec confirmation explicite avant toute modification.

- Détection automatique du disque de démarrage (ou saisie manuelle si introuvable)
- Sauvegarde tables de partitions + configuration GRUB avant modification
- Installation des dépendances manquantes
- Réinstallation GRUB adaptée à la distribution (debian/rhel/arch/suse/gentoo/void/alpine)
- Régénération initramfs après réparation
- Vérification santé filesystem

---

## Mode `--recommended` — 7 étapes

1. Génération rapport Boot-Info avant réparation
2. Sauvegarde des tables de partitions (sgdisk + sfdisk + MBR 512B via dd)
3. Installation des dépendances manquantes
4. Détection et réparation du bootloader (GRUB ou systemd-boot)
5. Vérification et restauration entrée EFI Windows si présente
6. Génération rapport Boot-Info après réparation
7. Validation et activation des consoles texte (getty tty1-tty6)

---

## Menu avancé (`--advanced`)

```
1)  Choisir disque cible + réinstaller GRUB
2)  Purge + réinstallation complète de GRUB
3)  Restaurer table de partitions (sfdisk ou sgdisk)
4)  Restauration MBR compatible Windows
5)  Restauration entrée EFI Microsoft
6)  Générer Boot-Info + upload en ligne
7)  Réparation via chroot (Live ISO uniquement)
8)  Configurer options menu GRUB
9)  Gestionnaire bootloaders (GRUB/systemd-boot/rEFInd/Limine)
10) État RAID / LVM
11) Secure Boot — état, MOK enrollment, signature EFI
12) Retour
```

### Sous-menu option 3 — Restauration table de partitions

```
1)  sfdisk  (.dump) — MBR/DOS/GPT
2)  sgdisk  (.bin)  — GPT uniquement, restaure header + backup GPT
```

### Sous-menu option 8 — Configuration GRUB

```
1)  Afficher le menu GRUB (désactiver timeout caché)
2)  Modifier le délai d'attente (GRUB_TIMEOUT)
3)  Ajouter une option noyau (nomodeset, acpi=off, quiet splash...)
4)  Supprimer une option noyau
5)  Modifier la résolution (GRUB_GFXMODE)
6)  Régénérer grub.cfg maintenant
7)  Retour
```

### Sous-menu option 9 — Gestionnaire bootloaders

Affiche l'état d'installation de chaque bootloader (✅/❌), puis :

```
[1]  GRUB         →  Installer / Réinstaller / Restaurer
[2]  systemd-boot →  Installer / Réinstaller / Supprimer
[3]  rEFInd       →  Installer / Réinstaller / Supprimer
[4]  Limine       →  Installer / Réinstaller / Supprimer
[5]  Restaurer GRUB original (purge + réinstallation)
[6]  Nettoyer ESP (supprimer TOUS les bootloaders tiers)
[7]  Retour
```

### Sous-menu option 11 — Secure Boot / MOK

```
1)  Afficher les clés MOK actuelles
2)  Enrôler une clé MOK existante (.der / .cer)
3)  Générer + enrôler une nouvelle paire de clés MOK (RSA-2048, openssl)
4)  Signer manuellement un fichier EFI ou module noyau
5)  Vérifier la signature d'un fichier EFI
6)  Retour
```

---

## Détection du disque de démarrage — comportement

Le script détecte automatiquement le disque cible en cherchant la partition de boot **du système en cours d'exécution** :

```
/boot/efi  →  résolution vers le disque parent (ex. sda)
/boot      →  idem si /boot/efi absent
/          →  idem si les deux absents
```

**Conséquence directe :** si le script est lancé depuis un **Live USB**, il détecte la partition EFI ou root du Live USB — pas les systèmes installés sur les autres disques. La réparation automatique (`--recommended`) échoue alors avec "Périphérique de démarrage introuvable".

**Solution dans ce cas :** utiliser `--live-chroot` (ou option 6 du menu principal) qui scanne toutes les partitions Linux disponibles (`ext2/3/4`, `btrfs`, `xfs`, `f2fs`, `jfs`, `reiserfs`) et propose une liste interactive des systèmes installés.

**Multi-disques / multi-OS :** la détection automatique ne retourne qu'un seul disque (celui du système actif). Pour choisir manuellement un disque cible, utiliser l'option 1 du menu avancé (`--advanced`) ou le mode chroot.

---

## Mode Live ISO (`--live-chroot`)

Scan automatique des partitions Linux disponibles (ext2/3/4, btrfs, xfs, f2fs, jfs, reiserfs).  
Supporte LUKS ouvert et LVM activé.

> `git` n'est pas disponible sur tous les Live ISO. Dans ce cas, télécharger le script via `wget` ou `curl` :
> ```bash
> wget https://raw.githubusercontent.com/ps81frt/repdem/main/repdem.sh
> chmod +x repdem.sh
> sudo ./repdem.sh --live-chroot
> ```

Séquence automatique :
1. Détection et liste de tous les OS installés
2. Montage de la partition root sélectionnée (avec gestion BTRFS subvol)
3. Montage des partitions séparées via `/etc/fstab` du système cible
4. Bind mounts des systèmes virtuels (`/dev`, `/proc`, `/sys`, `/run`, efivars)
5. Copie et relancement du script en chroot sur le système installé
6. Démontage propre à la sortie (trap sur EXIT/INT/TERM)

```bash
# Depuis un Live USB/ISO :
sudo ./repdem.sh --live-chroot
```

---

## Rapport `--analyze`

Collecte en lecture seule, sans modification du système :

- Informations système (kernel, arch, CPU, mémoire)
- Disques et partitions (`lsblk`, `fdisk`, `parted`, `blkid`, `sgdisk`)
- Configuration boot (EFI entries, GRUB config, MBR signature)
- Filesystems (ext4, XFS, BTRFS, F2FS, ZFS, RAID, LVM, LUKS, zram)
- Secure Boot et TPM
- Windows/BCD
- Journaux système (`journalctl`, `dmesg`)

```bash
# Affichage stdout
sudo ./repdem.sh --analyze

# Export vers fichier
sudo ./repdem.sh --analyze --output /tmp/rapport.txt
```

---

## Validations intégrées

Le script effectue plusieurs validations avant et pendant la réparation :

- **BLS** (Boot Loader Specification) — cohérence des entrées `/boot/loader/entries/`, UUIDs, chemins kernel/initramfs
- **LUKS/TPM2** — validation des UUIDs dans `/etc/crypttab` vs `blkid`, cohérence avec `GRUB_CMDLINE_LINUX`, tokens clevis-tpm2
- **crypttab suffix** — détection des suffixes `_XXXXX` qui cassent l'initramfs systemd-boot
- **initramfs** — présence et régénération si absent (dracut, mkinitcpio, update-initramfs)
- **Secure Boot** — état via `mokutil`, `sbctl`, lecture directe efivars
- **OSTree** — détection des systèmes immutables (Fedora Silverblue/Kinoite) et blocage volontaire

---

## Sauvegardes

Créées automatiquement dans `/var/backup/Rep-Dem-YYYYMMDD_HHMMSS/` avant toute opération :

| Contenu | Outil |
|---|---|
| Table GPT | `sgdisk --backup` |
| Table partitions | `sfdisk --dump` |
| MBR 512 octets | `dd bs=512 count=1` |
| Configuration GRUB | copie de `/etc/default/grub` et `/boot/grub/grub.cfg` |
| ESP (systemd-boot) | archive tar.gz |
| Rapport Boot-Info avant/après | fichiers texte |

Restauration de la table GPT disponible via le menu avancé option 3.

---

## Upload du rapport Boot-Info

L'upload nécessite `curl`. Si absent (certains Live ISO), il faut l'installer au préalable :

```bash
sudo apt install curl    # Debian/Ubuntu
sudo dnf install curl    # Fedora/RHEL
```

3 services interrogés en parallèle, sans compte requis :

| Service | Format | Durée |
|---|---|---|
| paste.ubuntu.com | texte | permanent |
| dpaste.com | texte | 7 jours |
| gofile.io | fichier | variable |

Les URLs sont affichées à l'écran et écrites dans le rapport local.

---

## Journaux

```
/var/log/Rep-Dem.log
```

Niveau DEBUG activable via variable d'environnement :

```bash
DEBUG=true sudo ./repdem.sh
```

---

## Comportement en cas d'erreur

- `set -uo pipefail` actif sur l'ensemble du script
- Trap sur `EXIT`, `INT`, `TERM` — démontage automatique du chroot si interrompu
- Toutes les opérations destructives requièrent une confirmation explicite
- Les sauvegardes sont créées avant chaque modification

---

## Limitations connues

- **Détection disque** : retourne uniquement le disque de la partition de boot active. Sur Live USB, correspond au Live USB et non aux disques installés — utiliser `--live-chroot`.
- **OSTree** (Fedora Silverblue, Kinoite) : détectés et bloqués — réparation GRUB non applicable sur systèmes immutables.
- **Alpine Linux** avec busybox grep : fonctions de détection BTRFS subvol et BLS dégradées.
- **RAID logiciel** (mdadm) : diagnostic disponible, reconstruction non automatisée.
- **ARM** : support UEFI partiel, vérification offset ESP spécifique à certains SoC.
- **curl absent** : l'upload du rapport Boot-Info en ligne est désactivé. Installer `curl` ou copier le fichier manuellement.
