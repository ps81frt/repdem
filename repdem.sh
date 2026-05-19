#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables may be used externally or in future code
# shellcheck disable=SC2329  # Functions may be invoked indirectly
#===============================================================================
#         UTILISATION: sudo ./repdem.sh [--boot|--recommended|--advanced|--boot-info|--analyze|--output <fichier>|--live-chroot]
#
#   DESCRIPTION: Outil de réparation boot Linux multi-distro, sans GUI.
#                Réparation bootloader CLI multi-distribution, sans dépendance graphique.
#
#       OPTIONS:
#         --boot          Réparation boot interactive avec confirmations
#         --recommended   Réparation automatique 7 étapes
#         --advanced      Menu 12 options : disque, purge, chroot, GRUB config, RAID, EFI, bootloaders (GRUB/systemd-boot/rEFInd/Limine)...
#         --boot-info     Génère un rapport Boot-Info structuré + upload en ligne optionnel
#         --analyze       Rapport brut système en lecture seule (stdout)
#         --output FILE   Exporte le rapport brut vers FILE
#         --live-chroot   Scan auto + chroot depuis un Live ISO
#         --help          Affiche l'aide complète
#         --version       Affiche la version
#
#  REQUIREMENTS: Root privileges, bash 4.0+, grub-install ou grub2-install
#     SUPPORTE:  Debian/Ubuntu/Mint · Fedora/RHEL/Rocky/Alma · Arch/Manjaro
#                openSUSE · Void Linux · Gentoo
#        AUTHOR: ps81frt
#        GITHUB: https://github.com/ps81frt/repdem
#       VERSION: 2.2.0
#       CREATED: 2026
#       LICENSE: MIT
#
#===============================================================================

set -uo pipefail
shopt -s nullglob

#-------------------------------------------------------------------------------
# GLOBAL CONSTANTS & VARIABLES
#-------------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="2.2.0"
BACKUP_DIR="/var/backup/Rep-Dem-$(date +%Y%m%d_%H%M%S)"
readonly BACKUP_DIR
readonly DEFAULT_LOG_FILE="/var/log/repdem/Rep-Dem.log"
LOG_FILE="$DEFAULT_LOG_FILE"
readonly MIN_BASH_VERSION=4

DETECTED_BTRFS_SUBVOL=""
export DETECTED_BTRFS_SUBVOL

DISTRO=""
DISTRO_FAMILY=""
DISTRO_VERSION=""
PKG_MANAGER=""
ID=""
PRETTY_NAME=""

declare -A COMPLETED_OPERATIONS
export MODE="interactive"
OUTPUT_FILE=""
ANALYZE_MODE=false
FORCE_DISK=""
export NONINTERACTIVE=false
CHROOT_TARGET=""     # point de montage auto-chroot (utilisé par le trap)
_INSIDE_CHROOT=false # true quand le script tourne à l'intérieur du chroot

#-------------------------------------------------------------------------------
# ANSI COLORS (désactivation auto hors terminal)
#-------------------------------------------------------------------------------

if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly WHITE='\033[1;37m'
    readonly NC='\033[0m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly MAGENTA=''
    readonly CYAN=''
    readonly WHITE=''
    readonly NC=''
    readonly BOLD=''
    readonly DIM=''
fi
#-------------------------------------------------------------------------------
# LOGGING FUNCTIONS
#-------------------------------------------------------------------------------
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_to_file() {
    local level="$1"
    local message="$2"

    if [[ -n "${LOG_FILE:-}" ]] && { [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; }; then
        echo "[$(get_timestamp)] [$level] $message" >>"$LOG_FILE" 2>/dev/null
    fi
}

log_info() {
    local message="$1"
    printf "%b%s\n" "${BLUE}[INFO]${NC}" "$message"
    log_to_file "INFO" "$message"
}

log_success() {
    local message="$1"
    printf "%b%s\n" "${GREEN}[SUCCES]${NC}" "$message"
    log_to_file "SUCCÈS" "$message"
}

log_warning() {
    local message="$1"
    printf "%b%s\n" "${YELLOW}[ATTENTION]${NC}" "$message"
    log_to_file "ATTENTION" "$message"
}

log_error() {
    local message="$1"
    printf "%b%s\n" "${RED}[ERREUR]${NC}" "$message" >&2
    log_to_file "ERREUR" "$message"
}

log_debug() {
    local message="$1"
    if [[ "${DEBUG:-false}" == "true" ]]; then
        printf "%b%s\n" "${DIM}[DÉBOGAGE]${NC}" "$message"
        log_to_file "DÉBOGAGE" "$message"
    fi
}

log_header() {
    local title="$1"
    local width=78
    local padding=$(((width - ${#title} - 2) / 2))

    echo ""
    printf "%b\n" "${CYAN}${BOLD}$(printf '═%.0s' $(seq 1 "$width"))${NC}"
    printf "%b\n" "${CYAN}${BOLD}$(printf ' %.0s' $(seq 1 "$padding")) $title $(printf ' %.0s' $(seq 1 "$padding"))${NC}"
    printf "%b\n" "${CYAN}${BOLD}$(printf '═%.0s' $(seq 1 "$width"))${NC}"
    echo ""
    log_to_file "HEADER" "=== $title ==="
}

log_subheader() {
    local title="$1"
    echo ""
    printf "%b\n" "${MAGENTA}${BOLD}─── $title ───${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# UTILITY FUNCTIONS
#-------------------------------------------------------------------------------
command_exists() {
    command -v "$1" &>/dev/null
}

portable_hexdump() {
    local file="$1"
    if command_exists hexdump; then
        hexdump -C -n 512 "$file" 2>/dev/null
    elif command_exists xxd; then
        xxd -g 1 -l 512 "$file" 2>/dev/null
    else
        return 1
    fi
}

prepare_output_file() {
    local file="$1"

    if [[ -z "$file" ]]; then
        return 1
    fi

    local dir
    dir=$(dirname "$file")
    mkdir -p "$dir" 2>/dev/null || true

    if [[ -e "$file" ]]; then
        if ! confirm_action "Le fichier de sortie existe déjà : $file. Voulez-vous le remplacer ?" yes; then
            log_error "Export annulé. Le fichier de sortie existe déjà : $file"
            exit 1
        fi

        local backup
        backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a "$file" "$backup" 2>/dev/null || true
    fi

    : >"$file"
}

report_line() {
    local line="$1"
    printf '%s\n' "$line"
    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '%s\n' "$line" >>"$OUTPUT_FILE"
    fi
}

raw_command_output() {
    local cmd="$1"
    local exe
    exe=$(printf '%s' "$cmd" | awk '{print $1}')

    if ! command_exists "$exe"; then
        echo "indisponible"
        return
    fi

    local output
    if output=$(eval "$cmd" 2>/dev/null); then
        if [[ -n "$output" ]]; then
            printf '%s\n' "$output"
        else
            echo "indisponible"
        fi
    else
        echo "indisponible"
    fi
}

report_section() {
    local title="$1"
    report_line ""
    report_line "================================================================"
    report_line " $title"
    report_line "================================================================"
    report_line ""
}

report_command() {
    local cmd="$1"
    report_line "$cmd"
    local out
    out=$(raw_command_output "$cmd")
    printf '%s\n' "$out"
    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '%s\n' "$out" >>"$OUTPUT_FILE"
    fi
}

is_operation_completed() {
    local operation="$1"
    [[ "${COMPLETED_OPERATIONS[$operation]:-}" == "true" ]]
}

mark_operation_completed() {
    local operation="$1"
    COMPLETED_OPERATIONS[$operation]="true"
}

confirm_action() {
    local prompt="$1"
    local mode="${2:-standard}"
    local response

    echo ""
    printf "%b\n" "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${YELLOW}${BOLD}║  CONFIRMATION REQUISE                                            ║${NC}"
    printf "%b\n" "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    printf "%b\n" "${WHITE}$prompt${NC}"
    echo ""

    if [[ "$mode" == "strict" ]]; then
        read -r -p "Confirmer en tapant OUI : " response
        if [[ "${response^^}" == "OUI" ]]; then
            log_to_file "CONFIRM" "Utilisateur confirmé avec OUI : $prompt"
            return 0
        fi
        log_info "Opération annulée par l'utilisateur"
        return 1
    fi

    if [[ "$mode" == "yes" ]]; then
        read -r -p "Continuer ? [O/n] : " response
        response="${response:-o}"
    else
        read -r -p "Continuer ? [o/N] : " response
        response="${response:-n}"
    fi

    case "$response" in
    [YyOo] | [YyOo][Ee][Ss])
        log_to_file "CONFIRM" "Utilisateur confirmé : $prompt"
        return 0
        ;;
    *)
        log_info "Opération annulée par l'utilisateur"
        return 1
        ;;
    esac
}

confirm_action_level2() {
    local prompt="$1"
    local phrase="${2:-JE CONFIRME LE RISQUE}"
    local response

    if ! confirm_action "$prompt" strict; then
        return 1
    fi

    read -r -p "Deuxieme validation - tapez exactement: $phrase : " response
    if [[ "$response" == "$phrase" ]]; then
        log_to_file "CONFIRM2" "Validation niveau 2 OK : $prompt"
        return 0
    fi

    log_info "Opération annulée (validation niveau 2 invalide)"
    return 1
}

backup_file() {
    local source_file="$1"
    local description="${2:-configuration file}"

    if [[ ! -e "$source_file" ]]; then
        log_debug "Sauvegarde ignorée (fichier introuvable) : $source_file"
        return 1
    fi

    if [[ ! -d "$BACKUP_DIR" ]]; then
        if ! mkdir -p "$BACKUP_DIR"; then
            log_error "Impossible de créer le répertoire de sauvegarde : $BACKUP_DIR"
            return 1
        fi
        chmod 700 "$BACKUP_DIR"
        log_info "Répertoire de sauvegarde créé : $BACKUP_DIR"
    fi

    local backup_subdir
    backup_subdir="$BACKUP_DIR$(dirname "$source_file")"

    mkdir -p "$backup_subdir"

    local backup_path
    backup_path="${backup_subdir}/$(basename "$source_file")"

    if [[ -e "$backup_path" ]]; then
        backup_path="${backup_path}.$(date +%H%M%S)"
    fi

    if cp -a "$source_file" "$backup_path" 2>/dev/null; then
        log_success "Sauvegarde effectuée pour $description : $source_file"
        log_debug "Emplacement de sauvegarde : $backup_path"
        return 0
    else
        log_error "Échec de la sauvegarde : $source_file"
        return 1
    fi
}

restore_backup() {
    local original_file="$1"
    local backup_path="${BACKUP_DIR}${original_file}"

    if [[ ! -f "$backup_path" ]]; then
        log_error "Aucune sauvegarde trouvée pour : $original_file"
        return 1
    fi

    if cp -a "$backup_path" "$original_file"; then
        log_success "Restauré à partir de la sauvegarde : $original_file"
        return 0
    else
        log_error "Échec de la restauration : $original_file"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# UTILITAIRES BLOCK-DEVICE ET FSTAB
#-------------------------------------------------------------------------------

_validate_block_device() {
    local _dev="$1"
    if [[ -z "$_dev" ]]; then
        log_error "_validate_block_device : chemin vide"
        return 1
    fi
    # Whitelist : seuls /dev/... avec des caractères alphanumériques, -, _, / sont autorisés
    if [[ ! "$_dev" =~ ^/dev/[a-zA-Z0-9_/-]+$ ]]; then
        log_error "Chemin de périphérique invalide (caractères non autorisés) : '$_dev'"
        return 1
    fi
    if [[ ! -b "$_dev" ]]; then
        log_error "N'est pas un périphérique bloc : '$_dev'"
        return 1
    fi
    return 0
}

_resolve_fstab_device() {
    local _spec="$1"
    local _dev=""

    case "$_spec" in
    UUID=*)
        local _uuid="${_spec#UUID=}"
        _dev=$(blkid -l -t "UUID=${_uuid}" -o device 2>/dev/null)
        [[ -z "$_dev" ]] && _dev="/dev/disk/by-uuid/${_uuid}"
        ;;
    PARTUUID=*)
        local _partuuid="${_spec#PARTUUID=}"
        _dev=$(blkid -l -t "PARTUUID=${_partuuid}" -o device 2>/dev/null)
        [[ -z "$_dev" ]] && _dev="/dev/disk/by-partuuid/${_partuuid}"
        ;;
    LABEL=*)
        local _label="${_spec#LABEL=}"
        _dev=$(blkid -l -t "LABEL=${_label}" -o device 2>/dev/null)
        [[ -z "$_dev" ]] && _dev="/dev/disk/by-label/${_label}"
        ;;
    PARTLABEL=*)
        local _plabel="${_spec#PARTLABEL=}"
        _dev=$(blkid -l -t "PARTLABEL=${_plabel}" -o device 2>/dev/null)
        [[ -z "$_dev" ]] && _dev="/dev/disk/by-partlabel/${_plabel}"
        ;;
    /dev/*)
        _dev="$_spec"
        ;;
    *)
        log_error "_resolve_fstab_device : spec non reconnue : '$_spec'"
        return 1
        ;;
    esac

    if [[ -z "$_dev" ]]; then
        log_error "_resolve_fstab_device : impossible de résoudre '$_spec'"
        return 1
    fi

    if [[ -L "$_dev" ]]; then
        _dev=$(readlink -f "$_dev" 2>/dev/null) || true
    fi

    if [[ ! -b "$_dev" ]]; then
        log_error "_resolve_fstab_device : '$_spec' résolu en '$_dev' mais ce n'est pas un block device"
        return 1
    fi

    echo "$_dev"
    return 0
}

check_bash_version() {
    if [[ "${BASH_VERSINFO[0]}" -lt "$MIN_BASH_VERSION" ]]; then
        log_error "Ce script requiert Bash version $MIN_BASH_VERSION ou supérieure"
        log_error "Version actuelle : ${BASH_VERSION}"
        exit 1
    fi
}

cleanup() {
    local exit_code=$?
    log_debug "Nettoyage appelé avec code de sortie : $exit_code"
    rm -f /tmp/Rep-Dem-*.tmp 2>/dev/null
    exit $exit_code
}

trap '_autochroot_cleanup 2>/dev/null; cleanup' EXIT INT TERM

#-------------------------------------------------------------------------------
# MODULE : VÉRIFICATIONS D'ENVIRONNEMENT
#-------------------------------------------------------------------------------
check_root_privileges() {
    log_info "Vérification des privilèges root..."

    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en tant que root"
        echo ""
        echo "Veuillez exécuter avec : sudo ./$SCRIPT_NAME"
        echo "  (Ubuntu/Debian : sudo ./repdem.sh — le compte root est désactivé, su -c ne fonctionne pas)"
        exit 1
    fi

    log_success "Exécution avec les privilèges root (UID : $EUID)"
}

detect_distribution() {
    log_info "Détection de la distribution Linux..."

    if [[ -f /etc/os-release ]]; then
        local _raw_id _raw_version _raw_id_like _raw_pretty
        _raw_id=$(grep -m1 '^ID=' /etc/os-release | cut -d= -f2- | tr -d '"')
        _raw_version=$(grep -m1 '^VERSION_ID=' /etc/os-release | cut -d= -f2- | tr -d '"')
        _raw_id_like=$(grep -m1 '^ID_LIKE=' /etc/os-release | cut -d= -f2- | tr -d '"')
        _raw_pretty=$(grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')
        DISTRO="${_raw_id:-unknown}"
        DISTRO_VERSION="${_raw_version:-unknown}"

        local _id_lower="${_raw_id,,}"
        local _id_like_raw="${_raw_id_like}"
        local _id_like_lower=""
        if [[ -n "$_id_like_raw" ]]; then
            _id_like_lower="${_id_like_raw,,}"
        fi

        _resolve_distro_family() {
            local _id="$1"
            case "$_id" in
            ubuntu | debian | linuxmint | lmde | pop | elementary | zorin | kali | \
                raspbian | mx | neon | pureos | tails | deepin | peppermint | \
                parrot | antix | bodhi | sparky | devuan | crunchbang* | bunsenlabs | \
                lite | xero | buntu | lubuntu | kubuntu | xubuntu | ubuntu-mate)
                DISTRO_FAMILY="debian"
                PKG_MANAGER="apt"
                ;;
            fedora)
                DISTRO_FAMILY="rhel"
                PKG_MANAGER="dnf"
                ;;
            rhel | centos | centos-stream | rocky | alma | almalinux | ol | \
                scientific | eurolinux | navix | oracle | cloudlinux)
                DISTRO_FAMILY="rhel"
                if command_exists dnf; then PKG_MANAGER="dnf"; else PKG_MANAGER="yum"; fi
                ;;
            arch | manjaro | endeavouros | garuda | artix | archcraft | \
                cachyos | arcolinux | crystal | rebornos | bluestar | blackarch | \
                xerolinux | archbang | archlabs)
                DISTRO_FAMILY="arch"
                PKG_MANAGER="pacman"
                ;;
            opensuse* | sles | suse | tumbleweed | leap)
                DISTRO_FAMILY="suse"
                PKG_MANAGER="zypper"
                ;;
            gentoo | calculate | sabayon | funtoo)
                DISTRO_FAMILY="gentoo"
                PKG_MANAGER="emerge"
                ;;
            void)
                DISTRO_FAMILY="void"
                PKG_MANAGER="xbps"
                ;;
            alpine)
                DISTRO_FAMILY="alpine"
                PKG_MANAGER="apk"
                ;;
            slackware*)
                DISTRO_FAMILY="slackware"
                PKG_MANAGER="pkgtool"
                ;;
            *) return 1 ;;
            esac
            return 0
        }

        if ! _resolve_distro_family "$_id_lower"; then
            local _resolved_via_like=false
            for _like_token in $_id_like_lower; do
                if _resolve_distro_family "$_like_token"; then
                    _resolved_via_like=true
                    log_info "Distribution reconnue via ID_LIKE (${_like_token}) : famille=$DISTRO_FAMILY"
                    break
                fi
            done
            if [[ "$_resolved_via_like" == false ]]; then
                DISTRO_FAMILY="unknown"
                if command_exists apt; then
                    PKG_MANAGER="apt"
                    DISTRO_FAMILY="debian"
                elif command_exists dnf; then
                    PKG_MANAGER="dnf"
                    DISTRO_FAMILY="rhel"
                elif command_exists yum; then
                    PKG_MANAGER="yum"
                    DISTRO_FAMILY="rhel"
                elif command_exists pacman; then
                    PKG_MANAGER="pacman"
                    DISTRO_FAMILY="arch"
                elif command_exists zypper; then
                    PKG_MANAGER="zypper"
                    DISTRO_FAMILY="suse"
                elif command_exists apk; then
                    PKG_MANAGER="apk"
                    DISTRO_FAMILY="alpine"
                else
                    PKG_MANAGER="unknown"
                fi
                log_warning "Distribution inconnue : ${_raw_id} (ID_LIKE=${_raw_id_like:-—}). Famille déduite : $DISTRO_FAMILY"
            fi
        fi
        unset -f _resolve_distro_family

        log_success "Détecté : ${_raw_pretty:-$DISTRO} (Famille : $DISTRO_FAMILY)"
        log_info "Gestionnaire de paquets : $PKG_MANAGER"
        ID="$DISTRO"
        PRETTY_NAME="${_raw_pretty:-$DISTRO}"

    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
        DISTRO_FAMILY="debian"
        PKG_MANAGER="apt"
        DISTRO_VERSION=$(cat /etc/debian_version)
        log_success "Détecté : Debian $DISTRO_VERSION"

    elif [[ -f /etc/redhat-release ]]; then
        DISTRO="rhel"
        DISTRO_FAMILY="rhel"
        PKG_MANAGER=$(command_exists dnf && echo "dnf" || echo "yum")
        DISTRO_VERSION=$(cat /etc/redhat-release)
        log_success "Détecté : $DISTRO_VERSION"

    elif [[ -f /etc/arch-release ]]; then
        DISTRO="arch"
        DISTRO_FAMILY="arch"
        PKG_MANAGER="pacman"
        log_success "Détecté : Arch Linux"

    else
        log_warning "Aucun fichier /etc/os-release trouvé — détection par outils disponibles..."
        if [[ -f /etc/debian_version ]]; then
            DISTRO="debian"
            DISTRO_FAMILY="debian"
            PKG_MANAGER="apt"
            DISTRO_VERSION=$(cat /etc/debian_version)
            log_success "Détecté via /etc/debian_version : Debian $DISTRO_VERSION"
        elif [[ -f /etc/redhat-release ]]; then
            DISTRO="rhel"
            DISTRO_FAMILY="rhel"
            PKG_MANAGER=$(command_exists dnf && echo "dnf" || echo "yum")
            DISTRO_VERSION=$(cat /etc/redhat-release)
            log_success "Détecté via /etc/redhat-release : $DISTRO_VERSION"
        elif [[ -f /etc/arch-release ]]; then
            DISTRO="arch"
            DISTRO_FAMILY="arch"
            PKG_MANAGER="pacman"
            log_success "Détecté via /etc/arch-release : Arch Linux"
        elif [[ -f /etc/alpine-release ]]; then
            DISTRO="alpine"
            DISTRO_FAMILY="alpine"
            PKG_MANAGER="apk"
            DISTRO_VERSION=$(cat /etc/alpine-release)
            log_success "Détecté via /etc/alpine-release : Alpine $DISTRO_VERSION"
        elif [[ -f /etc/gentoo-release ]]; then
            DISTRO="gentoo"
            DISTRO_FAMILY="gentoo"
            PKG_MANAGER="emerge"
            log_success "Détecté via /etc/gentoo-release : Gentoo"
        elif [[ -f /etc/void-release ]]; then
            DISTRO="void"
            DISTRO_FAMILY="void"
            PKG_MANAGER="xbps"
            log_success "Détecté via /etc/void-release : Void Linux"
        elif command_exists apt; then
            DISTRO="unknown"
            DISTRO_FAMILY="debian"
            PKG_MANAGER="apt"
            log_warning "Distribution inconnue — famille déduite via apt"
        elif command_exists dnf; then
            DISTRO="unknown"
            DISTRO_FAMILY="rhel"
            PKG_MANAGER="dnf"
            log_warning "Distribution inconnue — famille déduite via dnf"
        elif command_exists yum; then
            DISTRO="unknown"
            DISTRO_FAMILY="rhel"
            PKG_MANAGER="yum"
            log_warning "Distribution inconnue — famille déduite via yum"
        elif command_exists pacman; then
            DISTRO="unknown"
            DISTRO_FAMILY="arch"
            PKG_MANAGER="pacman"
            log_warning "Distribution inconnue — famille déduite via pacman"
        elif command_exists zypper; then
            DISTRO="unknown"
            DISTRO_FAMILY="suse"
            PKG_MANAGER="zypper"
            log_warning "Distribution inconnue — famille déduite via zypper"
        elif command_exists apk; then
            DISTRO="unknown"
            DISTRO_FAMILY="alpine"
            PKG_MANAGER="apk"
            log_warning "Distribution inconnue — famille déduite via apk"
        else
            log_error "Impossible de détecter la distribution Linux"
            log_error "Ce script prend en charge : Debian/Ubuntu, RHEL/Fedora, Arch, openSUSE, Alpine, Gentoo, Void"
            exit 1
        fi
    fi
}

detect_init_system() {
    log_info "Détection du système d'initialisation..."

    if [[ -d /run/systemd/system ]]; then
        log_success "Init system: systemd"
        echo "systemd"
    elif [[ -f /sbin/init ]] && /sbin/init --version 2>&1 | grep -q upstart; then
        log_success "Init system: upstart"
        echo "upstart"
    elif [[ -f /etc/init.d/cron ]] && [[ ! -d /run/systemd/system ]]; then
        log_success "Init system: sysvinit"
        echo "sysvinit"
    elif command_exists openrc; then
        log_success "Init system: OpenRC"
        echo "openrc"
    else
        log_warning "Système d'initialisation : inconnu"
        echo "unknown"
    fi
}

detect_boot_mode() {
    log_info "Détection du mode de démarrage..." >&2

    if [[ -d /sys/firmware/efi ]]; then
        log_success "Boot mode: UEFI" >&2
        echo "uefi"
        return
    fi

    if [[ -d /boot/efi/EFI ]] || [[ -d /efi/EFI ]]; then
        log_warning "Firmware EFI inactif, mais un répertoire EFI existe sur le disque" >&2
        log_success "Boot mode présumé : UEFI" >&2
        echo "uefi"
        return
    fi

    log_success "Boot mode: BIOS/Legacy" >&2
    echo "bios"
}

is_live_environment() {
    [[ -d /run/archiso ]] && return 0
    [[ -d /run/live ]] && return 0
    [[ -d /rofs ]] && return 0
    grep -qE 'boot=casper|boot=live|root=live:' /proc/cmdline 2>/dev/null && return 0
    return 1
}

_require_installed_or_chroot_context() {
    local operation="$1"
    if is_live_environment && [[ "${_INSIDE_CHROOT}" == false ]]; then
        log_error "$operation indisponible depuis le Live hôte"
        log_info "Utilisez d'abord --live-chroot puis relancez l'opération dans le système cible"
        return 1
    fi
    return 0
}

_detect_target_boot_mode() {
    local _chroot_dir="$1"

    if [[ -z "$_chroot_dir" || ! -d "$_chroot_dir" ]]; then
        echo "bios"
        return
    fi

    if [[ -d "$_chroot_dir/sys/firmware/efi/efivars" ]]; then
        echo "uefi"
        return
    fi

    if [[ -d "$_chroot_dir/boot/efi/EFI" ]] || [[ -d "$_chroot_dir/efi/EFI" ]] || [[ -d "$_chroot_dir/boot/EFI" ]]; then
        echo "uefi"
        return
    fi

    echo "bios"
}

detect_btrfs_subvol_root() {
    local device="$1"
    local fstype
    fstype=$(blkid -s TYPE -o value "$device" 2>/dev/null)

    [[ "$fstype" != "btrfs" ]] && return 1

    local tmp_mnt
    tmp_mnt=$(mktemp -d)
    local found_subvol=""

    if mount -o ro "$device" "$tmp_mnt" 2>/dev/null; then
        if command_exists btrfs; then
            while read -r subvol_path; do
                if [[ -f "$tmp_mnt/$subvol_path/etc/os-release" ]] ||
                    [[ -f "$tmp_mnt/$subvol_path/usr/lib/os-release" ]]; then
                    found_subvol="$subvol_path"
                    break
                fi
            done < <(btrfs subvolume list "$tmp_mnt" 2>/dev/null | awk '{print $NF}')

            if [[ -z "$found_subvol" ]]; then
                for subvol in "root" "@" "fedora" "ubuntu"; do
                    if [[ -d "$tmp_mnt/$subvol" ]] && {
                        [[ -f "$tmp_mnt/$subvol/etc/os-release" ]] ||
                            [[ -f "$tmp_mnt/$subvol/usr/lib/os-release" ]]
                    }; then
                        found_subvol="$subvol"
                        break
                    fi
                done
            fi
        fi
        umount "$tmp_mnt"
    fi
    rmdir "$tmp_mnt" 2>/dev/null

    echo "$found_subvol"
    [[ -n "$found_subvol" ]] && return 0 || return 1
}

_detect_btrfs_subvol_for_device() {
    local _dev="$1"
    local _fstab_hint="${2:-}"

    local _fstype
    _fstype=$(blkid -s TYPE -o value "$_dev" 2>/dev/null)
    [[ "$_fstype" != "btrfs" ]] && return 1

    local _tmp_mnt
    _tmp_mnt=$(mktemp -d /tmp/rd_btrfs_XXXXXX)

    if ! mount -o ro,subvolid=5 "$_dev" "$_tmp_mnt" 2>/dev/null; then
        if ! mount -o ro "$_dev" "$_tmp_mnt" 2>/dev/null; then
            rmdir "$_tmp_mnt" 2>/dev/null
            return 1
        fi
    fi

    local _result=""

    if [[ -n "$_fstab_hint" && "$_fstab_hint" != "/" ]]; then
        local _hint_clean="${_fstab_hint#/}"
        if [[ -d "$_tmp_mnt/$_hint_clean" ]]; then
            local _ro_flag
            _ro_flag=$(btrfs subvolume show "$_tmp_mnt/$_hint_clean" 2>/dev/null |
                grep -i "Flags:" | grep -c "readonly" || true)
            if [[ "$_ro_flag" -eq 0 ]]; then
                _result="$_fstab_hint"
            fi
        fi
    fi

    if [[ -z "$_result" ]] && command -v btrfs &>/dev/null; then
        local _default_id _default_path
        _default_id=$(btrfs subvolume get-default "$_tmp_mnt" 2>/dev/null | awk '{print $2}')
        if [[ -n "$_default_id" && "$_default_id" != "5" ]]; then
            _default_path=$(btrfs subvolume list "$_tmp_mnt" 2>/dev/null |
                awk -v id="$_default_id" '$2==id{print $NF}')
            if [[ -n "$_default_path" ]]; then
                if [[ ! "$_default_path" =~ \.snapshots|/snapshot$|timeshift-btrfs ]]; then
                    local _ro
                    _ro=$(btrfs subvolume show "$_tmp_mnt/$_default_path" 2>/dev/null |
                        grep -i "Flags:" | grep -c "readonly" || true)
                    [[ "$_ro" -eq 0 ]] && _result="/$_default_path"
                fi
            fi
        fi
    fi

    if [[ -z "$_result" ]] && command -v btrfs &>/dev/null; then
        while IFS= read -r _sv_path; do
            [[ "$_sv_path" =~ \.snapshots|/snapshot$|timeshift-btrfs ]] && continue
            if [[ -f "$_tmp_mnt/$_sv_path/etc/os-release" ||
                -f "$_tmp_mnt/$_sv_path/usr/lib/os-release" ]]; then
                local _ro
                _ro=$(btrfs subvolume show "$_tmp_mnt/$_sv_path" 2>/dev/null |
                    grep -i "Flags:" | grep -c "readonly" || true)
                if [[ "$_ro" -eq 0 ]]; then
                    _result="/$_sv_path"
                    break
                fi
            fi
        done < <(btrfs subvolume list "$_tmp_mnt" 2>/dev/null | awk '{print $NF}')
    fi

    umount "$_tmp_mnt" 2>/dev/null
    rmdir "$_tmp_mnt" 2>/dev/null

    if [[ -n "$_result" && "$_result" != "/" ]]; then
        echo "$_result"
        return 0
    fi
    return 1
}

detect_bootloader() {
    local found_grub=false found_sd=false

    # Détection systemd-boot (méthodes multiples)

    # 1. Via bootctl
    if command_exists bootctl && bootctl is-installed 2>/dev/null; then
        found_sd=true
    fi

    # 2. Via présence des fichiers sur ESP
    for _esp in /boot/efi /efi /boot; do
        if [[ -d "${_esp}/EFI/systemd" ]] ||
            [[ -f "${_esp}/EFI/systemd/systemd-bootx64.efi" ]] ||
            [[ -f "${_esp}/EFI/systemd/systemd-bootia32.efi" ]]; then
            found_sd=true
            break
        fi
    done

    # 3. Via fichier loader.conf
    for _esp in /boot/efi /efi /boot; do
        if [[ -f "${_esp}/loader/loader.conf" ]]; then
            found_sd=true
            break
        fi
    done

    # 4. Cas spécial Pop!_OS
    if [[ -f /etc/os-release ]]; then
        local _id
        _id=$(grep -m1 '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        if [[ "${_id,,}" == "pop" ]] && [[ -d /sys/firmware/efi ]]; then
            found_sd=true
        fi
    fi

    # 5. Via efibootmgr (dernier recours)
    if command_exists efibootmgr; then
        efibootmgr -v 2>/dev/null | grep -qi 'systemd\|sd-boot\|systemd-boot' && found_sd=true
    fi

    # Détection GRUB
    if [[ -f /boot/grub/grub.cfg ]] || [[ -f /boot/grub2/grub.cfg ]]; then
        found_grub=true
    fi

    if [[ "$found_grub" == false ]] && command_exists efibootmgr; then
        efibootmgr -v 2>/dev/null | grep -qi 'grub' && found_grub=true
    fi

    # Résultat final
    if [[ "$found_sd" == true && "$found_grub" == true ]]; then
        echo "both"
    elif [[ "$found_sd" == true ]]; then
        echo "systemd-boot"
    elif [[ "$found_grub" == true ]]; then
        echo "grub"
    else
        echo "unknown"
    fi
}

#-------------------------------------------------------------------------------
# MODULE : ÉTAT SYSTÈME CENTRALISÉ
#-------------------------------------------------------------------------------

declare -A _SYS_STATE=()

collect_system_state() {
    # Distribution
    _SYS_STATE[DISTRO_FAMILY]="${DISTRO_FAMILY:-unknown}"
    _SYS_STATE[DISTRO]="${DISTRO:-unknown}"
    _SYS_STATE[DISTRO_ID]="${ID:-unknown}"

    # Mode de démarrage
    _SYS_STATE[BOOT_MODE]=$(detect_boot_mode 2>/dev/null || echo "bios")

    # Chargeur d'amorçage
    _SYS_STATE[BOOTLOADER]=$(detect_bootloader 2>/dev/null || echo "unknown")

    # Système de fichiers racine
    local _root_fstype
    _root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null | head -1)
    _SYS_STATE[ROOT_FS]="${_root_fstype:-unknown}"

    # Sous-volume Btrfs
    if [[ "${_root_fstype}" == "btrfs" ]]; then
        local _subvol
        _subvol=$(findmnt -n -o OPTIONS / 2>/dev/null | sed -n 's/.*subvol=\([^,]*\).*/\1/p' | head -1)
        _SYS_STATE[ROOT_SUBVOL]="${_subvol:-/}"
    else
        _SYS_STATE[ROOT_SUBVOL]=""
    fi

    # LUKS (crypttab non vide)
    if grep -qsE '^[^#[:space:]]' /etc/crypttab 2>/dev/null; then
        _SYS_STATE[LUKS]="yes"
    else
        _SYS_STATE[LUKS]="no"
    fi

    # TPM2
    if ls /sys/class/tpm/tpm* &>/dev/null 2>&1 ||
        command -v tpm2_getcap &>/dev/null 2>&1; then
        _SYS_STATE[TPM2]="yes"
    else
        _SYS_STATE[TPM2]="no"
    fi

    # BLS (Boot Loader Specification)
    if [[ -d /boot/loader/entries || -d /boot/efi/loader/entries ||
        -d /efi/loader/entries ]]; then
        _SYS_STATE[BLS]="yes"
    else
        _SYS_STATE[BLS]="no"
    fi

    # UKI (Unified Kernel Image)
    if ls /boot/efi/EFI/Linux/*.efi &>/dev/null 2>&1 ||
        ls /efi/EFI/Linux/*.efi &>/dev/null 2>&1; then
        _SYS_STATE[UKI]="yes"
    else
        _SYS_STATE[UKI]="no"
    fi

    # Ostree / rpm-ostree
    if command -v rpm-ostree &>/dev/null 2>&1 ||
        command -v ostree &>/dev/null 2>&1 ||
        [[ -d /ostree/deploy ]]; then
        _SYS_STATE[OSTREE]="yes"
    else
        _SYS_STATE[OSTREE]="no"
    fi

    # Machine-id
    local _mid
    #_mid=$(cat /etc/machine-id 2>/dev/null | tr -d '[:space:]')
    _mid=$(tr -d '[:space:]' </etc/machine-id 2>/dev/null)
    _SYS_STATE[MACHINE_ID]="${_mid:-unknown}"

    # Init system
    _SYS_STATE[INIT]=$(detect_init_system 2>/dev/null || echo "unknown")

    # Architecture EFI
    if [[ "${_SYS_STATE[BOOT_MODE]}" == "uefi" ]]; then
        _SYS_STATE[EFI_ARCH]=$(detect_efi_arch 2>/dev/null || echo "x86_64-efi")
    else
        _SYS_STATE[EFI_ARCH]=""
    fi

    log_debug "collect_system_state: $(declare -p _SYS_STATE)"
}

sys_state() {
    local _key="$1"
    if [[ -v _SYS_STATE["$_key"] ]]; then
        echo "${_SYS_STATE[$_key]}"
        return 0
    fi
    log_debug "sys_state: clé inconnue '$_key'"
    return 1
}

initialize_logging() {
    local chosen_log=""
    local candidate
    local log_dir
    local -a candidates=(
        "${LOG_FILE}"
        "/var/tmp/Rep-Dem.log"
        "/tmp/Rep-Dem.log"
    )

    for candidate in "${candidates[@]}"; do
        log_dir=$(dirname "$candidate")
        [[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null || true
        if touch "$candidate" 2>/dev/null; then
            chosen_log="$candidate"
            break
        fi
    done

    if [[ -z "$chosen_log" ]]; then
        LOG_FILE=""
        log_warning "Impossible d'initialiser un fichier journal (ni /var/log, ni /var/tmp, ni /tmp)"
        return 0
    fi

    LOG_FILE="$chosen_log"
    chmod 644 "$LOG_FILE" 2>/dev/null || true
    if [[ "$(dirname "$LOG_FILE")" == "/var/log/repdem" ]]; then
        chmod 755 "/var/log/repdem" 2>/dev/null || true
    fi
    log_info "Fichier journal initialisé : $LOG_FILE"

    {
        echo ""
        echo "==============================================================================="
        echo "Session started: $(get_timestamp)"
        echo "Version du script : $SCRIPT_VERSION"
        echo "==============================================================================="
    } >>"$LOG_FILE" 2>/dev/null
}

run_environment_checks() {
    log_header "VÉRIFICATIONS D'ENVIRONNEMENT"

    check_bash_version
    check_root_privileges
    detect_distribution
    detect_init_system >/dev/null
    detect_boot_mode >/dev/null
    if [[ "$ANALYZE_MODE" != true ]]; then
        initialize_logging
    fi

    collect_system_state

    if [[ "$ANALYZE_MODE" != true ]]; then
        log_subheader "Informations système"
        log_info "Kernel : $(uname -r)"
        log_info "Architecture : $(uname -m)"
        log_info "Nom d'hôte : $(hostname)"
        echo ""
        printf "%b\n" "${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
        printf "%b  %-60s%b\n" "${BOLD}${CYAN}│${NC}" "Sauvegardes  :  $BACKUP_DIR" "${BOLD}${CYAN}│${NC}"
        printf "%b  %-60s%b\n" "${BOLD}${CYAN}│${NC}" "Journaux     :  $LOG_FILE" "${BOLD}${CYAN}│${NC}"
        printf "%b\n" "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""
    fi

    mark_operation_completed "environment_checks"
}

generate_raw_report() {
    if [[ -n "$OUTPUT_FILE" ]]; then
        prepare_output_file "$OUTPUT_FILE"
    fi

    report_section "SYSTEM"
    report_command "uname -a"
    report_command "hostname"
    report_command "cat /etc/os-release"
    report_command "uname -m"
    report_command "uname -r"
    report_command "grep -m1 'model name' /proc/cpuinfo"
    report_command "free -h"
    report_command "cat /proc/meminfo | head -5"

    report_section "DISKS"
    report_command "lsblk -f"
    report_command "lsblk -o NAME,FSTYPE,MOUNTPOINT,SIZE,UUID,LABEL,PARTUUID"
    report_command "cat /proc/partitions"
    report_command "fdisk -l"
    report_command "parted -l"
    report_command "blkid"
    report_command "df -hT"
    report_command "findmnt --fstab --raw"
    if command_exists sgdisk; then
        while read -r disk; do
            report_line "sgdisk --print /dev/$disk"
            sgdisk --print "/dev/$disk" 2>/dev/null || report_line "indisponible"
        done < <(lsblk -dn -o NAME 2>/dev/null | grep -vE '^(loop|ram)')
    fi

    report_section "BOOT-INFO"
    report_command "cat /proc/cmdline"
    report_line "--- EFI entries ---"
    report_command "efibootmgr -v"
    report_line "--- EFI partition ---"
    report_command "findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS /boot/efi"
    report_command "findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS /efi"
    report_command "ls -la /boot/efi/EFI"
    report_command "ls -la /efi/EFI"
    report_line "--- GRUB config ---"
    report_command "cat /boot/grub/grub.cfg"
    report_command "cat /boot/grub2/grub.cfg"
    report_line "--- MBR signature ---"
    if command_exists hexdump || command_exists xxd; then
        while read -r disk; do
            report_line "MBR /dev/$disk:"
            portable_hexdump "/dev/$disk" | tail -4 || report_line "indisponible"
        done < <(lsblk -dn -o NAME 2>/dev/null | grep -vE '^(loop|ram|zram)')
    fi

    report_section "WINDOWS/BCD"
    report_command "lsblk -f | grep -i ntfs"
    report_command "blkid | grep -i ntfs"
    report_command "ls /boot/efi/EFI 2>/dev/null | grep -i Microsoft || echo 'Aucune entrée Microsoft EFI détectée'"
    report_command "ls /efi/EFI 2>/dev/null | grep -i Microsoft || echo 'Aucune entrée Microsoft EFI détectée'"
    report_command "find /boot/efi -maxdepth 4 -type f | grep -i 'bootmgfw.efi\|bcd' 2>/dev/null || echo 'Aucun fichier Windows BCD/bootmgfw.efi trouvé'"
    report_command "find /efi -maxdepth 4 -type f | grep -i 'bootmgfw.efi\|bcd' 2>/dev/null || echo 'Aucun fichier Windows BCD/bootmgfw.efi trouvé'"

    report_section "GRUB"
    report_command "command -v grub-install"
    report_command "command -v grub2-install"
    report_command "grub-install --version"
    report_command "grub2-install --version"
    report_command "cat /etc/default/grub"
    report_command "ls -l /etc/grub.d"
    report_command "findmnt -n -o SOURCE /boot/grub"
    report_command "findmnt -n -o SOURCE /boot/grub2"

    report_section "SECUREBOOT"
    report_command "mokutil --sb-state"
    report_command "sbctl status"
    report_command "dmesg | grep -iE 'secureboot|efi' | tail -20"

    report_section "TPM"
    report_command "ls /sys/class/tpm/"
    report_command "dmesg | grep -i tpm | tail -20"
    report_command "tpm2_getcap -l"

    report_section "LUKS"
    report_command "lsblk -f | grep crypto_LUKS"
    report_command "cat /etc/crypttab"
    report_command "dmsetup table"

    report_section "RAID"
    report_command "cat /proc/mdstat"
    if command_exists mdadm; then
        report_command "mdadm --detail --scan"
        while read -r arr; do
            report_line "mdadm --detail $arr"
            mdadm --detail "$arr" 2>/dev/null || report_line "indisponible"
        done < <(mdadm --detail --scan 2>/dev/null | grep -oE '/dev/md\w+')
    fi

    report_section "FILESYSTEM"
    report_command "pvs"
    report_command "vgs"
    report_command "lvs"
    report_command "dmsetup table"
    report_command "findmnt -n -o SOURCE -t ext2,ext3,ext4 | sort -u | while read -r dev; do tune2fs -l \"\$dev\" 2>/dev/null || echo indisponible; done"
    report_command "findmnt -n -t xfs -o TARGET | while read -r mnt; do xfs_info \"\$mnt\" 2>/dev/null || echo indisponible; done"
    report_command "btrfs filesystem show"
    report_command "command -v f2fs > /dev/null && findmnt -n -t f2fs -o SOURCE | while read -r dev; do f2fs info \"\$dev\" 2>/dev/null || echo indisponible; done"
    report_command "zpool status"
    report_command "lsblk -f | grep -E 'vfat|ntfs'"
    report_command "blkid | grep -E 'TYPE=\"(vfat|ntfs)\"'"
    report_command "lsblk -f | grep crypto_LUKS"
    report_command "cat /etc/crypttab"
    report_command "cat /etc/fstab"
    report_command "command -v genfstab"
    report_command "zramctl --output-all"
    report_command "cat /sys/block/zram*/comp_algorithm"
    report_command "ls /sys/block/zram0 > /dev/null 2>&1 && cat /sys/block/zram*/comp_algorithm || echo 'zram non activé'"
    report_command "swapon --show"
    report_command "findmnt --fstab --raw"
    report_command "lsblk -o NAME,FSTYPE,MOUNTPOINT,SIZE,UUID"

    report_section "LOGS"
    report_command "journalctl -p 3 -xb --no-pager -n 50"
    report_command "dmesg | tail -50"
}

#-------------------------------------------------------------------------------
# MODULE : RÉPARATION BOOT
#-------------------------------------------------------------------------------
detect_boot_device() {
    local boot_device=""
    local boot_partition=""

    log_info "Détection du périphérique de démarrage..." >&2

    if [[ -d /sys/firmware/efi ]]; then
        boot_partition=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null | head -1)
        if [[ -z "$boot_partition" ]]; then
            boot_partition=$(findmnt -n -o SOURCE /boot 2>/dev/null | head -1)
        fi
    fi

    if [[ -z "$boot_partition" ]]; then
        boot_partition=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
    fi

    # Détection du sous-volume BTRFS si nécessaire
    local btrfs_subvol=""
    if [[ -n "$boot_partition" ]]; then
        local fstype
        fstype=$(blkid -s TYPE -o value "$boot_partition" 2>/dev/null)
        if [[ "$fstype" == "btrfs" ]] && command_exists btrfs; then
            btrfs_subvol=$(_detect_btrfs_subvol_for_device "$boot_partition") || true
            if [[ -n "$btrfs_subvol" ]]; then
                log_info "Sous-volume BTRFS détecté : $btrfs_subvol" >&2
                export DETECTED_BTRFS_SUBVOL="$btrfs_subvol"
            fi
        fi
    fi

    if [[ -n "$boot_partition" ]]; then
        boot_device=$(_resolve_grub_target_disk "$boot_partition")
    fi

    if [[ -n "$boot_device" ]] && [[ -b "$boot_device" ]]; then
        log_info "Périphérique de démarrage détecté : $boot_device" >&2
        echo "$boot_device"
    else
        log_warning "Impossible de détecter automatiquement le périphérique de démarrage" >&2
        echo ""
    fi
}

