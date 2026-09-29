#!/usr/bin/env bash
# Arranca el agente XRCE y PX4 SITL (tras `source env_native.sh`, que define
# OPS_DIR, LOG_DIR, PX4_DIR y SIM).
#
#   scripts/start_sim.sh              # ciudad por defecto: toulouse
#   scripts/start_sim.sh donostia     # otra ciudad (AR-019): solo cambia el fichero ops/
#
#   SIM=sih (por defecto)  -> simulador SIH, sin Gazebo
#   SIM=gz                 -> Gazebo con el x500;  HEADLESS=1 sin interfaz
#
# El origen (home) se lee de ops/<ciudad>.yaml (repo drone-ros); no hay coordenadas en el código.
set -euo pipefail

CITY="${1:-toulouse}"
: "${OPS_DIR:?Haz antes: source env_native.sh}"
: "${PX4_DIR:?Haz antes: source env_native.sh}"
LOG_DIR="${LOG_DIR:-logs}"
SIM="${SIM:-sih}"
OPS_FILE="${OPS_DIR}/${CITY}.yaml"
mkdir -p "${LOG_DIR}"

if [ ! -f "${OPS_FILE}" ]; then
    echo "No existe ${OPS_FILE}" >&2
    exit 1
fi

# Lee home del fichero de operación
read -r PX4_HOME_LAT PX4_HOME_LON PX4_HOME_ALT < <(python3 - "${OPS_FILE}" <<'EOF'
import sys, yaml
with open(sys.argv[1]) as f:
    ops = yaml.safe_load(f)
h = ops["hub"]
print(h["lat"], h["lon"], h["alt_m"])
EOF
)
export PX4_HOME_LAT PX4_HOME_LON PX4_HOME_ALT
echo "Ciudad: ${CITY}  home: ${PX4_HOME_LAT}, ${PX4_HOME_LON}, ${PX4_HOME_ALT} m"

# Agente XRCE en segundo plano (PX4 SITL se conecta por UDP 8888)
MicroXRCEAgent udp4 -p 8888 > "${LOG_DIR}/xrce_agent.log" 2>&1 &
AGENT_PID=$!
trap 'kill ${AGENT_PID} 2>/dev/null || true' EXIT

cd "${PX4_DIR}"
case "${SIM}" in
    gz)  echo "Simulador: Gazebo (HEADLESS=${HEADLESS:-1})"
         HEADLESS="${HEADLESS:-1}" make px4_sitl gz_x500 ;;
    sih) echo "Simulador: SIH (sin Gazebo)"
         make px4_sitl sihsim_quadx ;;
    *)   echo "SIM debe ser gz o sih (recibido: ${SIM})" >&2; exit 1 ;;
esac
