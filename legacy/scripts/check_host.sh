#!/usr/bin/env bash
# Recoge la información del PC que necesito para interpretar los resultados. Se ejecuta en el host.
#   ./scripts/check_host.sh
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${REPO_DIR}/logs"
OUT="${REPO_DIR}/logs/00_host.txt"

{
    echo "== Fecha";        date -Is
    echo "== SO";           (lsb_release -ds 2>/dev/null || head -2 /etc/os-release); uname -r
    echo "== CPU";          lscpu | grep -E "Model name|^CPU\(s\)"
    echo "== RAM";          free -h | head -2
    echo "== GPU";          (lspci 2>/dev/null | grep -iE "vga|3d|display") || echo "lspci no disponible"
    echo "== Disco libre";  df -h "${HOME}" | tail -1
    echo "== Docker";       docker --version 2>&1
    docker info --format 'Servidor {{.ServerVersion}}, almacenamiento {{.Driver}}' 2>&1 | head -1
    echo "== Grupo docker"; id -nG | tr ' ' '\n' | grep -x docker || echo "el usuario NO está en el grupo docker"
    echo "== /dev/dri";     ls -l /dev/dri 2>&1
    echo "== Sesión gráfica"; echo "DISPLAY=${DISPLAY:-sin DISPLAY}  XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?}"
    echo "== QGroundControl"; (ls "${HOME}"/QGroundControl*.AppImage 2>/dev/null || echo "no encontrado en ~")
} 2>&1 | tee "${OUT}"

echo
echo "Guardado en ${OUT}"
