# drone-sim — instalación nativa (Ubuntu 24.04, sin Docker)

Instala el entorno de simulación en el propio sistema (solo Ubuntu 24.04 con ROS 2 Jazzy). El enfoque con
contenedor está descartado y queda en `legacy/`.

Todo lo descargado va a `.deps/` (ignorado por git). No toca otros proyectos ni `/opt/ros`.

## Instalar (una vez)

```bash
mkdir -p ~/drone && cd ~/drone
git clone https://github.com/XabMS/drone-sim.git && cd drone-sim
./scripts/setup_native.sh
```

Las versiones exactas de todo (drone-ros, drone-px4, px4_msgs, agente XRCE) las fija `drone.repos`; el script las
lee de ahí. `drone-ros` queda clonado en `ros2_ws/src/drone-ros` y es tu copia de trabajo (ramas, commits, PR).

Tarda entre 45 y 90 min la primera vez (clon de PX4, compilación de PX4 —más de 30 min—, agente XRCE y px4_msgs).
Pide la contraseña de sudo en los pasos `apt` y `px4`. Es idempotente: si se corta, se relanza.
El log queda en `logs/setup_native_<fecha>.log`.

Pasos sueltos: `./scripts/setup_native.sh px4build`, `... xrce`, `... ws`, etc. (ver cabecera del script).
Si la compilación de PX4 se queda sin memoria: `JOBS=2 ./scripts/setup_native.sh px4build`.
Si en este equipo ya ejecutaste `Tools/setup/ubuntu.sh` de PX4: `SKIP_PX4_DEPS=1 ./scripts/setup_native.sh`.
Para probar otra versión sin editar `drone.repos`: `PX4_REF=...`, `PX4_MSGS_REF=...`, `XRCE_AGENT_REF=...`, `DRONE_ROS_REF=...`.

## Comprobar

```bash
source env_native.sh
./scripts/check_native.sh                 # herramientas, validación de ops y humo de simulación
RUN_TESTS=1 ./scripts/check_native.sh     # además, los 64 tests unitarios
```

Devuelve el fichero `logs/check_native.txt` (y `logs/setup_native_*.log` si algo falló).

## Uso diario (equivale a las tres terminales de README_S2.md)

En **cada terminal**: `source <ruta al clon>/env_native.sh`. Usa una terminal nueva: no la mezcles con una que tenga cargado el entorno de otro proyecto ROS 2 (el script lo detecta y avisa).

```bash
# Terminal A — simulación (SIH por defecto; SIM=gz para Gazebo, HEADLESS=0 con interfaz)
./scripts/start_sim.sh toulouse

# Terminal B — nodos de misión
ros2 launch drone_mission s2.launch.py city:=toulouse mission_id:=tls_demo_01

# Terminal C — escenarios
python3 scripts/s2_scenarios.py sim01
```

`env_native.sh` define `OPS_DIR` y `MISSIONS_DIR` (apuntan a `ros2_ws/src/drone-ros/ops` y `.../missions`),
`LOG_DIR` y `PX4_DIR`; `start_sim.sh` y `s2.launch.py` los usan.
Para recompilar tus paquetes: `cd ros2_ws && colcon build --symlink-install`.

## Notas del entorno

- Simulador por defecto: **SIH** (sin Gazebo), que es con lo que se verificó S2 y lo que cabe bien en gráfica integrada. `SIM=gz` usa Gazebo.
- PX4 vive en `.deps/PX4-Autopilot`, clonado del fork `drone-px4` en el tag de `drone.repos` (PX4 v1.17.0 + drop_guard como commits reales, rama `drone`).
- El agente XRCE tiene un wrapper (`.deps/bin/MicroXRCEAgent`) que carga sus propias librerías Fast-DDS solo para ese proceso, para no chocar con las de ROS 2.
- `px4_msgs` está en un workspace aparte (`.deps/px4_msgs_ws`). **Pendiente para S3:** el fork añade `DropGuardStatus.msg`; `px4_msgs release/1.17` no lo trae, así que en S3 habrá que generar `px4_msgs` desde el `msg/` del fork `drone-px4`.
