#!/usr/bin/env bash
# Comprueba la instalación nativa de punta a punta. Requiere haber hecho `source env_native.sh`.
#
#   ./scripts/check_native.sh            # herramientas + validación de ops + humo de simulación
#   RUN_TESTS=1 ./scripts/check_native.sh   # además, colcon test (64 tests esperados)
#
# Arranca PX4 SITL (SIH o Gazebo según $SIM) y el agente en segundo plano, comprueba que
# los tópicos _v1 de PX4 llegan a ROS 2 y lo apaga todo. Deja el resultado en logs/check_native.txt
set -uo pipefail

: "${DRONE_SIM_DIR:?Haz antes: source env_native.sh}"
REPO="${DRONE_SIM_DIR}"
OUT="${LOG_DIR}/check_native.txt"
mkdir -p "${LOG_DIR}"
: > "${OUT}"
exec > >(tee -a "${OUT}") 2>&1

PASS=0; FAIL=0
ok()   { printf '  [ OK ] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FALLA] %s\n' "$*"; FAIL=$((FAIL+1)); }
chk()  { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${msg}"; else bad "${msg}"; fi; }
sec()  { printf '\n== %s\n' "$*"; }

sec "Entorno"
echo "$(lsb_release -ds 2>/dev/null) · ROS_DISTRO=${ROS_DISTRO:-?} · SIM=${SIM} · PX4_DIR=${PX4_DIR}"
chk "ROS 2 Jazzy cargado"                       test "${ROS_DISTRO:-}" = "jazzy"
chk "px4_msgs visible para ROS 2"               ros2 pkg prefix px4_msgs
chk "px4_msgs incluye DropGuardStatus (del fork)" bash -c 'ros2 interface show px4_msgs/msg/DropGuardStatus >/dev/null'
chk "drone_core, drone_interfaces, drone_mission compilados" bash -c 'ros2 pkg prefix drone_core && ros2 pkg prefix drone_interfaces && ros2 pkg prefix drone_mission'
chk "MicroXRCEAgent arranca (-h)"               bash -c 'MicroXRCEAgent -h 2>&1 | grep -q "^Usage"'
chk "pymavlink y pyulog importables"            python3 -c "import pymavlink, pyulog"
chk "PX4 SITL compilado"                        test -x "${PX4_DIR}/build/px4_sitl_default/bin/px4"
chk "PX4 lleva el módulo drop_guard"            test -e "${PX4_DIR}/build/px4_sitl_default/bin/px4-drop_guard"
chk "PX4 es el fork drone-px4 sobre v1.17.0"    bash -c "git -C '${PX4_DIR}' describe --tags | grep -q '^v1.17.0'"
if command -v gz >/dev/null 2>&1; then ok "Gazebo: $(gz sim --versions 2>/dev/null | head -1)"; else echo "  (Gazebo no instalado: solo SIM=sih)"; fi

sec "Configuración por ciudad (AR-019)"
chk "toulouse + tls_demo_01 valida"  ros2 run drone_core drone_validate "${OPS_DIR}" toulouse "${MISSIONS_DIR}" tls_demo_01
chk "donostia + dss_demo_01 valida"  ros2 run drone_core drone_validate "${OPS_DIR}" donostia "${MISSIONS_DIR}" dss_demo_01

if [ "${RUN_TESTS:-0}" = "1" ]; then
    sec "Tests unitarios"
    ( cd "${REPO}/ros2_ws" && colcon test --packages-select drone_core drone_mission >/dev/null 2>&1; colcon test-result | tail -3 )
    if ( cd "${REPO}/ros2_ws" && colcon test-result >/dev/null 2>&1 ); then ok "colcon test"; else bad "colcon test (mira colcon test-result --verbose)"; fi
fi

sec "Humo de simulación (${SIM}) — puede tardar 1-3 min la primera vez"
pkill -f 'bin/px4' 2>/dev/null; pkill -f MicroXRCEAgent 2>/dev/null; sleep 1
SIMLOG="${LOG_DIR}/check_native_sim.log"
# `sleep infinity |` mantiene abierto el stdin de PX4 (su consola pxh no debe ver EOF)
setsid bash -c "sleep infinity | '${REPO}/scripts/start_sim.sh' toulouse" > "${SIMLOG}" 2>&1 &
SIM_PGID=$!
cleanup() {
    kill -- "-${SIM_PGID}" 2>/dev/null
    pkill -f 'bin/px4' 2>/dev/null; pkill -f MicroXRCEAgent 2>/dev/null
}
trap cleanup EXIT

# PX4 1.17 añade el sufijo _vN a los mensajes versionados (vehicle_status_v1, ...): se resuelve el nombre real
topic_of() { ros2 topic list 2>/dev/null | grep -E "^/fmu/out/$1(_v[0-9]+)?$" | head -1; }
TOPIC=""
for _ in $(seq 1 90); do
    TOPIC="$(topic_of vehicle_status)"
    [ -n "${TOPIC}" ] && break
    sleep 2
done
if [ -n "${TOPIC}" ]; then ok "tópico ${TOPIC} visible en ROS 2 (agente XRCE conectado)"; else bad "no aparece /fmu/out/vehicle_status* tras 3 min (mira ${SIMLOG} y logs/xrce_agent.log)"; fi

if [ -n "${TOPIC}" ]; then
    NAV=$(timeout 20 ros2 topic echo --once "${TOPIC}" --field nav_state 2>/dev/null | head -1)
    if [ -n "${NAV}" ]; then ok "${TOPIC} recibe datos (nav_state=${NAV})"; else bad "${TOPIC} no entrega mensajes"; fi
    GP="$(topic_of vehicle_global_position)"
    LAT=$(timeout 20 ros2 topic echo --once "${GP:-/fmu/out/vehicle_global_position}" --field lat 2>/dev/null | head -1)
    HOME_LAT=$(python3 -c "import yaml;print(yaml.safe_load(open('${OPS_DIR}/toulouse.yaml'))['hub']['lat'])")
    if [ -n "${LAT}" ] && python3 -c "import sys; sys.exit(0 if abs(float('${LAT}')-float('${HOME_LAT}'))<0.01 else 1)"; then
        ok "el origen sigue ops/toulouse.yaml (lat ${LAT} ≈ ${HOME_LAT})"
    else
        bad "el origen no coincide con ops/toulouse.yaml (lat=${LAT:-sin dato}, esperada ${HOME_LAT})"
    fi
fi
grep -qi "drop_guard" "${SIMLOG}" && echo "  (drop_guard aparece en el arranque de PX4)" || echo "  (aviso: drop_guard no se menciona en ${SIMLOG}; revisa el arranque)"

sec "Resultado"
echo "${PASS} correctas, ${FAIL} fallidas. Informe: ${OUT}"
[ "${FAIL}" -eq 0 ]
