# shellcheck shell=bash
# drone-sim — entorno NATIVO (Ubuntu 24.04). Uso, en cada terminal nueva:
#
#     source <ruta al clon>/drone-sim/env_native.sh
#
# No usa `set -u` ni `set -e`: se hace `source` desde tu shell interactiva.

_DS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Este entorno NO debe mezclarse con el de otro workspace de ROS 2 (otro proyecto): comparten
# ROS 2 Jazzy pero no workspace, ni PX4, ni modelos de Gazebo. Se detecta cualquier ruta de
# AMENT_PREFIX_PATH que no sea /opt/ros ni de este repo.
IFS=: read -ra _ds_paths <<< "${AMENT_PREFIX_PATH:-}"
for _ds_p in "${_ds_paths[@]}"; do
    case "${_ds_p}" in
        ""|/opt/ros/*|"${_DS_REPO}"/*) ;;
        *)
            echo "AVISO: esta terminal ya tiene cargado otro entorno ROS 2 (${_ds_p}). Abre una terminal nueva." >&2
            unset _DS_REPO _ds_paths _ds_p
            return 1 2>/dev/null || exit 1
            ;;
    esac
done
unset _ds_paths _ds_p

export DRONE_SIM_DIR="${_DS_REPO}"
export DRONE_DEPS="${_DS_REPO}/.deps"
export PX4_DIR="${DRONE_DEPS}/PX4-Autopilot"

# Configuración por ciudad y misiones: viven en el repo drone-ros, clonado por setup_native.sh (paso ws)
export OPS_DIR="${_DS_REPO}/ros2_ws/src/drone-ros/ops"
export MISSIONS_DIR="${_DS_REPO}/ros2_ws/src/drone-ros/missions"
export LOG_DIR="${_DS_REPO}/logs"

# Simulador por defecto en el portátil (gráfica integrada): SIH, sin Gazebo.
#   SIM=sih  -> make px4_sitl sihsim_quadx   (ligero; es con lo que se verificó S2)
#   SIM=gz   -> make px4_sitl gz_x500        (Gazebo; HEADLESS=1 sin interfaz)
export SIM="${SIM:-sih}"
export HEADLESS="${HEADLESS:-1}"

source /opt/ros/jazzy/setup.bash
[ -f "${DRONE_DEPS}/px4_msgs_ws/install/setup.bash" ] && source "${DRONE_DEPS}/px4_msgs_ws/install/setup.bash"
[ -f "${_DS_REPO}/ros2_ws/install/setup.bash" ]       && source "${_DS_REPO}/ros2_ws/install/setup.bash"

# MicroXRCEAgent (con su wrapper de librerías) y pymavlink/pyulog para los scripts de prueba
export PATH="${DRONE_DEPS}/bin:${PATH}"
export PYTHONPATH="${DRONE_DEPS}/pylibs${PYTHONPATH:+:${PYTHONPATH}}"

unset _DS_REPO
