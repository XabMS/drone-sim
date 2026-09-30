# drone-sim

Entorno de simulación y pruebas del dron de reparto urbano de última milla (ROS 2 Jazzy + PX4 v1.17). Es el repo
que **reconstruye el sistema completo**: fija las versiones de todo en `drone.repos` y lo instala con un solo script.

> Proyecto de aprendizaje personal. Sigue un proceso inspirado en ARP4754A/ARP4761A, **sin certificación**.

- **Nivel de control:** CC2 (versionado, sin proceso formal de cambios), según el plan de configuración (DOC-09 §5).
- **Solo Ubuntu 24.04** con ROS 2 Jazzy; instalación nativa, sin contenedores.

## Cómo se relaciona con los otros repos

| Repo | Contenido | Control |
| --- | --- | --- |
| [`drone-ros`](https://github.com/XabMS/drone-ros) | Paquetes ROS 2, configuración por ciudad (`ops/`) y misiones | CC1 |
| [`drone-px4`](https://github.com/XabMS/drone-px4) | Fork de PX4 con el módulo `drop_guard` (rama `drone`) | CC1 |
| **`drone-sim`** (este) | Scripts de instalación, `drone.repos`, pruebas de simulación | CC2 |
| [`drone-docs`](https://github.com/XabMS/drone-docs) | Documentación y requisitos | CC1 |

## Empezar

```bash
mkdir -p ~/drone && cd ~/drone
git clone https://github.com/XabMS/drone-sim.git && cd drone-sim
./scripts/setup_native.sh          # con SKIP_PX4_DEPS=1 si el sistema ya tiene las dependencias de PX4
source env_native.sh
RUN_TESTS=1 ./scripts/check_native.sh
```

La primera instalación tarda entre 45 y 90 min (la compilación de PX4 pasa de 30 min). Detalles en
[`README_NATIVE.md`](README_NATIVE.md); el hito S2 (gestión de misión) está en [`README_S2.md`](README_S2.md).

## Estructura

```
drone-sim/
├── drone.repos        versiones exactas de drone-ros, drone-px4, px4_msgs y Micro XRCE-DDS Agent
├── env_native.sh      entorno de cada terminal (source)
├── scripts/           setup_native.sh, check_native.sh, start_sim.sh, s2_scenarios.py
├── tests/             sitl_drop_guard_test.py (drop_guard en PX4 SITL)
├── legacy/            enfoque con contenedor (descartado, no se mantiene)
├── ros2_ws/src/       (ignorado) aquí se clona drone-ros
└── .deps/             (ignorado) PX4, agente XRCE, px4_msgs y pylibs
```

## Baselines

`drone.repos` es lo que representa cada baseline. Los tags de baseline siguen el formato `vFASE.BASELINE.N`
(por ejemplo `v1.PDR.0`) y se crean en las revisiones SRR, PDR, CDR y TRR/FRR. Todavía no hay ninguno.

## Pendiente

- CI: `nightly.yml` ejecuta la instalación completa y `check_native.sh` (ver el workflow).

## Licencia

Apache-2.0 (ver [`LICENSE`](LICENSE)).