_resolve_grub_target_disk() {
    local _node="$1"
    local _depth=0

    [[ -z "$_node" ]] && return 1

    while [[ $_depth -lt 10 ]]; do
        [[ -b "$_node" ]] || return 1

        case "$_node" in
        /dev/sd[a-z] | /dev/vd[a-z] | /dev/xvd[a-z] | /dev/nvme[0-9]n[0-9] | /dev/mmcblk[0-9])
            echo "$_node"
            return 0
            ;;
        esac

        local _type
        _type=$(lsblk -no TYPE "$_node" 2>/dev/null | head -1)
        if [[ "$_type" == "disk" ]]; then
            echo "$_node"
            return 0
        fi

        local _pk
        _pk=$(lsblk -no PKNAME "$_node" 2>/dev/null | head -1)
        if [[ -n "$_pk" ]]; then
            _node="/dev/${_pk}"
        else
            local _real
            _real=$(readlink -f "$_node" 2>/dev/null || true)
            if [[ -n "$_real" && "$_real" != "$_node" ]]; then
                _node="$_real"
            else
                break
            fi
        fi
        _depth=$((_depth + 1))
    done

    return 1
}

_build_chroot_initramfs_refresh_cmd() {
    local _chroot_dir="$1"

    if chroot "$_chroot_dir" command -v update-initramfs >/dev/null 2>&1; then
        echo "update-initramfs -u -k all 2>/dev/null"
        return
    fi
    if chroot "$_chroot_dir" command -v mkinitcpio >/dev/null 2>&1; then
        echo "mkinitcpio -P 2>/dev/null"
        return
    fi
    if chroot "$_chroot_dir" command -v dracut >/dev/null 2>&1; then
        echo "dracut --force --regenerate-all 2>/dev/null"
        return
    fi
    if chroot "$_chroot_dir" command -v mkinitrd >/dev/null 2>&1; then
        echo "mkinitrd 2>/dev/null"
        return
    fi
    if chroot "$_chroot_dir" command -v mkinitfs >/dev/null 2>&1; then
        echo "mkinitfs -F 2>/dev/null"
        return
    fi
    if chroot "$_chroot_dir" command -v genkernel >/dev/null 2>&1; then
        echo "genkernel initramfs 2>/dev/null"
        return
    fi
    if chroot "$_chroot_dir" command -v xbps-reconfigure >/dev/null 2>&1; then
        echo "xbps-reconfigure -fa 2>/dev/null"
        return
    fi

    echo "true"
}

