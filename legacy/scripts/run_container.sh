#!/usr/bin/env bash
# Arranca el contenedor de simulación. Se ejecuta en el PC (host). Probado para Ubuntu 24.04 y Fedora.
#
#   HEADLESS=1 ./scripts/run_container.sh   # sin interfaz de Gazebo (por defecto)
#   HEADLESS=0 ./scripts/run_container.sh   # con interfaz 3D (GPU dedicada recomendada)
#
# Red en modo host: QGroundControl en el PC ve el dron simulado en UDP 14550.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-drone-sim:s1}"
HEADLESS="${HEADLESS:-1}"

EXTRA_OPTS=()

# SELinux (Fedora): sin esto los volúmenes montados dan "permission denied" dentro del contenedor
# y la GPU puede quedar bloqueada. Se desactiva el etiquetado solo para este contenedor.
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    EXTRA_OPTS+=(--security-opt label=disable)
    echo "SELinux activo: etiquetado desactivado para el contenedor"
fi

# GPU (Mesa: AMD e Intel). Si no hay /dev/dri, Gazebo usa renderizado por software.
if [ -e /dev/dri ]; then
    EXTRA_OPTS+=(--device /dev/dri)
else
    echo "Aviso: no hay /dev/dri; Gazebo con interfaz irá por software"
fi

if [ "${HEADLESS}" = "0" ]; then
    # Permite que el contenedor abra ventanas en el escritorio (X11 o XWayland)
    if command -v xhost >/dev/null 2>&1; then
        xhost +local:root >/dev/null
    else
        echo "Falta xhost (Ubuntu: sudo apt install x11-xserver-utils · Fedora: sudo dnf install xhost)" >&2
        exit 1
    fi
fi

mkdir -p "${REPO_DIR}/logs"

docker run -it --rm \
    --name drone-sim \
    --network host \
    --ipc host \
    "${EXTRA_OPTS[@]}" \
    -e DISPLAY="${DISPLAY:-:0}" \
    -e HEADLESS="${HEADLESS}" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "${REPO_DIR}/ros2_ws/src:/ws/src/drone" \
    -v "${REPO_DIR}/ops:/ops:ro" \
    -v "${REPO_DIR}/missions:/missions:ro" \
    -v "${REPO_DIR}/scripts:/scripts:ro" \
    -v "${REPO_DIR}/logs:/logs" \
    -v "${REPO_DIR}/px4_patches:/px4_patches:ro" \
    "${IMAGE}" "$@"
