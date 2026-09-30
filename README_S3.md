# Hito S3 — suelta real con confirmación del piloto

> El software (`drone_payload`, `drone_gcs_bridge` y la conexión de `mission_manager`) vive en el repo `drone-ros`; el módulo
> `drop_guard`, en el fork `drone-px4`. Aquí quedan los escenarios y su arnés.

Objetivo (DOC-10 §8): `payload_manager` y el módulo `drop_guard` del fork de PX4 con la confirmación del piloto desde tierra.
Habilita SIM-05, SIM-06 y SIM-07, y convierte SIM-01 en una misión con la suelta real.

## Cómo se suelta

```
mission_manager ──(acción DropPayload)──▶ payload_manager ──(DO_GRIPPER por DDS)──▶ drop_guard (PX4) ──▶ gripper
                                                ▲
pilot_confirm_bridge ◀── MAV_CMD_USER_1 ◀── tierra (QGroundControl)
```

1. En DROP, `mission_manager` pide la suelta cuando PX4 ya aceptó el Hold sobre la zona.
2. `payload_manager` espera la confirmación del piloto. `pilot_confirm_bridge` avisa a tierra por STATUSTEXT con el hash de la zona.
3. El piloto confirma con `COMMAND_LONG MAV_CMD_USER_1` (31010) al componente 191 del companion. `param1` y `param2` llevan el
   `DG_ZONE_HASH` de la zona anunciada (dos mitades de 16 bits), así una confirmación de otra misión no vale.
4. `payload_manager` comprueba zona, altura, carga y hash, y envía `DO_GRIPPER RELEASE` **una sola vez**. `drop_guard` vuelve a
   comprobar la zona por su cuenta y puede vetarla.
5. `payload_manager` verifica la liberación con el sensor de carga (simulado aquí, a partir de `drop_guard_status`).

## Escenarios

`scripts/run_s3.sh` lanza cada escenario con una simulación limpia (PX4 SITL con SIH, sin Gazebo) y los nodos que necesita:

| Escenario | DOC-10 | Qué comprueba |
| --- | --- | --- |
| `sim01_real` | SIM-01 | Misión completa con la suelta real: prevuelo bloqueado sin los `DG_*` cargados, confirmación fuera de tiempo rechazada, aviso al piloto con el hash, hash equivocado rechazado sin abrir, confirmación correcta, carga liberada y regreso |
| `sim05` | SIM-05 | Llegada a la zona sin confirmación: no suelta (sin ninguna apertura) y regresa con la carga al agotar el tiempo |
| `sim06` | SIM-06 | Orden de suelta forzada por ROS 2 (DDS) fuera del radio y bajo la banda de altura: la veta `drop_guard`; control positivo dentro de la zona |
| `sim07` | SIM-07 | Carga que no se libera (`sim_stuck`): `NOT_RELEASED` en menos de 3 s, aviso al piloto y regreso con la carga |
| `abort` | — | `ABORT` del operador mientras se espera la confirmación: regreso sin abrir |

```bash
source env_native.sh
./scripts/run_s3.sh                # todos
./scripts/run_s3.sh sim05 sim07    # solo estos
```

Deja los logs y el informe en `logs/s3_<fecha>/` y sale con código distinto de 0 si algún escenario falla. El `nightly` los ejecuta
todos tras `check_native.sh`.

- **Datos de prueba:** `tests/make_s3_data.py` parte de los `ops/` reales de `drone-ros` y solo mueve la zona de suelta a 150 m al
  norte del hub (y escribe una misión corta, `s3_short`), para que cada escenario dure minutos. No toca `ops/` ni `missions/`.
- **Parámetros de PX4:** PX4 SITL guarda sus parámetros entre arranques (`rootfs/parameters.bson`), incluidos los `DG_*`. El arnés
  los borra antes de cada escenario; si lanzas `s3_scenarios.py` a mano, hazlo tú.
- **Carga de `DG_*`:** en estos escenarios los carga el script por MAVLink antes de armar. En la operación real los cargará el MSN
  (SR-MSN-003, hito S4); `mission_manager` ya bloquea el inicio si `drop_guard` no tiene la zona de la misión.

## A mano

En cada terminal, `source env_native.sh`. Con los datos de prueba (`python3 tests/make_s3_data.py /tmp/s3` y `OPS_DIR`/`MISSIONS_DIR`
apuntando a ellos):

```bash
# Terminal A
sleep infinity | ./scripts/start_sim.sh toulouse          # sleep infinity: evita el spam de pxh> en el log

# Terminal B
ros2 launch drone_payload s3.launch.py city:=toulouse mission_id:=s3_short

# Terminal C
python3 scripts/s3_scenarios.py sim01_real "$OPS_DIR"
```

## Límites conocidos

- La confirmación llega por UDP sin firma MAVLink. Vale en simulación y en un enlace local; por LTE habrá que firmar los mensajes o
  usar una VPN.
- El sensor de carga es simulado. El microinterruptor real del companion sustituirá a esta entrada sin cambiar la máquina de estados.
- SIH no simula el servo del gripper: la apertura se verifica por `drop_guard_status` (`release_count`) y por los acks de
  `DO_GRIPPER`, no por el movimiento de un objeto (eso queda para `SIM=gz`).