backup_grub_configuration() {
    echo ""
    printf "%b\n" "${YELLOW}${BOLD}[BACKUP]${NC} Configuration GRUB → ${BACKUP_DIR}/etc/"

    local grub_files=(
        "/etc/default/grub"
        "/boot/grub/grub.cfg"
        "/boot/grub2/grub.cfg"
    )

    for file in "${grub_files[@]}"; do
        if [[ -f "$file" ]]; then
            backup_file "$file" "Configuration GRUB"
            log_success "  sauvegardé : $file"
        fi
    done

    if [[ -d /etc/grub.d ]]; then
        local backup_target="${BACKUP_DIR}/etc/grub.d"
        mkdir -p "$backup_target"
        cp -a /etc/grub.d/* "$backup_target/" 2>/dev/null
        log_success "  sauvegardé : /etc/grub.d/ → ${backup_target}"
    fi

    printf "%b\n" "${GREEN}${BOLD}[BACKUP OK]${NC} Config GRUB sauvegardée dans : ${BACKUP_DIR}/etc/"
    echo ""
}

backup_partition_tables() {
    local bpt_dir="${BACKUP_DIR}/partition-tables"
    mkdir -p "$bpt_dir"
    echo ""
    printf "%b\n" "${YELLOW}${BOLD}[BACKUP]${NC} Tables de partitions → ${bpt_dir}"
    while read -r disk; do
        local dev="/dev/$disk"
        [[ ! -b "$dev" ]] && continue
        command_exists sgdisk && sgdisk --backup="${bpt_dir}/${disk}-sgdisk.bin" "$dev" 2>/dev/null &&
            log_success "  sgdisk  : ${bpt_dir}/${disk}-sgdisk.bin"
        command_exists sfdisk && sfdisk --dump "$dev" >"${bpt_dir}/${disk}-sfdisk.dump" 2>/dev/null &&
            log_success "  sfdisk  : ${bpt_dir}/${disk}-sfdisk.dump"
        dd if="$dev" of="${bpt_dir}/${disk}-mbr512.bin" bs=512 count=1 status=none 2>/dev/null &&
            log_success "  MBR 512B: ${bpt_dir}/${disk}-mbr512.bin"
    done < <(lsblk -dn -o NAME 2>/dev/null | grep -vE '^(loop|ram)')
    echo ""
    printf "%b\n" "${GREEN}${BOLD}[BACKUP OK]${NC} Tables sauvegardées dans : ${bpt_dir}"
    echo ""
}

#-------------------------------------------------------------------------------
# MODULE : DÉTECTION ARCHITECTURE EFI
#-------------------------------------------------------------------------------
detect_efi_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
    x86_64) echo "x86_64-efi" ;;
    aarch64 | arm64) echo "arm64-efi" ;;
    armv7l | armhf) echo "arm-efi" ;;
    riscv64) echo "riscv64-efi" ;;
    loongarch64) echo "loongarch64-efi" ;;
    *)
        log_warning "Architecture inconnue : $machine — utilisation de x86_64-efi par défaut" >&2
        echo "x86_64-efi"
        ;;
    esac
}

detect_efi_binary_name() {
    local machine
    machine=$(uname -m)
    case "$machine" in
    x86_64) echo "grubx64.efi" ;;
    aarch64 | arm64) echo "grubaa64.efi" ;;
    armv7l | armhf) echo "grubarm.efi" ;;
    riscv64) echo "grubriscv64.efi" ;;
    *) echo "grubx64.efi" ;;
    esac
}

detect_shim_packages() {
    local machine
    machine=$(uname -m)
    case "$DISTRO_FAMILY" in
    debian)
        case "$machine" in
        x86_64) echo "shim-signed grub-efi-amd64-signed grub-efi-amd64" ;;
        aarch64 | arm64) echo "shim-signed grub-efi-arm64-signed grub-efi-arm64" ;;
        *) echo "grub-efi-${machine}" ;;
        esac
        ;;
    rhel)
        case "$machine" in
        x86_64) echo "shim-x64 grub2-efi-x64" ;;
        aarch64 | arm64) echo "shim-aa64 grub2-efi-aa64" ;;
        *) echo "grub2-efi" ;;
        esac
        ;;
    arch)
        echo "grub efibootmgr"
        ;;
    *)
        echo ""
        ;;
    esac
}

check_esp_offset_arm() {
    local efi_dir="$1"
    local machine
    machine=$(uname -m)

    [[ "$machine" != "aarch64" && "$machine" != "arm64" ]] && return 0

    local esp_dev
    esp_dev=$(findmnt -n -o SOURCE "$efi_dir" 2>/dev/null | head -1)
    if [[ -z "$esp_dev" || ! -b "$esp_dev" ]]; then
        log_warning "ARM ESP check: périphérique ESP introuvable sur $efi_dir — vérification ignorée"
        return 0
    fi

    local esp_name disk_name
    esp_name=$(basename "$esp_dev")
    disk_name=$(lsblk -no PKNAME "$esp_dev" 2>/dev/null | head -1)
    if [[ -z "$disk_name" ]]; then
        log_warning "ARM ESP check: disque parent de $esp_dev introuvable"
        return 0
    fi

    local start_path="/sys/block/${disk_name}/${esp_name}/start"
    if [[ ! -r "$start_path" ]]; then
        log_warning "ARM ESP check: $start_path illisible — vérification ignorée"
        return 0
    fi

    local start_sectors start_bytes start_mb
    start_sectors=$(cat "$start_path")
    start_bytes=$((start_sectors * 512))
    start_mb=$((start_bytes / 1024 / 1024))

    local limit_mb=256
    local limit_bytes=$((limit_mb * 1024 * 1024))

    if [[ "$start_bytes" -gt "$limit_bytes" ]]; then
        echo ""
        printf "%b\n" "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${YELLOW}${BOLD}║  AVERTISSEMENT ARM — Contrainte offset ESP (Tianocore / RPi)    ║${NC}"
        printf "%b\n" "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        printf "%b\n" "${YELLOW}  L'ESP ($esp_dev) démarre à ${start_mb} Mo sur /dev/${disk_name}.${NC}"
        printf "%b\n" "${YELLOW}  Certains firmwares ARM (Raspberry Pi Tianocore, Ampere eMAG...)${NC}"
        printf "%b\n" "${YELLOW}  exigent que l'ESP soit dans les ${limit_mb} premiers Mo du disque.${NC}"
        printf "%b\n" "${YELLOW}  Offset actuel : ${start_mb} Mo > ${limit_mb} Mo → risque de non-démarrage.${NC}"
        echo ""
        echo "  Solutions :"
        echo "    1) Repartitionner pour placer l'ESP avant ${limit_mb} Mo"
        echo "       (nécessite un live USB + sauvegarde préalable)"
        echo "    2) Mettre à jour le firmware UEFI (les versions récentes Tianocore"
        echo "       peuvent ne plus avoir cette limite)"
        echo "    3) Continuer — si votre firmware ne souffre pas de cette contrainte"
        echo ""
        if ! confirm_action "Continuer l'installation de GRUB malgré l'offset ESP > ${limit_mb} Mo ?" yes; then
            return 1
        fi
    else
        log_info "ARM ESP check: offset OK — $esp_dev à ${start_mb} Mo sur /dev/${disk_name} (< ${limit_mb} Mo)"
    fi

    return 0
}

# SUSE / openSUSE
reinstall_grub_suse() {
    local boot_device="$1"
    log_info "Réinstallation GRUB pour SUSE/openSUSE..."
    local boot_mode
    boot_mode=$(detect_boot_mode)
    local efi_target
    efi_target=$(detect_efi_arch)
    if [[ "$boot_mode" == "uefi" ]]; then
        local machine
        machine=$(uname -m)
        case "$machine" in
        x86_64) zypper install --force grub2 grub2-x86_64-efi shim efibootmgr ;;
        aarch64) zypper install --force grub2 grub2-arm64-efi shim efibootmgr ;;
        *) zypper install --force grub2 efibootmgr ;;
        esac
        local efi_dir="/boot/efi"
        [[ ! -d "$efi_dir/EFI" ]] && efi_dir="/efi"
        grub2-install --target="$efi_target" --efi-directory="$efi_dir" \
            --bootloader-id=grub --recheck || {
            log_error "Échec grub2-install SUSE UEFI"
            return 1
        }
    else
        zypper install --force grub2 grub2-i386-pc
        grub2-install --target=i386-pc --recheck "$boot_device" || {
            log_error "Échec grub2-install SUSE BIOS"
            return 1
        }
    fi

    # Gestion BTRFS pour SUSE
    if [[ -n "${DETECTED_BTRFS_SUBVOL:-}" ]]; then
        if [[ "${DETECTED_BTRFS_SUBVOL}" =~ [^a-zA-Z0-9/_@.-] ]]; then
            log_warning "Nom de sous-volume Btrfs invalide : '${DETECTED_BTRFS_SUBVOL}' — rootflags non injecté"
        elif [[ -f /etc/default/grub ]]; then
            if ! grep -qE "rootflags=subvol=" /etc/default/grub; then
                if grep -qE '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                elif grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                fi
            fi
        fi
    fi

    grub2-mkconfig -o /boot/grub2/grub.cfg
}

# Gentoo
reinstall_grub_gentoo() {
    local boot_device="$1"
    log_info "Réinstallation GRUB pour Gentoo..."
    local boot_mode
    boot_mode=$(detect_boot_mode)
    local efi_target
    efi_target=$(detect_efi_arch)
    if [[ "$boot_mode" == "uefi" ]]; then
        log_info "Gentoo UEFI — GRUB_PLATFORMS=efi-64 emerge grub"
        GRUB_PLATFORMS="efi-64" emerge --noreplace sys-boot/grub
        local efi_dir="/boot/efi"
        [[ ! -d "$efi_dir/EFI" ]] && efi_dir="/efi"
        grub-install --target="$efi_target" --efi-directory="$efi_dir" \
            --bootloader-id=GRUB --recheck || {
            log_error "Échec grub-install Gentoo UEFI"
            return 1
        }
    else
        log_info "Gentoo BIOS — emerge grub"
        GRUB_PLATFORMS="pc" emerge --noreplace sys-boot/grub
        grub-install --target=i386-pc --recheck "$boot_device" || {
            log_error "Échec grub-install Gentoo BIOS"
            return 1
        }
    fi

    # Gestion BTRFS pour Gentoo
    if [[ -n "${DETECTED_BTRFS_SUBVOL:-}" ]]; then
        if [[ "${DETECTED_BTRFS_SUBVOL}" =~ [^a-zA-Z0-9/_@.-] ]]; then
            log_warning "Nom de sous-volume Btrfs invalide : '${DETECTED_BTRFS_SUBVOL}' — rootflags non injecté"
        elif [[ -f /etc/default/grub ]]; then
            if ! grep -qE "rootflags=subvol=" /etc/default/grub; then
                if grep -qE '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                elif grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                fi
            fi
        fi
    fi

    grub-mkconfig -o /boot/grub/grub.cfg
}

# Void Linux
reinstall_grub_void() {
    local boot_device="$1"
    log_info "Réinstallation GRUB pour Void Linux..."
    local boot_mode
    boot_mode=$(detect_boot_mode)
    local efi_target
    efi_target=$(detect_efi_arch)
    if [[ "$boot_mode" == "uefi" ]]; then
        log_info "Void UEFI — installation grub-x86_64-efi + efibootmgr"
        xbps-install -y "grub-${efi_target%%-efi}"-efi efibootmgr
        local efi_dir="/boot/efi"
        [[ ! -d "$efi_dir/EFI" ]] && efi_dir="/efi"
        grub-install --target="$efi_target" --efi-directory="$efi_dir" \
            --bootloader-id=GRUB --recheck || {
            log_error "Échec grub-install Void UEFI"
            return 1
        }
    else
        log_info "Void BIOS — installation grub"
        xbps-install -y grub
        grub-install --target=i386-pc --recheck "$boot_device" || {
            log_error "Échec grub-install Void BIOS"
            return 1
        }
    fi

    # Gestion BTRFS pour Void
    if [[ -n "${DETECTED_BTRFS_SUBVOL:-}" ]]; then
        if [[ "${DETECTED_BTRFS_SUBVOL}" =~ [^a-zA-Z0-9/_@.-] ]]; then
            log_warning "Nom de sous-volume Btrfs invalide : '${DETECTED_BTRFS_SUBVOL}' — rootflags non injecté"
        elif [[ -f /etc/default/grub ]]; then
            if ! grep -qE "rootflags=subvol=" /etc/default/grub; then
                if grep -qE '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                elif grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                fi
            fi
        fi
    fi

    if command_exists update-grub; then
        update-grub
    else
        grub-mkconfig -o /boot/grub/grub.cfg
    fi
}

# Alpine
reinstall_grub_alpine() {
    local boot_device="$1"
    log_info "Réinstallation GRUB pour Alpine Linux..."
    local boot_mode
    boot_mode=$(detect_boot_mode)
    local efi_target
    efi_target=$(detect_efi_arch)
    if [[ "$boot_mode" == "uefi" ]]; then
        log_info "Alpine UEFI — installation grub-efi + efibootmgr"
        apk add grub-efi efibootmgr
        local efi_dir="/boot/efi"
        [[ ! -d "$efi_dir/EFI" ]] && efi_dir="/efi"
        grub-install --target="$efi_target" --efi-directory="$efi_dir" \
            --bootloader-id=GRUB --recheck || {
            log_error "Échec grub-install Alpine UEFI"
            return 1
        }
    else
        log_info "Alpine BIOS — installation grub-bios"
        apk add grub-bios
        grub-install --target=i386-pc --recheck "$boot_device" || {
            log_error "Échec grub-install Alpine BIOS"
            return 1
        }
    fi

    # Gestion BTRFS pour Alpine
    if [[ -n "${DETECTED_BTRFS_SUBVOL:-}" ]]; then
        if [[ "${DETECTED_BTRFS_SUBVOL}" =~ [^a-zA-Z0-9/_@.-] ]]; then
            log_warning "Nom de sous-volume Btrfs invalide : '${DETECTED_BTRFS_SUBVOL}' — rootflags non injecté"
        elif [[ -f /etc/default/grub ]]; then
            if ! grep -qE "rootflags=subvol=" /etc/default/grub; then
                if grep -qE '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                elif grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                fi
            fi
        fi
    fi

    grub-mkconfig -o /boot/grub/grub.cfg ||
        update-grub 2>/dev/null || true
}

reinstall_grub_debian() {
    local boot_device="$1"
    local boot_mode
    boot_mode=$(detect_boot_mode)
    local efi_target
    efi_target=$(detect_efi_arch)

    log_info "Réinstallation de GRUB pour système Debian (cible EFI : $efi_target)..."

    apt-get update -qq

    if [[ "$boot_mode" == "uefi" ]]; then
        log_info "Installation de GRUB pour UEFI..."
        local shim_pkgs
        shim_pkgs=$(detect_shim_packages)
        if [[ -n "$shim_pkgs" ]]; then
            log_info "Paquets UEFI : $shim_pkgs"
            # shellcheck disable=SC2086
            apt-get install --reinstall -y $shim_pkgs 2>&1 | while read -r line; do
                log_debug "$line"
            done
        fi

        local efi_dir="/boot/efi"
        [[ ! -d "$efi_dir/EFI" ]] && efi_dir="/efi"
        if [[ ! -d "$efi_dir" ]]; then
            log_error "Répertoire EFI introuvable"
            return 1
        fi

        check_esp_offset_arm "$efi_dir" || return 1
        grub-install --target="$efi_target" --efi-directory="$efi_dir" \
            --bootloader-id="GRUB" --recheck 2>&1 || {
            log_error "Échec de grub-install (target=$efi_target)"
            return 1
        }
    else
        log_info "Installation de GRUB pour BIOS/Legacy..."
        apt-get install --reinstall -y grub-pc 2>&1 | while read -r line; do
            log_debug "$line"
        done
        grub-install --target=i386-pc --recheck "$boot_device" 2>&1 || {
            log_error "Échec de grub-install BIOS"
            return 1
        }
    fi

    # ===== Gestion BTRFS pour Debian/Ubuntu =====
    if [[ -n "${DETECTED_BTRFS_SUBVOL:-}" ]]; then
        log_info "Configuration BTRFS détectée : sous-volume '${DETECTED_BTRFS_SUBVOL}'"
        if [[ "${DETECTED_BTRFS_SUBVOL}" =~ [^a-zA-Z0-9/_@.-] ]]; then
            log_warning "Nom de sous-volume Btrfs invalide : '${DETECTED_BTRFS_SUBVOL}' — rootflags non injecté"
        elif [[ -f /etc/default/grub ]]; then
            if ! grep -qE "rootflags=subvol=" /etc/default/grub; then
                log_info "Ajout de rootflags=subvol=${DETECTED_BTRFS_SUBVOL} à /etc/default/grub"
                if grep -qE '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                elif grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                fi
            fi
        fi
    fi
    # ===== FIN GESTION BTRFS =====

    log_info "Regenerating GRUB configuration..."
    update-grub 2>&1 || {
        log_error "Échec de update-grub"
        return 1
    }

    return 0
}

reinstall_grub_rhel() {
    local boot_device="$1"
    local boot_mode
    boot_mode=$(detect_boot_mode)
    local efi_target
    efi_target=$(detect_efi_arch)

    log_info "Réinstallation de GRUB pour système RHEL (cible EFI : $efi_target)..."

    if [[ "$boot_mode" == "uefi" ]]; then
        log_info "Installation de GRUB pour UEFI..."

        # Détection automatique du répertoire EFI
        local efi_dir=""
        for d in "/boot/efi" "/efi" "/boot"; do
            if [[ -d "$d" ]] && (mountpoint -q "$d" 2>/dev/null || grep -q "$d" /proc/mounts 2>/dev/null); then
                efi_dir="$d"
                break
            fi
        done

        if [[ -z "$efi_dir" ]]; then
            log_error "Aucune partition EFI montée trouvée"
            return 1
        fi

        log_info "Partition EFI détectée : $efi_dir"

        local sb_active=false
        if command_exists mokutil; then
            mokutil --sb-state 2>/dev/null | grep -qi "enabled" && sb_active=true
        fi

        if [[ "$sb_active" == "true" ]]; then
            log_info "Secure Boot actif - installation des paquets signés"
            $PKG_MANAGER reinstall -y shim-x64 grub2-efi-x64 2>&1 | while read -r line; do
                log_debug "$line"
            done
        else
            log_info "Secure Boot inactif - installation standard"
            $PKG_MANAGER reinstall -y grub2-efi-x64 2>&1 | while read -r line; do
                log_debug "$line"
            done
        fi

        local grub_target="${efi_dir}/EFI/GRUB"
        mkdir -p "$grub_target"

        # Tentative 1 : installation avec --force (nécessaire sur certaines Fedora)
        if grub2-install --target="$efi_target" --efi-directory="$efi_dir" \
            --bootloader-id=GRUB --force --recheck 2>&1; then
            log_success "GRUB installé avec succès (--force)"
        else
            log_warning "Première tentative échouée - tentative avec --removable"
            # Tentative 2 : mode removable (plus tolérant)
            if grub2-install --target="$efi_target" --efi-directory="$efi_dir" \
                --bootloader-id=GRUB --removable --recheck 2>&1; then
                log_success "GRUB installé en mode removable"
            else
                log_error "Échec de grub2-install"
                return 1
            fi
        fi

        # S'assurer que le chemin bootx64.efi existe (fallback UEFI)
        local fallback_target="${efi_dir}/EFI/BOOT/BOOTX64.EFI"
        local grub_target_file="${efi_dir}/EFI/GRUB/grubx64.efi"
        if [[ -f "$grub_target_file" ]] && [[ ! -f "$fallback_target" ]]; then
            mkdir -p "$(dirname "$fallback_target")"
            cp "$grub_target_file" "$fallback_target" 2>/dev/null
            log_info "Fallback EFI créé : $fallback_target"
        fi

    else
        log_info "Installation de GRUB pour BIOS/Legacy..."
        $PKG_MANAGER reinstall -y grub2-pc 2>&1 | while read -r line; do
            log_debug "$line"
        done
        grub2-install --target=i386-pc --recheck "$boot_device" 2>&1 || {
            log_error "Échec de grub2-install BIOS"
            return 1
        }
    fi

    # ===== Gestion BTRFS =====
    # Le noyau Linux ignore subvol= dans un remount — ne jamais tenter remount /
    if [[ -n "${DETECTED_BTRFS_SUBVOL:-}" ]]; then
        log_info "Configuration BTRFS détectée : sous-volume '${DETECTED_BTRFS_SUBVOL}'"
        if [[ "${DETECTED_BTRFS_SUBVOL}" =~ [^a-zA-Z0-9/_@.-] ]]; then
            log_warning "Nom de sous-volume Btrfs invalide : '${DETECTED_BTRFS_SUBVOL}' — rootflags non injecté"
        elif [[ -f /etc/default/grub ]]; then
            if ! grep -qE "rootflags=subvol=" /etc/default/grub; then
                log_info "Ajout de rootflags=subvol=${DETECTED_BTRFS_SUBVOL} à /etc/default/grub"
                if grep -qE '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" \
                        /etc/default/grub
                elif grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" \
                        /etc/default/grub
                fi
            else
                log_info "rootflags=subvol déjà présent dans /etc/default/grub"
            fi
        fi
    fi
    # ===== FIN Gestion BTRFS =====

    log_info "Regenerating GRUB configuration..."
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 || {
        log_error "Échec de grub2-mkconfig"
        return 1
    }

    return 0
}

reinstall_grub_arch() {
    local boot_device="$1"
    local boot_mode
    boot_mode=$(detect_boot_mode)
    local efi_target
    efi_target=$(detect_efi_arch)

    log_info "Réinstallation de GRUB pour système Arch (cible EFI : $efi_target)..."

    local grub_pkgs
    grub_pkgs=$(detect_shim_packages)
    # shellcheck disable=SC2086
    pacman -S --noconfirm --needed ${grub_pkgs:-grub efibootmgr} 2>&1 | while read -r line; do
        log_debug "$line"
    done

    if [[ "$boot_mode" == "uefi" ]]; then
        log_info "Installation de GRUB pour UEFI..."

        local efi_dir="/boot/efi"
        [[ ! -d "$efi_dir" ]] && efi_dir="/boot"

        check_esp_offset_arm "$efi_dir" || return 1
        grub-install --target="$efi_target" --efi-directory="$efi_dir" --bootloader-id=GRUB --recheck 2>&1 || {
            log_error "Échec de grub-install (target=$efi_target)"
            return 1
        }
    else
        log_info "Installation de GRUB pour BIOS/Legacy..."
        if ! repair_bios_mbr "$boot_device"; then
            return 1
        fi
    fi

    # ===== Gestion BTRFS pour Arch =====
    if [[ -n "${DETECTED_BTRFS_SUBVOL:-}" ]]; then
        log_info "Configuration BTRFS détectée : sous-volume '${DETECTED_BTRFS_SUBVOL}'"
        if [[ "${DETECTED_BTRFS_SUBVOL}" =~ [^a-zA-Z0-9/_@.-] ]]; then
            log_warning "Nom de sous-volume Btrfs invalide : '${DETECTED_BTRFS_SUBVOL}' — rootflags non injecté"
        elif [[ -f /etc/default/grub ]]; then
            if ! grep -qE "rootflags=subvol=" /etc/default/grub; then
                log_info "Ajout de rootflags=subvol=${DETECTED_BTRFS_SUBVOL} à /etc/default/grub"
                if grep -qE '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                elif grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 rootflags=subvol=${DETECTED_BTRFS_SUBVOL}\"|" /etc/default/grub
                fi
            fi
        fi
    fi
    # ===== FIN GESTION BTRFS =====

    log_info "Regenerating GRUB configuration..."
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 || {
        log_error "Échec de grub-mkconfig"
        return 1
    }

    return 0
}

#-------------------------------------------------------------------------------
# MODULE : RESTAURATION GPT BINAIRE (sgdisk --load-backup)
#-------------------------------------------------------------------------------
restore_partition_table_sgdisk() {
    local bpt_dir="${BACKUP_DIR}/partition-tables"

    if [[ ! -d "$bpt_dir" ]]; then
        log_error "Aucune sauvegarde sgdisk disponible dans $bpt_dir"
        return 1
    fi

    echo ""
    printf "%b\n" "${CYAN}${BOLD}Sauvegardes sgdisk disponibles :${NC}"
    echo "───────────────────────────────────────────────────────────"
    find "$bpt_dir" -maxdepth 1 -name '*-sgdisk.bin' \
        -printf '  %f  (%s bytes)\n' 2>/dev/null | sort
    echo "───────────────────────────────────────────────────────────"
    echo ""

    read -r -p "Fichier .bin sgdisk à restaurer : " bin_file
    local full_path="${bpt_dir}/${bin_file}"

    if [[ ! -f "$full_path" ]]; then
        log_error "Fichier introuvable : $full_path"
        return 1
    fi

    local suggested_disk
    suggested_disk="/dev/$(basename "$bin_file" | sed 's/-sgdisk\.bin$//')"

    echo ""
    lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null | grep -v loop |
        awk 'NR==1{print "  "$0} NR>1{print "  /dev/"$0}'
    echo ""

    read -r -p "Disque cible (Entrée = $suggested_disk) : " target_disk
    target_disk="${target_disk:-$suggested_disk}"

    if [[ ! -b "$target_disk" ]]; then
        log_error "Périphérique invalide : $target_disk"
        return 1
    fi

    echo ""
    printf "%b\n" "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${RED}${BOLD}║  AVERTISSEMENT CRITIQUE                                      ║${NC}"
    printf "%b\n" "${RED}${BOLD}║                                                              ║${NC}"
    printf "%b\n" "${RED}${BOLD}║  sgdisk --load-backup écrase la table GPT PRINCIPALE         ║${NC}"
    printf "%b\n" "${RED}${BOLD}║  ET DE SAUVEGARDE du disque cible.                           ║${NC}"
    printf "%b\n" "${RED}${BOLD}║  Les données des partitions elles-mêmes ne sont pas          ║${NC}"
    printf "%b\n" "${RED}${BOLD}║  effacées, mais un mauvais disque cible est irrécupérable.  ║${NC}"
    printf "%b\n" "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "Source  : $full_path"
    log_info "Cible   : $target_disk"
    echo ""

    if ! confirm_action \
        "Restaurer la table GPT de $full_path sur $target_disk ? Action IRRÉVERSIBLE." strict; then
        return 0
    fi

    local ts
    ts=$(date +%H%M%S)
    local emergency_backup="${bpt_dir}/${target_disk##*/}-sgdisk-pre-restore-${ts}.bin"
    if command_exists sgdisk; then
        sgdisk --backup="$emergency_backup" "$target_disk" 2>/dev/null &&
            log_success "Sauvegarde d'urgence GPT créée : $emergency_backup"
    fi
    dd if="$target_disk" of="${bpt_dir}/${target_disk##*/}-mbr-pre-restore-${ts}.bin" \
        bs=512 count=1 status=none 2>/dev/null &&
        log_success "MBR d'urgence sauvegardé"

    log_info "Restauration GPT via sgdisk --load-backup..."
    sgdisk --load-backup="$full_path" "$target_disk" 2>&1 |
        while read -r line; do log_info "sgdisk: $line"; done
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        log_success "Table GPT restaurée sur $target_disk"

        log_info "Mise à jour des partitions noyau..."
        if command_exists partprobe; then
            partprobe "$target_disk" 2>/dev/null && log_success "partprobe OK"
        elif command_exists blockdev; then
            blockdev --rereadpt "$target_disk" 2>/dev/null && log_success "blockdev --rereadpt OK"
        else
            log_warning "Aucun outil pour recharger la table — redémarrage recommandé"
        fi

        echo ""
        log_info "Table restaurée :"
        sgdisk --print "$target_disk" 2>/dev/null |
            while read -r line; do printf '  %s\n' "$line"; done
        return 0
    else
        log_error "Échec de sgdisk --load-backup"
        log_info "Vous pouvez tenter manuellement : sudo sgdisk --load-backup=\"$full_path\" $target_disk"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# MODULE : SECURE BOOT / MOK ENROLLMENT
#-------------------------------------------------------------------------------
check_secure_boot_status() {
    # NOTE: tous les log_* et printf vont sur stderr pour que la valeur de
    # retour (stdout) ne soit pas polluée quand on fait sb=$(check_secure_boot_status)
    log_subheader "État Secure Boot" >&2

    local sb_state="inconnu"
    if command_exists mokutil; then
        sb_state=$(mokutil --sb-state 2>/dev/null || echo "indisponible")
        log_info "Secure Boot : $sb_state" >&2
    elif [[ -f /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ]]; then
        local sb_byte
        sb_byte=$(od -An -j4 -N1 -tu1 \
            /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c \
            2>/dev/null | tr -d ' ')
        [[ "$sb_byte" == "1" ]] && sb_state="enabled" || sb_state="disabled"
        log_info "Secure Boot (efivars) : $sb_state" >&2
    fi

    if command_exists sbctl; then
        log_info "sbctl status :" >&2
        sbctl status 2>/dev/null | while read -r l; do printf '  %s\n' "$l" >&2; done
    fi

    echo "$sb_state"
}

enroll_mok_key() {
    log_header "ENRÔLEMENT CLÉ MOK (Secure Boot)"

    if [[ $(detect_boot_mode) != "uefi" ]]; then
        log_error "Secure Boot nécessite UEFI"
        return 1
    fi

    if ! command_exists mokutil; then
        log_warning "mokutil non disponible — tentative d'installation..."
        install_packages mokutil || {
            log_error "mokutil requis pour la gestion MOK"
            return 1
        }
    fi

    echo ""
    echo "  Options MOK :"
    echo "  1)  Afficher les clés MOK actuelles"
    echo "  2)  Enrôler une clé MOK existante (.der / .cer)"
    echo "  3)  Générer + enrôler une nouvelle paire de clés MOK"
    echo "  4)  Signer manuellement un fichier EFI ou module noyau"
    echo "  5)  Vérifier la signature d'un fichier EFI"
    echo "  6)  Retour"
    echo ""
    read -r -p "Choix [1-6] : " mok_choice

    case "$mok_choice" in
    1)
        echo ""
        mokutil --list-enrolled 2>/dev/null |
            while read -r l; do printf '  %s\n' "$l"; done ||
            log_warning "Aucune clé MOK enrôlée"
        ;;
    2)
        read -r -p "Chemin vers la clé .der ou .cer à enrôler : " mok_cert
        if [[ ! -f "$mok_cert" ]]; then
            log_error "Fichier introuvable : $mok_cert"
            return 1
        fi
        echo ""
        printf "%b\n" "${YELLOW}Un redémarrage sera nécessaire pour finaliser l'enrôlement.${NC}"
        printf "%b\n" "${YELLOW}MokManager demandera la confirmation et le mot de passe.${NC}"
        echo ""
        if confirm_action "Enrôler $mok_cert dans la base MOK ?" yes; then
            mokutil --import "$mok_cert" 2>&1 |
                while read -r l; do log_info "mokutil: $l"; done
            log_success "Clé mise en file d'attente. Redémarrez pour finaliser dans MokManager."
        fi
        ;;
    3)
        local mok_dir="/etc/Rep-Dem/mok"
        mkdir -p "$mok_dir"
        chmod 700 "$mok_dir"

        local mok_key="${mok_dir}/MOK.key"
        local mok_crt="${mok_dir}/MOK.crt"
        local mok_der="${mok_dir}/MOK.der"

        if [[ -f "$mok_key" && -f "$mok_der" ]]; then
            log_info "Clé MOK existante détectée dans $mok_dir"
            if ! confirm_action "Régénérer la paire de clés MOK ? (l'ancienne sera sauvegardée)" yes; then
                read -r -p "Utiliser la clé existante pour l'enrôlement ? [O/n] : " use_existing
                if [[ "${use_existing,,}" != "n" ]]; then
                    mokutil --import "$mok_der" 2>&1 |
                        while read -r l; do log_info "mokutil: $l"; done
                    log_success "Clé existante mise en file d'attente. Redémarrez pour MokManager."
                fi
                return 0
            fi
            local bts
            bts=$(date +%H%M%S)
            cp -a "$mok_key" "${mok_key}.bak.${bts}" 2>/dev/null
            cp -a "$mok_der" "${mok_der}.bak.${bts}" 2>/dev/null
        fi

        if ! command_exists openssl; then
            log_warning "openssl requis — tentative d'installation..."
            install_packages openssl || {
                log_error "openssl requis"
                return 1
            }
        fi

        log_info "Génération d'une paire RSA-2048 + certificat auto-signé..."
        openssl req -new -x509 -newkey rsa:2048 -keyout "$mok_key" \
            -out "$mok_crt" -days 3650 -subj "/CN=Rep-Dem MOK/" \
            -nodes 2>/dev/null || {
            log_error "Échec openssl"
            return 1
        }
        openssl x509 -in "$mok_crt" -outform DER -out "$mok_der" 2>/dev/null || {
            log_error "Conversion DER échouée"
            return 1
        }
        chmod 600 "$mok_key"
        log_success "Clé générée    : $mok_key"
        log_success "Certificat     : $mok_crt"
        log_success "Format DER     : $mok_der"

        mokutil --import "$mok_der" 2>&1 |
            while read -r l; do log_info "mokutil: $l"; done
        echo ""
        printf "%b\n" "${GREEN}Clé MOK mise en file d'attente.${NC}"
        printf "%b\n" "${YELLOW}Au prochain démarrage, MokManager vous demandera de confirmer${NC}"
        printf "%b\n" "${YELLOW}l'enrôlement et de saisir le mot de passe indiqué ci-dessus.${NC}"
        echo ""
        ;;
    4)
        if ! command_exists sbsign && ! command_exists pesign; then
            log_warning "sbsign ou pesign requis — tentative d'installation..."
            install_packages sbsigntool 2>/dev/null ||
                install_packages pesign 2>/dev/null ||
                {
                    log_error "Aucun outil de signature disponible"
                    return 1
                }
        fi

        local mok_key="/etc/Rep-Dem/mok/MOK.key"
        local mok_crt="/etc/Rep-Dem/mok/MOK.crt"

        if [[ ! -f "$mok_key" || ! -f "$mok_crt" ]]; then
            log_error "Clé MOK non générée. Utilisez l'option 3 d'abord."
            return 1
        fi

        read -r -p "Fichier EFI ou module .ko à signer : " file_to_sign
        if [[ ! -f "$file_to_sign" ]]; then
            log_error "Fichier introuvable : $file_to_sign"
            return 1
        fi

        local signed_file="${file_to_sign}.signed"
        if command_exists sbsign; then
            sbsign --key "$mok_key" --cert "$mok_crt" \
                --output "$signed_file" "$file_to_sign" 2>&1 |
                while read -r l; do log_info "sbsign: $l"; done
            if [[ -f "$signed_file" ]]; then
                log_success "Fichier signé : $signed_file"
                if confirm_action "Remplacer l'original par le fichier signé ?" yes; then
                    mv "$signed_file" "$file_to_sign"
                    log_success "Original remplacé"
                fi
            fi
        elif command_exists pesign; then
            pesign --sign --in="$file_to_sign" --out="$signed_file" \
                --certificate="$mok_crt" 2>&1 |
                while read -r l; do log_info "pesign: $l"; done
            if [[ -f "$signed_file" ]]; then
                log_success "Fichier signé : $signed_file"
                if confirm_action "Remplacer l'original par le fichier signé ?" yes; then
                    mv "$signed_file" "$file_to_sign"
                    log_success "Original remplacé"
                fi
            fi
        fi
        ;;
    5)
        read -r -p "Fichier EFI à vérifier : " file_to_verify
        if [[ ! -f "$file_to_verify" ]]; then
            log_error "Fichier introuvable : $file_to_verify"
            return 1
        fi
        echo ""
        if command_exists sbverify; then
            sbverify --list "$file_to_verify" 2>&1 |
                while read -r l; do printf '  %s\n' "$l"; done
        elif command_exists pesign; then
            pesign --show-signatures --in="$file_to_verify" 2>&1 |
                while read -r l; do printf '  %s\n' "$l"; done
        else
            log_warning "sbverify / pesign non disponibles"
        fi
        ;;
    6) return 0 ;;
    *) log_warning "Choix invalide" ;;
    esac
}

#-------------------------------------------------------------------------------
# GARDE OSTREE / RPM-OSTREE (C27)
#-------------------------------------------------------------------------------

_check_ostree_immutable() {
    if command -v rpm-ostree &>/dev/null; then
        log_error "Système géré par rpm-ostree détecté (Fedora Silverblue/Kinoite/CoreOS)."
        log_error "La réparation directe du bootloader ou de l'initramfs est NON SUPPORTÉE."
        log_error "Utilisez : rpm-ostree kargs, rpm-ostree initramfs, ou ostree admin pinned."
        return 1
    fi
    if command -v ostree &>/dev/null && [[ -d /ostree/deploy ]]; then
        log_error "Déploiement ostree détecté dans /ostree/deploy."
        log_error "La réparation directe est NON SUPPORTÉE sur ce système immutable."
        log_error "Consultez la documentation ostree pour la récupération."
        return 1
    fi
    return 0
}

#-------------------------------------------------------------------------------
# VALIDATION BLS ENTRIES (C20/C11)
#-------------------------------------------------------------------------------

_validate_bls_entries() {
    log_info "Validation des entrées BLS..."

    local _bls_dir=""
    for _d in /boot/loader/entries /boot/efi/loader/entries /efi/loader/entries; do
        [[ -d "$_d" ]] && _bls_dir="$_d" && break
    done

    if [[ -z "$_bls_dir" ]]; then
        log_info "Aucun répertoire d'entrées BLS trouvé — passage ignoré"
        return 0
    fi

    local _machine_id
    #_machine_id=$(cat /etc/machine-id 2>/dev/null | tr -d '[:space:]')
    _mid=$(</etc/machine-id tr -d '[:space:]' 2>/dev/null)
    local _errors=0
    local _repaired=0

    for _conf in "$_bls_dir"/*.conf; do
        [[ -f "$_conf" ]] || continue
        local _linux _initrd _entry_mid

        _linux=$(grep -m1 '^linux ' "$_conf" 2>/dev/null | awk '{print $2}')
        _initrd=$(grep -m1 '^initrd ' "$_conf" 2>/dev/null | awk '{print $2}')

        # Vérifier cohérence machine-id (l'entrée doit avoir été créée pour ce system)
        _entry_mid=$(basename "$_conf" | sed -n 's/^\([0-9a-f]\{32\}\).*/\1/p' || true)
        if [[ -n "$_entry_mid" && -n "$_machine_id" &&
            "$_entry_mid" != "$_machine_id" ]]; then
            log_warning "Entrée BLS machine-id mismatch : $(basename "$_conf") — ignorée"
            continue
            # Ne pas incrémenter _errors : openSUSE/Fedora n'utilisent pas machine-id comme préfixe
            # REF: https://uapi-group.org/specifications/specs/boot_loader_specification/
        fi
        # Si pas de préfixe machine-id dans le nom → entrée valide (openSUSE, Fedora récent)

        # Déterminer le préfixe ESP (ESP monté sur /boot ou /boot/efi ou /efi)
        local _esp_prefix=""
        for _ep in /boot/efi /efi /boot; do
            [[ -d "$_ep/loader" ]] && _esp_prefix="$_ep" && break
        done

        # Vérifier présence du vmlinuz référencé
        if [[ -n "$_linux" ]]; then
            local _linux_abs="${_esp_prefix}${_linux}"
            if [[ ! -f "$_linux_abs" ]]; then
                log_warning "vmlinuz absent pour l'entrée $(basename "$_conf") : $_linux_abs"
                _errors=$((_errors + 1))

                # Sur Fedora avec kernel-install, tenter la regénération
                if [[ "$DISTRO_FAMILY" == "rhel" ]] && command -v kernel-install &>/dev/null; then
                    local _kver
                    _kver=$(grep -m1 '^options ' "$_conf" | sed -n 's/.*BOOT_IMAGE=\([^ ]*\).*/\1/p' |
                        sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+[^[:space:]]*\).*/\1/p' | head -1)
                    if [[ -n "$_kver" ]]; then
                        log_info "Tentative kernel-install add $_kver"
                        if kernel-install add "$_kver" \
                            "/lib/modules/${_kver}/vmlinuz" 2>&1 |
                            while IFS= read -r _l; do log_debug "$_l"; done; then
                            log_success "Entrée BLS regénérée pour noyau $_kver"
                            _repaired=$((_repaired + 1))
                            _errors=$((_errors - 1))
                        fi
                    fi
                fi
            fi
        fi
    done

    if [[ $_errors -gt 0 ]]; then
        log_warning "_validate_bls_entries : $_errors entrée(s) problématique(s) détectée(s), $_repaired réparée(s)"
        return 1
    fi

    log_success "_validate_bls_entries : toutes les entrées BLS sont cohérentes"
    return 0
}

#-------------------------------------------------------------------------------
# VALIDATION LUKS/TPM2 (C26 complément)
#-------------------------------------------------------------------------------

