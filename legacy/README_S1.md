# drone-sim — Hito S1

Entorno de simulación del dron de reparto (DOC-10). Instalación nativa en Ubuntu (sin Docker): ver **README_NATIVE.md**.

(Hito S1 original:) Objetivo del hito S1: el x500 despega, mantiene estacionario y aterriza en PX4 SITL + Gazebo, **mandado desde un nodo ROS 2**.

## Estructura

```
drone-sim/
├── docker/          Dockerfile + entrypoint (Ubuntu 24.04, ROS 2 Jazzy, Gazebo Harmonic, PX4, XRCE agent, px4_msgs)
├── scripts/         build_image.sh, run_container.sh (host) · start_sim.sh (contenedor)
├── ops/             Configuración por ciudad: toulouse.yaml, donostia.yaml (AR-019)
├── ros2_ws/src/     Paquetes propios (se montan en /ws/src/drone)
│   └── drone_s1_demo/   Nodo de demostración: despegue → estacionario → aterrizaje
└── logs/            Logs del agente y de las pruebas (montado en /logs)
```

## Requisitos en el portátil

- Ubuntu 24.04 nativo con Docker Engine (y el usuario en el grupo `docker`).
- ~15 GB libres para la imagen.
- QGroundControl instalado en el host (opcional para S1, recomendado).

## Pasos

Para la sesión guiada completa (con qué devolver), ver **RUNBOOK_S1.md**.

**1. Construir la imagen** (una vez; 30-60 min):

```bash
chmod +x scripts/*.sh docker/entrypoint.sh
./scripts/build_image.sh
```

**2. Terminal A — arrancar la simulación:**

```bash
./scripts/run_container.sh                 # sin interfaz de Gazebo
# dentro del contenedor:
/scripts/start_sim.sh toulouse
```

Espera a ver `pxh>` y el mensaje de que el cliente uXRCE-DDS está conectado.

**3. Terminal B — compilar y lanzar el nodo ROS 2:**

```bash
docker exec -it drone-sim /entrypoint.sh bash
cd /ws && colcon build --packages-up-to drone_s1_demo --symlink-install
source install/setup.bash
ros2 topic list | grep fmu                 # comprueba los nombres de los tópicos
ros2 launch drone_s1_demo s1_demo.launch.py altitude_m:=10.0 hover_s:=15.0
```

**4. (Opcional) QGroundControl** en el host: se conecta solo por UDP 14550 y muestra el vuelo.

Para ver Gazebo con interfaz (va justo con gráfica integrada): `HEADLESS=0 ./scripts/run_container.sh`.

## Criterios de salida del hito S1

- [ ] La imagen se construye desde cero sin errores.
- [ ] `ros2 topic list` muestra los tópicos `/fmu/in/*` y `/fmu/out/*`.
- [ ] El nodo pasa por STREAM → ARMING → CLIMB → HOVER → LAND → DONE.
- [ ] El x500 sube a 10 m ± 0,5 m, se mantiene 15 s y aterriza desarmado.
- [ ] Si se mata el nodo durante HOVER, PX4 aplica su failsafe de pérdida de Offboard (primera evidencia de ADR-001).
- [ ] El ULog del vuelo queda guardado (en `/opt/PX4-Autopilot/build/px4_sitl_default/rootfs/log/`).
- [ ] Cambiar a `start_sim.sh donostia` mueve el origen sin tocar código.

## Problemas conocidos / a comprobar

- **Nombres de tópicos:** PX4 v1.17 añade el sufijo `_vN` a los mensajes con versión distinta de 0. El nodo ya usa por defecto `/fmu/out/vehicle_status_v1` y `/fmu/out/vehicle_local_position_v1`; si `ros2 topic list` los muestra sin sufijo, pásalos como argumentos del launch (`topic_vehicle_status:=...`, `topic_local_position:=...`).
- **Versiones:** `PX4_TAG` (v1.17.0, última estable a 25/09/2026) y `PX4_MSGS_BRANCH` (release/1.17) deben ir emparejados. Desde el hito S3 PX4 se compilará desde el fork con drop_guard.
- **Hub provisional:** `ops/toulouse.yaml` usa el centro de Toulouse; sustituir por las coordenadas del terreno de aeromodelismo de Blagnac.
- El nodo `drone_s1_demo` es **desechable**: el software de misión real (IDAL C) se escribe en S2 con su propio diseño y pruebas.
