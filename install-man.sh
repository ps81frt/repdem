#!/usr/bin/env bash
# install-man.sh — Installation de la page de manuel repdem(8)
# Auteur  : ps81frt
# GitHub  : https://github.com/ps81frt/repdem
# Licence : MIT

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTES
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly MAN_SRC="repdem.8"
readonly MAN_DEST_DIR="/usr/share/man/man8"
readonly MAN_DEST="${MAN_DEST_DIR}/repdem.8"
readonly MAN_DEST_GZ="${MAN_DEST}.gz"

# ─────────────────────────────────────────────────────────────────────────────
# COULEURS (désactivées hors terminal)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'
    YELLOW='\033[1;33m'; CYAN='\033[0;36m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# FONCTIONS
# ─────────────────────────────────────────────────────────────────────────────
info()    { printf "%b[INFO]%b %s\n"    "${CYAN}"   "${NC}" "$*"; }
success() { printf "%b[OK]%b   %s\n"   "${GREEN}"  "${NC}" "$*"; }
warn()    { printf "%b[WARN]%b  %s\n"  "${YELLOW}" "${NC}" "$*" >&2; }
die()     { printf "%b[ERR]%b   %s\n"  "${RED}"    "${NC}" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
${BOLD}UTILISATION${NC}
    sudo ./${SCRIPT_NAME} [--uninstall]

${BOLD}OPTIONS${NC}
    (aucune)      Installe repdem.8 dans ${MAN_DEST_DIR}/
    --uninstall   Supprime la page de manuel installée
    --help        Affiche ce message

${BOLD}PRÉREQUIS${NC}
    - Droits root
    - Fichier ${MAN_SRC} dans le même répertoire que ce script
    - gzip, man-db (mandb)
EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Ce script doit être exécuté en tant que root. Utilisez : sudo ./${SCRIPT_NAME}"
    fi
}

check_source() {
    local src_dir
    src_dir="$(cd "$(dirname "$0")" && pwd)"
    MAN_SRC_PATH="${src_dir}/${MAN_SRC}"
    if [[ ! -f "$MAN_SRC_PATH" ]]; then
        die "Fichier source introuvable : ${MAN_SRC_PATH}
Placez ${MAN_SRC} dans le même répertoire que ${SCRIPT_NAME}."
    fi
}

check_deps() {
    local missing=()
    for cmd in gzip mandb; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Dépendances manquantes : ${missing[*]}
Installez-les avec : sudo apt install gzip man-db"
    fi
}

install_man() {
    check_root
    check_source
    check_deps

    info "Source      : ${MAN_SRC_PATH}"
    info "Destination : ${MAN_DEST_GZ}"

    # Créer le répertoire si nécessaire
    if [[ ! -d "$MAN_DEST_DIR" ]]; then
        mkdir -p "$MAN_DEST_DIR"
        success "Répertoire créé : ${MAN_DEST_DIR}"
    fi

    # Supprimer une version précédente
    rm -f "$MAN_DEST" "$MAN_DEST_GZ" 2>/dev/null || true

    # Copier et compresser
    install -o root -g root -m 644 "$MAN_SRC_PATH" "$MAN_DEST"
    gzip -f "$MAN_DEST"
    success "Page de manuel installée : ${MAN_DEST_GZ}"

    # Mettre à jour la base mandb
    info "Mise à jour de la base mandb..."
    mandb -q 2>/dev/null || mandb 2>/dev/null || warn "mandb a retourné une erreur non fatale"
    success "Base mandb mise à jour"

    echo ""
    printf "%b%s%b\n" "${BOLD}" "Installation terminée. Utilisation :" "${NC}"
    echo "    man repdem"
    echo "    man 8 repdem"
}

uninstall_man() {
    check_root

    if [[ ! -f "$MAN_DEST_GZ" && ! -f "$MAN_DEST" ]]; then
        warn "Page de manuel non installée (${MAN_DEST_GZ} introuvable)"
        exit 0
    fi

    rm -f "$MAN_DEST" "$MAN_DEST_GZ"
    success "Supprimé : ${MAN_DEST_GZ}"

    info "Mise à jour de la base mandb..."
    mandb -q 2>/dev/null || mandb 2>/dev/null || true
    success "Base mandb mise à jour"

    echo ""
    success "Désinstallation terminée"
}

# ─────────────────────────────────────────────────────────────────────────────
# POINT D'ENTRÉE
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --uninstall) uninstall_man ;;
    --help | -h) usage ;;
    "")          install_man ;;
    *) die "Option inconnue : $1. Utilisez --help pour l'aide." ;;
esac