_validate_luks_tpm2_config() {
    local _errors=0

    # 1. Vérifier les UUID de crypttab vs blkid
    if [[ -f /etc/crypttab ]]; then
        log_info "Validation de /etc/crypttab..."
        while IFS= read -r _line; do
            [[ "$_line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${_line//[[:space:]]/}" ]] && continue
            local _name _dev _rest
            read -r _name _dev _rest <<<"$_line"

            local _real_dev
            _real_dev=$(_resolve_fstab_device "$_dev" 2>/dev/null) || true
            if [[ -z "$_real_dev" ]]; then
                log_warning "crypttab : device introuvable : '$_dev' (entrée: $_name)"
                _errors=$((_errors + 1))
                continue
            fi

            local _fstype
            _fstype=$(blkid -s TYPE -o value "$_real_dev" 2>/dev/null)
            if [[ "$_fstype" != "crypto_LUKS" ]]; then
                log_warning "crypttab : '$_real_dev' n'est pas de type crypto_LUKS (type: ${_fstype:-inconnu})"
                _errors=$((_errors + 1))
            fi
        done </etc/crypttab
    fi

    # 2. Vérifier les arguments kernel rd.luks.uuid / luks.uuid dans /etc/default/grub
    if [[ -f /etc/crypttab && -f /etc/default/grub ]]; then
        local _grub_line
        _grub_line=$(grep -E '^GRUB_CMDLINE_LINUX=' /etc/default/grub | head -1)
        while IFS= read -r _cline; do
            [[ "$_cline" =~ ^# ]] && continue
            [[ -z "${_cline//[[:space:]]/}" ]] && continue
            read -r _ _dev _ <<<"$_cline"
            local _luks_uuid
            _luks_uuid=$(blkid -s UUID -o value "$(_resolve_fstab_device "$_dev" 2>/dev/null)" 2>/dev/null) || true
            if [[ -n "$_luks_uuid" ]]; then
                if [[ "$_grub_line" != *"$_luks_uuid"* ]]; then
                    log_warning "GRUB_CMDLINE_LINUX ne contient pas rd.luks.uuid=${_luks_uuid} pour $_dev"
                fi
            fi
        done </etc/crypttab
    fi

    # 3. Vérifier tokens TPM2/clevis dans les en-têtes LUKS
    if [[ "$_errors" -eq 0 ]] && command -v clevis &>/dev/null; then
        if [[ -f /etc/crypttab ]]; then
            while IFS= read -r _cline; do
                [[ "$_cline" =~ ^# ]] && continue
                [[ -z "${_cline//[[:space:]]/}" ]] && continue
                read -r _ _dev _rest <<<"$_cline"
                [[ "$_rest" != *clevis* ]] && continue
                local _real_dev
                _real_dev=$(_resolve_fstab_device "$_dev" 2>/dev/null) || continue
                if ! clevis luks list -d "$_real_dev" 2>/dev/null | grep -q 'tpm2'; then
                    log_warning "Aucun token clevis-tpm2 trouvé sur $_real_dev (vérifié via clevis luks list)"
                    _errors=$((_errors + 1))
                fi
            done </etc/crypttab
        fi
    fi

    if [[ $_errors -gt 0 ]]; then
        log_warning "_validate_luks_tpm2_config : $_errors incohérence(s) détectée(s)"
        return 1
    fi

    log_success "_validate_luks_tpm2_config : configuration LUKS/TPM2 cohérente"
    return 0
}

#-------------------------------------------------------------------------------
# HELPERS INITRAMFS
#-------------------------------------------------------------------------------

_repair_initramfs_dracut() {
    local _dracut_conf_dir="/etc/dracut.conf.d"
    mkdir -p "$_dracut_conf_dir"

    # LUKS détecté dans crypttab → s'assurer que le module crypt est inclus
    if grep -qsE '^[^#]' /etc/crypttab 2>/dev/null; then
        if ! grep -qsrE 'add_dracutmodules.*\bcrypt\b' \
            "${_dracut_conf_dir}/"*.conf /etc/dracut.conf 2>/dev/null; then
            log_warning "LUKS détecté dans /etc/crypttab — ajout du module 'crypt' à dracut"
            echo 'add_dracutmodules+=" crypt "' \
                >"${_dracut_conf_dir}/99-repdem-crypt.conf"
        fi
    fi

    # Clevis/TPM2 détecté → s'assurer que les modules clevis/tpm2 sont inclus
    if command_exists clevis || ls /etc/clevis.d/*.json &>/dev/null 2>&1; then
        if ! grep -qsrE 'clevis|tpm2' \
            "${_dracut_conf_dir}/"*.conf /etc/dracut.conf 2>/dev/null; then
            log_warning "Clevis/TPM2 détecté — ajout des modules clevis/tpm2-tss à dracut"
            echo 'add_dracutmodules+=" clevis crypt tpm2-tss "' \
                >"${_dracut_conf_dir}/99-repdem-clevis.conf"
        fi
    fi

    # C19 : --regenerate-all pour tous les noyaux installés, pas seulement $(uname -r)
    dracut --force --regenerate-all 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
    return "${PIPESTATUS[0]}"
}

_repair_initramfs_mkinitcpio() {
    mkinitcpio -P 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
    return "${PIPESTATUS[0]}"
}

_repair_initramfs_debian() {
    update-initramfs -u -k all 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
    return "${PIPESTATUS[0]}"
}

_validate_initramfs_present() {
    local _kver
    _kver="$(uname -r)"
    for _ipath in \
        "/boot/initrd.img-${_kver}" \
        "/boot/initramfs-${_kver}.img" \
        "/boot/initramfs-${_kver}+.img" \
        "/boot/initrd"; do
        if [[ -f "$_ipath" && -s "$_ipath" ]]; then
            local _size
            _size=$(du -sh "$_ipath" 2>/dev/null | cut -f1)
            log_success "Initramfs présent : $_ipath (${_size:-?})"
            return 0
        fi
    done
    log_warning "Aucun initramfs trouvé pour le noyau ${_kver} — le système pourrait ne pas démarrer"
    return 1
}
repair_initramfs() {
    if is_operation_completed "initramfs_repair"; then
        log_info "Régénération initramfs déjà effectuée durant cette session"
        return 0
    fi

    # C27: bloquer sur systèmes immutables ostree
    _check_ostree_immutable || return 1

    local _rc=0

    case "$DISTRO_FAMILY" in
    debian)
        if command_exists update-initramfs; then
            log_info "Régénération initramfs (Debian/Ubuntu) : update-initramfs -u -k all"
            _repair_initramfs_debian || _rc=$?
        else
            log_warning "update-initramfs introuvable — tentative avec dracut"
            command_exists dracut && { _repair_initramfs_dracut || _rc=$?; } || _rc=1
        fi
        ;;
    rhel)
        if command_exists dracut; then
            log_info "Régénération initramfs (RHEL/Fedora) : dracut --force --regenerate-all"
            _repair_initramfs_dracut || _rc=$?
        else
            log_warning "dracut introuvable"
            _rc=1
        fi
        ;;
    arch)
        if command_exists mkinitcpio; then
            log_info "Régénération initramfs (Arch) : mkinitcpio -P"
            _repair_initramfs_mkinitcpio || _rc=$?
        else
            log_warning "mkinitcpio introuvable"
            _rc=1
        fi
        ;;
    suse)
        if command_exists dracut; then
            log_info "Régénération initramfs (SUSE) : dracut --force --regenerate-all"
            _repair_initramfs_dracut || _rc=$?
        elif command_exists mkinitrd; then
            log_info "Régénération initramfs (SUSE) : mkinitrd"
            mkinitrd 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
            _rc=${PIPESTATUS[0]}
        else
            log_warning "dracut/mkinitrd introuvables — commande manuelle : sudo mkinitrd"
            _rc=1
        fi
        ;;
    void)
        if command_exists dracut; then
            log_info "Régénération initramfs (Void) : dracut --force --regenerate-all"
            _repair_initramfs_dracut || _rc=$?
        else
            log_warning "dracut introuvable — commande manuelle : sudo dracut --force"
            _rc=1
        fi
        ;;
    gentoo)
        if command_exists genkernel; then
            log_info "Régénération initramfs (Gentoo) : genkernel --install initramfs"
            genkernel --install initramfs 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
            _rc=${PIPESTATUS[0]}
        else
            log_warning "genkernel introuvable — commande manuelle : sudo genkernel --install initramfs"
            _rc=1
        fi
        ;;
    *)
        log_warning "Famille inconnue : $DISTRO_FAMILY — tentative générique"
        if command_exists dracut; then
            _repair_initramfs_dracut || _rc=$?
        elif command_exists mkinitramfs; then
            log_info "Tentative avec mkinitramfs (méthode générique)..."
            mkinitramfs -o "/boot/initrd.img-$(uname -r)" "$(uname -r)" \
                2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
            _rc=${PIPESTATUS[0]}
        elif command_exists mkinitcpio; then
            _repair_initramfs_mkinitcpio || _rc=$?
        else
            log_error "Aucun outil de génération initramfs trouvé (dracut/mkinitramfs/mkinitcpio)"
            _rc=1
        fi
        ;;
    esac

    if [[ $_rc -eq 0 ]]; then
        _validate_initramfs_present || true
        log_success "Initramfs régénéré avec succès"
        mark_operation_completed "initramfs_repair"
        return 0
    fi

    log_error "Échec de la régénération de l'initramfs"
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  INITRAMFS : ACTION MANUELLE REQUISE                             ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Régénérez l'initramfs manuellement selon votre distribution :"
    echo "    - Debian/Ubuntu : sudo update-initramfs -u -k all"
    echo "    - RHEL/Fedora   : sudo dracut --force --regenerate-all"
    echo "    - Arch Linux    : sudo mkinitcpio -P"
    echo "    - SUSE          : sudo mkinitrd"
    echo "    - Void          : sudo dracut --force"
    echo "    - Gentoo        : sudo genkernel --install initramfs"
    echo ""
    read -r -p "Appuyez sur Entrée après avoir effectué la régénération manuelle..."
    mark_operation_completed "initramfs_repair"
    return 0
}

package_install_command() {
    case "$PKG_MANAGER" in
    apt)
        echo "apt-get install -y"
        ;;
    dnf)
        echo "dnf install -y"
        ;;
    yum)
        echo "yum install -y"
        ;;
    pacman)
        echo "pacman -S --noconfirm --needed"
        ;;
    zypper)
        echo "zypper install -y"
        ;;
    emerge)
        echo "emerge --noreplace"
        ;;
    xbps)
        echo "xbps-install -y"
        ;;
    *)
        return 1
        ;;
    esac
}

package_refresh_command() {
    case "$PKG_MANAGER" in
    apt)
        echo "apt-get update"
        ;;
    dnf)
        echo "dnf makecache --refresh"
        ;;
    yum)
        echo "yum makecache"
        ;;
    pacman)
        echo "pacman -Sy --noconfirm"
        ;;
    zypper)
        echo "zypper refresh"
        ;;
    xbps)
        echo "xbps-install -Sy"
        ;;
    emerge)
        echo "emerge --sync"
        ;;
    *)
        return 1
        ;;
    esac
}

install_packages() {
    local packages=("$@")
    if [[ ${#packages[@]} -eq 0 ]]; then
        log_warning "install_packages appelé sans argument"
        return 1
    fi

    log_info "Installation des paquets requis : ${packages[*]}"

    # Actualisation des métadonnées (best-effort, non bloquant)
    local _refresh_rc=0
    case "$PKG_MANAGER" in
    apt)
        apt-get update -qq 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _refresh_rc=${PIPESTATUS[0]}
        ;;
    dnf)
        dnf makecache --refresh -q 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _refresh_rc=${PIPESTATUS[0]}
        ;;
    yum)
        yum makecache -q 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _refresh_rc=${PIPESTATUS[0]}
        ;;
    pacman)
        pacman -Sy --noconfirm 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _refresh_rc=${PIPESTATUS[0]}
        ;;
    zypper)
        zypper refresh 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _refresh_rc=${PIPESTATUS[0]}
        ;;
    xbps)
        xbps-install -Sy 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _refresh_rc=${PIPESTATUS[0]}
        ;;
    emerge)
        emerge --sync 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _refresh_rc=${PIPESTATUS[0]}
        ;;
    esac
    [[ $_refresh_rc -ne 0 ]] &&
        log_warning "Actualisation du cache échouée (code $_refresh_rc) — tentative d'installation directe"

    # Installation — pas d'eval, invocation directe par gestionnaire
    local _install_rc=0
    case "$PKG_MANAGER" in
    apt)
        apt-get install -y "${packages[@]}" 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _install_rc=${PIPESTATUS[0]}
        ;;
    dnf)
        dnf install -y "${packages[@]}" 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _install_rc=${PIPESTATUS[0]}
        ;;
    yum)
        yum install -y "${packages[@]}" 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _install_rc=${PIPESTATUS[0]}
        ;;
    pacman)
        pacman -S --noconfirm --needed "${packages[@]}" 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _install_rc=${PIPESTATUS[0]}
        ;;
    zypper)
        zypper install -y "${packages[@]}" 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _install_rc=${PIPESTATUS[0]}
        ;;
    emerge)
        emerge --noreplace "${packages[@]}" 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _install_rc=${PIPESTATUS[0]}
        ;;
    xbps)
        xbps-install -y "${packages[@]}" 2>&1 | while IFS= read -r _l; do log_debug "$_l"; done
        _install_rc=${PIPESTATUS[0]}
        ;;
    *)
        log_warning "Gestionnaire de paquets non pris en charge : $PKG_MANAGER"
        return 1
        ;;
    esac

    if [[ $_install_rc -eq 0 ]]; then
        log_success "Paquets installés : ${packages[*]}"
        return 0
    fi

    log_error "Échec de l'installation des paquets (code $_install_rc)"
    return 1
}

package_installed() {
    local pkg="$1"
    case "$PKG_MANAGER" in
    apt)
        dpkg -s "$pkg" &>/dev/null
        ;;
    dnf | yum | zypper)
        rpm -q "$pkg" &>/dev/null
        ;;
    pacman)
        pacman -Q "$pkg" &>/dev/null
        ;;
    xbps)
        xbps-query -l "$pkg" &>/dev/null
        ;;
    emerge)
        command -v equery >/dev/null 2>&1 && equery list "$pkg" >/dev/null 2>&1
        ;;
    *)
        return 1
        ;;
    esac
}

install_repair_dependencies() {
    local boot_mode
    boot_mode=$(detect_boot_mode)
    local required_packages=()
    local required_commands=()

    # Vérification des commandes de base (util-linux) — requises sur tout live ISO
    local base_commands=(findmnt blkid lsblk mount umount chroot)
    for _cmd in "${base_commands[@]}"; do
        command_exists "$_cmd" || {
            log_error "Commande de base manquante : $_cmd (paquet util-linux)"
            return 1
        }
    done

    local _machine
    _machine=$(uname -m)

    case "$DISTRO_FAMILY" in
    debian)
        if [[ "$boot_mode" == "uefi" ]]; then
            case "$_machine" in
            x86_64) required_packages+=(grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr) ;;
            aarch64 | arm64) required_packages+=(grub-efi-arm64 grub-efi-arm64-signed shim-signed efibootmgr) ;;
            armv7l) required_packages+=(grub-efi-arm efibootmgr) ;;
            *) required_packages+=(grub-efi efibootmgr) ;;
            esac
            required_commands+=(grub-install efibootmgr)
        else
            required_packages+=(grub-pc)
            required_commands+=(grub-install)
        fi
        required_packages+=(initramfs-tools os-prober)
        required_commands+=(update-initramfs)
        if command_exists bootctl || [[ -f /boot/efi/loader/loader.conf ]] ||
            [[ -f /efi/loader/loader.conf ]] || [[ -f /boot/loader/loader.conf ]] ||
            [[ -f /boot/efi/EFI/systemd/systemd-bootx64.efi ]] ||
            [[ -f /efi/EFI/systemd/systemd-bootx64.efi ]]; then
            required_commands+=(bootctl)
        fi
        ;;
    rhel)
        required_packages+=(grub2-common dracut os-prober)
        required_commands+=(dracut)
        if [[ "$boot_mode" == "uefi" ]]; then
            case "$_machine" in
            x86_64) required_packages+=(grub2-efi-x64 grub2-efi-x64-modules shim-x64) ;;
            aarch64) required_packages+=(grub2-efi-aa64 grub2-efi-aa64-modules shim-aa64) ;;
            esac
            required_packages+=(efibootmgr)
            required_commands+=(grub2-install efibootmgr)
        else
            required_packages+=(grub2-pc grub2-pc-modules)
            required_commands+=(grub2-install)
        fi
        ;;
    arch)
        required_packages+=(grub mkinitcpio os-prober)
        required_commands+=(grub-install mkinitcpio)
        if [[ "$boot_mode" == "uefi" ]]; then
            required_packages+=(efibootmgr)
            required_commands+=(efibootmgr)
        fi
        if command_exists bootctl || [[ -f /boot/loader/loader.conf ]]; then
            required_commands+=(bootctl)
        fi
        ;;
    suse)
        required_packages+=(grub2 os-prober)
        required_commands+=(grub2-install grub2-mkconfig)
        if [[ "$boot_mode" == "uefi" ]]; then
            case "$_machine" in
            x86_64) required_packages+=(grub2-x86_64-efi shim) ;;
            aarch64) required_packages+=(grub2-arm64-efi shim) ;;
            esac
            required_packages+=(efibootmgr)
            required_commands+=(efibootmgr)
        else
            required_packages+=(grub2-i386-pc)
        fi
        ;;
    void)
        required_commands+=(grub-install grub-mkconfig)
        if [[ "$boot_mode" == "uefi" ]]; then
            case "$_machine" in
            x86_64) required_packages+=(grub-x86_64-efi efibootmgr) ;;
            aarch64) required_packages+=(grub-arm64-efi efibootmgr) ;;
            *) required_packages+=(grub efibootmgr) ;;
            esac
            required_commands+=(efibootmgr)
        else
            required_packages+=(grub)
        fi
        ;;
    gentoo)
        required_commands+=(grub-install grub-mkconfig emerge)
        if [[ "$boot_mode" == "uefi" ]]; then
            required_packages+=(sys-boot/grub efibootmgr)
            required_commands+=(efibootmgr)
        else
            required_packages+=(sys-boot/grub)
        fi
        ;;
    alpine)
        required_commands+=(grub-install grub-mkconfig)
        if [[ "$boot_mode" == "uefi" ]]; then
            required_packages+=(grub-efi efibootmgr)
            required_commands+=(efibootmgr)
        else
            required_packages+=(grub-bios)
        fi
        ;;
    *)
        log_warning "Installation automatique des dépendances non prise en charge pour $DISTRO_FAMILY"
        return 1
        ;;
    esac

    local missing_packages=()
    local missing_commands=()
    local pkg
    local cmd

    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    for pkg in "${required_packages[@]}"; do
        if ! package_installed "$pkg"; then
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]] && [[ ${#missing_commands[@]} -eq 0 ]]; then
        log_success "Toutes les dépendances requises sont présentes"
        return 0
    fi

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_warning "Outils manquants détectés : ${missing_commands[*]}"
    fi
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_warning "Dépendances manquantes : ${missing_packages[*]}"
    fi

    if ! confirm_action "Installer les dépendances manquantes avant la réparation ?" yes; then
        return 1
    fi

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_error "Des outils nécessaires sont manquants mais aucun paquet n'a été identifié pour installation automatique. Vérifiez le système ou installez manuellement : ${missing_commands[*]}"
        return 1
    fi

    install_packages "${missing_packages[@]}"
}

#-------------------------------------------------------------------------------
# MODULE : RÉPARATION SYSTEMD-BOOT
#-------------------------------------------------------------------------------
repair_systemd_boot() {
    log_header "RÉPARATION SYSTEMD-BOOT"

    # Valider les entrées BLS avant réparation
    _validate_bls_entries || log_warning "Des incohérences BLS ont été détectées — voir log ci-dessus"

    if ! command_exists bootctl; then
        log_warning "bootctl introuvable. Tentative d'installation..."
        case "$DISTRO_FAMILY" in
        debian) install_packages systemd-boot-efi 2>/dev/null ||
            install_packages systemd 2>/dev/null ;;
        arch) install_packages systemd 2>/dev/null ;;
        rhel) install_packages systemd-udev 2>/dev/null ;;
        *)
            log_error "Installation automatique de bootctl non supportée pour $DISTRO_FAMILY"
            return 1
            ;;
        esac
        if ! command_exists bootctl; then
            log_error "bootctl toujours introuvable après tentative d'installation"
            return 1
        fi
    fi

    if [[ $(detect_boot_mode) != "uefi" ]]; then
        log_error "systemd-boot nécessite un système UEFI. Mode BIOS/Legacy détecté."
        return 1
    fi

    local esp_dir=""
    for d in /boot/efi /efi /boot; do
        if findmnt -n "$d" &>/dev/null && [[ "$(findmnt -n -o FSTYPE "$d" 2>/dev/null)" == "vfat" ]]; then
            esp_dir="$d"
            break
        fi
    done
    if [[ -z "$esp_dir" ]]; then
        log_error "Partition EFI (ESP) non montée. Montez-la sur /boot/efi ou /efi avant de continuer."
        echo ""
        echo "Partitions vfat disponibles :"
        blkid | grep -i vfat || lsblk -f | grep -i vfat || echo "aucune"
        return 1
    fi
    log_info "ESP détectée : $esp_dir"

    echo ""
    echo "  Options systemd-boot :"
    echo "  1)  Réinstaller bootctl (bootctl install)"
    echo "  2)  Mettre à jour bootctl (bootctl update)"
    echo "  3)  Afficher statut (bootctl status)"
    echo "  4)  Lister les entrées de boot (bootctl list)"
    echo "  5)  Créer une entrée boot manquante"
    echo "  6)  Valider UUID entrées boot (fix BusyBox / ALERT UUID)"
    echo "  7)  Vérifier crypttab (fix suffix _XXXXX qui casse initramfs)"
    echo "  8)  Retour"
    echo ""
    read -r -p "Choix [1-8] : " sd_choice

    case "$sd_choice" in
    1)
        if ! confirm_action "Réinstaller systemd-boot dans $esp_dir. Écrase le bootloader EFI existant." strict; then
            return 0
        fi
        local esp_bak
        esp_bak="${BACKUP_DIR}/esp-backup-$(date +%H%M%S).tar.gz"
        mkdir -p "$BACKUP_DIR"
        if tar -czf "$esp_bak" -C "$(dirname "$esp_dir")" "$(basename "$esp_dir")" 2>/dev/null; then
            log_success "[BACKUP OK] ESP sauvegardée : $esp_bak"
        else
            log_warning "Sauvegarde ESP échouée"
        fi

        if bootctl install --esp-path="$esp_dir" 2>&1 | while read -r l; do log_info "bootctl: $l"; done; then
            log_success "systemd-boot réinstallé dans $esp_dir"
        else
            log_error "Échec de bootctl install"
            return 1
        fi

        local loader_conf="${esp_dir}/loader/loader.conf"
        if [[ ! -f "$loader_conf" ]]; then
            mkdir -p "${esp_dir}/loader"
            printf 'timeout 5\ndefault @saved\nconsole-mode auto\n' >"$loader_conf"
            log_success "loader.conf créé : $loader_conf"
        fi

        # ============================================
        # === AJOUT : CRÉATION DE L'ENTRÉE EFI NVRAM ===
        # ============================================
        log_info "Création de l'entrée systemd-boot dans le firmware UEFI..."

        local efi_dev
        efi_dev=$(findmnt -n -o SOURCE "$esp_dir" 2>/dev/null | head -1)
        if [[ -n "$efi_dev" ]]; then
            local disk
            disk=$(lsblk -no PKNAME "$efi_dev" 2>/dev/null | head -1)
            local part
            part=$(lsblk -no PARTN "$efi_dev" 2>/dev/null | head -1)

            if [[ -n "$disk" && -n "$part" ]]; then
                if ! efibootmgr -v 2>/dev/null | grep -qi "systemd-boot\|Linux Boot Manager\|systemd.*boot"; then
                    if efibootmgr --create --disk "/dev/$disk" --part "$part" \
                        --loader '\EFI\systemd\systemd-bootx64.efi' \
                        --label "Linux Boot Manager" --verbose 2>&1 | while read -r l; do
                        log_info "efibootmgr: $l"
                    done; then
                        log_success "Entrée systemd-boot créée dans le firmware"

                        # Mettre l'entrée en premier dans l'ordre de boot
                        local new_boot
                        new_boot=$(efibootmgr -v 2>/dev/null | grep -i "Linux Boot Manager" | grep -oE 'Boot[0-9A-F]{4}' | head -1 | sed 's/Boot//')
                        if [[ -n "$new_boot" ]]; then
                            local current_order
                            current_order=$(efibootmgr -v 2>/dev/null | grep "BootOrder:" | cut -d: -f2 | tr -d ' ')
                            if efibootmgr --bootorder "$new_boot,$current_order" 2>/dev/null; then
                                log_success "Ordre de boot modifié : systemd-boot en premier"
                            fi
                        fi
                    else
                        log_warning "Échec de création de l'entrée EFI"
                    fi
                else
                    log_info "Entrée systemd-boot déjà présente dans le firmware"
                fi
            else
                log_warning "Impossible de déterminer disque/partition pour l'ESP"
            fi
        else
            log_warning "ESP non trouvée dans les montages"
        fi
        # === FIN AJOUT ===

        if [[ "$DISTRO_FAMILY" == "arch" ]] && command_exists mkinitcpio; then
            mkinitcpio -P 2>&1 | while read -r l; do log_debug "$l"; done
            log_success "initramfs régénéré"
        elif [[ "$DISTRO_FAMILY" == "debian" ]] && command_exists update-initramfs; then
            update-initramfs -u -k all 2>&1 | while read -r l; do log_debug "$l"; done
            log_success "initramfs régénéré"
        fi

        if command_exists kernel-install; then
            log_info "Réinstallation des entrées noyau via kernel-install..."
            local kver
            kver=$(uname -r)
            kernel-install add "$kver" "/boot/vmlinuz-${kver}" 2>&1 |
                while read -r l; do log_debug "$l"; done &&
                log_success "Entrée noyau $kver installée"
        fi
        ;;
    2)
        if bootctl update --esp-path="$esp_dir" 2>&1 | while read -r l; do log_info "bootctl: $l"; done; then
            log_success "systemd-boot mis à jour"
        else
            log_error "Échec de bootctl update"
            return 1
        fi
        ;;
    3)
        echo ""
        bootctl status 2>&1 | while read -r l; do printf '  %s\n' "$l"; done
        ;;
    4)
        echo ""
        bootctl list 2>&1 | while read -r l; do printf '  %s\n' "$l"; done
        ;;
    5)
        _create_sd_boot_entry "$esp_dir"
        ;;
    6)
        _validate_sd_boot_uuids "$esp_dir"
        ;;
    7)
        _check_crypttab_suffix
        ;;
    8) return 0 ;;
    *) log_warning "Choix invalide" ;;
    esac
}

_validate_sd_boot_uuids() {
    local esp_dir="$1"
    local entries_dir="${esp_dir}/loader/entries"
    if [[ ! -d "$entries_dir" ]]; then
        log_error "Répertoire d'entrées introuvable : $entries_dir"
        return 1
    fi

    log_subheader "Validation UUID entrées systemd-boot"
    local any_mismatch=false

    for conf in "${entries_dir}/"*.conf; do
        [[ -f "$conf" ]] || continue
        local entry_uuid
        entry_uuid=$(sed -n 's/.*root=UUID="\?\([0-9A-Za-z-]*\)"\?.*/\1/p' "$conf" | head -1)
        [[ -z "$entry_uuid" ]] && continue

        local real_dev
        real_dev=$(blkid -t UUID="$entry_uuid" -o device 2>/dev/null | head -1)

        echo ""
        printf "  Entrée : %s\n" "$(basename "$conf")"
        printf "  UUID dans .conf : %s\n" "$entry_uuid"
        if [[ -n "$real_dev" ]]; then
            printf "%b  OK : UUID trouvé sur %s%b\n" "${GREEN}" "$real_dev" "${NC}"
        else
            printf "%b  MISMATCH : aucun device avec UUID=%s%b\n" "${RED}" "$entry_uuid" "${NC}"
            any_mismatch=true
            local real_uuid
            real_uuid=$(findmnt -n -o UUID / 2>/dev/null | head -1)
            [[ -z "$real_uuid" ]] && real_uuid=$(blkid /dev/mapper/data-root -s UUID -o value 2>/dev/null | head -1)
            if [[ -n "$real_uuid" ]]; then
                printf "  UUID correct détecté : %s\n" "$real_uuid"
                if confirm_action "Corriger UUID dans $(basename "$conf") : $entry_uuid → $real_uuid ?" yes; then
                    cp "$conf" "${conf}.bak.$(date +%H%M%S)"
                    sed -i "s|root=UUID=${entry_uuid}|root=UUID=${real_uuid}|g" "$conf"
                    log_success "UUID corrigé dans $(basename "$conf")"
                fi
            fi
        fi
    done

    [[ "$any_mismatch" == false ]] && log_success "Tous les UUID des entrées boot sont valides"
}

_check_crypttab_suffix() {
    log_subheader "Vérification /etc/crypttab"
    if [[ ! -f /etc/crypttab ]]; then
        log_info "/etc/crypttab absent — pas de chiffrement LUKS configuré"
        return 0
    fi

    echo ""
    echo "Contenu actuel de /etc/crypttab :"
    #cat /etc/crypttab | while read -r l; do printf '  %s\n' "$l"; done
    while read -r l; do printf '  %s\n' "$l"; done </etc/crypttab
    echo ""

    local fixed=false
    local new_crypttab
    new_crypttab=$(mktemp /tmp/rd_crypttab_XXXXXX)

    while IFS= read -r line; do
        if [[ "$line" =~ ^cryptdata_[A-Za-z0-9]+ ]]; then
            local suffix rest
            suffix=$(echo "$line" | grep -oE '^cryptdata_[A-Za-z0-9]+')
            rest="${line#"$suffix"}"
            local fixed_line="cryptdata${rest}"
            printf "%b  Suffix parasite détecté :%b\n    avant : %s\n    après : %s\n" \
                "${YELLOW}" "${NC}" "$line" "$fixed_line"
            echo "$fixed_line" >>"$new_crypttab"
            fixed=true
        else
            echo "$line" >>"$new_crypttab"
        fi
    done </etc/crypttab

    if [[ "$fixed" == true ]]; then
        if confirm_action "Corriger /etc/crypttab (supprimer suffix _XXXXX sur cryptdata) ?" yes; then
            cp /etc/crypttab "/etc/crypttab.bak.$(date +%H%M%S)"
            cp "$new_crypttab" /etc/crypttab
            log_success "crypttab corrigé"
            if command_exists update-initramfs; then
                log_info "Régénération initramfs..."
                update-initramfs -c -k all 2>&1 | while read -r l; do log_debug "$l"; done
                log_success "initramfs régénéré"
            fi
        fi
    else
        log_success "Aucun suffix parasite détecté dans /etc/crypttab"
    fi
    rm -f "$new_crypttab"
}

_create_sd_boot_entry() {
    local esp_dir="$1"
    local entries_dir="${esp_dir}/loader/entries"
    mkdir -p "$entries_dir"

    local kver
    kver=$(uname -r)
    local vmlinuz=""
    local initrd_path=""
    for vml in "/boot/vmlinuz-${kver}" "/boot/vmlinuz" "/boot/Image"; do
        [[ -f "$vml" ]] && vmlinuz="$vml" && break
    done
    for ird in "/boot/initrd.img-${kver}" "/boot/initramfs-${kver}.img" "/boot/initrd.img"; do
        [[ -f "$ird" ]] && initrd_path="$ird" && break
    done

    if [[ -z "$vmlinuz" ]]; then
        log_error "vmlinuz introuvable pour le noyau $kver"
        return 1
    fi

    local root_uuid
    root_uuid=$(findmnt -n -o UUID / 2>/dev/null | head -1)
    if [[ -z "$root_uuid" ]]; then
        # Fallback : sur LUKS/LVM, findmnt peut ne pas retourner l'UUID directement
        local _root_src
        _root_src=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
        if [[ -n "$_root_src" ]]; then
            root_uuid=$(blkid -s UUID -o value "$_root_src" 2>/dev/null)
        fi
    fi
    if [[ -z "$root_uuid" ]]; then
        log_error "UUID partition root introuvable (findmnt + blkid échoués) — entrée non créée"
        return 1
    fi

    local esp_kdir="${esp_dir}/${DISTRO_FAMILY:-linux}"
    mkdir -p "$esp_kdir"
    local esp_vmlinuz="${esp_kdir}/vmlinuz-${kver}"
    local esp_initrd="${esp_kdir}/initrd-${kver}.img"
    if cp "$vmlinuz" "$esp_vmlinuz" 2>/dev/null; then
        log_success "vmlinuz copié dans ESP : $esp_vmlinuz"
    else
        log_warning "Échec copie vmlinuz vers ESP"
    fi
    if [[ -n "$initrd_path" ]]; then
        if cp "$initrd_path" "$esp_initrd" 2>/dev/null; then
            log_success "initrd copié dans ESP : $esp_initrd"
        else
            log_warning "Échec copie initrd vers ESP"
        fi
    fi

    local entry_file="${entries_dir}/${DISTRO:-linux}-${kver}.conf"
    {
        echo "title   ${PRETTY_NAME:-Linux ${kver}}"
        echo "linux   /${DISTRO_FAMILY:-linux}/vmlinuz-${kver}"
        [[ -n "$initrd_path" ]] && echo "initrd  /${DISTRO_FAMILY:-linux}/initrd-${kver}.img"
        echo "options root=UUID=${root_uuid} rw quiet splash"
    } >"$entry_file"

    log_success "Entrée boot créée : $entry_file"
    echo ""
    #cat "$entry_file" | while read -r l; do printf '  %s\n' "$l"; done
    while read -r l; do printf '  %s\n' "$l"; done <"$entry_file"

    echo ""
}

#-------------------------------------------------------------------------------
# MODULE : RÉPARATION rEFInd (UEFI only)
#-------------------------------------------------------------------------------
repair_refind() {
    log_header "RÉPARATION rEFIND"

    if [[ $(detect_boot_mode) != "uefi" ]]; then
        log_error "rEFInd nécessite un système UEFI. Mode BIOS détecté."
        return 1
    fi

    local esp_dir=""
    for d in /boot/efi /efi /boot; do
        if mountpoint -q "$d" 2>/dev/null && [[ "$(findmnt -n -o FSTYPE "$d" 2>/dev/null)" == "vfat" ]]; then
            esp_dir="$d"
            break
        fi
    done

    if [[ -z "$esp_dir" ]]; then
        log_error "Partition EFI (ESP) non trouvée. Montez-la sur /boot/efi ou /efi."
        return 1
    fi

    log_info "ESP détectée : $esp_dir"

    if [[ -f "$esp_dir/EFI/refind/refind.conf" ]]; then
        backup_file "$esp_dir/EFI/refind/refind.conf" "rEFInd configuration"
    fi

    if [[ -d "$esp_dir/EFI/refind" ]]; then
        local refind_backup
        refind_backup="${BACKUP_DIR}/refind-$(date +%Y%m%d_%H%M%S).tar.gz"
        tar -czf "$refind_backup" -C "$esp_dir/EFI" refind 2>/dev/null
        log_success "Dossier rEFInd sauvegardé : $refind_backup"
    fi

    if ! command_exists refind-install; then
        log_warning "refind-install introuvable. Installation en cours..."

        case "$DISTRO_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y refind 2>&1 | while read -r line; do log_debug "$line"; done
            ;;
        arch)
            pacman -S --noconfirm refind 2>&1 | while read -r line; do log_debug "$line"; done
            ;;
        rhel)
            dnf install -y epel-release 2>/dev/null
            dnf install -y refind 2>&1 | while read -r line; do log_debug "$line"; done
            ;;
        suse)
            zypper install -y refind 2>&1 | while read -r line; do log_debug "$line"; done
            ;;
        *)
            log_error "Installation automatique non supportée pour $DISTRO_FAMILY"
            log_info "Installez manuellement : refind"
            return 1
            ;;
        esac

        if ! command_exists refind-install; then
            log_error "refind-install toujours introuvable"
            return 1
        fi
    fi

    local esp_dev
    esp_dev=$(findmnt -n -o SOURCE "$esp_dir" 2>/dev/null | head -1)

    if [[ -z "$esp_dev" ]]; then
        log_error "Impossible de déterminer le périphérique de l'ESP"
        return 1
    fi

    log_info "Installation de rEFInd sur $esp_dev"

    if refind-install --usedefault "$esp_dev" 2>&1 | while read -r line; do
        log_info "refind-install: $line"
    done; then
        log_success "rEFInd installé avec succès"
    else
        log_error "Échec de refind-install"

        if [[ -d /usr/share/refind ]]; then
            mkdir -p "$esp_dir/EFI/refind"
            cp -r /usr/share/refind/* "$esp_dir/EFI/refind/" 2>/dev/null
            log_success "Fallback : fichiers copiés manuellement"
        else
            return 1
        fi
    fi

    if command_exists efibootmgr; then
        if ! efibootmgr -v 2>/dev/null | grep -qi 'refind'; then
            local disk part
            disk=$(lsblk -no PKNAME "$esp_dev" 2>/dev/null | head -1)
            part=$(lsblk -no PARTN "$esp_dev" 2>/dev/null | head -1)

            if [[ -n "$disk" && -n "$part" ]]; then
                log_info "Création de l'entrée UEFI..."
                efibootmgr --create --disk "/dev/$disk" --part "$part" \
                    --loader '\\EFI\\refind\\refind_x64.efi' \
                    --label "rEFInd Boot Manager" 2>&1 | while read -r line; do
                    log_info "efibootmgr: $line"
                done
                log_success "Entrée UEFI créée"
            fi
        fi
    fi

    local refind_conf_dir="$esp_dir/EFI/refind"
    mkdir -p "$refind_conf_dir"
    if [[ ! -f "$esp_dir/EFI/refind/refind.conf" ]]; then
        cat >"$esp_dir/EFI/refind/refind.conf" <<'EOF'
# rEFInd minimal configuration
timeout 5
default_selection 1

menuentry "Linux" {
    icon /EFI/refind/icons/os_linux.png
    loader /vmlinuz-linux
    initrd /initramfs-linux.img
    options "root=UUID=auto rw"
}

include /EFI/refind/drivers_x64
EOF
        log_success "refind.conf généré"
    fi

    log_success "Réparation rEFInd terminée"
    mark_operation_completed "refind_repair"
    return 0
}

#-------------------------------------------------------------------------------
# MODULE : RÉPARATION Limine (BIOS + UEFI)
#-------------------------------------------------------------------------------
repair_limine() {
    log_header "RÉPARATION LIMINE"

    local boot_mode
    boot_mode=$(detect_boot_mode)

    if ! command_exists limine; then
        log_warning "limine introuvable. Installation en cours..."

        case "$DISTRO_FAMILY" in
        arch)
            pacman -S --noconfirm limine 2>&1 | while read -r line; do log_debug "$line"; done
            ;;
        debian | ubuntu)
            log_error "Limine n'est pas dans les dépôts Debian/Ubuntu"
            log_info "Installez manuellement depuis : https://github.com/limine-bootloader/limine"
            return 1
            ;;
        rhel | fedora)
            log_error "Limine non disponible dans les dépôts RHEL/Fedora"
            return 1
            ;;
        *)
            log_error "Installation automatique non supportée pour $DISTRO_FAMILY"
            return 1
            ;;
        esac

        if ! command_exists limine; then
            log_error "limine toujours introuvable après installation"
            return 1
        fi
    fi

    if [[ -f /boot/limine.cfg ]]; then
        backup_file "/boot/limine.cfg" "Limine configuration"
    fi

    if [[ -f /boot/limine/limine.cfg ]]; then
        backup_file "/boot/limine/limine.cfg" "Limine configuration (alternative)"
    fi

    if [[ ! -d /boot ]]; then
        log_error "Répertoire /boot introuvable"
        return 1
    fi

    local boot_fstype
    boot_fstype=$(findmnt -n -o FSTYPE /boot 2>/dev/null)
    if [[ "$boot_fstype" != "vfat" ]] && [[ "$boot_fstype" != "msdos" ]] && [[ "$boot_fstype" != "fat" ]]; then
        log_error "Limine nécessite que /boot soit en FAT32. Type actuel : ${boot_fstype:-inconnu}"
        log_info "Solution : réinstaller avec une partition /boot séparée en FAT32"
        return 1
    fi
    log_success "Vérification FAT32 : OK ($boot_fstype)"

    if [[ "$boot_mode" != "uefi" ]]; then
        local bios_sys_src="/usr/share/limine/limine-bios.sys"
        if [[ -f "$bios_sys_src" ]]; then
            cp "$bios_sys_src" /boot/ 2>/dev/null
            log_success "limine-bios.sys copié vers /boot/"
        else
            log_warning "limine-bios.sys introuvable dans /usr/share/limine/"
        fi
    fi

    local limine_sys_src=""
    for src in /usr/share/limine/limine.sys /usr/lib/limine/limine.sys; do
        if [[ -f "$src" ]]; then
            limine_sys_src="$src"
            break
        fi
    done

    if [[ -z "$limine_sys_src" ]]; then
        log_error "limine.sys introuvable. Réinstallation de limine nécessaire."
        return 1
    fi

    if [[ ! -f /boot/limine.sys ]]; then
        cp "$limine_sys_src" /boot/ 2>/dev/null
        log_success "limine.sys copié vers /boot/"
    fi

    if [[ "$boot_mode" == "uefi" ]]; then
        log_info "Déploiement de Limine en mode UEFI..."

        local esp_dir=""
        for d in /boot/efi /efi /boot; do
            if mountpoint -q "$d" 2>/dev/null && [[ "$(findmnt -n -o FSTYPE "$d" 2>/dev/null)" == "vfat" ]]; then
                esp_dir="$d"
                break
            fi
        done

        if [[ -z "$esp_dir" ]]; then
            log_error "Partition EFI (ESP) non trouvée pour le déploiement UEFI"
            return 1
        fi

        log_info "ESP détectée : $esp_dir"
        mkdir -p "$esp_dir/EFI/LIMINE"

        local uefi_src="/usr/share/limine"
        if [[ -f "$uefi_src/BOOTX64.EFI" ]]; then
            cp "$uefi_src/BOOTX64.EFI" "$esp_dir/EFI/LIMINE/" 2>/dev/null
            log_success "BOOTX64.EFI copié"
        fi

        if [[ -f "$uefi_src/BOOTIA32.EFI" ]]; then
            cp "$uefi_src/BOOTIA32.EFI" "$esp_dir/EFI/LIMINE/" 2>/dev/null
            log_success "BOOTIA32.EFI copié"
        fi

        if [[ ! -f "$esp_dir/EFI/LIMINE/BOOTX64.EFI" ]] && [[ -f /boot/BOOTX64.EFI ]]; then
            cp /boot/BOOTX64.EFI "$esp_dir/EFI/LIMINE/" 2>/dev/null
            log_success "BOOTX64.EFI copié depuis /boot"
        fi

        if command_exists efibootmgr; then
            local esp_dev
            esp_dev=$(findmnt -n -o SOURCE "$esp_dir" 2>/dev/null | head -1)

            if [[ -n "$esp_dev" ]]; then
                local disk part
                disk=$(lsblk -no PKNAME "$esp_dev" 2>/dev/null | head -1)
                part=$(lsblk -no PARTN "$esp_dev" 2>/dev/null | head -1)

                if [[ -n "$disk" && -n "$part" ]]; then
                    if ! efibootmgr -v 2>/dev/null | grep -qi 'limine'; then
                        log_info "Création de l'entrée UEFI pour Limine..."
                        efibootmgr --create --disk "/dev/$disk" --part "$part" \
                            --loader '\\EFI\\LIMINE\\BOOTX64.EFI' \
                            --label "Limine Boot Manager" 2>&1 | while read -r line; do
                            log_info "efibootmgr: $line"
                        done
                        log_success "Entrée UEFI créée"
                    else
                        log_info "Entrée Limine déjà présente"
                    fi
                fi
            fi
        fi

    else
        log_info "Déploiement de Limine en mode BIOS..."

        local boot_disk=""
        boot_disk=$(detect_boot_device)

        if [[ -z "$boot_disk" ]]; then
            echo ""
            lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | grep -v loop
            echo ""
            read -r -p "Disque cible pour Limine (ex. /dev/sda) : " boot_disk
        fi

        if [[ ! -b "$boot_disk" ]]; then
            log_error "Périphérique invalide : $boot_disk"
            return 1
        fi

        log_info "Installation de Limine sur $boot_disk"

        local limine_output
        local limine_exit_code
        limine_output=$(limine bios-install "$boot_disk" 2>&1)
        limine_exit_code=$?

        while IFS= read -r line; do
            log_info "limine bios-install: $line"
        done <<<"$limine_output"

        if [[ $limine_exit_code -eq 0 ]]; then
            log_success "Limine installé sur $boot_disk (BIOS)"
        else
            log_error "Échec de limine bios-install"
            return 1
        fi
    fi

    if [[ ! -f /boot/limine.cfg ]] && [[ ! -f /boot/limine/limine.cfg ]]; then
        local root_uuid
        root_uuid=$(findmnt -n -o UUID / 2>/dev/null | head -1)

        if [[ -z "$root_uuid" ]]; then
            root_uuid=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /)" 2>/dev/null)
        fi

        cat >/boot/limine.cfg <<EOF
# Limine configuration generated by Rep-Dem
TIMEOUT=5

:Linux
    COMMENT=Boot default Linux
    PROTOCOL=linux
    KERNEL_PATH=/boot/vmlinuz-linux
    MODULE_PATH=/boot/initramfs-linux.img
    KERNEL_CMDLINE=root=UUID=${root_uuid} rw quiet

:Linux-Fallback
    COMMENT=Boot Linux (fallback initramfs)
    PROTOCOL=linux
    KERNEL_PATH=/boot/vmlinuz-linux
    MODULE_PATH=/boot/initramfs-linux-fallback.img
    KERNEL_CMDLINE=root=UUID=${root_uuid} rw

:UEFI-Shell
    COMMENT=UEFI Shell
    PROTOCOL=uefi-shell
EOF
        log_success "Configuration Limine générée : /boot/limine.cfg"
    fi

    log_success "Réparation Limine terminée"
    mark_operation_completed "limine_repair"
    return 0
}

#-------------------------------------------------------------------------------
# MODULE : GESTIONNAIRE DE BOOTLOADERS (installation/suppression/restauration)
#-------------------------------------------------------------------------------
manage_bootloaders() {
    log_header "GESTIONNAIRE DE BOOTLOADERS"

    _require_installed_or_chroot_context "Gestionnaire de bootloaders" || return 1

    while true; do
        echo ""
        printf "%b\n" "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${BOLD}║                     GESTIONNAIRE DE BOOTLOADERS                      ║${NC}"
        printf "%b\n" "${BOLD}╠══════════════════════════════════════════════════════════════════════╣${NC}"
        printf "%b\n" "${BOLD}║${NC}                                                                      ${BOLD}║${NC}"
        printf "%b\n" "${BOLD}║${NC}  ┌─────────────┬─────────────────────────────────────────────┐    ${BOLD}║${NC}"
        printf "%b\n" "${BOLD}║${NC}  │ BOOTLOADER  │  ACTIONS                                    │    ${BOLD}║${NC}"
        printf "%b\n" "${BOLD}║${NC}  ├─────────────┼─────────────────────────────────────────────┤    ${BOLD}║${NC}"

        local grub_status="❌ non installé                                    "
        [[ -f /boot/grub/grub.cfg || -f /boot/grub2/grub.cfg ]] && grub_status="✅ installé                                        "
        printf "%b\n" "${BOLD}║${NC}  │ ${CYAN}GRUB${NC}        │  ${grub_status}${BOLD}║${NC}"

        local sd_status="❌ non installé                                    "
        (command_exists bootctl && bootctl is-installed 2>/dev/null) && sd_status="✅ installé                                        "
        printf "%b\n" "${BOLD}║${NC}  │ ${CYAN}systemd-boot${NC}│  ${sd_status}${BOLD}║${NC}"

        local refind_status="❌ non installé                                    "
        [[ -d /boot/efi/EFI/refind || -d /efi/EFI/refind ]] && refind_status="✅ installé                                        "
        printf "%b\n" "${BOLD}║${NC}  │ ${CYAN}rEFInd${NC}      │  ${refind_status}${BOLD}║${NC}"

        local limine_status="❌ non installé                                    "
        [[ -f /boot/limine.cfg || -f /boot/limine/limine.cfg ]] && limine_status="✅ installé                                        "
        printf "%b\n" "${BOLD}║${NC}  │ ${CYAN}Limine${NC}      │  ${limine_status}${BOLD}║${NC}"

        printf "%b\n" "${BOLD}║${NC}  └─────────────┴─────────────────────────────────────────────┘    ${BOLD}║${NC}"
        printf "%b\n" "${BOLD}║${NC}                                                                      ${BOLD}║${NC}"
        printf "%b\n" "${BOLD}╠══════════════════════════════════════════════════════════════════════╣${NC}"
        printf "%b\n" "${BOLD}║${NC}                                                                      ${BOLD}║${NC}"
        printf "%b  %b[1]%b  %-61s  %b\n" "${BOLD}║${NC}" "${YELLOW}" "${NC}" "GRUB         →  Installer / Réinstaller / Restaurer" "${BOLD}║${NC}"
        printf "%b  %b[2]%b  %-61s  %b\n" "${BOLD}║${NC}" "${YELLOW}" "${NC}" "systemd-boot →  Installer / Réinstaller / Supprimer" "${BOLD}║${NC}"
        printf "%b  %b[3]%b  %-61s  %b\n" "${BOLD}║${NC}" "${YELLOW}" "${NC}" "rEFInd       →  Installer / Réinstaller / Supprimer" "${BOLD}║${NC}"
        printf "%b  %b[4]%b  %-61s  %b\n" "${BOLD}║${NC}" "${YELLOW}" "${NC}" "Limine       →  Installer / Réinstaller / Supprimer" "${BOLD}║${NC}"
        printf "%b  %b[5]%b  %-61s  %b\n" "${BOLD}║${NC}" "${YELLOW}" "${NC}" "Restaurer GRUB original (purge + réinstallation)" "${BOLD}║${NC}"
        printf "%b  %b[6]%b  %-61s  %b\n" "${BOLD}║${NC}" "${YELLOW}" "${NC}" "Nettoyer ESP (supprimer TOUS les bootloaders tiers)" "${BOLD}║${NC}"
        printf "%b  %b[7]%b  %-61s  %b\n" "${BOLD}║${NC}" "${YELLOW}" "${NC}" "Retour" "${BOLD}║${NC}"
        printf "%b\n" "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        read -r -p "Choix [1-7] : " bl_choice

        case "$bl_choice" in
        1) _submenu_grub ;;
        2) _submenu_systemd_boot ;;
        3) _submenu_refind ;;
        4) _submenu_limine ;;
        5) _restore_original_grub ;;
        6) _clean_esp_bootloaders ;;
        7) return 0 ;;
        *) log_warning "Choix invalide" ;;
        esac
    done
}

_submenu_grub() {
    while true; do
        echo ""
        printf "%b\n" "${CYAN}${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
        printf "%b\n" "${CYAN}${BOLD}│                        GESTION GRUB                         │${NC}"
        printf "%b\n" "${CYAN}${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "1)  Installer / Réinstaller GRUB"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "2)  Supprimer GRUB (fichiers + entrée UEFI)"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "3)  Retour"
        printf "%b\n" "${CYAN}${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        read -r -p "Choix [1-3] : " grub_choice

        case "$grub_choice" in
        1) repair_grub ;;
        2) _remove_grub ;;
        3) return 0 ;;
        *) log_warning "Choix invalide" ;;
        esac
    done
}

_remove_grub() {
    log_subheader "SUPPRESSION DE GRUB"

    _require_installed_or_chroot_context "Suppression GRUB" || return 1

    if ! confirm_action_level2 "Supprimer GRUB ? Cela rendra le système non bootable sans autre bootloader." "DELETE-GRUB"; then
        return 1
    fi

    log_info "Suppression des fichiers GRUB..."
    rm -rf /boot/grub 2>/dev/null
    rm -rf /boot/grub2 2>/dev/null
    rm -rf /etc/default/grub 2>/dev/null
    rm -rf /etc/grub.d 2>/dev/null

    if [[ $(detect_boot_mode) == "uefi" ]]; then
        log_info "Suppression de l'entrée UEFI GRUB..."
        efibootmgr -v 2>/dev/null | grep -i grub | grep -oE 'Boot[0-9A-F]{4}' | while read -r boot; do
            num=${boot#Boot}
            efibootmgr -b "$num" -B 2>/dev/null
            log_success "Entrée $boot supprimée"
        done
    fi

    local grub_pkg_installed=false
    case "$DISTRO_FAMILY" in
    debian)
        dpkg -l grub-pc grub-efi* 2>/dev/null | grep -q '^ii' && grub_pkg_installed=true
        ;;
    rhel)
        rpm -q grub2* &>/dev/null && grub_pkg_installed=true
        ;;
    arch)
        pacman -Q grub &>/dev/null && grub_pkg_installed=true
        ;;
    esac

    if [[ "$grub_pkg_installed" == true ]]; then
        if confirm_action "Supprimer également les paquets GRUB ?" no; then
            case "$DISTRO_FAMILY" in
            debian) apt purge -y grub-pc grub-efi* grub-common ;;
            rhel) dnf remove -y grub2* ;;
            arch) pacman -Rns --noconfirm grub ;;
            esac
            log_success "Paquets GRUB supprimés"
        fi
    else
        log_info "Paquets GRUB non installés (déjà supprimés)"
    fi

    log_success "GRUB a été supprimé"
    mark_operation_completed "grub_removed" 2>/dev/null
}

_submenu_refind() {
    while true; do
        echo ""
        printf "%b\n" "${CYAN}${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
        printf "%b\n" "${CYAN}${BOLD}│                       GESTION rEFIND                        │${NC}"
        printf "%b\n" "${CYAN}${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "1)  Installer / Réinstaller rEFInd"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "2)  Supprimer rEFInd (fichiers + entrée UEFI)"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "3)  Retour"
        printf "%b\n" "${CYAN}${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        read -r -p "Choix [1-3] : " refind_choice

        case "$refind_choice" in
        1) repair_refind ;;
        2) _remove_refind ;;
        3) return 0 ;;
        *) log_warning "Choix invalide" ;;
        esac
    done
}

_remove_refind() {
    log_subheader "SUPPRESSION DE rEFIND"

    _require_installed_or_chroot_context "Suppression rEFInd" || return 1

    if ! confirm_action_level2 "Supprimer rEFInd ?" "DELETE-REFIND"; then
        return 1
    fi

    for esp in /boot/efi /efi /boot; do
        if [[ -d "$esp/EFI/refind" ]]; then
            rm -rf "$esp/EFI/refind"
            log_success "Supprimé : $esp/EFI/refind"
        fi
        if [[ -d "$esp/EFI/BOOT" ]]; then
            rm -f "$esp/EFI/BOOT"/refind*.efi 2>/dev/null
        fi
    done

    if [[ $(detect_boot_mode) == "uefi" ]]; then
        log_info "Suppression de l'entrée UEFI rEFInd..."
        efibootmgr -v 2>/dev/null | grep -i refind | grep -oE 'Boot[0-9A-F]{4}' | while read -r boot; do
            num=${boot#Boot}
            efibootmgr -b "$num" -B 2>/dev/null
            log_success "Entrée $boot supprimée"
        done
    fi

    local pkg_installed=false
    case "$DISTRO_FAMILY" in
    debian)
        dpkg -s refind &>/dev/null && pkg_installed=true
        ;;
    rhel)
        rpm -q refind &>/dev/null && pkg_installed=true
        ;;
    arch)
        pacman -Q refind &>/dev/null && pkg_installed=true
        ;;
    esac

    if [[ "$pkg_installed" == true ]]; then
        if confirm_action "Supprimer également les paquets rEFInd ?" no; then
            case "$DISTRO_FAMILY" in
            debian) apt purge -y refind ;;
            rhel) dnf remove -y refind ;;
            arch) pacman -Rns --noconfirm refind ;;
            esac
            log_success "Paquets rEFInd supprimés"
        fi
    else
        log_info "Paquet rEFInd non installé (déjà supprimé)"
    fi

    log_success "rEFInd a été supprimé"
}

_submenu_limine() {
    while true; do
        echo ""
        printf "%b\n" "${CYAN}${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
        printf "%b\n" "${CYAN}${BOLD}│                       GESTION LIMINE                        │${NC}"
        printf "%b\n" "${CYAN}${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "1)  Installer / Réinstaller Limine"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "2)  Supprimer Limine (fichiers + entrée UEFI)"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "3)  Retour"
        printf "%b\n" "${CYAN}${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        read -r -p "Choix [1-3] : " limine_choice

        case "$limine_choice" in
        1) repair_limine ;;
        2) _remove_limine ;;
        3) return 0 ;;
        *) log_warning "Choix invalide" ;;
        esac
    done
}

_remove_limine() {
    log_subheader "SUPPRESSION DE LIMINE"

    _require_installed_or_chroot_context "Suppression Limine" || return 1

    if ! confirm_action_level2 "Supprimer Limine ?" "DELETE-LIMINE"; then
        return 1
    fi

    rm -f /boot/limine.cfg 2>/dev/null
    rm -f /boot/limine.sys 2>/dev/null
    rm -f /boot/limine-bios.sys 2>/dev/null
    rm -rf /boot/limine 2>/dev/null

    for esp in /boot/efi /efi /boot; do
        if [[ -d "$esp/EFI/LIMINE" ]]; then
            rm -rf "$esp/EFI/LIMINE"
            log_success "Supprimé : $esp/EFI/LIMINE"
        fi
    done

    if [[ $(detect_boot_mode) == "uefi" ]]; then
        log_info "Suppression de l'entrée UEFI Limine..."
        efibootmgr -v 2>/dev/null | grep -i limine | grep -oE 'Boot[0-9A-F]{4}' | while read -r boot; do
            num=${boot#Boot}
            efibootmgr -b "$num" -B 2>/dev/null
            log_success "Entrée $boot supprimée"
        done
    fi

    local limine_pkg_installed=false
    case "$DISTRO_FAMILY" in
    arch)
        pacman -Q limine &>/dev/null && limine_pkg_installed=true
        ;;
    esac

    if [[ "$limine_pkg_installed" == true ]]; then
        if confirm_action "Supprimer également les paquets Limine ?" no; then
            case "$DISTRO_FAMILY" in
            arch) pacman -Rns --noconfirm limine ;;
            esac
            log_success "Paquets Limine supprimés"
        fi
    else
        log_info "Paquet Limine non installé (déjà supprimé ou distribution non supportée)"
    fi

    log_success "Limine a été supprimé"
}

_submenu_systemd_boot() {
    while true; do
        echo ""
        printf "%b\n" "${CYAN}${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
        printf "%b\n" "${CYAN}${BOLD}│                    GESTION SYSTEMD-BOOT                     │${NC}"
        printf "%b\n" "${CYAN}${BOLD}├─────────────────────────────────────────────────────────────┤${NC}"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "1)  Installer / Réinstaller systemd-boot"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "2)  Supprimer systemd-boot (fichiers + entrée UEFI)"
        printf "${CYAN}${BOLD}│${NC}  %-57s  ${CYAN}${BOLD}│${NC}\n" "3)  Retour"
        printf "%b\n" "${CYAN}${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        read -r -p "Choix [1-3] : " sd_choice

        case "$sd_choice" in
        1) repair_systemd_boot ;;
        2) _remove_systemd_boot ;;
        3) return 0 ;;
        *) log_warning "Choix invalide" ;;
        esac
    done
}

_remove_systemd_boot() {
    log_subheader "SUPPRESSION DE SYSTEMD-BOOT"

    _require_installed_or_chroot_context "Suppression systemd-boot" || return 1

    if ! confirm_action_level2 "Supprimer systemd-boot ?" "DELETE-SDBOOT"; then
        return 1
    fi

    for esp in /boot/efi /efi /boot; do
        if [[ -d "$esp/EFI/systemd" ]]; then
            rm -rf "$esp/EFI/systemd"
            log_success "Supprimé : $esp/EFI/systemd"
        fi
        rm -rf "$esp/loader" 2>/dev/null
    done

    if [[ $(detect_boot_mode) == "uefi" ]]; then
        log_info "Suppression de l'entrée UEFI systemd-boot..."
        efibootmgr -v 2>/dev/null | grep -iE 'systemd-boot|Linux Boot Manager' | grep -oE 'Boot[0-9A-F]{4}' | while read -r boot; do
            num=${boot#Boot}
            efibootmgr -b "$num" -B 2>/dev/null
            log_success "Entrée $boot supprimée"
        done
    fi

    log_success "systemd-boot a été supprimé"
}

_restore_original_grub() {
    log_header "RESTAURATION GRUB ORIGINAL"

    _require_installed_or_chroot_context "Restauration GRUB" || return 1

    if ! confirm_action_level2 "Cette action va purger GRUB et le réinstaller complètement. Continue ?" "RESTORE-GRUB"; then
        return 1
    fi

    backup_partition_tables
    backup_grub_configuration
    purge_grub
    COMPLETED_OPERATIONS["grub_repair"]=""
    repair_grub

    log_success "GRUB original restauré"
}

_clean_esp_bootloaders() {
    log_header "NETTOYAGE DE L'ESP"

    _require_installed_or_chroot_context "Nettoyage ESP" || return 1

    echo ""
    printf "%b\n" "${RED}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${RED}${BOLD}║  ATTENTION : Cette action va supprimer TOUS les bootloaders     ║${NC}"
    printf "%b\n" "${RED}${BOLD}║  tiers de votre ESP (rEFInd, Limine, systemd-boot).            ║${NC}"
    printf "%b\n" "${RED}${BOLD}║  GRUB sera conservé si présent.                                 ║${NC}"
    printf "%b\n" "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if ! confirm_action_level2 "Voulez-vous vraiment nettoyer l'ESP ?" "CLEAN-ESP"; then
        return 1
    fi

    local esp_backup
    esp_backup="${BACKUP_DIR}/esp-clean-$(date +%Y%m%d_%H%M%S).tar.gz"
    for esp in /boot/efi /efi /boot; do
        if [[ -d "$esp/EFI" ]]; then
            tar -czf "$esp_backup" -C "$(dirname "$esp")" "$(basename "$esp")" 2>/dev/null
            log_success "ESP sauvegardée : $esp_backup"
            break
        fi
    done

    _remove_refind 2>/dev/null
    _remove_limine 2>/dev/null
    _remove_systemd_boot 2>/dev/null

    log_success "ESP nettoyée. GRUB est conservé."
}

#-------------------------------------------------------------------------------
# MODULE : RÉPARATION EN CHROOT (live USB → système installé)
#-------------------------------------------------------------------------------
_chroot_cleanup() {
    local chroot_dir="$1"
    log_info "Démontage du chroot $chroot_dir..."
    for sub in /sys/firmware/efi/efivars /run /sys /proc /dev/pts /dev /boot/efi /boot; do
        umount "${chroot_dir}${sub}" 2>/dev/null || true
    done
    umount "$chroot_dir" 2>/dev/null || true
    rmdir "$chroot_dir" 2>/dev/null || true
    log_info "Chroot démonté"
}

repair_in_chroot() {
    log_header "RÉPARATION EN CHROOT"
    echo ""
    log_info "Scan des partitions Linux disponibles..."

    if command_exists vgscan; then
        vgscan --mknodes >/dev/null 2>&1 || true
    fi
    if command_exists vgchange; then
        if vgchange -ay >/dev/null 2>&1; then
            log_info "Volumes LVM activés (vgchange -ay)"
        fi
    fi

    local tmp_mnt
    tmp_mnt=$(mktemp -d /tmp/rd_probe_XXXXXX)
    local idx=0
    declare -A inst_map
    local -a installs=()

    local -a _candidates=()
    while read -r _dev; do
        [[ -b "$_dev" ]] || continue
        local _fstype
        _fstype=$(blkid -s TYPE -o value "$_dev" 2>/dev/null)
        case "$_fstype" in
        ext2 | ext3 | ext4 | btrfs | xfs | f2fs | jfs | reiserfs) _candidates+=("$_dev") ;;
        esac
    done < <(
        # Partitions classiques
        lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="part"{print $1}'
        # Mappers device-mapper (LUKS ouvert, LVM LV)
        lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="lvm" || $2=="crypt"{print $1}'
        # /dev/mapper/* explicites au cas où lsblk ne remonte pas tout
        for f in /dev/mapper/*; do
            [ "$f" != "/dev/mapper/control" ] && printf '%s\n' "$f"
        done
    )
    # Dédoublonnage
    local -a _unique_candidates=()
    local _seen=""
    for _c in "${_candidates[@]}"; do
        [[ "$_seen" == *"|${_c}|"* ]] && continue
        _seen+="|${_c}|"
        _unique_candidates+=("$_c")
    done

    for dev in "${_unique_candidates[@]}"; do
        if mount -o ro,noatime "$dev" "$tmp_mnt" 2>/dev/null; then
            if [[ -f "$tmp_mnt/etc/os-release" ]]; then
                local name _uuid
                name=$(grep -m1 '^PRETTY_NAME=' "$tmp_mnt/etc/os-release" 2>/dev/null |
                    tr -d '"' | cut -d= -f2-)
                _uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || echo "—")
                idx=$((idx + 1))
                inst_map[$idx]="$dev"
                installs+=("$(printf "  %2d) %-22s  %-28s  UUID: %s" \
                    "$idx" "$dev" "${name:-Linux}" "$_uuid")")
            fi
            umount "$tmp_mnt" 2>/dev/null
        fi
    done
    rmdir "$tmp_mnt" 2>/dev/null

    if ((${#installs[@]} == 0)); then
        log_warning "Aucun système Linux installé détecté sur les partitions disponibles."
        echo ""
        echo "  Partitions et mappers visibles :"
        lsblk -o NAME,FSTYPE,SIZE,TYPE,MOUNTPOINT 2>/dev/null | grep -vE '^loop' | awk '{print "  "$0}'
        echo ""
        echo "  Si votre root est sur LUKS, déverrouillez-le d'abord :"
        echo "    cryptsetup luksOpen /dev/sdXY nom_mapper"
        echo "  Si votre root est sur LVM, activez les VGs :"
        echo "    vgchange -ay"
        return 1
    fi

    echo ""
    printf "%b\n" "${CYAN}${BOLD}Installations Linux détectées :${NC}"
    echo "───────────────────────────────────────────────────────────"
    printf '%s\n' "${installs[@]}"
    echo "───────────────────────────────────────────────────────────"
    echo ""
    read -r -p "Numéro de l'installation à réparer : " chosen

    local root_dev="${inst_map[$chosen]:-}"
    if [[ -z "$root_dev" || ! -b "$root_dev" ]]; then
        log_error "Sélection invalide"
        return 1
    fi

    local chroot_dir
    chroot_dir=$(mktemp -d /tmp/rd_chroot_XXXXXX)
    log_info "Montage de $root_dev sur $chroot_dir..."

    if ! mount "$root_dev" "$chroot_dir"; then
        log_error "Impossible de monter $root_dev"
        rmdir "$chroot_dir"
        return 1
    fi

    local boot_dev=""
    if [[ -f "$chroot_dir/etc/fstab" ]]; then
        local boot_spec efi_spec efi_dev
        boot_spec=$(awk '$2=="/boot" && $1!~/^#/{print $1}' "$chroot_dir/etc/fstab" | head -1)
        efi_spec=$(awk '$2=="/boot/efi" && $1!~/^#/{print $1}' "$chroot_dir/etc/fstab" | head -1)
        if [[ -n "$boot_spec" ]]; then
            boot_dev=$(_resolve_fstab_device "$boot_spec" 2>/dev/null) || true
            if [[ -n "$boot_dev" ]] && _validate_block_device "$boot_dev" 2>/dev/null; then
                log_info "Montage /boot séparé : $boot_dev"
                mount "$boot_dev" "$chroot_dir/boot" 2>/dev/null ||
                    log_warning "Impossible de monter /boot"
            fi
        fi
        if [[ -n "$efi_spec" ]]; then
            efi_dev=$(_resolve_fstab_device "$efi_spec" 2>/dev/null) || true
            if [[ -n "$efi_dev" ]] && _validate_block_device "$efi_dev" 2>/dev/null; then
                mkdir -p "$chroot_dir/boot/efi"
                log_info "Montage EFI : $efi_dev"
                mount "$efi_dev" "$chroot_dir/boot/efi" 2>/dev/null ||
                    log_warning "Impossible de monter /boot/efi"
            fi
        fi
        local efi2_spec efi2_dev
        efi2_spec=$(awk '$2=="/efi" && $1!~/^#/{print $1}' "$chroot_dir/etc/fstab" | head -1)
        if [[ -n "$efi2_spec" ]]; then
            efi2_dev=$(_resolve_fstab_device "$efi2_spec" 2>/dev/null) || true
            if [[ -n "$efi2_dev" ]] && _validate_block_device "$efi2_dev" 2>/dev/null; then
                mkdir -p "$chroot_dir/efi"
                log_info "Montage EFI (/efi) : $efi2_dev"
                mount "$efi2_dev" "$chroot_dir/efi" 2>/dev/null ||
                    log_warning "Impossible de monter /efi"
            fi
        fi
    fi

    for d in /dev /dev/pts /proc /sys /run; do
        mkdir -p "${chroot_dir}${d}"
        # C10: --rbind + --make-rslave pour éviter la propagation inverse vers l'hôte
        if mount --rbind "$d" "${chroot_dir}${d}" 2>/dev/null; then
            mount --make-rslave "${chroot_dir}${d}" 2>/dev/null || true
        else
            mount --bind "$d" "${chroot_dir}${d}" 2>/dev/null ||
                log_warning "mount $d échoué"
        fi
    done
    if [[ -d /sys/firmware/efi/efivars ]]; then
        mkdir -p "$chroot_dir/sys/firmware/efi/efivars"
        mount --bind /sys/firmware/efi/efivars \
            "$chroot_dir/sys/firmware/efi/efivars" 2>/dev/null || true
    fi

    local chroot_family=""
    if [[ -f "$chroot_dir/etc/os-release" ]]; then
        local chroot_id chroot_id_like
        chroot_id=$(grep -m1 '^ID=' "$chroot_dir/etc/os-release" 2>/dev/null |
            cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        chroot_id_like=$(grep -m1 '^ID_LIKE=' "$chroot_dir/etc/os-release" 2>/dev/null |
            cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        _resolve_chroot_family() {
            case "$1" in
            ubuntu | debian | mint | pop | linuxmint | elementary | zorin | kali | parrot | \
                raspbian | mx | neon | devuan | antix | bodhi | sparky | peppermint)
                chroot_family="debian"
                ;;
            fedora | rhel | centos | centos-stream | rocky | alma | almalinux | ol | scientific)
                chroot_family="rhel"
                ;;
            arch | manjaro | endeavouros | garuda | artix | cachyos | arcolinux)
                chroot_family="arch"
                ;;
            opensuse* | sles | suse | tumbleweed | leap)
                chroot_family="suse"
                ;;
            void)
                chroot_family="void"
                ;;
            gentoo | calculate | funtoo)
                chroot_family="gentoo"
                ;;
            alpine)
                chroot_family="alpine"
                ;;
            esac
        }
        _resolve_chroot_family "$chroot_id"
        if [[ -z "$chroot_family" ]]; then
            for _tok in $chroot_id_like; do
                _resolve_chroot_family "$_tok"
                [[ -n "$chroot_family" ]] && break
            done
        fi
        if [[ -z "$chroot_family" ]]; then
            if [[ -x "$chroot_dir/usr/bin/pacman" ]]; then
                chroot_family="arch"
            elif [[ -x "$chroot_dir/usr/bin/dnf" ]]; then
                chroot_family="rhel"
            elif [[ -x "$chroot_dir/usr/bin/yum" ]]; then
                chroot_family="rhel"
            elif [[ -x "$chroot_dir/usr/bin/apt-get" ]]; then
                chroot_family="debian"
            elif [[ -x "$chroot_dir/usr/bin/zypper" ]]; then
                chroot_family="suse"
            elif [[ -x "$chroot_dir/usr/bin/xbps-install" ]]; then
                chroot_family="void"
            elif [[ -x "$chroot_dir/usr/bin/emerge" ]]; then
                chroot_family="gentoo"
            elif [[ -x "$chroot_dir/sbin/apk" ]]; then
                chroot_family="alpine"
            else
                chroot_family="debian"
                log_warning "Famille chroot non détectée — fallback debian (risque)"
            fi
            log_warning "os-release insuffisant — famille déduite via binaires : $chroot_family"
        fi
        unset -f _resolve_chroot_family
    else
        chroot_family="debian"
        log_warning "/etc/os-release absent dans le chroot — fallback debian"
    fi

    local grub_disk boot_mode
    local grub_probe_source="$root_dev"
    [[ -n "$boot_dev" ]] && grub_probe_source="$boot_dev"

    grub_disk=$(_resolve_grub_target_disk "$grub_probe_source" 2>/dev/null || true)

    if [[ -z "$grub_disk" ]]; then
        grub_disk=$(detect_boot_device)
    fi

    if [[ -z "$grub_disk" ]]; then
        echo ""
        lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null |
            grep -v loop |
            awk 'NR==1{print "  "$0} NR>1{print "  /dev/"$0}'
        echo ""
        read -r -p "Disque cible pour GRUB (ex. /dev/sda) : " grub_disk
    fi

    # C07: validation stricte de grub_disk pour éviter l'injection de shell
    if ! _validate_block_device "$grub_disk" 2>/dev/null; then
        log_error "Disque invalide ou chemin dangereux : '$grub_disk'"
        _chroot_cleanup "$chroot_dir"
        return 1
    fi

    boot_mode=$(_detect_target_boot_mode "$chroot_dir")
    local target_uefi=false
    if [[ -f "$chroot_dir/boot/efi/loader/loader.conf" ]] ||
        [[ -f "$chroot_dir/boot/loader/loader.conf" ]] ||
        [[ -f "$chroot_dir/efi/loader/loader.conf" ]] ||
        [[ -d "$chroot_dir/boot/efi/EFI" ]] ||
        [[ -d "$chroot_dir/efi/EFI" ]]; then
        target_uefi=true
    fi

    local chroot_uses_sd=false
    if [[ "$boot_mode" == "uefi" || "$target_uefi" == true ]]; then
        local _id_chroot
        _id_chroot=$(grep -m1 '^ID=' "$chroot_dir/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
        if [[ "${_id_chroot,,}" == "pop" ]]; then
            chroot_uses_sd=true
        elif [[ -f "$chroot_dir/boot/efi/loader/loader.conf" ]] ||
            [[ -f "$chroot_dir/boot/loader/loader.conf" ]] ||
            [[ -f "$chroot_dir/efi/loader/loader.conf" ]] ||
            compgen -G "$chroot_dir/boot/efi/EFI/systemd/systemd-boot*.efi" >/dev/null ||
            compgen -G "$chroot_dir/efi/EFI/systemd/systemd-boot*.efi" >/dev/null; then
            chroot_uses_sd=true
        fi
    fi

    if [[ "$chroot_uses_sd" == true ]]; then
        log_info "Système cible utilise systemd-boot — réparation via bootctl"
        local sd_cmd
        sd_cmd=$(_build_chroot_initramfs_refresh_cmd "$chroot_dir")
        sd_cmd+="; exit"
        log_info "Commande chroot systemd-boot : $sd_cmd"
        chroot "$chroot_dir" /bin/bash -c "$sd_cmd" 2>&1 |
            while read -r line; do log_info "chroot: $line"; done
        local chroot_esp=""
        local chroot_esp_rel=""
        for _rel in /boot/efi /efi /boot; do
            local _host_esp="${chroot_dir}${_rel}"
            if mountpoint -q "$_host_esp" 2>/dev/null || [[ -d "$_host_esp/EFI" || -f "$_host_esp/loader/loader.conf" ]]; then
                chroot_esp="$_host_esp"
                chroot_esp_rel="$_rel"
                break
            fi
        done

        local sd_ok=false
        if [[ -n "$chroot_esp" ]]; then
            if ! command_exists bootctl && ! chroot "$chroot_dir" command -v bootctl >/dev/null 2>&1; then
                log_error "bootctl introuvable (Live et chroot) — impossible de réparer systemd-boot"
                _chroot_cleanup "$chroot_dir"
                return 1
            fi

            if command_exists bootctl; then
                if bootctl install --esp-path="$chroot_esp" 2>&1 |
                    while read -r line; do log_info "bootctl: $line"; done; then
                    sd_ok=true
                    log_success "systemd-boot réinstallé via Live (esp=$chroot_esp)"
                elif bootctl install --esp-path="$chroot_esp" --no-variables 2>&1 |
                    while read -r line; do log_info "bootctl(no-vars): $line"; done; then
                    sd_ok=true
                    log_success "systemd-boot réinstallé via Live sans MAJ NVRAM (esp=$chroot_esp)"
                elif bootctl --variables=no install --esp-path="$chroot_esp" 2>&1 |
                    while read -r line; do log_info "bootctl(vars=no): $line"; done; then
                    sd_ok=true
                    log_success "systemd-boot réinstallé via Live avec compat variables=no (esp=$chroot_esp)"
                fi
            fi

            if [[ "$sd_ok" == false ]]; then
                if chroot "$chroot_dir" command -v bootctl >/dev/null 2>&1; then
                    if chroot "$chroot_dir" bootctl install --esp-path="$chroot_esp_rel" 2>&1 |
                        while read -r line; do log_info "chroot bootctl: $line"; done; then
                        sd_ok=true
                        log_success "systemd-boot réinstallé depuis le chroot (esp=$chroot_esp_rel)"
                    elif chroot "$chroot_dir" bootctl install --esp-path="$chroot_esp_rel" --no-variables 2>&1 |
                        while read -r line; do log_info "chroot bootctl(no-vars): $line"; done; then
                        sd_ok=true
                        log_success "systemd-boot réinstallé depuis le chroot sans MAJ NVRAM (esp=$chroot_esp_rel)"
                    elif chroot "$chroot_dir" bootctl --variables=no install --esp-path="$chroot_esp_rel" 2>&1 |
                        while read -r line; do log_info "chroot bootctl(vars=no): $line"; done; then
                        sd_ok=true
                        log_success "systemd-boot réinstallé depuis le chroot avec compat variables=no (esp=$chroot_esp_rel)"
                    fi
                fi
            fi

            if [[ "$sd_ok" == false ]]; then
                log_error "Échec bootctl install (Live et chroot)"
            fi
        else
            log_warning "ESP introuvable dans le chroot — bootctl non installé"
        fi
        _chroot_cleanup "$chroot_dir"
        return 0
    fi

    local _efi_tgt
    _efi_tgt=$(detect_efi_arch)
    local _efi_dir="/boot/efi"
    if mountpoint -q "$chroot_dir/efi" 2>/dev/null || [[ -d "$chroot_dir/efi/EFI" ]]; then
        _efi_dir="/efi"
    fi

    case "$chroot_family" in
    debian)
        if [[ "$boot_mode" == "uefi" || "$target_uefi" == true ]]; then
            # C07: invocation directe chroot avec arguments — pas de bash -c
            log_info "chroot GRUB Debian UEFI"
            chroot "$chroot_dir" grub-install \
                --target="$_efi_tgt" --efi-directory="$_efi_dir" \
                --bootloader-id=GRUB --recheck 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
            chroot "$chroot_dir" update-grub 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
        else
            log_info "chroot GRUB Debian BIOS"
            chroot "$chroot_dir" grub-install \
                --target=i386-pc --recheck "$grub_disk" 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
            chroot "$chroot_dir" update-grub 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
        fi
        ;;
    rhel)
        if [[ "$boot_mode" == "uefi" || "$target_uefi" == true ]]; then
            log_info "chroot GRUB RHEL UEFI"
            chroot "$chroot_dir" grub2-install \
                --target="$_efi_tgt" --efi-directory="$_efi_dir" \
                --bootloader-id=GRUB --recheck 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
            chroot "$chroot_dir" grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
        else
            log_info "chroot GRUB RHEL BIOS"
            chroot "$chroot_dir" grub2-install \
                --target=i386-pc --recheck "$grub_disk" 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
            chroot "$chroot_dir" grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
        fi
        ;;
    arch)
        if [[ "$boot_mode" == "uefi" || "$target_uefi" == true ]]; then
            log_info "chroot GRUB Arch UEFI"
            chroot "$chroot_dir" grub-install \
                --target="$_efi_tgt" --efi-directory="$_efi_dir" \
                --bootloader-id=GRUB --recheck 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
            chroot "$chroot_dir" grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
        else
            log_info "chroot GRUB Arch BIOS"
            chroot "$chroot_dir" grub-install \
                --target=i386-pc --recheck "$grub_disk" 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
            chroot "$chroot_dir" grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
        fi
        ;;
    suse)
        if [[ "$boot_mode" == "uefi" || "$target_uefi" == true ]]; then
            log_info "chroot GRUB SUSE UEFI"
            chroot "$chroot_dir" grub2-install \
                --target="$_efi_tgt" --efi-directory="$_efi_dir" \
                --bootloader-id=grub --recheck 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
            chroot "$chroot_dir" grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
        else
            log_info "chroot GRUB SUSE BIOS"
            chroot "$chroot_dir" grub2-install \
                --target=i386-pc --recheck "$grub_disk" 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
            chroot "$chroot_dir" grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | while IFS= read -r _l; do log_info "chroot: $_l"; done
        fi
        ;;
    *)
        log_info "chroot GRUB générique"
        chroot "$chroot_dir" grub-install --recheck "$grub_disk" 2>/dev/null | while IFS= read -r _l; do log_info "chroot: $_l"; done || true
        chroot "$chroot_dir" update-grub 2>/dev/null | while IFS= read -r _l; do log_info "chroot: $_l"; done ||
            chroot "$chroot_dir" grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null | while IFS= read -r _l; do log_info "chroot: $_l"; done || true
        ;;
    esac

    log_success "GRUB réinstallé avec succès via chroot sur $chroot_dir"

    _chroot_cleanup "$chroot_dir"
}

#-------------------------------------------------------------------------------
# MODULE : UPLOAD RAPPORT EN LIGNE
#-------------------------------------------------------------------------------
upload_report() {
    local report_file="${1:-${BACKUP_DIR}/boot-info.txt}"
    if [[ ! -f "$report_file" ]]; then
        log_error "Fichier rapport introuvable : $report_file"
        return 1
    fi
    local _has_curl=false _has_wget=false
    command_exists curl && _has_curl=true
    command_exists wget && _has_wget=true
    if [[ "$_has_curl" == false && "$_has_wget" == false ]]; then
        log_warning "curl et wget non disponibles — upload impossible."
        log_info "Rapport local : $report_file"
        log_info "Pour installer : sudo apt install curl  (Debian/Ubuntu)  |  sudo dnf install curl  (Fedora/RHEL)"
        return 1
    fi
    if [[ "$_has_curl" == true ]]; then
        curl -sf --max-time 15 --head https://dpaste.com >/dev/null 2>&1
    else
        wget -q --spider --timeout=15 https://dpaste.com >/dev/null 2>&1
    fi || {
        log_warning "Pas de connexion internet détectée. Upload ignoré."
        log_info "Rapport local : $report_file"
        return 1
    }

    local url_ubuntu="" url_dpaste="" url_gofile=""
    if [[ "$_has_curl" == true ]]; then
        local tmp_u tmp_d tmp_g
        tmp_u=$(mktemp /tmp/rd_up_ubuntu_XXXXXX)
        tmp_d=$(mktemp /tmp/rd_up_dpaste_XXXXXX)
        tmp_g=$(mktemp /tmp/rd_up_gofile_XXXXXX)

        log_info "Upload en parallèle sur les 3 services..."

        # paste.ubuntu.com
        (
            _html=$(curl -sf --max-time 30 \
                -A "Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0" \
                -L \
                -F "poster=Rep-Dem" \
                -F "syntax=text" \
                -F "content=<${report_file}" \
                https://paste.ubuntu.com/ 2>/dev/null)
            echo "$_html" | grep -oE 'next=/p/[A-Za-z0-9]+' | head -1 | cut -d'=' -f2 >"$tmp_u"
        ) &

        local pid_u=$!

        # dpaste.com
        (curl -sf --max-time 30 -X POST https://dpaste.com/api/v2/ \
            --data-urlencode "content@${report_file}" \
            -d "syntax=text" \
            -d "expiry_days=7" 2>/dev/null >"$tmp_d") &
        local pid_d=$!

        # gofile.io
        (
            _gf_server=$(curl -sf --max-time 10 "https://api.gofile.io/servers" 2>/dev/null |
                grep -oE '"name":"[^"]+"' | head -1 | cut -d'"' -f4)
            if [[ -n "$_gf_server" ]]; then
                curl -sf --max-time 60 \
                    -X POST \
                    -F "file=@${report_file}" \
                    "https://${_gf_server}.gofile.io/contents/uploadfile" 2>/dev/null |
                    grep -oE '"downloadPage":"[^"]+' | cut -d'"' -f4 | head -1 >"$tmp_g"
            fi
        ) &
        local pid_g=$!

        wait $pid_u $pid_d $pid_g 2>/dev/null

        local raw_u raw_d
        raw_u=$(cat "$tmp_u" 2>/dev/null)
        raw_d=$(cat "$tmp_d" 2>/dev/null)
        [[ -n "$raw_u" ]] && url_ubuntu="https://paste.ubuntu.com${raw_u}/"
        [[ -n "$raw_d" ]] && url_dpaste="$raw_d"
        url_gofile=$(cat "$tmp_g" 2>/dev/null)
        rm -f "$tmp_u" "$tmp_d" "$tmp_g"
    else
        log_info "curl absent — upload via wget (dpaste.com uniquement)..."
        if command_exists python3; then
            local _enc
            _enc=$(python3 -c "import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(open(sys.argv[1]).read()))" "$report_file" 2>/dev/null)
            [[ -n "$_enc" ]] && url_dpaste=$(wget -qO- --timeout=30 \
                --post-data "content=${_enc}&syntax=text&expiry_days=7" \
                https://dpaste.com/api/v2/ 2>/dev/null | tr -d '[:space:]')
        fi
        [[ -z "$url_dpaste" ]] && log_warning "Upload dpaste.com via wget échoué."
    fi

    local any_ok=false
    echo ""
    printf "%b\n" "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "LIENS DU RAPPORT BOOT-INFO" "${GREEN}${BOLD}║${NC}"
    printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "" "${GREEN}${BOLD}║${NC}"
    if [[ -n "$url_ubuntu" ]]; then
        any_ok=true
        printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "  paste.ubuntu.com : $url_ubuntu" "${GREEN}${BOLD}║${NC}"
    else
        printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "  paste.ubuntu.com : échec" "${GREEN}${BOLD}║${NC}"
    fi
    if [[ -n "$url_dpaste" ]]; then
        any_ok=true
        printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "  dpaste.com       : $url_dpaste" "${GREEN}${BOLD}║${NC}"
    else
        printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "  dpaste.com       : échec" "${GREEN}${BOLD}║${NC}"
    fi
    if [[ -n "$url_gofile" ]]; then
        any_ok=true
        printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "  gofile.io        : $url_gofile" "${GREEN}${BOLD}║${NC}"
    else
        printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "  gofile.io        : échec" "${GREEN}${BOLD}║${NC}"
    fi
    printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "" "${GREEN}${BOLD}║${NC}"
    printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "  Fichier local : $report_file" "${GREEN}${BOLD}║${NC}"
    printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "  Tous les liens sont écrits à la fin du rapport." "${GREEN}${BOLD}║${NC}"
    printf "%b\n" "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    {
        echo ""
        echo "=== LIENS UPLOAD ==="
        [[ -n "$url_ubuntu" ]] && echo "paste.ubuntu.com : $url_ubuntu"
        [[ -n "$url_dpaste" ]] && echo "dpaste.com       : $url_dpaste"
        [[ -n "$url_gofile" ]] && echo "gofile.io        : $url_gofile"
    } >>"$report_file"

    if [[ "$any_ok" == false ]]; then
        log_error "Tous les services d'upload ont échoué."
        log_info "Uploadez manuellement sur : https://paste.ubuntu.com  https://dpaste.com  https://gofile.io"
        return 1
    fi
}
#-------------------------------------------------------------------------------
# MODULE : CONFIGURATION OPTIONS MENU GRUB
#-------------------------------------------------------------------------------
configure_grub_menu_options() {
    log_header "CONFIGURATION GRUB"
    local grub_default="/etc/default/grub"
    if [[ ! -f "$grub_default" ]]; then
        log_error "Fichier introuvable : $grub_default — GRUB installé ?"
        return 1
    fi

    backup_file "$grub_default"

    echo ""
    echo "Configuration actuelle de $grub_default :"
    echo "───────────────────────────────────────────────────────────"
    grep -E '^GRUB_(TIMEOUT|DEFAULT|CMDLINE_LINUX_DEFAULT|GFXMODE|HIDDEN_TIMEOUT)' \
        "$grub_default" | awk '{print "  "$0}'
    echo "───────────────────────────────────────────────────────────"
    echo ""
    echo "  1)  Afficher le menu GRUB (désactiver timeout caché)"
    echo "  2)  Modifier le délai d'attente (GRUB_TIMEOUT)"
    echo "  3)  Ajouter une option noyau"
    echo "  4)  Supprimer une option noyau"
    echo "  5)  Modifier la résolution (GRUB_GFXMODE)"
    echo "  6)  Régénérer grub.cfg maintenant"
    echo "  7)  Retour"
    echo ""
    read -r -p "Choix [1-7] : " grub_opt

    case "$grub_opt" in
    1)
        sed -i '/^GRUB_HIDDEN_TIMEOUT=/d' "$grub_default" 2>/dev/null
        local cur_t
        cur_t=$(grep '^GRUB_TIMEOUT=' "$grub_default" 2>/dev/null | head -1 | cut -d= -f2)
        if [[ "$cur_t" == "0" || "$cur_t" == "-1" || -z "$cur_t" ]]; then
            sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' "$grub_default" 2>/dev/null ||
                echo 'GRUB_TIMEOUT=10' >>"$grub_default"
            log_success "GRUB_TIMEOUT réglé à 10 secondes — le menu s'affichera"
        else
            log_info "GRUB_TIMEOUT déjà à $cur_t — aucune modification"
        fi
        ;;
    2)
        read -r -p "Délai en secondes (ex. 10, -1=infini, 0=caché) : " new_t
        if grep -q '^GRUB_TIMEOUT=' "$grub_default"; then
            sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=${new_t}/" "$grub_default"
        else
            echo "GRUB_TIMEOUT=${new_t}" >>"$grub_default"
        fi
        log_success "GRUB_TIMEOUT=${new_t}"
        ;;
    3)
        echo "Exemples : nomodeset  acpi=off  acpi_osi=  noapic  nolapic  rootdelay=90  quiet splash"
        read -r -p "Option(s) à ajouter (séparées par des espaces) : " new_opt
        local cur_cmd
        cur_cmd=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default" |
            sed 's/^GRUB_CMDLINE_LINUX_DEFAULT=//' | tr -d '"')
        local new_cmd="${cur_cmd:+$cur_cmd }${new_opt}"
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new_cmd}\"|" \
            "$grub_default"
        log_success "Options noyau : \"$new_cmd\""
        ;;
    4)
        local cur_cmd
        cur_cmd=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default" |
            sed 's/^GRUB_CMDLINE_LINUX_DEFAULT=//' | tr -d '"')
        echo "Options actuelles : $cur_cmd"
        read -r -p "Option à supprimer : " rm_opt
        local new_cmd
        new_cmd=$(echo "$cur_cmd" | sed "s/\b${rm_opt}\b//g" |
            tr -s ' ' | sed 's/^ //;s/ $//')
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new_cmd}\"|" \
            "$grub_default"
        log_success "Options noyau après suppression : \"$new_cmd\""
        ;;
    5)
        read -r -p "Résolution (ex. 1024x768, 1920x1080, auto) : " new_gfx
        if grep -q '^GRUB_GFXMODE=' "$grub_default"; then
            sed -i "s|^GRUB_GFXMODE=.*|GRUB_GFXMODE=${new_gfx}|" "$grub_default"
        else
            echo "GRUB_GFXMODE=${new_gfx}" >>"$grub_default"
        fi
        log_success "GRUB_GFXMODE=${new_gfx}"
        ;;
    6) ;;
    7) return 0 ;;
    *)
        log_warning "Choix invalide"
        return 0
        ;;
    esac

    if [[ "$grub_opt" != "7" ]]; then
        local regenerate=false
        [[ "$grub_opt" == "6" ]] && regenerate=true
        if [[ "$grub_opt" != "6" ]] && confirm_action "Régénérer grub.cfg maintenant ?"; then
            regenerate=true
        fi
        if [[ "$regenerate" == "true" ]]; then
            if command_exists update-grub; then
                update-grub 2>&1 | while read -r line; do log_info "$line"; done
            elif command_exists grub-mkconfig; then
                grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | while read -r line; do log_info "$line"; done
            elif command_exists grub2-mkconfig; then
                grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | while read -r line; do log_info "$line"; done
            else
                log_error "Aucun outil grub-mkconfig / update-grub trouvé"
            fi
        fi
    fi
}

repair_bios_mbr() {
    local boot_device="$1"
    if ! command_exists grub-install; then
        log_warning "grub-install introuvable : impossible de restaurer le MBR via GRUB"
        return 1
    fi
    log_info "Restauration du MBR GRUB sur $boot_device"
    if grub-install --target=i386-pc --boot-directory=/boot --recheck "$boot_device" 2>&1 | while read -r line; do log_debug "$line"; done; then
        log_success "MBR GRUB restauré sur $boot_device"
        return 0
    fi
    log_error "Échec de la restauration du MBR GRUB sur $boot_device"
    return 1
}

purge_grub() {
    log_subheader "Purge GRUB"

    _require_installed_or_chroot_context "Purge GRUB" || return 1

    if ! confirm_action_level2 "Purge des paquets GRUB. Cette action est destructive." "PURGE-GRUB"; then
        return 1
    fi

    case "$DISTRO_FAMILY" in
    debian)
        apt-get purge -y grub-pc grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-signed grub-common grub2-common 2>&1 | while read -r line; do log_debug "$line"; done
        apt-get autoremove -y 2>&1 | while read -r line; do log_debug "$line"; done
        ;;
    rhel)
        $PKG_MANAGER remove -y grub2 grub2-efi-x64 grub2-pc 2>&1 | while read -r line; do log_debug "$line"; done
        ;;
    arch)
        pacman -Rns --noconfirm grub 2>&1 | while read -r line; do log_debug "$line"; done
        ;;
    *)
        log_warning "Purge GRUB non prise en charge pour : $DISTRO_FAMILY"
        return 1
        ;;
    esac
    log_success "Purge GRUB terminée"
}

generate_boot_info() {
    local output_file="${1:-${BACKUP_DIR}/boot-info.txt}"
    mkdir -p "$(dirname "$output_file")"
    log_info "Génération du rapport Boot-Info : $output_file"
    {
        echo "==============================================================================="
        echo " Boot-Info v${SCRIPT_VERSION}  |  $(date)"
        echo " Host: $(hostname)  |  Kernel: $(uname -r)  |  Arch: $(uname -m)"
        echo "==============================================================================="
        echo ""

        echo "============================== Boot Info Summary =============================="
        echo ""
        echo "Mode boot    : $([[ -d /sys/firmware/efi ]] && echo UEFI || echo "BIOS/Legacy")"
        echo "Bootloader   : $(detect_bootloader 2>/dev/null || echo inconnu)"
        echo "Distribution : $(sed -n 's/^PRETTY_NAME="\([^"]*\)".*/\1/p' /etc/os-release 2>/dev/null ||
            sed -n 's/^PRETTY_NAME=\([^\n]*\)/\1/p' /etc/os-release 2>/dev/null ||
            echo inconnu)"
        echo ""

        local _os_count
        _os_count=$(lsblk -lno FSTYPE 2>/dev/null | grep -cE '^(ext[234]|btrfs|xfs|f2fs|jfs|reiserfs)$' || echo "?")
        echo "==================== Partitions Linux potentielles : ${_os_count} ===================="
        lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINT,SIZE 2>/dev/null |
            grep -vE '^(loop|ram|zram)' || echo "indisponible"
        echo ""

        echo "================================ Host/Hardware ================================"
        echo "CPU arch : $(uname -m)"
        grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: /CPU model : /' || true
        echo ""

        echo "===================================== UEFI ===================================="
        if [[ -d /sys/firmware/efi ]]; then
            echo "Firmware UEFI : actif"
            efibootmgr -v 2>/dev/null | head -20 || echo "efibootmgr indisponible"
        else
            echo "Mode BIOS/Legacy (non-UEFI)"
        fi
        echo ""

        echo "============================= Drive/Partition Info ============================"
        echo ""
        echo "lsblk: _________________________________________________________________________"
        lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,UUID,LABEL,PARTUUID 2>/dev/null || echo "indisponible"
        echo ""
        echo "blkid (filtré): ________________________________________________________________"
        blkid 2>/dev/null || echo "indisponible"
        echo ""
        echo "fdisk -l (filtré): _____________________________________________________________"
        fdisk -l 2>/dev/null | grep -E '^(Disk /dev|/dev/|Units|Sector)' || echo "indisponible"
        echo ""
        echo "parted -lm (filtré): ___________________________________________________________"
        parted -lm 2>/dev/null | grep -v '^BYT' | head -40 || echo "indisponible"
        echo ""

        echo "=========================== fstab ============================================="
        grep -v '^#' /etc/fstab 2>/dev/null | grep -v '^[[:space:]]*$' || echo "absent"
        echo ""

        echo "=========================== /etc/default/grub ================================="
        if [[ -f /etc/default/grub ]]; then
            grep -v '^#' /etc/default/grub | grep -v '^[[:space:]]*$'
        else
            echo "absent"
        fi
        echo ""

        echo "=========================== grub.cfg (filtré) ================================="
        for cfg in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
            [[ -f "$cfg" ]] || continue
            echo "--- $cfg ---"
            grep -E '^[[:space:]]*(menuentry |### END |set default=|set timeout=)' "$cfg" |
                sed "s/menuentry ['\"]\\([^'\"]*\\)['\"].*/menuentry '\\1'/" |
                head -40 || echo "(aucune entrée)"
        done
        echo ""

        echo "=========================== grub.d (liste) ===================================="
        for d in /etc/grub.d /boot/grub/grub.d; do
            [[ -d "$d" ]] || continue
            echo "--- $d ---"
            ls -la "$d" 2>/dev/null || echo "vide"
        done
        echo ""

        echo "=========================== EFI partition contents ============================"
        for efi_dir in /boot/efi /efi; do
            [[ -d "$efi_dir/EFI" ]] || continue
            echo "$efi_dir/EFI :"
            find "$efi_dir/EFI" -maxdepth 3 2>/dev/null | sort
        done
        echo ""

        echo "=========================== systemd-boot ======================================"
        if command_exists bootctl; then
            bootctl status 2>/dev/null || echo "systemd-boot non installé"
            echo ""
            echo "--- Entrées (bootctl list) ---"
            bootctl list --no-pager 2>/dev/null || echo "aucune entrée"
        else
            echo "bootctl non disponible"
        fi
        for esp in /boot/efi /efi /boot; do
            [[ -f "${esp}/loader/loader.conf" ]] || continue
            echo "--- ${esp}/loader/loader.conf ---"
            cat "${esp}/loader/loader.conf" 2>/dev/null
            echo "--- ${esp}/loader/entries/ (liste) ---"
            ls "${esp}/loader/entries/" 2>/dev/null || echo "vide"
        done
        echo ""

        echo "=========================== Windows / BCD ====================================="
        for efi_dir in /boot/efi /efi; do
            find "$efi_dir" -maxdepth 4 \( -iname 'bootmgfw.efi' -o -iname 'bcd' \) 2>/dev/null
        done
        lsblk -f 2>/dev/null | grep -i ntfs || echo "Aucune partition NTFS détectée"
        echo ""

        echo "=========================== RAID =============================================="
        grep -v '^$' /proc/mdstat 2>/dev/null || echo "indisponible"
        command_exists mdadm && { mdadm --detail --scan 2>/dev/null || echo "aucun RAID mdadm"; }
        echo ""

        echo "=========================== LVM ==============================================="
        pvs 2>/dev/null || echo "aucun PV"
        vgs 2>/dev/null || echo "aucun VG"
        lvs 2>/dev/null || echo "aucun LV"
        echo ""

        echo "=========================== LUKS =============================================="
        command_exists cryptsetup &&
            { blkid -t TYPE=crypto_LUKS 2>/dev/null || echo "aucun volume LUKS détecté"; } ||
            echo "cryptsetup non disponible"
        echo ""

        echo "=========================== Secure Boot ======================================="
        mokutil --sb-state 2>/dev/null || echo "indisponible"
        echo ""

        echo "=========================== Kernel cmdline ===================================="
        cat /proc/cmdline 2>/dev/null
        echo ""

        echo "=========================== MBR signatures ==================================="
        if command_exists hexdump || command_exists xxd; then
            while read -r disk; do
                echo "/dev/$disk :"
                portable_hexdump "/dev/$disk" | tail -4 || echo "indisponible"
            done < <(lsblk -dn -o NAME 2>/dev/null | grep -vE '^(loop|ram|zram)')
        fi
        echo ""

        echo "=========================== sgdisk ============================================"
        if command_exists sgdisk; then
            while read -r disk; do
                echo "--- /dev/$disk ---"
                sgdisk --print "/dev/$disk" 2>/dev/null || echo "indisponible"
            done < <(lsblk -dn -o NAME 2>/dev/null | grep -vE '^(loop|ram)')
        fi
        echo ""
        echo "=========================== Journal (erreurs) ================================="
        journalctl -p 3 -xb --no-pager -n 20 2>/dev/null || echo "indisponible"
        echo ""
        echo "=========================== dmesg (erreurs) ==================================="
        dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -20 || echo "indisponible"
        echo ""
    } >"$output_file"
    echo ""
    printf "%b\n" "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "Boot-Info généré avec succès" "${GREEN}${BOLD}║${NC}"
    printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "Fichier : $output_file" "${GREEN}${BOLD}║${NC}"
    printf "%b  %-66s%b\n" "${GREEN}${BOLD}║${NC}" "Logs    : $LOG_FILE" "${GREEN}${BOLD}║${NC}"
    printf "%b\n" "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Pour lire le rapport complet :"
    echo "    less $output_file"
    echo ""
    echo "  Pour partager sur un forum :"
    echo "    sudo ./$SCRIPT_NAME --advanced  → option 6 (upload en ligne)"
    echo ""
}

