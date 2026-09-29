# Guía de pruebas en el portátil — hito S1 y drop_guard

**Tiempo total:** unas 2 horas, casi todo esperando a que se construya la imagen (30–60 min). La parte 2 es opcional.

**Regla general:** todo lo que salga en pantalla queda guardado en `drone-sim/logs/` gracias a los `tee` de los comandos. Si algo falla, **no lo arregles**: sigue al paso siguiente si puedes y al final me mandas el paquete de logs.

---

## Parte 0 · Preparación (10 min)

**0.1** Descomprime `drone-sim.zip` donde quieras, por ejemplo en `~/drone`:

```bash
mkdir -p ~/drone && cd ~/drone
unzip ~/Descargas/drone-sim.zip        # ajusta la ruta si lo descargaste en otro sitio
cd drone-sim
chmod +x scripts/*.sh docker/entrypoint.sh
```

**0.2** Si no tienes Docker instalado:

```bash
sudo apt update && sudo apt install -y docker.io
sudo usermod -aG docker $USER
# cierra sesión y vuelve a entrar (o reinicia) para que el grupo tenga efecto
```

**En Fedora** (en lugar de 0.2): Docker CE desde su repositorio oficial. Podman también funciona, pero los scripts están probados con Docker.

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io xhost
sudo systemctl enable --now docker
sudo usermod -aG docker $USER      # y vuelve a iniciar sesión
```

`run_container.sh` detecta SELinux y desactiva el etiquetado solo para este contenedor; no hace falta tocar nada más.

**0.3** Recoge los datos del PC:

```bash
./scripts/check_host.sh
```

✅ Esperado: termina con `Guardado en .../logs/00_host.txt`.

---

## Parte 1 · Hito S1 (1–1,5 h)

### 1.1 Construir la imagen (30–60 min, puedes dejarlo solo)

```bash
./scripts/build_image.sh 2>&1 | tee logs/01_build.log
```

✅ Esperado: la última línea es `Imagen construida: drone-sim:s1`.
❌ Si falla: no sigas con la parte 1; salta a la parte 3 y mándame los logs.

### 1.2 Terminal A — arrancar la simulación

```bash
cd ~/drone/drone-sim
./scripts/run_container.sh
```

Ya dentro del contenedor (el prompt cambia a `root@...`):

```bash
/scripts/start_sim.sh toulouse 2>&1 | tee /logs/02_sim_toulouse.log
```

✅ Esperado, en 1–3 minutos (la primera vez compila un poco): líneas `INFO [uxrce_dds_client] ...` indicando que está conectado y `Ready for takeoff!`.
Deja esta terminal abierta.

### 1.3 Terminal B — compilar el nodo y ver los tópicos

Abre otra terminal:

```bash
docker exec -it drone-sim /entrypoint.sh bash
```

Dentro del contenedor:

```bash
cd /ws
colcon build --packages-up-to drone_s1_demo 2>&1 | tee /logs/03_colcon.log
source install/setup.bash
ros2 topic list | tee /logs/04_topics.txt
ros2 topic echo --once /fmu/out/vehicle_status_v1 > /logs/05_vehicle_status.txt 2>&1
```

✅ Esperado: `04_topics.txt` muestra tópicos `/fmu/in/...` y `/fmu/out/...`, entre ellos `/fmu/out/vehicle_status_v1`.
⚠️ Si `vehicle_status` aparece **sin** `_v1`, apúntalo: habrá que lanzar el paso 1.4 con
`topic_vehicle_status:=/fmu/out/vehicle_status topic_local_position:=/fmu/out/vehicle_local_position` al final del comando.

### 1.4 Terminal B — primer vuelo: despegue, estacionario y aterrizaje

```bash
ros2 launch drone_s1_demo s1_demo.launch.py 2>&1 | tee /logs/06_vuelo_nominal.log
```

✅ Esperado (unos 45 s): el log pasa por `STREAM -> ARMING -> CLIMB -> HOVER -> LAND -> DONE` y termina con `Aterrizado y desarmado. S1 completado.`

Si tienes QGroundControl abierto en el PC, verás el dron subir a 10 m y bajar (se conecta solo).

**Con GPU dedicada (p. ej. RX 7600) y ganas de verlo en 3D:** arranca la terminal A con `HEADLESS=0 ./scripts/run_container.sh` y, antes de la simulación, comprueba que el contenedor usa la GPU:

```bash
glxinfo -B | grep -E "renderer|version" | tee /logs/02b_gpu.txt
```

✅ Esperado: `OpenGL renderer string: AMD Radeon RX 7600 (radeonsi, ...)`. Si pone `llvmpipe`, está usando la CPU: apúntalo.

### 1.5 Terminal B — prueba de failsafe (ADR-001)

Relanza el nodo y **córtalo con Ctrl+C justo cuando aparezca `CLIMB -> HOVER`**:

```bash
ros2 launch drone_s1_demo s1_demo.launch.py hover_s:=60.0 2>&1 | tee /logs/07_failsafe.log
```

Después espera 1–2 minutos mirando la **terminal A**: PX4 debería detectar la pérdida del modo Offboard y pasar a espera, regreso o aterrizaje por su cuenta.
✅ Esperado: el dron acaba aterrizado y desarmado sin que hagas nada. Apunta qué modo ves en la terminal A o en QGroundControl.

### 1.6 Terminal B — guardar el log de vuelo de PX4 (ULog)

```bash
cp $(ls -t /opt/PX4-Autopilot/build/px4_sitl_default/rootfs/log/*/*.ulg | head -2) /logs/
```

### 1.7 Cambio de ciudad (AR-019)

En la **terminal A**, para la simulación con **Ctrl+C** y arráncala con Donostia:

```bash
/scripts/start_sim.sh donostia 2>&1 | tee /logs/08_sim_donostia.log
```

✅ Esperado: la primera línea dice `Ciudad: donostia home: 43.3183, -1.9812, 10.0 m`.
En la terminal B, repite el vuelo:

```bash
ros2 launch drone_s1_demo s1_demo.launch.py 2>&1 | tee /logs/09_vuelo_donostia.log
```

Para la simulación con Ctrl+C en la terminal A cuando termine.

---

## Parte 2 · drop_guard en el mismo contenedor (opcional, 30 min)

Hazla solo si la parte 1 ha ido bien y te apetece. Todo en la **terminal A**, dentro del contenedor y con la simulación parada.

### 2.1 Aplicar el parche y compilar

```bash
cd /opt/PX4-Autopilot
git apply --check /px4_patches/drop_guard_px4_v1.17.0.patch && git apply /px4_patches/drop_guard_px4_v1.17.0.patch
make px4_sitl_default 2>&1 | tee /logs/10_build_drop_guard.log | tail -3
```

✅ Esperado: termina sin errores (`Linking CXX executable bin/px4`).

### 2.2 Tests unitarios dentro de PX4

```bash
make tests TESTFILTER=DropGuardLogic 2>&1 | tee /logs/11_tests_drop_guard.log | tail -15
```

✅ Esperado: `100% tests passed`. (Esto no lo pude ejecutar yo porque mi entorno bloquea una descarga que necesita PX4.)

### 2.3 Prueba de vuelo de drop_guard con SIH (sin Gazebo)

Cierra QGroundControl si lo tienes abierto (usa el mismo puerto). Terminal A:

```bash
make px4_sitl sihsim_quadx 2>&1 | tee /logs/12_sitl_sih.log
```

Terminal B:

```bash
python3 /px4_patches/sitl_drop_guard_test.py 2>&1 | tee /logs/13_test_drop_guard.log
```

✅ Esperado (unos 2 min): `6/6 casos pasan`.

---

## Parte 3 · Qué me devuelves

**3.1** En el PC, fuera del contenedor:

```bash
cd ~/drone/drone-sim
./scripts/collect_results.sh
```

Te dirá dónde ha dejado `drone_s1_resultados_<fecha>.tar.gz` (en tu carpeta personal). **Adjúntalo en el chat.**

**3.2** Y contéstame en una línea cada una:

1. ¿Cuánto tardó en construirse la imagen?
2. ¿Voló el dron en el paso 1.4 (sí / no / a medias)?
3. En el failsafe (1.5), ¿qué hizo PX4 y en qué modo acabó?
4. ¿Hiciste la parte 2? Si sí, ¿cuántos casos pasaron?
5. ¿Algo raro que no salga en los logs (el portátil se colgó, el ventilador a tope, mensajes en rojo que te llamaron la atención…)?

Con eso cierro el hito S1 o te digo exactamente qué corregir.

---

### Problemas típicos

| Síntoma | Qué hacer |
| --- | --- |
| `permission denied` al usar docker | No estás en el grupo docker: paso 0.2 y vuelve a iniciar sesión |
| `No space left on device` durante la construcción | Libera al menos 15 GB y repite 1.1 |
| El nodo se queda en `ARMING` y repite `Sin Offboard/armado; reintentando` | Deja que lo intente 30 s y luego Ctrl+C; queda en el log |
| No aparece ningún tópico `/fmu/...` en 1.3 | Mira si en la terminal A hay errores del agente o de `uxrce_dds_client`; queda en el log |
| La terminal A se llena de mensajes de Gazebo | Normal; no hace falta hacer nada |
