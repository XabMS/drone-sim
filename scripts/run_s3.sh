#!/usr/bin/env bash
# Lanza los escenarios del hito S3 (suelta real), cada uno con una simulación limpia. Requiere `source env_native.sh`.
#
#   ./scripts/run_s3.sh                    # todos: sim01_real sim05 sim06 sim07 abort
#   ./scripts/run_s3.sh sim05 sim07        # solo estos
#
# Por escenario: borra los parámetros persistentes de PX4 SITL (los DG_* de un run seguirían en el siguiente), arranca
# PX4 SITL (SIH) y el agente, arranca los nodos de drone-ros que necesite y ejecuta scripts/s3_scenarios.py.
# Usa datos de prueba generados por tests/make_s3_data.py (zona de suelta a 150 m del hub): no toca ops/ ni missions/.
# Deja los logs en logs/s3_<fecha>/ y sale con código distinto de 0 si algún escenario falla.
set -uo pipefail

: "${DRONE_SIM_DIR:?Haz antes: source env_native.sh}"
: "${PX4_DIR:?Haz antes: source env_native.sh}"
REPO="${DRONE_SIM_DIR}"
LOG_DIR="${LOG_DIR:-${REPO}/logs}"
SCENARIOS=("$@")
[ "${#SCENARIOS[@]}" -gt 0 ] || SCENARIOS=(sim01_real sim05 sim06 sim07 abort)

OUT="${LOG_DIR}/s3_$(date +%Y%m%d_%H%M%S)"
DATA="${OUT}/data"
mkdir -p "${OUT}"
SUMMARY="${OUT}/summary.txt"

python3 "${REPO}/tests/make_s3_data.py" "${DATA}" "${OPS_DIR}" || exit 1
export OPS_DIR="${DATA}/ops"
export MISSIONS_DIR="${DATA}/missions"
ros2 run drone_core drone_validate "${OPS_DIR}" toulouse "${MISSIONS_DIR}" s3_short >/dev/null || {
    echo "Los datos de prueba no validan: revisa ${DATA}" >&2
    exit 1
}
MISSION_PARAMS="$(ros2 pkg prefix drone_mission)/share/drone_mission/config/mission_manager.yaml"
PX4_ROOTFS="${PX4_DIR}/build/px4_sitl_default/rootfs"

PIDS=()
teardown() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill -TERM -- "-${pid}" 2>/dev/null
    done
    sleep 3
    pkill -f 'bin/px4' 2>/dev/null
    pkill -f MicroXRCEAgent 2>/dev/null
    pkill -f 'lib/drone_mission/(config|mission)_manager|lib/drone_payload/payload_manager|pilot_confirm_bridge' 2>/dev/null
    sleep 2
    PIDS=()
}
trap teardown EXIT

start() {   # start <fichero de log> <orden...>: lanza en su propio grupo de procesos
    local logfile="$1"
    shift
    setsid "$@" > "${logfile}" 2>&1 &
    PIDS+=($!)
}

run_scenario() {
    local scen="$1" prefix="${OUT}/$1" confirm_timeout=90.0
    [ "${scen}" = sim05 ] && confirm_timeout=10.0
    rm -f "${PX4_ROOTFS}/parameters.bson" "${PX4_ROOTFS}/parameters_backup.bson"
    PIDS=()

    # `sleep infinity |` mantiene abierto el stdin de PX4: sin él su consola repite el prompt sin parar y el log llega a GB
    start "${prefix}.sim.log" bash -c "sleep infinity | '${REPO}/scripts/start_sim.sh' toulouse"
    local up=0 _
    for _ in $(seq 1 90); do
        if timeout 8 ros2 topic echo --once /fmu/out/vehicle_status_v1 --qos-reliability best_effort >/dev/null 2>&1; then
            up=1
            break
        fi
        sleep 2
    done
    if [ "${up}" != 1 ]; then
        echo "PX4 no arrancó (mira ${prefix}.sim.log)" | tee -a "${prefix}.log"
        teardown
        return 1
    fi

    if [ "${scen}" != sim06 ]; then   # sim06 prueba la orden forzada por DDS: no necesita los nodos
        start "${prefix}.config.log" ros2 run drone_mission config_manager --ros-args \
            -p ops_dir:="${OPS_DIR}" -p city:=toulouse
        start "${prefix}.mission.log" ros2 run drone_mission mission_manager --ros-args --params-file "${MISSION_PARAMS}" \
            -p ops_dir:="${OPS_DIR}" -p missions_dir:="${MISSIONS_DIR}" -p mission_id:=s3_short
        start "${prefix}.payload.log" ros2 run drone_payload payload_manager --ros-args \
            -p ops_dir:="${OPS_DIR}" -p city:=toulouse -p confirm_timeout_s:="${confirm_timeout}"
        start "${prefix}.bridge.log" ros2 run drone_gcs_bridge pilot_confirm_bridge
    fi
    sleep 6

    timeout 900 python3 "${REPO}/scripts/s3_scenarios.py" "${scen}" "${OPS_DIR}" > "${prefix}.log" 2>&1
    local rc=$?
    teardown
    return "${rc}"
}

failed=0
: > "${SUMMARY}"
for scen in "${SCENARIOS[@]}"; do
    echo "=== ${scen} ($(date +%T)) ===" | tee -a "${SUMMARY}"
    run_scenario "${scen}"
    rc=$?
    sed -n '/^RESUMEN/,$p' "${OUT}/${scen}.log" 2>/dev/null | tee -a "${SUMMARY}"
    if [ "${rc}" -ne 0 ]; then
        failed=$((failed + 1))
        echo "FALLA ${scen} (rc=${rc}); logs en ${OUT}" | tee -a "${SUMMARY}"
    fi
done

echo
echo "$(( ${#SCENARIOS[@]} - failed )) de ${#SCENARIOS[@]} escenarios pasan. Informe: ${SUMMARY}" | tee -a "${SUMMARY}"
[ "${failed}" -eq 0 ]