repair_windows_efi() {
    log_subheader "Restauration EFI Microsoft"

    _require_installed_or_chroot_context "Restauration EFI Microsoft" || return 1

    if ! confirm_action_level2 "Modifier les entrées EFI Microsoft/NVRAM et fallback EFI ?" "RESTORE-EFI"; then
        return 1
    fi

    local efi_dir=""
    for d in /boot/efi /efi; do
        [[ -d "$d/EFI" ]] && efi_dir="$d" && break
    done
    if [[ -z "$efi_dir" ]]; then
        log_error "Aucun répertoire EFI monté détecté"
        return 1
    fi
    local ms_efi="${efi_dir}/EFI/Microsoft/Boot/bootmgfw.efi"
    if [[ ! -f "$ms_efi" ]]; then
        log_info "bootmgfw.efi introuvable — aucun Windows dans la partition EFI"
        return 0
    fi
    if command_exists efibootmgr; then
        local ms_entry
        ms_entry=$(efibootmgr -v 2>/dev/null | grep -i 'Windows Boot Manager' | head -1 | grep -oE 'Boot[0-9A-Fa-f]{4}' | head -1)
        if [[ -n "$ms_entry" ]]; then
            local boot_num="${ms_entry#Boot}"
            if efibootmgr --bootnum "$boot_num" --active 2>/dev/null; then
                log_success "Entrée EFI Microsoft activée : $ms_entry"
            else
                log_warning "Impossible d'activer $ms_entry"
            fi
        else
            log_info "Entrée 'Windows Boot Manager' absente — création..."
            local disk part_src disk_dev part_num
            part_src=$(findmnt -n -o SOURCE "${efi_dir}" 2>/dev/null | head -1)
            disk_dev=$(lsblk -no PKNAME "$part_src" 2>/dev/null | head -1)
            part_num=$(lsblk -no PARTN "$part_src" 2>/dev/null | head -1)
            if [[ -z "$disk_dev" || -z "$part_num" ]]; then
                log_error "Impossible de déterminer le disque/numéro de partition EFI (disk_dev='${disk_dev}' part_num='${part_num}')"
            else
                if efibootmgr --create \
                    --disk "/dev/${disk_dev}" \
                    --part "${part_num}" \
                    --loader '\EFI\Microsoft\Boot\bootmgfw.efi' \
                    --label 'Windows Boot Manager' 2>/dev/null; then
                    log_success "Entrée EFI Windows Boot Manager créée"
                else
                    log_error "Échec de création de l'entrée EFI Windows"
                fi
            fi
        fi
    fi
    local efi_fallback="${efi_dir}/EFI/BOOT"
    mkdir -p "$efi_fallback"
    if ! diff -q "$ms_efi" "${efi_fallback}/bootx64.efi" &>/dev/null; then
        if cp "$ms_efi" "${efi_fallback}/bootx64.efi" 2>/dev/null; then
            log_success "bootmgfw.efi copié vers EFI/BOOT/bootx64.efi (fallback UEFI)"
        else
            log_warning "Échec copie fallback EFI"
        fi
    fi
    return 0
}

