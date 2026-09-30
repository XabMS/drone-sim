#!/usr/bin/env bash
# drone-sim — instalación NATIVA en Ubuntu 24.04 (sin contenedores).
#
#   ./scripts/setup_native.sh                 # todos los pasos, en orden
#   ./scripts/setup_native.sh px4 px4build    # solo algunos pasos
#
# Pasos (idempotentes; se pueden relanzar sin miedo):
#   preflight  comprueba SO, ROS 2 Jazzy, disco y RAM
#   apt        paquetes del sistema (solo instala los que faltan)
#   px4        clona el fork drone-px4 (con drop_guard) y ejecuta su ubuntu.sh --no-nuttx
#   px4build   make px4_sitl
#   xrce       compila Micro XRCE-DDS Agent en .deps/xrce
#   msgs       compila px4_msgs en un workspace aparte (.deps/px4_msgs_ws)
#   pylibs     pymavlink + pyulog en .deps/pylibs (los usan s2_scenarios.py y tests/sitl_drop_guard_test.py)
#   ws         obtiene drone-ros con vcs import (ros2_ws/src/drone-ros) y hace colcon build
#
# Las versiones (drone-ros, drone-px4, px4_msgs, Micro-XRCE-DDS-Agent) las fija drone.repos;
# ese fichero es lo que representa cada baseline. Para probar otra versión sin editarlo:
#   PX4_REF, PX4_MSGS_REF, XRCE_AGENT_REF, DRONE_ROS_REF   (rama o tag; DRONE_ROS_REF admite también un commit)
#
# Variables opcionales:
#   JOBS=N                                     trabajos de compilación (por defecto nproc; con poca RAM usa 2)
#   SKIP_PX4_DEPS=1                            no ejecutar Tools/setup/ubuntu.sh (ya hecho en esta máquina)
#
# Todo lo que se descarga queda en .deps/ (ignorado por git). No toca /opt/ros, ni otros
# proyectos, ni instala nada fuera de apt y de los paquetes que pide PX4.
# El log completo queda en logs/setup_native_<fecha>.log

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="${REPO_DIR}/.deps"
PX4_DIR="${DEPS}/PX4-Autopilot"
REPOS_FILE="${REPO_DIR}/drone.repos"
JOBS="${JOBS:-$(nproc)}"
# Mensajes que añade el fork drone-px4 y que px4_msgs release/1.17 no trae. Se copian del msg/ del fork
# fijado en drone.repos, para que ROS 2 y PX4 compartan exactamente la misma definición (S3).
FORK_MSGS=(DropGuardStatus)

mkdir -p "${DEPS}" "${REPO_DIR}/logs"
LOG="${REPO_DIR}/logs/setup_native_$(date +%Y%m%d_%H%M).log"
exec > >(tee -a "${LOG}") 2>&1

# Lee url o version de una entrada de drone.repos (la clave es la ruta relativa al repo).
repos_get() {
    python3 - "${REPOS_FILE}" "$1" "$2" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    entry = yaml.safe_load(f)["repositories"][sys.argv[2]]
print(entry[sys.argv[3]])
PYEOF
}
[ -f "${REPOS_FILE}" ] || { echo "ERROR: falta ${REPOS_FILE}" >&2; exit 1; }
PX4_URL="$(repos_get .deps/PX4-Autopilot url)"
PX4_REF="${PX4_REF:-$(repos_get .deps/PX4-Autopilot version)}"
PX4_MSGS_URL="$(repos_get .deps/px4_msgs_ws/src/px4_msgs url)"
PX4_MSGS_REF="${PX4_MSGS_REF:-$(repos_get .deps/px4_msgs_ws/src/px4_msgs version)}"
XRCE_AGENT_URL="$(repos_get .deps/src/Micro-XRCE-DDS-Agent url)"
XRCE_AGENT_REF="${XRCE_AGENT_REF:-$(repos_get .deps/src/Micro-XRCE-DDS-Agent version)}"

