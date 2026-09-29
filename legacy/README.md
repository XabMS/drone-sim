# legacy/ — enfoque con contenedor (descartado)

Este directorio conserva el enfoque del hito S1 con Docker (imagen, scripts de contenedor y runbook).
**Está descartado**: el entorno se instala ahora de forma nativa en Ubuntu 24.04 con `scripts/setup_native.sh`
(ver el README de la raíz y `README_NATIVE.md`).

Se guarda solo como referencia histórica y **no se mantiene**: los scripts asumen el layout antiguo
(`ros2_ws/src`, `px4_patches/`, `ops/` en la raíz), que ya no existe; el parche de `drop_guard` vive ahora
como commits en la rama `drone` del fork `drone-px4`.

- `docker/`, `scripts/` — Dockerfile y scripts del contenedor.
- `RUNBOOK_S1.md` — guion del hito S1 con contenedor.
- `README_S1.md` — README original del hito S1.