restore_windows_mbr() {
    local boot_device="$1"
    log_subheader "Restauration MBR compatible Windows"

    _require_installed_or_chroot_context "Restauration MBR Windows" || return 1

    if ! confirm_action_level2 "Écrire un MBR Windows sur $boot_device ?" "WRITE-MBR"; then
        return 1
    fi

    if command_exists ms-sys; then
        if ms-sys --mbr7 "$boot_device" 2>/dev/null; then
            log_success "MBR Windows 7/8/10/11 restauré sur $boot_device"
            return 0
        fi
    fi
    log_warning "ms-sys introuvable. Tentative d'installation..."
    if install_packages ms-sys 2>/dev/null; then
        if ms-sys --mbr7 "$boot_device" 2>/dev/null; then
            log_success "MBR Windows restauré sur $boot_device"
            return 0
        fi
    fi
    log_error "ms-sys non disponible : restauration MBR Windows impossible"
    return 1
}

repair_filesystem_health() {
    if ! command_exists fsck; then
        log_warning "fsck non disponible, réparation des systèmes de fichiers impossible"
        return 1
    fi

    log_subheader "Vérification des systèmes de fichiers"

    local root_device boot_device devices=()
    root_device=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    boot_device=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)

    if [[ -n "$root_device" ]]; then
        devices+=("$root_device")
    fi
    if [[ -n "$boot_device" ]] && [[ "$boot_device" != "$root_device" ]]; then
        devices+=("$boot_device")
    fi

    if [[ -f /etc/fstab ]]; then
        while read -r spec _mount _fstab_fstype _fstab_opts _rest; do
            [[ -z "$spec" || "$spec" == \#* ]] && continue
            case "$_fstab_fstype" in
            swap | tmpfs | proc | sysfs | cgroup* | debugfs | devtmpfs | devpts | overlay)
                continue
                ;;
            esac
            local _resolved_spec=""
            if [[ "$spec" == /dev/* ]]; then
                _resolved_spec="$spec"
            else
                _resolved_spec=$(_resolve_fstab_device "$spec" 2>/dev/null) || true
            fi
            if [[ -n "$_resolved_spec" ]] && [[ " ${devices[*]} " != *" $_resolved_spec "* ]]; then
                devices+=("$_resolved_spec")
            fi
        done </etc/fstab
    fi

    local device mountpoint
    for device in "${devices[@]}"; do
        mountpoint=$(findmnt -n -o TARGET "$device" 2>/dev/null || true)

        if [[ -z "$mountpoint" ]]; then
            log_info "Périphérique non monté détecté : $device"
            if confirm_action "Exécuter fsck -f -y sur $device ? Cette opération peut réparer des erreurs sur le système de fichiers." strict; then
                fsck -f -y "$device" 2>&1 | while read -r line; do log_debug "$line"; done
                log_success "fsck appliqué sur $device"
            else
                log_warning "Réparation fsck annulée pour $device"
            fi
        else
            log_warning "$device est monté sur $mountpoint. Un fsck correct ne doit pas être exécuté sur un périphérique monté."
            log_info "Vérification en lecture seule du système de fichiers monté avec fsck -N sur $device"
            fsck -N "$device" 2>&1 | while read -r line; do log_debug "$line"; done
        fi
    done

    return 0
}

repair_grub() {
    local noninteractive="${1:-false}"
    log_subheader "Réparation du chargeur GRUB"

    _require_installed_or_chroot_context "Réparation GRUB" || return 1

    # C27: bloquer sur systèmes immutables ostree
    _check_ostree_immutable || return 1

    if is_operation_completed "grub_repair"; then
        log_info "Réparation GRUB déjà effectuée durant cette session"
        return 0
    fi

    if [[ "$noninteractive" != "true" ]]; then
        if ! confirm_action "Cela va réinstaller et reconfigurer le chargeur GRUB.
Opération CRITIQUE. Assurez-vous d'avoir un support de récupération disponible." strict; then
            return 1
        fi
    fi

    if ! install_repair_dependencies; then
        log_error "Dépendances manquantes. Réparation annulée."
        return 1
    fi

    backup_partition_tables
    backup_grub_configuration

    local boot_device
    if [[ -n "$FORCE_DISK" ]]; then
        boot_device="$FORCE_DISK"
        log_info "Disque forcé par l'utilisateur : $boot_device"
    else
        boot_device=$(detect_boot_device)
    fi

    if [[ -z "$boot_device" ]]; then
        log_warning "Impossible de détecter automatiquement le périphérique de démarrage"
        echo ""
        echo "Périphériques de blocs disponibles :"
        lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E "^NAME|disk"
        echo ""
        read -r -p "Entrez le périphérique de démarrage (ex. /dev/sda) : " boot_device
        if [[ ! -b "$boot_device" ]]; then
            log_error "Périphérique invalide : $boot_device"
            return 1
        fi
    fi

    log_info "Utilisation du périphérique : $boot_device"

    local result=0
    case "$DISTRO_FAMILY" in
    debian)
        reinstall_grub_debian "$boot_device"
        result=$?
        ;;
    rhel)
        reinstall_grub_rhel "$boot_device"
        result=$?
        ;;
    arch)
        reinstall_grub_arch "$boot_device"
        result=$?
        ;;
    suse)
        reinstall_grub_suse "$boot_device"
        result=$?
        ;;
    gentoo)
        reinstall_grub_gentoo "$boot_device"
        result=$?
        ;;
    void)
        reinstall_grub_void "$boot_device"
        result=$?
        ;;
    alpine)
        reinstall_grub_alpine "$boot_device"
        result=$?
        ;;
    *)
        log_error "Réparation GRUB non prise en charge pour : $DISTRO_FAMILY"
        return 1
        ;;
    esac

    if [[ $result -eq 0 ]]; then
        log_success "Réparation du chargeur GRUB terminée avec succès"
        mark_operation_completed "grub_repair"
        repair_initramfs || log_warning "Régénération initramfs non disponible ou échouée"
        repair_filesystem_health
    else
        log_error "La réparation GRUB a échoué"
        log_info "Restauration possible depuis : $BACKUP_DIR"
    fi

    return $result
}

run_boot_repair() {
    log_header "RÉPARATION BOOT"
    repair_grub
}

run_recommended_repair() {
    log_header "RÉPARATION RECOMMANDÉE"
    log_info "Mode Recommended Repair — flux automatique sécurisé"
    echo ""

    _require_installed_or_chroot_context "Réparation recommandée" || return 1

    _check_ostree_immutable || return 1
    run_environment_checks

    # Validation préliminaire BLS et LUKS/TPM2
    if [[ "$(sys_state BLS 2>/dev/null)" == "yes" ]]; then
        _validate_bls_entries || log_warning "Incohérences BLS détectées avant réparation"
    fi
    if [[ "$(sys_state LUKS 2>/dev/null)" == "yes" ]]; then
        _validate_luks_tpm2_config || log_warning "Incohérences LUKS/TPM2 détectées — vérifiez crypttab et GRUB_CMDLINE_LINUX"
    fi

    log_subheader "[1/7] Génération Boot-Info avant réparation"
    generate_boot_info "${BACKUP_DIR}/boot-info-pre-repair.txt"

    log_subheader "[2/7] Sauvegarde des tables de partitions"
    backup_partition_tables

    log_subheader "[3/7] Installation des dépendances"
    if ! install_repair_dependencies; then
        log_error "Dépendances manquantes. Réparation recommandée annulée."
        return 1
    fi

    log_subheader "[4/7] Détection et réparation bootloader"
    backup_grub_configuration

    local boot_device
    boot_device=$(detect_boot_device)
    if [[ -z "$boot_device" ]]; then
        log_error "Périphérique de démarrage introuvable. Réparation recommandée annulée."
        return 1
    fi
    log_info "Disque cible : $boot_device"

    local active_bl
    active_bl=$(detect_bootloader)
    log_info "Bootloader détecté : $active_bl"

    # ===== DÉTECTION UNIVERSELLE SYSTEMD-BOOT =====
    local use_systemd_boot=false

    # 1. Via detect_bootloader
    if [[ "$active_bl" == "systemd-boot" ]] || [[ "$active_bl" == "both" ]]; then
        use_systemd_boot=true
    fi

    # 2. Via fichier loader.conf (tous les chemins possibles)
    for d in /boot/efi /efi /boot /boot/efi/EFI /efi/EFI; do
        if [[ -f "$d/loader/loader.conf" ]]; then
            use_systemd_boot=true
            log_info "systemd-boot détecté : $d/loader/loader.conf"
            break
        fi
    done

    # 3. Via binaires systemd-boot
    for d in /boot/efi /efi /boot; do
        if [[ -f "$d/EFI/systemd/systemd-bootx64.efi" ]] ||
            [[ -f "$d/EFI/systemd/systemd-bootia32.efi" ]] ||
            { [[ -f "$d/EFI/BOOT/BOOTX64.EFI" ]] && command_exists bootctl; }; then
            use_systemd_boot=true
            log_info "systemd-boot détecté : binaire dans $d"
            break
        fi
    done

    # 4. Cas particulier Pop!_OS
    if [[ "${DISTRO,,}" == "pop" ]] || grep -qi '^ID=pop' /etc/os-release 2>/dev/null; then
        use_systemd_boot=true
        log_info "Pop!_OS détecté : utilisation de systemd-boot"
    fi
    # ===== FIN DÉTECTION UNIVERSELLE =====

    local result=0
    if [[ "$use_systemd_boot" == "true" ]]; then
        log_info "systemd-boot détecté — réparation via bootctl"
        repair_systemd_boot || result=$?
    else
        log_info "GRUB détecté — réparation standard"
        case "$DISTRO_FAMILY" in
        debian)
            reinstall_grub_debian "$boot_device"
            result=$?
            ;;
        rhel)
            reinstall_grub_rhel "$boot_device"
            result=$?
            ;;
        arch)
            reinstall_grub_arch "$boot_device"
            result=$?
            ;;
        suse)
            reinstall_grub_suse "$boot_device"
            result=$?
            ;;
        gentoo)
            reinstall_grub_gentoo "$boot_device"
            result=$?
            ;;
        void)
            reinstall_grub_void "$boot_device"
            result=$?
            ;;
        alpine)
            reinstall_grub_alpine "$boot_device"
            result=$?
            ;;
        *)
            log_error "Distribution non prise en charge : $DISTRO_FAMILY"
            result=1
            ;;
        esac
    fi

    if [[ $result -ne 0 ]]; then
        log_error "Réparation du chargeur a échoué"
        return $result
    fi

    log_subheader "[5/7] Finalisation"

    # Régénération de l'initramfs (selon distribution)
    repair_initramfs || log_warning "Initramfs : non disponible"
    mark_operation_completed "bootloader_repair"

    # Vérification Secure Boot (universel)
    local sb_state
    sb_state=$(check_secure_boot_status)
    if [[ "$sb_state" == *"enabled"* ]]; then
        log_warning "Secure Boot actif. Si problème, utilisez --advanced → MOK enrollment"
    fi

    # Windows EFI (UEFI uniquement)
    local boot_mode
    boot_mode=$(detect_boot_mode)
    if [[ "$boot_mode" == "uefi" ]]; then
        repair_windows_efi
    fi

    # ===== VÉRIFICATION POST-RÉPARATION =====
    log_subheader "Vérification post-réparation"

    # 1. Vérifier et régénérer l'initramfs si absent
    local current_kernel
    current_kernel=$(uname -r)
    if [[ ! -f "/boot/initramfs-${current_kernel}.img" ]] &&
        [[ ! -f "/boot/initramfs-${current_kernel}" ]] &&
        [[ ! -f "/boot/initrd.img-${current_kernel}" ]]; then
        log_warning "Initramfs manquant - régénération forcée"
        case "$DISTRO_FAMILY" in
        debian) update-initramfs -c -k all ;;
        rhel) dracut -f --regenerate-all ;;
        arch) mkinitcpio -P ;;
        suse) mkinitrd ;;
        esac
    else
        log_success "Initramfs présent"
    fi

    # 2. Vérifier que getty est activé (sinon pas de login)
    if command_exists systemctl; then
        if ! systemctl is-enabled getty@tty1 &>/dev/null; then
            log_warning "Service getty@tty1 non activé - activation"
            systemctl enable getty@tty1 2>/dev/null || true
            systemctl enable getty@tty2 2>/dev/null || true
            log_success "Services getty activés"
        else
            log_success "Services getty déjà actifs"
        fi
    fi

    log_success "Vérifications post-réparation terminées"
    # ===== FIN VÉRIFICATION POST-RÉPARATION =====

    log_subheader "[6/7] Génération Boot-Info post-réparation"
    generate_boot_info "${BACKUP_DIR}/boot-info-post-repair.txt"

    log_success "Recommended Repair terminé"
    log_info "Boot-Info avant : ${BACKUP_DIR}/boot-info-pre-repair.txt"
    log_info "Boot-Info après : ${BACKUP_DIR}/boot-info-post-repair.txt"
    log_info "Sauvegardes     : ${BACKUP_DIR}"
    echo ""
    read -r -p "Uploader les rapports en ligne ? [o/N] : " do_upload
    if [[ "${do_upload,,}" == "o" || "${do_upload,,}" == "oui" || "${do_upload,,}" == "y" ]]; then
        upload_report "${BACKUP_DIR}/boot-info-post-repair.txt"
    fi
    log_subheader "[7/7] Validation du démarrage"

    # Activer les consoles texte (sécurité en cas d'échec du display manager)
    if command_exists systemctl; then
        log_info "Activation des consoles texte (tty1-tty6)"
        for tty in {1..6}; do
            systemctl enable "getty@tty$tty" 2>/dev/null || true
        done
    fi

    log_success "Validation terminée - Le système devrait démarrer"
    log_info "Si le boot échoue, utilisez Ctrl+Alt+F2 pour passer en console"
    # ===== FIN VALIDATION =====

}

run_advanced_repair() {
    log_header "MENU AVANCÉ"
    run_environment_checks

    local ctx_line="Système installé"
    if is_live_environment; then
        if [[ "${_INSIDE_CHROOT}" == true ]]; then
            ctx_line="Live ISO -> chroot cible"
        else
            ctx_line="Live ISO (hôte)"
        fi
    fi
    log_info "Contexte courant : $ctx_line"

    _list_disks() {
        echo ""
        printf "%b\n" "${CYAN}${BOLD}Disques détectés sur ce système :${NC}"
        echo "───────────────────────────────────────────────────────────"
        lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL 2>/dev/null |
            grep -v "^loop" |
            awk 'NR==1 {print "  "$0} NR>1 {print "  /dev/"$0}'
        echo "───────────────────────────────────────────────────────────"
        echo ""
    }

    local boot_device
    while true; do
        echo ""
        printf "%b\n" "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${BOLD}║                       OPTIONS AVANCÉES                              ║${NC}"
        printf "%b\n" "${BOLD}╠══════════════════════════════════════════════════════════════════════╣${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "1)  Choisir le disque cible + reinstaller GRUB" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "2)  Purge + reinstallation complete de GRUB" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "3)  Restaurer table de partitions (sfdisk ou sgdisk)" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "4)  Restauration MBR compatible Windows" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "5)  Restauration entree EFI Microsoft" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "6)  Generer Boot-Info + upload en ligne" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "7)  Reparation via chroot (Live ISO uniquement)" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "8)  Configurer options menu GRUB" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "9)  Gestionnaire bootloaders (GRUB/systemd-boot/rEFInd/Limine)" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "10) Etat RAID / LVM" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "11) Secure Boot: etat, MOK enrollment, signature EFI" "${BOLD}║${NC}"
        printf "%b  %-66s  %b\n" "${BOLD}║${NC}" "12) Retour" "${BOLD}║${NC}"
        printf "%b\n" "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -r -p "Choix [1-12] : " adv_choice
        case "$adv_choice" in
        1)
            _list_disks
            read -r -p "Disque cible pour GRUB (ex. /dev/sda) : " FORCE_DISK
            if [[ ! -b "$FORCE_DISK" ]]; then
                log_error "Périphérique invalide : $FORCE_DISK"
                FORCE_DISK=""
                return 1
            fi
            log_info "Disque sélectionné : $FORCE_DISK"
            repair_grub
            FORCE_DISK=""
            ;;
        2)
            _require_installed_or_chroot_context "Purge + réinstallation GRUB" || {
                echo ""
                read -r -p "Appuyez sur Entrée pour continuer..."
                continue
            }
            _list_disks
            echo "La purge supprime tous les paquets GRUB puis les réinstalle."
            echo "Les tables de partitions et la config GRUB seront sauvegardées au préalable."
            echo ""
            if confirm_action_level2 "Purge GRUB puis réinstallation complète. Opération destructive." "ADV-PURGE-GRUB"; then
                backup_partition_tables
                backup_grub_configuration
                purge_grub
                COMPLETED_OPERATIONS["grub_repair"]=""
                repair_grub
            fi
            ;;
        3)
            echo ""
            echo "  Format de sauvegarde à restaurer :"
            echo "  1)  sfdisk  (.dump) — recommandé pour MBR/DOS/GPT simple"
            echo "  2)  sgdisk  (.bin)  — GPT uniquement, restaure header + backup GPT"
            echo ""
            read -r -p "Choix [1-2] : " pt_fmt
            case "$pt_fmt" in
            1)
                local bpt_dir="${BACKUP_DIR}/partition-tables"
                if [[ ! -d "$bpt_dir" ]]; then
                    log_error "Aucune sauvegarde disponible dans $bpt_dir"
                    log_info "Exécutez d'abord une réparation pour créer une sauvegarde."
                    return 1
                fi
                echo ""
                printf "%b\n" "${CYAN}${BOLD}Sauvegardes de tables de partitions disponibles :${NC}"
                echo "───────────────────────────────────────────────────────────"
                find "$bpt_dir" -maxdepth 1 -name '*.dump' \
                    -printf '  %f  (%s bytes)\n' 2>/dev/null | sort
                echo "───────────────────────────────────────────────────────────"
                read -r -p "Nom du fichier .dump sfdisk à restaurer : " dump_file
                local full_path="${bpt_dir}/${dump_file}"
                if [[ ! -f "$full_path" ]]; then
                    log_error "Fichier introuvable : $full_path"
                    return 1
                fi
                _list_disks
                read -r -p "Disque cible pour la restauration (ex. /dev/sda) : " target_disk
                if [[ ! -b "$target_disk" ]]; then
                    log_error "Périphérique invalide : $target_disk"
                    return 1
                fi
                if confirm_action_level2 "Restaurer $full_path sur $target_disk ? Écrase entièrement la table de partitions." "RESTORE-PARTITION"; then
                    if sfdisk "$target_disk" <"$full_path"; then
                        log_success "Table de partitions restaurée sur $target_disk"
                    else
                        log_error "Échec de restauration sfdisk"
                    fi
                fi
                ;;
            2)
                restore_partition_table_sgdisk
                ;;
            *)
                log_warning "Choix invalide"
                ;;
            esac
            ;;
        4)
            _require_installed_or_chroot_context "Restauration MBR Windows" || {
                echo ""
                read -r -p "Appuyez sur Entrée pour continuer..."
                continue
            }
            echo ""
            echo "La restauration MBR Windows remplace le MBR du disque par un"
            echo "MBR compatible Windows 7/8/10/11 via ms-sys."
            echo ""
            _list_disks
            boot_device=$(detect_boot_device)
            if [[ -n "$boot_device" ]]; then
                log_info "Disque détecté automatiquement : $boot_device"
                read -r -p "Confirmer ce disque ou saisir un autre (Entrée = $boot_device) : " override
                [[ -n "$override" ]] && boot_device="$override"
            else
                read -r -p "Disque cible pour MBR Windows (ex. /dev/sda) : " boot_device
            fi
            if [[ ! -b "$boot_device" ]]; then
                log_error "Périphérique invalide : $boot_device"
                return 1
            fi
            restore_windows_mbr "$boot_device"
            ;;
        5)
            _require_installed_or_chroot_context "Restauration EFI Microsoft" || {
                echo ""
                read -r -p "Appuyez sur Entrée pour continuer..."
                continue
            }
            echo ""
            echo "Détection et restauration de l'entrée EFI Microsoft (bootmgfw.efi)."
            echo "Nécessite une partition EFI montée sur /boot/efi ou /efi."
            echo ""
            repair_windows_efi
            ;;
        6)
            local bi_file="${BACKUP_DIR}/boot-info.txt"
            generate_boot_info "$bi_file"
            echo ""
            read -r -p "Uploader le rapport en ligne pour partage forum ? [o/N] : " do_upload
            if [[ "${do_upload,,}" == "o" || "${do_upload,,}" == "oui" || "${do_upload,,}" == "y" ]]; then
                upload_report "$bi_file"
            fi
            ;;
        7)
            echo ""
            echo "La réparation via chroot est prévue pour Live ISO."
            echo ""
            if [[ "${_INSIDE_CHROOT}" == true ]]; then
                log_warning "Vous êtes déjà dans le chroot cible. Utilisez les options GRUB/bootloaders directement."
            elif is_live_environment; then
                auto_scan_and_chroot
            else
                log_warning "Option réservée au mode Live ISO."
                log_info "Sur système installé, utilisez les options 1/2/8/9 selon le besoin."
            fi
            ;;
        8)
            _require_installed_or_chroot_context "Configuration GRUB" || {
                echo ""
                read -r -p "Appuyez sur Entrée pour continuer..."
                continue
            }
            configure_grub_menu_options
            ;;
        9)
            _require_installed_or_chroot_context "Gestionnaire bootloaders" || {
                echo ""
                read -r -p "Appuyez sur Entrée pour continuer..."
                continue
            }
            manage_bootloaders
            ;;
        10)
            echo ""
            printf "%b\n" "${CYAN}${BOLD}État RAID (mdadm) :${NC}"
            echo "───────────────────────────────────────────────────────────"
            cat /proc/mdstat 2>/dev/null || echo "  /proc/mdstat indisponible"
            if command_exists mdadm; then
                echo ""
                mdadm --detail --scan 2>/dev/null || echo "  Aucun RAID mdadm"
            fi
            echo ""
            printf "%b\n" "${CYAN}${BOLD}État LVM :${NC}"
            echo "───────────────────────────────────────────────────────────"
            pvs 2>/dev/null || echo "  pvs : indisponible"
            vgs 2>/dev/null || echo "  vgs : indisponible"
            lvs 2>/dev/null || echo "  lvs : indisponible"
            echo "───────────────────────────────────────────────────────────"
            ;;
        11)
            enroll_mok_key
            ;;
        12)
            unset -f _list_disks
            return 0
            ;;
        *)
            log_warning "Choix invalide"
            ;;
        esac
        echo ""
        read -r -p "Appuyez sur Entrée pour continuer..."
    done
    unset -f _list_disks
}

#-------------------------------------------------------------------------------
# MAIN MENU AND EXECUTION
#-------------------------------------------------------------------------------
show_system_overview() {
    local boot_mode bootloader distro
    boot_mode=$([[ -d /sys/firmware/efi ]] && echo "UEFI" || echo "BIOS/Legacy")
    bootloader=$(detect_bootloader 2>/dev/null || echo "inconnu")
    distro=$(sed -n 's/^PRETTY_NAME="\([^"]*\)".*/\1/p' /etc/os-release 2>/dev/null)
    [[ -z "$distro" ]] && distro="inconnu"

    local -a _disk_lines=()
    while IFS= read -r _dl; do
        _disk_lines+=("$_dl")
    done < <(lsblk -d -o NAME,SIZE,TRAN,MODEL 2>/dev/null | grep -v '^loop')

    local -a _os_lines=()
    local _tmpmnt
    _tmpmnt=$(mktemp -d /tmp/rd_ov_XXXXXX)
    while read -r _dev; do
        [[ -b "$_dev" ]] || continue
        local _fstype=""
        _fstype=$(blkid -s TYPE -o value "$_dev" 2>/dev/null)
        case "$_fstype" in ext2 | ext3 | ext4 | btrfs | xfs | f2fs | jfs | reiserfs) ;; *) continue ;; esac
        if mount -o ro,noatime "$_dev" "$_tmpmnt" 2>/dev/null; then
            local _rel="" _name=""
            [[ -f "$_tmpmnt/etc/os-release" ]] && _rel="$_tmpmnt/etc/os-release"
            [[ -z "$_rel" && -f "$_tmpmnt/usr/lib/os-release" ]] && _rel="$_tmpmnt/usr/lib/os-release"
            if [[ -n "$_rel" ]]; then
                _name=$(grep -m1 '^PRETTY_NAME=' "$_rel" 2>/dev/null | tr -d '"' | cut -d= -f2-)
                _os_lines+=("$(printf "%-15s  %-8s  %-39s" "$_dev" "$_fstype" "${_name:-Linux}")")
            fi
            umount "$_tmpmnt" 2>/dev/null || true
        fi
    done < <(lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="part"{print $1}')
    rmdir "$_tmpmnt" 2>/dev/null || true

    echo ""
    printf "%b\n" "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${CYAN}${BOLD}║                          APERÇU DU SYSTÈME                          ║${NC}"
    printf "%b\n" "${CYAN}${BOLD}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    printf "%b  Mode boot     : %-50s  %b\n" "${CYAN}${BOLD}║${NC}" "$boot_mode" "${CYAN}${BOLD}║${NC}"
    printf "%b  Bootloader    : %-50s  %b\n" "${CYAN}${BOLD}║${NC}" "$bootloader" "${CYAN}${BOLD}║${NC}"
    printf "%b  OS courant    : %-50s  %b\n" "${CYAN}${BOLD}║${NC}" "$distro" "${CYAN}${BOLD}║${NC}"
    printf "%b\n" "${CYAN}${BOLD}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    printf "%b  %-66s  %b\n" "${CYAN}${BOLD}║${NC}" "Disques physiques :" "${CYAN}${BOLD}║${NC}"
    printf "%b\n" "${CYAN}${BOLD}╟──────────────────────────────────────────────────────────────────────╢${NC}"
    if [[ ${#_disk_lines[@]} -gt 0 ]]; then
        for _dl in "${_disk_lines[@]}"; do
            printf "%b  %-66s  %b\n" "${CYAN}${BOLD}║${NC}" "$_dl" "${CYAN}${BOLD}║${NC}"
        done
    fi
    printf "%b\n" "${CYAN}${BOLD}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    printf "%b  %-66s  %b\n" "${CYAN}${BOLD}║${NC}" "Systèmes Linux installés :" "${CYAN}${BOLD}║${NC}"
    printf "%b\n" "${CYAN}${BOLD}╟──────────────────────────────────────────────────────────────────────╢${NC}"
    if [[ ${#_os_lines[@]} -gt 0 ]]; then
        for _ol in "${_os_lines[@]}"; do
            printf "%b  %-66s  %b\n" "${CYAN}${BOLD}║${NC}" "$_ol" "${CYAN}${BOLD}║${NC}"
        done
    else
        printf "%b  %-66s  %b\n" "${CYAN}${BOLD}║${NC}" "(aucun — Live ISO ou partitions LUKS non ouvertes)" "${CYAN}${BOLD}║${NC}"
    fi
    printf "%b\n" "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_banner() {
    clear
    printf "%b\n" "${CYAN}${BOLD}"
    cat <<'BANNER'
░█████████  ░██████████ ░█████████          ░███████   ░██████████ ░███     ░███ 
░██     ░██ ░██         ░██     ░██         ░██   ░██  ░██         ░████   ░████ 
░██     ░██ ░██         ░██     ░██         ░██    ░██ ░██         ░██░██ ░██░██ 
░█████████  ░█████████  ░█████████  ░██████ ░██    ░██ ░█████████  ░██ ░████ ░██ 
░██   ░██   ░██         ░██                 ░██    ░██ ░██         ░██  ░██  ░██ 
░██    ░██  ░██         ░██                 ░██   ░██  ░██         ░██       ░██ 
░██     ░██ ░██████████ ░██                 ░███████   ░██████████ ░██       ░██ 
                                                                            
BANNER
    printf "%b\n" "${NC}"
    printf "%b\n" "${WHITE}   Outil de réparation boot Linux${NC}"
    printf "%b\n" "${DIM}   Version $SCRIPT_VERSION ${NC}"
    echo ""
}

show_menu() {
    local ctx="Système installé"
    if is_live_environment; then
        if [[ "${_INSIDE_CHROOT}" == true ]]; then
            ctx="Live ISO -> chroot cible"
        else
            ctx="Live ISO (hôte)"
        fi
    fi

    echo ""
    printf "%b\n" "${BOLD}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${BOLD}║                         MENU PRINCIPAL                                ║${NC}"
    printf "%b\n" "${BOLD}╠════════════════════════════════════════════════════════════════════════╣${NC}"
    printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "Contexte : $ctx" "${BOLD}║${NC}"
    printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "1)  Reparation recommandee (automatique, securisee)" "${BOLD}║${NC}"
    printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "2)  Reparation boot interactive" "${BOLD}║${NC}"
    printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "3)  Options avancees (disque, purge, chroot, EFI, RAID...)" "${BOLD}║${NC}"
    printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "4)  Generer Boot-Info (rapport + upload)" "${BOLD}║${NC}"
    printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "5)  Rapport brut lecture seule" "${BOLD}║${NC}"
    if [[ "${_INSIDE_CHROOT}" == false ]]; then
        printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "6)  Live ISO: auto-chroot detection (reparer depuis live USB)" "${BOLD}║${NC}"
        printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "7)  Quitter" "${BOLD}║${NC}"
        if is_live_environment; then
            printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "[Live hote: options 1/2/3 protegent les actions destructrices]" "${BOLD}║${NC}"
        fi
    else
        printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "6)  Quitter" "${BOLD}║${NC}"
        printf "%b  %-68.68s  %b\n" "${BOLD}║${NC}" "[Mode chroot actif: Live ISO non disponible ici]" "${BOLD}║${NC}"
    fi
    printf "%b\n" "${BOLD}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_help() {
    cat <<HELP
UTILISATION : $SCRIPT_NAME [OPTION]

Outil de réparation boot Linux – Version $SCRIPT_VERSION
Multi-distro, sans interface graphique.
Supportes : GRUB 2 (BIOS + UEFI), systemd-boot (UEFI), rEFInd (UEFI), Limine (BIOS+UEFI).

OPTIONS :
    --recommended       Réparation automatique en 7 étapes sécurisées
    --boot              Réparation GRUB interactive avec confirmations
    --advanced          Menu avancé 12 options
    --boot-info [FILE]  Génère un rapport Boot-Info complet (défaut : ${BACKUP_DIR}/boot-info.txt)
    --analyze           Rapport brut système en lecture seule (stdout)
    --output FILE       Exporte le rapport brut vers FILE
    --live-chroot       Scan auto + chroot depuis un Live ISO (réparer le système installé)
    --inside-chroot     Usage interne — lancé automatiquement par --live-chroot
    --help, -h          Affiche ce message d'aide
    --version, -v       Affiche la version du script

EXEMPLES :
    sudo $SCRIPT_NAME
        Lance le menu interactif principal

    sudo $SCRIPT_NAME --recommended
        Réparation sécurisée automatique :
        Boot-Info avant → sauvegarde tables → dépendances → bootloader → Windows/EFI → Boot-Info après

    sudo $SCRIPT_NAME --boot
        Réparation GRUB interactive avec confirmations

    sudo $SCRIPT_NAME --advanced
        Menu avancé : purge, disque, chroot (live USB), bootloaders, RAID, MBR Windows, EFI

    sudo $SCRIPT_NAME --boot-info /tmp/mon-rapport.txt
        Génère un rapport Boot-Info vers le fichier spécifié

    sudo $SCRIPT_NAME --analyze --output rapport.txt
        Rapport brut lecture seule enregistré dans rapport.txt

    sudo $SCRIPT_NAME --live-chroot
        Depuis un Live USB/ISO : scan auto des OS installés, montage, bind mounts,
        relancement du script à l'intérieur du chroot pour réparer le vrai système.

MENU AVANCÉ (--advanced) :
    1)   Choisir disque cible + réinstaller GRUB
    2)   Purge + réinstallation complète de GRUB
    3)   Restaurer table de partitions (sfdisk ou sgdisk)
    4)   Restauration MBR compatible Windows (ms-sys)
    5)   Restauration entrée EFI Microsoft (bootmgfw.efi)
    6)   Générer Boot-Info + upload en ligne
    7)   Réparation via chroot (depuis live USB)
    8)   Configurer options menu GRUB (timeout, nomodeset, résolution...)
    9)   Gestionnaire bootloaders (install/suppression/réparation GRUB/systemd-boot/rEFInd/Limine)
    10)  État RAID (mdadm) + LVM
    11)  Secure Boot — état, MOK enrollment, signature EFI
    12)  Retour