say()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mAVISO: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Entorno limpio para compilar PX4 y el agente: sin ROS 2 ni rutas de otros proyectos
# (de otros proyectos) que puedan colarse en CMake, en las librerías o en las rutas de Gazebo.
clean_env() {
    env -u AMENT_PREFIX_PATH -u CMAKE_PREFIX_PATH -u COLCON_PREFIX_PATH -u LD_LIBRARY_PATH \
        -u PYTHONPATH -u GZ_SIM_RESOURCE_PATH -u ROS_DISTRO -u ROS_VERSION -u ROS_PYTHON_VERSION \
        -u MAKEFLAGS -u MFLAGS -u MAKELEVEL "$@"
}

# ------------------------------------------------------------------ preflight
step_preflight() {
    say "Comprobaciones previas"
    [ "$(id -u)" -ne 0 ] || die "No lo ejecutes como root; pedirá sudo cuando haga falta."
    . /etc/os-release
    [ "${ID}" = "ubuntu" ] && [ "${VERSION_ID}" = "24.04" ] \
        || die "Se necesita Ubuntu 24.04 (este equipo: ${PRETTY_NAME}). ROS 2 Jazzy solo está soportado ahí."
    [ -f /opt/ros/jazzy/setup.bash ] \
        || die "Falta ROS 2 Jazzy en /opt/ros/jazzy. Instálalo: https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html (paquete ros-jazzy-desktop)."
    command -v git >/dev/null || die "Falta git (sudo apt install git)."
    local free_gb ram_gb
    free_gb=$(df -BG --output=avail "${REPO_DIR}" | tail -1 | tr -dc '0-9')
    ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
    echo "Ubuntu ${VERSION_ID} · ${JOBS} hilos · ${ram_gb} GB de RAM · ${free_gb} GB libres en el disco"
    [ "${free_gb}" -ge 12 ] || die "Se necesitan unos 12 GB libres (hay ${free_gb})."
    if [ "${ram_gb}" -lt 8 ]; then
        warn "Con menos de 8 GB de RAM el enlazado de PX4 puede quedarse sin memoria. Si pasa: JOBS=2 ./scripts/setup_native.sh px4build"
    fi
    local p
    while IFS= read -r p; do
        case "${p}" in
            ""|/opt/ros/*|"${REPO_DIR}"/*) ;;
            *) warn "Esta terminal tiene cargado otro entorno ROS 2 (${p}); los pasos de compilación lo ignoran, pero abre una terminal nueva para trabajar."; break ;;
        esac
    done < <(printf '%s\n' "${AMENT_PREFIX_PATH:-}" | tr ':' '\n')
    echo "OK"
}

# ------------------------------------------------------------------------ apt
step_apt() {
    say "Paquetes del sistema"
    local wanted=(git curl wget lsb-release gnupg ca-certificates cmake build-essential
                  python3-pip python3-yaml python3-venv python3-colcon-common-extensions python3-vcstool
                  libyaml-cpp-dev nlohmann-json3-dev
                  ros-jazzy-desktop ros-jazzy-ros-gz mesa-utils iproute2)
    local missing=()
    for p in "${wanted[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        echo "No falta ninguno."
    else
        echo "Faltan: ${missing[*]}"
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends "${missing[@]}"
    fi
}

# ------------------------------------------------------------------------ px4
step_px4() {
    say "PX4 (fork drone-px4) ${PX4_REF}"
    if [ -d "${PX4_DIR}/.git" ]; then
        local have
        have="$(git -C "${PX4_DIR}" describe --tags 2>/dev/null || true)"
        echo "Ya existe ${PX4_DIR} (${have:-sin tag})"
        case "${have}" in "${PX4_REF}"*) ;; *) die "No es ${PX4_REF}. Borra .deps/PX4-Autopilot o cambia PX4_REF." ;; esac
    else
        clean_env git clone --recursive --shallow-submodules --depth 1 --branch "${PX4_REF}" \
            "${PX4_URL}" "${PX4_DIR}"
    fi
    if [ "${SKIP_PX4_DEPS:-0}" = "1" ]; then
        echo "SKIP_PX4_DEPS=1: no se ejecuta ubuntu.sh"
    elif [ -f "${DEPS}/.px4_deps_done" ]; then
        echo "Dependencias de PX4 ya instaladas (borra .deps/.px4_deps_done para repetir)"
    else
        echo "Ejecutando Tools/setup/ubuntu.sh --no-nuttx (pedirá sudo; instala Gazebo Harmonic y las dependencias de compilación)"
        clean_env bash "${PX4_DIR}/Tools/setup/ubuntu.sh" --no-nuttx
        touch "${DEPS}/.px4_deps_done"
    fi
}

step_px4build() {
    say "Compilando PX4 SITL (la primera vez tarda 15-30 min)"
    cd "${PX4_DIR}"
    clean_env make -j"${JOBS}" px4_sitl
    [ -e build/px4_sitl_default/bin/px4-drop_guard ] \
        || die "PX4 compiló pero el binario no incluye drop_guard: ¿es el fork drone-px4 (rama drone)?"
    echo "OK: build/px4_sitl_default/bin/px4 con drop_guard"
}

# ----------------------------------------------------------------------- xrce
step_xrce() {
    say "Micro XRCE-DDS Agent ${XRCE_AGENT_REF}"
    local src="${DEPS}/src/Micro-XRCE-DDS-Agent" prefix="${DEPS}/xrce"
    mkdir -p "${DEPS}/src" "${DEPS}/bin"
    if [ -x "${prefix}/bin/MicroXRCEAgent" ] && [ -x "${DEPS}/bin/MicroXRCEAgent" ]; then
        echo "Ya compilado."
        return
    fi
    [ -d "${src}/.git" ] || clean_env git clone --depth 1 --branch "${XRCE_AGENT_REF}" \
        "${XRCE_AGENT_URL}" "${src}"
    clean_env cmake -S "${src}" -B "${src}/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${prefix}"
    clean_env cmake --build "${src}/build" -j"${JOBS}"
    clean_env cmake --install "${src}/build"
    # Wrapper: las librerías Fast-DDS del agente se cargan SOLO para ese proceso, sin mezclarse
    # con las de ROS 2 (que van por LD_LIBRARY_PATH en el resto de terminales).
    cat > "${DEPS}/bin/MicroXRCEAgent" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${prefix}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
exec "${prefix}/bin/MicroXRCEAgent" "\$@"
EOF
    chmod +x "${DEPS}/bin/MicroXRCEAgent"
    # -h imprime el uso y sale con código 1 (con pipefail rompería la tubería): se comprueba el texto, no el código
    { "${DEPS}/bin/MicroXRCEAgent" -h 2>&1 || true; } | grep -q "^Usage" || warn "MicroXRCEAgent no arranca; revisa el log."
    echo "OK: ${DEPS}/bin/MicroXRCEAgent"
}

# ----------------------------------------------------------------------- msgs
step_msgs() {
    say "px4_msgs ${PX4_MSGS_REF} (workspace aparte)"
    local ws="${DEPS}/px4_msgs_ws"
    mkdir -p "${ws}/src"
    [ -d "${ws}/src/px4_msgs/.git" ] || git clone --depth 1 --branch "${PX4_MSGS_REF}" \
        "${PX4_MSGS_URL}" "${ws}/src/px4_msgs"
    # Superposición del fork: px4_msgs hace glob de msg/*.msg, basta con copiar los ficheros. El sello
    # (hash de las definiciones) fuerza la recompilación si cambian o si aún no se habían añadido.
    local m src stamp=""
    for m in "${FORK_MSGS[@]}"; do
        src="${PX4_DIR}/msg/${m}.msg"
        [ -f "${src}" ] || die "Falta ${src}: ejecuta antes el paso px4."
        cp "${src}" "${ws}/src/px4_msgs/msg/${m}.msg"
        stamp+="$(sha256sum "${src}" | cut -d' ' -f1)"
    done
    stamp="$(printf '%s' "${stamp}" | sha256sum | cut -d' ' -f1)"
    if [ -f "${ws}/install/setup.bash" ] && [ "$(cat "${ws}/install/.fork_msgs_stamp" 2>/dev/null || true)" = "${stamp}" ]; then
        echo "Ya compilado."
        return
    fi
    set +u
    # shellcheck disable=SC1091
    source /opt/ros/jazzy/setup.bash
    set -u
    # --cmake-force-configure: px4_msgs lista los .msg con file(GLOB) al configurar; sin reconfigurar,
    # un mensaje recién copiado no entra en una compilación incremental.
    ( cd "${ws}" && colcon build --packages-select px4_msgs --parallel-workers "${JOBS}" \
        --cmake-force-configure --cmake-args -DCMAKE_BUILD_TYPE=Release )
    set +u
    # shellcheck disable=SC1091
    source "${ws}/install/setup.bash"
    set -u
    for m in "${FORK_MSGS[@]}"; do
        ros2 interface show "px4_msgs/msg/${m}" >/dev/null || die "px4_msgs no incluye ${m} tras compilar."
    done
    echo "${stamp}" > "${ws}/install/.fork_msgs_stamp"
}

# --------------------------------------------------------------------- pylibs
step_pylibs() {
    say "pymavlink y pyulog"
    # numpy<2: pylibs va delante en PYTHONPATH y numpy 2.x taparía al numpy 1.x del sistema,
    # contra el que están compiladas ROS 2 y scipy.
    python3 -m pip install --quiet --upgrade --target "${DEPS}/pylibs" "numpy<2" pymavlink pyulog
    PYTHONPATH="${DEPS}/pylibs" python3 -c "import pymavlink, pyulog; print('OK pymavlink', pymavlink.__file__)"
}

# ------------------------------------------------------------------------- ws
step_ws() {
    say "Workspace ROS 2 (ros2_ws): drone-ros + colcon build"
    [ -f "${DEPS}/px4_msgs_ws/install/setup.bash" ] || die "Falta px4_msgs: ejecuta antes el paso msgs."
    command -v vcs >/dev/null || die "Falta vcstool (sudo apt install python3-vcstool; lo instala el paso apt)."
    # Solo la entrada drone-ros de drone.repos (las demás las clonan sus pasos). Si ya está clonado
    # se deja como está: es tu copia de trabajo, y vcs no debe moverla de rama.
    local only="${DEPS}/drone_ros.repos"
    python3 - "${REPOS_FILE}" "${only}" "${DRONE_ROS_REF:-}" <<'PYEOF'
import sys, yaml
key = "ros2_ws/src/drone-ros"
with open(sys.argv[1]) as f:
    entry = yaml.safe_load(f)["repositories"][key]
if sys.argv[3]:
    entry["version"] = sys.argv[3]
with open(sys.argv[2], "w") as f:
    yaml.safe_dump({"repositories": {key: entry}}, f)
PYEOF
    vcs import --skip-existing "${REPO_DIR}" < "${only}"
    echo "drone-ros: $(git -C "${REPO_DIR}/ros2_ws/src/drone-ros" describe --tags --always 2>/dev/null) ($(git -C "${REPO_DIR}/ros2_ws/src/drone-ros" rev-parse --abbrev-ref HEAD))"
    set +u
    # shellcheck disable=SC1091
    source /opt/ros/jazzy/setup.bash
    source "${DEPS}/px4_msgs_ws/install/setup.bash"
    set -u
    cd "${REPO_DIR}/ros2_ws"
    colcon build --symlink-install --parallel-workers "${JOBS}"
}

# ----------------------------------------------------------------------- main
STEPS=("$@")
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(preflight apt px4 px4build xrce msgs pylibs ws)

for s in "${STEPS[@]}"; do
    declare -F "step_${s}" >/dev/null || die "Paso desconocido: ${s}"
done
for s in "${STEPS[@]}"; do "step_${s}"; done

say "Listo (${STEPS[*]})"
echo "Siguiente:  source ${REPO_DIR}/env_native.sh && ${REPO_DIR}/scripts/check_native.sh"
echo "Log: ${LOG}"
