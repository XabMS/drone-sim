#!/usr/bin/env bash
# Construye la imagen de simulación. Se ejecuta en el PC (host).
# La primera vez tarda (PX4 + Gazebo): cuenta con 30-60 min y ~15 GB de disco.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-drone-sim:s1}"

docker build -t "${IMAGE}" "${REPO_DIR}/docker" "$@"
echo "Imagen construida: ${IMAGE}"