BOOTLOADERS SUPPORTÉS :
    GRUB 2     : Debian/Ubuntu/Mint, Fedora/RHEL/Rocky/Alma, Arch/Manjaro, openSUSE, Void, Gentoo
    systemd-boot : Pop!_OS 18.04+, Ubuntu 24.04+, Fedora (UEFI), Arch (UEFI)
    rEFInd       : UEFI (détection et installation si paquet disponible)
    Limine       : BIOS+UEFI (installation automatique surtout Arch, manuel ailleurs)
    Détection automatique : grub.cfg, loader.conf, EFI binaires, efibootmgr, ID distro

DÉPENDANCES REQUISES (installées automatiquement si absentes) :
    GRUB/BIOS   : grub-pc
    GRUB/UEFI   : grub-efi-amd64, grub-efi-amd64-signed, shim-signed, efibootmgr
    systemd-boot: bootctl (inclus dans systemd), kernel-install (optionnel)
    initramfs   : update-initramfs (Debian), dracut (RHEL), mkinitcpio (Arch)
    Rapport     : curl, hexdump, sgdisk, sfdisk, parted, mdadm, lvm2
    Chroot      : mount, chroot, findmnt, blkid
    Windows MBR : ms-sys

UPLOAD RAPPORT (option 6) :
    3 services en parallèle, sans compte requis :
    paste.ubuntu.com  — texte, permanent
    dpaste.com        — texte, 7 jours
    gofile.io         — fichier, grand format
    Les 3 liens s'affichent à l'écran et sont écrits dans le rapport local.

SAUVEGARDES :
    $BACKUP_DIR
    Contenu : tables de partitions (sgdisk+sfdisk+dd MBR), config GRUB,
              ESP (pour systemd-boot), Boot-Info avant et après réparation.

JOURNAUX :
    $LOG_FILE

HELP
}

#-------------------------------------------------------------------------------
# MODULE : VÉRIFICATION OUTILS REQUIS (Live ISO)
#-------------------------------------------------------------------------------
check_required_tools() {
    local -a required=("lsblk" "blkid" "mount" "umount" "chroot" "findmnt")
    local -a recommended=("sgdisk" "curl" "efibootmgr" "rsync")
    local -a missing_req=() missing_rec=()

    log_subheader "Vérification des outils requis"
    for tool in "${required[@]}"; do
        command_exists "$tool" || missing_req+=("$tool")
    done
    for tool in "${recommended[@]}"; do
        command_exists "$tool" || missing_rec+=("$tool")
    done

    if ((${#missing_req[@]} > 0)); then
        log_error "Outils obligatoires manquants : ${missing_req[*]}"
        log_error "Impossible de continuer sans ces outils."
        return 1
    fi
    log_success "Outils obligatoires : tous présents"

    if ((${#missing_rec[@]} > 0)); then
        log_warning "Outils recommandés absents : ${missing_rec[*]}"
        confirm_action "Installer ces outils temporairement sur le Live ISO ?" yes || {
            log_warning "Certaines opérations pourraient être limitées."
            return 0
        }
        local live_pm=""
        command_exists apt-get && live_pm="apt-get"
        command_exists pacman && [[ -z "$live_pm" ]] && live_pm="pacman"
        command_exists dnf && [[ -z "$live_pm" ]] && live_pm="dnf"
        command_exists zypper && [[ -z "$live_pm" ]] && live_pm="zypper"
        if [[ -z "$live_pm" ]]; then
            log_warning "Gestionnaire de paquets introuvable sur le Live ISO."
            return 0
        fi
        log_info "Installation via $live_pm : ${missing_rec[*]}"
        case "$live_pm" in
        apt-get) apt-get install -y "${missing_rec[@]}" 2>&1 | while read -r l; do log_debug "$l"; done ;;
        pacman) pacman -Sy --noconfirm "${missing_rec[@]}" 2>&1 | while read -r l; do log_debug "$l"; done ;;
        dnf) dnf install -y "${missing_rec[@]}" 2>&1 | while read -r l; do log_debug "$l"; done ;;
        zypper) zypper install -y "${missing_rec[@]}" 2>&1 | while read -r l; do log_debug "$l"; done ;;
        esac
        log_success "Installation des outils recommandés terminée"
    else
        log_success "Outils recommandés : tous présents"
    fi
    return 0
}

#-------------------------------------------------------------------------------
# MODULE : NETTOYAGE AUTO-CHROOT (appelé par le trap global)
#-------------------------------------------------------------------------------
_autochroot_cleanup() {
    local target="${CHROOT_TARGET:-}"
    [[ -z "$target" || ! -d "$target" ]] && return 0
    log_info "Démontage du chroot automatique : $target"
    local -a submounts=(
        "${target}/sys/firmware/efi/efivars"
        "${target}/run"
        "${target}/sys"
        "${target}/proc"
        "${target}/dev/pts"
        "${target}/dev"
        "${target}/boot/efi"
        "${target}/boot"
    )
    for sub in "${submounts[@]}"; do
        if mountpoint -q "$sub" 2>/dev/null; then
            if umount -lf "$sub" 2>/dev/null; then
                log_info "  Démonté : $sub"
            fi
        fi
    done

    if mountpoint -q "$target" 2>/dev/null; then
        if umount -lf "$target" 2>/dev/null; then
            log_success "Partition root démontée : $target"
        fi
    fi
    CHROOT_TARGET=""

}

#-------------------------------------------------------------------------------
# MODULE : AUTO-SCAN ET CHROOT DEPUIS UN LIVE ISO
#-------------------------------------------------------------------------------

auto_scan_and_chroot() {
    log_header "AUTO-CHROOT DÉTECTION — MODE LIVE ISO"
    echo ""
    check_required_tools || return 1

    local VGBIN=""
    if command_exists vgchange; then
        VGBIN="vgchange"
    elif [[ -x /sbin/vgchange ]]; then
        VGBIN="/sbin/vgchange"
        export PATH="$PATH:/sbin"
    elif [[ -x /usr/sbin/vgchange ]]; then
        VGBIN="/usr/sbin/vgchange"
        export PATH="$PATH:/usr/sbin"
    fi

    if [[ -n "$VGBIN" ]]; then
        log_info "Activation des VG LVM ($VGBIN -ay)..."
        $VGBIN -ay 2>/dev/null
        log_success "LVM activés"
    else
        log_warning "vgchange non trouvé - LVM peut ne pas être détecté"
    fi

    local target_dir="/mnt/target"
    if mountpoint -q "$target_dir" 2>/dev/null; then
        log_warning "$target_dir est déjà utilisé comme point de montage."
        confirm_action "Démonter et réutiliser $target_dir ?" strict || return 1
        CHROOT_TARGET="$target_dir"
        _autochroot_cleanup
    fi
    mkdir -p "$target_dir"

    log_info "Scan des partitions (ext2/3/4, btrfs, xfs, f2fs, jfs, reiserfs)..."
    echo ""

    local tmp_mnt
    tmp_mnt=$(mktemp -d /tmp/rd_scan_XXXXXX)
    local idx=0
    declare -A scan_map
    local -a found_systems=()

    # Fonction pour trouver le bon point de montage (gère BTRFS subvolumes)
    _find_root_mount() {
        local mnt="$1"

        # Pour BTRFS, chercher le sous-volume root
        if command_exists btrfs; then
            # Lister les sous-volumes et trouver celui qui contient /etc
            local subvols
            subvols=$(btrfs subvolume list "$mnt" 2>/dev/null | awk '{print $NF}')
            for subvol in $subvols; do
                if [[ -f "$mnt/$subvol/etc/os-release" ]] || [[ -f "$mnt/$subvol/usr/lib/os-release" ]]; then
                    echo "$subvol"
                    return 0
                fi
            done
            # Fallback sur 'root' ou '@' les plus courants
            for subvol in "root" "@" "fedora"; do
                if [[ -d "$mnt/$subvol" ]] && [[ -f "$mnt/$subvol/etc/os-release" || -f "$mnt/$subvol/usr/lib/os-release" ]]; then
                    echo "$subvol"
                    return 0
                fi
            done
        fi
        return 1
    }

    while read -r dev; do
        [[ -b "$dev" ]] || continue
        local fstype
        fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
        case "$fstype" in
        ext2 | ext3 | ext4 | btrfs | xfs | f2fs | jfs | reiserfs) ;;
        *) continue ;;
        esac

        if mount -o ro,noatime "$dev" "$tmp_mnt" 2>/dev/null; then
            # Gestion BTRFS : trouver le bon sous-volume
            local detected_root="$tmp_mnt"
            local subvol_name=""

            if [[ "$fstype" == "btrfs" ]]; then
                subvol_name=$(_find_root_mount "$tmp_mnt")
                if [[ -n "$subvol_name" ]] && [[ -d "$tmp_mnt/$subvol_name" ]]; then
                    detected_root="$tmp_mnt/$subvol_name"
                fi
            fi

            # Vérifier os-release (direct ou via lien symbolique)
            if [[ -f "$detected_root/etc/os-release" ]] || [[ -f "$detected_root/usr/lib/os-release" ]]; then
                idx=$((idx + 1))
                local name uuid
                # Extraire PRETTY_NAME du bon endroit
                if [[ -f "$detected_root/etc/os-release" ]]; then
                    name=$(grep -m1 '^PRETTY_NAME=' "$detected_root/etc/os-release" 2>/dev/null |
                        tr -d '"' | cut -d= -f2-)
                elif [[ -f "$detected_root/usr/lib/os-release" ]]; then
                    name=$(grep -m1 '^PRETTY_NAME=' "$detected_root/usr/lib/os-release" 2>/dev/null |
                        tr -d '"' | cut -d= -f2-)
                fi
                uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || echo "—")

                # Stocker le device ET le sous-volume si BTRFS
                scan_map[$idx]="$dev|${subvol_name}"
                found_systems+=("$(printf "  %2d)  %-22s  %-30s  UUID: %s" \
                    "$idx" "$dev" "${name:-Linux}" "$uuid")")
            fi
            umount "$tmp_mnt" 2>/dev/null || true
        fi
    done < <(
        lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="part"{print $1}'
        lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="lvm" || $2=="crypt"{print $1}'
        # ls /dev/mapper/* 2>/dev/null | grep -v control
        for f in /dev/mapper/*; do
            [ "$f" != "/dev/mapper/control" ] && printf '%s\n' "$f"
        done
    )
    rmdir "$tmp_mnt" 2>/dev/null || true

    if ((${#found_systems[@]} == 0)); then
        log_error "Aucun système Linux détecté sur les partitions disponibles."
        echo ""
        echo "  Partitions visibles :"
        lsblk -lno NAME,SIZE,FSTYPE,TYPE 2>/dev/null | awk '$4=="part" || $4=="lvm" || $4=="crypt"{print "  /dev/"$0}' || true
        if lsblk -lno FSTYPE 2>/dev/null | grep -q 'crypto_LUKS'; then
            log_warning "Partition LUKS détectée non ouverte — système non visible au scan."
            echo ""
            echo "  Déverrouillez d'abord puis relancez le script :"
            echo ""
            echo "  # Pop!_OS / Ubuntu (NVMe) :"
            echo "    cryptsetup luksOpen /dev/nvme0n1p3 cryptdata"
            echo "    lvscan && vgchange -ay"
            echo "    # partition root sera sur /dev/mapper/data-root"
            echo ""
            echo "  # Pop!_OS / Ubuntu (SATA) :"
            echo "    cryptsetup luksOpen /dev/sda3 cryptdata"
            echo "    lvscan && vgchange -ay"
            echo ""
            echo "  # Autre distro :"
            echo "    cryptsetup luksOpen /dev/sdXY nom_mapper"
            echo "    vgchange -ay"
            echo ""
        fi
        return 1
    fi

    printf "%b\n" "${CYAN}${BOLD}Systèmes Linux détectés :${NC}"
    echo "────────────────────────────────────────────────────────────────────────────"
    printf '%s\n' "${found_systems[@]}"
    echo "────────────────────────────────────────────────────────────────────────────"
    echo ""

    local chosen_num root_dev subvol_name
    while true; do
        read -r -p "Numéro du système à réparer [1-${idx}] : " chosen_num
        local entry="${scan_map[$chosen_num]:-}"
        root_dev="${entry%%|*}"
        subvol_name="${entry##*|}"
        [[ -b "$root_dev" ]] && break
        log_warning "Sélection invalide. Entrez un numéro entre 1 et $idx."
    done

    log_info "Système sélectionné : $root_dev"
    [[ -n "$subvol_name" ]] && log_info "Sous-volume BTRFS : $subvol_name"

    # Montage de la partition root avec gestion BTRFS
    log_info "Montage de $root_dev sur $target_dir..."
    if [[ -n "$subvol_name" ]] && [[ "$(blkid -s TYPE -o value "$root_dev" 2>/dev/null)" == "btrfs" ]]; then
        if ! mount -o subvol="$subvol_name" "$root_dev" "$target_dir"; then
            log_error "Impossible de monter $root_dev (subvol=$subvol_name)"
            return 1
        fi
    else
        if ! mount "$root_dev" "$target_dir"; then
            log_error "Impossible de monter $root_dev sur $target_dir"
            return 1
        fi
    fi
    CHROOT_TARGET="$target_dir"

    # --- Partitions séparées via /etc/fstab du système cible ---
    if [[ -f "$target_dir/etc/fstab" ]]; then
        log_info "Analyse de $target_dir/etc/fstab pour les partitions séparées..."
        while read -r spec mountpt fstype _opts _dump _pass; do
            [[ -z "$spec" || "$spec" == \#* ]] && continue
            [[ "$mountpt" == "/" ]] && continue
            case "$fstype" in
            swap | tmpfs | proc | sysfs | devtmpfs | devpts | overlay | cgroup* | none | auto) continue ;;
            esac
            local real_dev=""
            case "$spec" in
            UUID=*) real_dev=$(blkid -U "${spec#UUID=}" 2>/dev/null) ;;
            PARTUUID=*) real_dev=$(blkid -l -t PARTUUID="${spec#PARTUUID=}" -o device 2>/dev/null) ;;
            LABEL=*) real_dev=$(blkid -L "${spec#LABEL=}" 2>/dev/null) ;;
            /dev/*) real_dev="$spec" ;;
            esac
            if [[ -n "$real_dev" && -b "$real_dev" ]]; then
                local full_mp="${target_dir}${mountpt}"
                mkdir -p "$full_mp"
                if mount "$real_dev" "$full_mp" 2>/dev/null; then
                    log_info "  Monté : $real_dev → $mountpt"
                else
                    log_warning "  Échec montage : $real_dev → $mountpt"
                fi
            fi
        done <"$target_dir/etc/fstab"
    fi

    # --- Bind mounts : /dev /dev/pts /proc /sys /run ---
    log_info "Bind mounts des systèmes de fichiers virtuels..."
    for vfs in /dev /dev/pts /proc /sys /run; do
        local bind_tgt="${target_dir}${vfs}"
        mkdir -p "$bind_tgt"
        if mount --rbind "$vfs" "$bind_tgt" 2>/dev/null; then
            mount --make-rslave "$bind_tgt" 2>/dev/null || true
            log_info "  rbind : $vfs"
        else
            if mount --bind "$vfs" "$bind_tgt" 2>/dev/null; then
                log_info "  bind  : $vfs (fallback)"
            else
                log_warning "  Échec bind : $vfs"
            fi
        fi
    done

    # efivars si UEFI
    if [[ -d /sys/firmware/efi/efivars ]]; then
        local efivars_tgt="${target_dir}/sys/firmware/efi/efivars"
        mkdir -p "$efivars_tgt"
        if mount --bind /sys/firmware/efi/efivars "$efivars_tgt" 2>/dev/null; then
            log_info "  bind  : efivars"
        else
            log_warning "  Échec bind : efivars"
        fi
    fi

    # --- Copie du script dans le chroot ---
    local script_name
    script_name="$(basename "$0")"
    local script_in_chroot="${target_dir}/tmp/Rep-Dem"
    mkdir -p "$script_in_chroot"
    if ! cp "$0" "${script_in_chroot}/${script_name}"; then
        log_error "Impossible de copier le script dans le chroot"
        _autochroot_cleanup
        return 1
    fi
    chmod +x "${script_in_chroot}/${script_name}"

    echo ""
    log_success "Environnement chroot prêt. Lancement de la réparation sur $root_dev..."
    printf "%b\n" "${YELLOW}${BOLD}[CHROOT]${NC} Les commandes suivantes s'exécutent sur le système installé."
    echo ""

    # --- Relancement du script à l'intérieur du chroot ---
    chroot "$target_dir" /bin/bash "/tmp/Rep-Dem/${script_name}" --inside-chroot
    local chroot_exit=$?

    unset -f _find_root_mount
    log_info "Session chroot terminée (code : $chroot_exit)"
    _autochroot_cleanup
    return $chroot_exit
}
main() {
    case "${1:-}" in
    --analyze)
        ANALYZE_MODE=true
        if [[ "${2:-}" == "--output" ]]; then
            OUTPUT_FILE="${3:-}"
            [[ -z "$OUTPUT_FILE" ]] && {
                log_error "Fichier de sortie manquant"
                exit 1
            }
        fi
        generate_raw_report
        exit 0
        ;;
    --output)
        OUTPUT_FILE="${2:-}"
        [[ -z "$OUTPUT_FILE" ]] && {
            log_error "Fichier de sortie manquant"
            exit 1
        }
        ANALYZE_MODE=true
        generate_raw_report
        exit 0
        ;;
    --help | -h)
        show_help
        exit 0
        ;;
    --version | -v)
        echo "$SCRIPT_NAME version $SCRIPT_VERSION"
        exit 0
        ;;
    --recommended)
        show_banner
        run_recommended_repair
        exit $?
        ;;
    --boot)
        show_banner
        run_environment_checks
        show_system_overview
        run_boot_repair
        exit $?
        ;;
    --advanced)
        show_banner
        show_system_overview
        run_advanced_repair
        exit $?
        ;;
    --boot-info)
        run_environment_checks
        generate_boot_info "${2:-${BACKUP_DIR}/boot-info.txt}"
        exit 0
        ;;
    --live-chroot)
        show_banner
        auto_scan_and_chroot
        exit $?
        ;;
    --inside-chroot)
        # Lancé automatiquement par auto_scan_and_chroot à l'intérieur du chroot
        _INSIDE_CHROOT=true
        show_banner
        printf "%b\n" "${YELLOW}${BOLD}[CHROOT]${NC} Vous opérez sur le système installé — pas sur le Live ISO."
        echo ""
        run_environment_checks
        while true; do
            show_menu
            read -r -p "Entrez votre choix [1-6] : " menu_choice
            case "$menu_choice" in
            1) run_recommended_repair ;;
            2) run_boot_repair ;;
            3) run_advanced_repair ;;
            4) generate_boot_info ;;
            5)
                ANALYZE_MODE=true
                generate_raw_report
                ;;
            6)
                echo ""
                log_info "Fermeture du chroot. À bientôt !"
                echo ""
                exit 0
                ;;
            *) log_warning "Choix invalide. Veuillez entrer 1-6." ;;
            esac
            echo ""
            read -r -p "Appuyez sur Entrée pour continuer..."
        done
        ;;
    "")
        show_banner
        run_environment_checks
        show_system_overview
        while true; do
            show_menu
            read -r -p "Entrez votre choix [1-7] : " menu_choice
            case "$menu_choice" in
            1) run_recommended_repair ;;
            2) run_boot_repair ;;
            3) run_advanced_repair ;;
            4) generate_boot_info ;;
            5)
                ANALYZE_MODE=true
                generate_raw_report
                ;;
            6) auto_scan_and_chroot ;;
            7)
                echo ""
                log_info "Fermeture. À bientôt !"
                echo ""
                exit 0
                ;;
            *) log_warning "Choix invalide. Veuillez entrer 1-7." ;;
            esac
            echo ""
            read -r -p "Appuyez sur Entrée pour continuer..."
        done
        ;;
    *)
        log_error "Option inconnue : $1"
        echo "Utilisez --help pour obtenir des informations d'utilisation"
        exit 1
        ;;
    esac
}

main "$@"
