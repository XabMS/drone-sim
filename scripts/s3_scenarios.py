#!/usr/bin/env python3
"""Escenarios automáticos del hito S3 (suelta real) contra PX4 SITL + los nodos de drone-ros ya arrancados.

  python3 s3_scenarios.py sim01_real OPS_DIR   # misión completa con la suelta real y la confirmación por MAVLink
  python3 s3_scenarios.py sim05 OPS_DIR        # llegada a la zona sin confirmación del piloto: no suelta y regresa
  python3 s3_scenarios.py sim07 OPS_DIR        # carga que no se libera: aviso y regreso con la carga
  python3 s3_scenarios.py abort OPS_DIR        # ABORT del operador mientras se espera la confirmación
  python3 s3_scenarios.py sim06 OPS_DIR        # orden de suelta forzada por ROS 2 fuera de la zona: la veta drop_guard

OPS_DIR es el directorio con los datos de prueba (tests/make_s3_data.py). Normalmente se lanzan con scripts/run_s3.sh,
que arranca la simulación y los nodos de cada escenario. Sale con código 0 si el escenario pasa.

La confirmación del piloto se envía como lo haría QGroundControl: COMMAND_LONG MAV_CMD_USER_1 al componente 191 por el enlace
de PX4 a 14550, con el DG_ZONE_HASH de la zona en param1/param2 (DOC-06 §4).
"""

import json
import math
import os
import sys
import threading
import time
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tests'))
import sitl_drop_guard_test as T  # noqa: E402  (ayudas MAVLink: set_param, goto, command_long...)

import rclpy  # noqa: E402
from drone_interfaces.msg import MissionState  # noqa: E402
from drone_interfaces.srv import MissionCommand  # noqa: E402
from px4_msgs.msg import DropGuardStatus, VehicleCommand, VehicleCommandAck  # noqa: E402
from rcl_interfaces.msg import Parameter, ParameterType, ParameterValue  # noqa: E402
from rcl_interfaces.srv import SetParameters  # noqa: E402
from rclpy.executors import SingleThreadedExecutor  # noqa: E402
from rclpy.node import Node  # noqa: E402
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy  # noqa: E402

M = T.mavutil.mavlink
MAV_CMD_USER_1 = 31010
COMPONENT_COMPANION = 191
STATE_NAMES = ['PREFLIGHT', 'ARMING', 'TAKEOFF', 'CRUISE', 'APPROACH', 'DROP', 'RETURN', 'CONTINGENCY', 'COMPLETED']
M_PER_DEG_LAT = 111194.9
REASON_OUTSIDE_RADIUS = 9   # drop_guard::Reason
REASON_BELOW_BAND = 10
log = T.log
results = []


def check(name, ok, detail=''):
    results.append((name, ok, detail))
    log(f'{name}: {"PASA" if ok else "FALLA"} {detail}')


def finish(scenario):
    print(f'\nRESUMEN {scenario}')
    for name, ok, detail in results:
        print(f'  {"PASA " if ok else "FALLA"}  {name:54s} {detail}')
    passed = sum(1 for _, ok, _ in results if ok)
    print(f'{passed}/{len(results)} pasan')
    sys.stdout.flush()
    os._exit(0 if results and passed == len(results) else 1)   # os._exit: evita el abort de rclpy con hilos vivos


def load_zone(ops_dir):
    """Zona de suelta del GeoJSON de prueba y su DG_ZONE_HASH (mismo cálculo que drone_core::drop_zone_hash)."""
    features = json.load(open(os.path.join(ops_dir, 'toulouse.geojson')))['features']
    feat = [f for f in features if f['properties'].get('role') == 'drop_zone'][0]
    lon, lat = feat['geometry']['coordinates']
    p = feat['properties']
    z = {'id': p['id'], 'lat': lat, 'lon': lon, 'radius': float(p['radius_m']),
         'alt_min': float(p['drop_alt_min_m']), 'alt_max': float(p['drop_alt_max_m'])}
    canon = f"{z['id']}|{lat:.7f}|{lon:.7f}|{z['radius']:.7f}|{z['alt_min']:.7f}|{z['alt_max']:.7f}"
    h = zlib.crc32(canon.encode())
    z['hash'] = h - (1 << 32) if h >= (1 << 31) else h
    return z


def confirm_params(zone_hash):
    """param1 y param2 de MAV_CMD_USER_1: el hash (uint32) partido en dos mitades de 16 bits."""
    u = zone_hash & 0xFFFFFFFF
    return float(u & 0xFFFF), float(u >> 16)


class Ros(Node):
    def __init__(self):
        super().__init__('s3_scenarios')
        self.state = None
        self.history = []
        self.dg = None
        self.acks = []
        reliable = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE, durability=DurabilityPolicy.TRANSIENT_LOCAL)
        px4 = QoSProfile(depth=10, reliability=ReliabilityPolicy.BEST_EFFORT, durability=DurabilityPolicy.TRANSIENT_LOCAL)
        self.create_subscription(MissionState, '/drone/mission/state', self.on_state, reliable)
        self.create_subscription(DropGuardStatus, '/fmu/out/drop_guard_status', lambda m: setattr(self, 'dg', m), px4)
        self.create_subscription(VehicleCommandAck, '/fmu/out/vehicle_command_ack', self.on_ack, px4)
        self.cmd_pub = self.create_publisher(VehicleCommand, '/fmu/in/vehicle_command', px4)
        self.mission_cmd = self.create_client(MissionCommand, '/mission_manager/command')
        self.payload_params = self.create_client(SetParameters, '/payload_manager/set_parameters')

    def on_state(self, m):
        if self.state is None or m.state != self.state.state:
            self.history.append((STATE_NAMES[m.state], m.cause))
            log(f'  estado: {STATE_NAMES[m.state]:12s} ({m.cause})')
        self.state = m

    def on_ack(self, m):
        if m.command == VehicleCommand.VEHICLE_CMD_DO_GRIPPER:
            self.acks.append((m.result, m.result_param2))

    def call(self, client, request, timeout=10.0):
        client.wait_for_service(timeout_sec=10.0)
        fut = client.call_async(request)
        end = time.time() + timeout
        while not fut.done() and time.time() < end:
            time.sleep(0.05)
        return fut.result()

    def wait(self, pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return True
            time.sleep(0.2)
        return False

    def set_sim_stuck(self, value):
        p = Parameter(name='sim_stuck', value=ParameterValue(type=ParameterType.PARAMETER_BOOL, bool_value=value))
        return self.call(self.payload_params, SetParameters.Request(parameters=[p]))

    def force_release(self):
        """DO_GRIPPER RELEASE por DDS, como lo enviaría un nodo ROS 2 (defectuoso o comprometido): drop_guard decide."""
        c = VehicleCommand()
        c.command = VehicleCommand.VEHICLE_CMD_DO_GRIPPER
        c.param1 = 0.0
        c.param2 = float(VehicleCommand.GRIPPER_ACTION_RELEASE)
        c.target_system = 1
        c.target_component = 1
        c.source_system = 1
        c.source_component = COMPONENT_COMPANION
        c.from_external = True
        c.timestamp = int(self.get_clock().now().nanoseconds / 1000)
        self.cmd_pub.publish(c)


class Gcs:
    """Tierra: lee en segundo plano lo que el companion (componente 191) envía por el enlace de PX4."""

    def __init__(self, mav):
        self.mav = mav
        self.lock = threading.Lock()
        self.texts = []
        self.acks = []
        self.beats = 0

    def run(self):
        while True:
            with self.lock:
                m = self.mav.recv_match(blocking=False)
            if m is None:
                time.sleep(0.01)
                continue
            kind = m.get_type()
            if kind == 'STATUSTEXT' and m.text.startswith(('SUELTA', 'RECHAZO')):
                self.texts.append(m.text)
                log(f'  tierra recibe STATUSTEXT: {m.text}')
            elif kind == 'COMMAND_ACK' and m.command == MAV_CMD_USER_1:
                self.acks.append((m.result, m.get_srcComponent()))
            elif kind == 'HEARTBEAT' and m.get_srcComponent() == COMPONENT_COMPANION:
                self.beats += 1

    def send_confirmation(self, p1, p2):
        with self.lock:
            self.mav.mav.command_long_send(1, COMPONENT_COMPANION, MAV_CMD_USER_1, 0, p1, p2, 0, 0, 0, 0, 0)


def connect():
    rclpy.init()
    node = Ros()
    executor = SingleThreadedExecutor()
    executor.add_node(node)
    threading.Thread(target=executor.spin, daemon=True).start()
    mav = T.mavutil.mavlink_connection('udpin:127.0.0.1:14550', source_system=255, source_component=190)
    mav.wait_heartbeat(timeout=60)
    return node, mav


def load_dg_params(mav, lock, z, takeoff_alt=None):
    """Carga en PX4 la zona de la misión (en la operación real lo hará el MSN por MAVLink; SR-MSN-003, S4)."""
    params = [('DG_ENABLE', 1, True), ('DG_LAT_E7', round(z['lat'] * 1e7), True), ('DG_LON_E7', round(z['lon'] * 1e7), True),
              ('DG_RADIUS', z['radius'], False), ('DG_ALT_MIN', z['alt_min'], False), ('DG_ALT_MAX', z['alt_max'], False),
              ('DG_ZONE_HASH', z['hash'], True)]
    if takeoff_alt is not None:
        params.append(('MIS_TAKEOFF_ALT', takeoff_alt, False))
    for name, value, is_int in params:
        with lock:
            T.set_param(mav, name, value, is_int)


# ----------------------------------------------------------------------------- misión completa

def run_mission(scenario, ops_dir):
    z = load_zone(ops_dir)
    node, mav = connect()
    gcs = Gcs(mav)
    threading.Thread(target=gcs.run, daemon=True).start()

    log(f'escenario {scenario}: esperando PREFLIGHT')
    if not node.wait(lambda: node.state is not None and node.state.state == 0, 60):
        check('estado PREFLIGHT', False)
        finish(scenario)
    # Sin los DG_* de la misión cargados en PX4, el prevuelo debe bloquear el inicio (run_s3.sh parte de parámetros limpios)
    node.wait(lambda: any('drop_guard' in b for b in node.state.preflight_blockers), 20)
    check('prevuelo bloqueado sin los DG_* de la misión',
          (not node.state.ready_to_start) and any('drop_guard' in b for b in node.state.preflight_blockers),
          str(list(node.state.preflight_blockers)))
    load_dg_params(mav, gcs.lock, z)
    ready = node.wait(lambda: node.state.ready_to_start, 30)
    check('prevuelo listo con los DG_* cargados', ready, str(list(node.state.preflight_blockers)))
    check('latido del companion (componente 191) visto en tierra', node.wait(lambda: gcs.beats > 0, 10))
    if not ready:
        finish(scenario)

    if scenario == 'sim07':
        node.set_sim_stuck(True)
    res = node.call(node.mission_cmd, MissionCommand.Request(command=MissionCommand.Request.START))
    check('START aceptado', bool(res and res.accepted), res.message if res else '')

    p1, p2 = confirm_params(z['hash'])
    if scenario == 'sim01_real':
        # Una confirmación fuera de tiempo (en crucero) no vale ni se guarda para después
        node.wait(lambda: node.state.state == 3, 120)
        gcs.send_confirmation(p1, p2)
        check('confirmación en crucero rechazada (ACK DENIED)', node.wait(lambda: any(a[0] == 2 for a in gcs.acks), 5),
              str(gcs.acks))

    if not node.wait(lambda: node.state.state == 5, 400):
        check('llegó a DROP', False, STATE_NAMES[node.state.state])
        finish(scenario)
    check('llegó a DROP', True)
    unsigned = z['hash'] & 0xFFFFFFFF
    check('aviso al piloto con el hash de la zona', node.wait(lambda: any(f'{unsigned:08X}' in t for t in gcs.texts), 10),
          str(gcs.texts))

    if scenario in ('sim01_real', 'sim07'):
        acks_before = len(gcs.acks)
        if scenario == 'sim01_real':
            bp1, bp2 = confirm_params(z['hash'] + 1)   # hash equivocado: se rechaza y la suelta sigue esperando
            gcs.send_confirmation(bp1, bp2)
            check('hash equivocado rechazado (ACK DENIED)',
                  node.wait(lambda: len(gcs.acks) > acks_before and gcs.acks[-1][0] == 2, 5), str(gcs.acks[acks_before:]))
            time.sleep(1.0)
            check('la suelta sigue esperando, sin apertura', node.state.state == 5 and node.dg.release_count == 0,
                  f'release_count={node.dg.release_count}')
            acks_before = len(gcs.acks)
        gcs.send_confirmation(p1, p2)
        check('confirmación correcta aceptada (ACK ACCEPTED)',
              node.wait(lambda: len(gcs.acks) > acks_before and gcs.acks[-1][0] == 0, 5), str(gcs.acks[acks_before:]))
    elif scenario == 'abort':
        time.sleep(3)
        r = node.call(node.mission_cmd, MissionCommand.Request(command=MissionCommand.Request.ABORT))
        check('ABORT aceptado en DROP', bool(r and r.accepted), r.message if r else '')

    check('misión terminada (COMPLETED)', node.wait(lambda: node.state.state == 8, 400), STATE_NAMES[node.state.state])
    causes = {s: c for s, c in node.history}
    drop_result = node.state.drop_result
    release_count = node.dg.release_count if node.dg else -1
    if scenario == 'sim01_real':
        check('RETURN por carga liberada', causes.get('RETURN') == 'carga liberada en la zona de suelta', causes.get('RETURN'))
        check('drop_result RELEASED y misión COMPLETED', drop_result == 1 and node.state.result == 1,
              f'drop_result={drop_result} result={node.state.result}')
        check('drop_guard autorizó una apertura', release_count == 1, f'release_count={release_count}')
        check('resultado avisado al piloto', any('CARGA LIBERADA' in t for t in gcs.texts), str(gcs.texts[-1:]))
    elif scenario == 'sim05':
        check('RETURN por falta de confirmación', 'no confirmó' in causes.get('RETURN', ''), causes.get('RETURN'))
        check('drop_result TIMEOUT y misión COMPLETED', drop_result == 3 and node.state.result == 1,
              f'drop_result={drop_result} result={node.state.result}')
        check('sin ninguna apertura', release_count == 0, f'release_count={release_count}')
    elif scenario == 'sim07':
        check('RETURN con la carga', 'no se liberó' in causes.get('RETURN', ''), causes.get('RETURN'))
        check('drop_result NOT_RELEASED', drop_result == 4, f'drop_result={drop_result}')
        check('resultado avisado al piloto', any('CARGA NO LIBERADA' in t for t in gcs.texts), str(gcs.texts[-1:]))
    elif scenario == 'abort':
        check('RETURN por aborto', causes.get('RETURN') == 'abortado por el operador', causes.get('RETURN'))
        check('misión ABORTED y sin apertura', node.state.result == 2 and release_count == 0,
              f'result={node.state.result} release_count={release_count}')
    finish(scenario)


# ----------------------------------------------------------------------------- SIM-06

def run_sim06(ops_dir):
    """Una orden de suelta fuera del volumen de suelta la veta drop_guard aunque la mande ROS 2 (AR-008, FC-05)."""
    z = load_zone(ops_dir)
    node, mav = connect()
    lock = threading.Lock()
    home = None
    for _ in range(60):
        T.command_long(mav, M.MAV_CMD_REQUEST_MESSAGE, M.MAVLINK_MSG_ID_HOME_POSITION)
        home = T.wait_msg(mav, 'HOME_POSITION', 2.0)
        if home is not None:
            break
    if home is None:
        check('HOME_POSITION recibido', False)
        finish('sim06')
    hlat, hlon, halt = home.latitude * 1e-7, home.longitude * 1e-7, home.altitude * 1e-3
    load_dg_params(mav, lock, z, takeoff_alt=20.0)
    node.wait(lambda: node.dg is not None, 10)

    for _ in range(20):
        ack = T.command_long(mav, M.MAV_CMD_COMPONENT_ARM_DISARM, 1)
        if ack is not None and ack.result == M.MAV_RESULT_ACCEPTED:
            break
        time.sleep(2)
    T.command_long(mav, M.MAV_CMD_NAV_TAKEOFF, 0, 0, 0, math.nan, math.nan, math.nan, math.nan)
    if not T.goto(mav, hlat, hlon, halt + 22.0, halt, 22.0, tol=1.5, timeout=90):
        check('despegue a 22 m sobre el hub', False)
        finish('sim06')

    def try_release(name, expected_result, expected_reason):
        node.acks.clear()
        denied_before, released_before = node.dg.deny_count, node.dg.release_count
        node.force_release()
        got = node.wait(lambda: len(node.acks) > 0, 5)
        result, reason = node.acks[0] if node.acks else (None, None)
        ok = got and result == expected_result and (expected_reason is None or reason == expected_reason)
        check(name, ok, f'ack={"ACCEPTED" if result == 0 else "DENIED" if result == 2 else result} motivo={reason}')
        time.sleep(0.6)
        return denied_before, released_before

    # A: sobre el hub, a 150 m del centro de la zona, y con el radio en 10 m: fuera del radio
    d0, r0 = try_release('A orden por ROS 2 fuera del radio -> DENIED', 2, REASON_OUTSIDE_RADIUS)
    check('A drop_guard no autorizó ninguna apertura', node.dg.release_count == r0 and node.dg.deny_count == d0 + 1,
          f'release_count={node.dg.release_count} deny_count={node.dg.deny_count}')

    # B: sobre el centro de la zona pero por debajo de la banda de altura
    if T.goto(mav, z['lat'], z['lon'], halt + 8.0, halt, 8.0, tol=1.5, timeout=120):
        d0, r0 = try_release('B sobre la zona, bajo la banda -> DENIED', 2, REASON_BELOW_BAND)
        check('B drop_guard no autorizó ninguna apertura', node.dg.release_count == r0, f'release_count={node.dg.release_count}')
    else:
        check('B llegar al centro de la zona a 8 m', False)

    # C (control positivo): dentro de la zona y de la banda, la misma vía DDS sí abre
    if T.goto(mav, z['lat'], z['lon'], halt + 22.0, halt, 22.0, tol=1.5, timeout=60):
        d0, r0 = try_release('C dentro de la zona y de la banda -> ACCEPTED', 0, None)
        check('C drop_guard autorizó una apertura', node.dg.release_count == r0 + 1, f'release_count={node.dg.release_count}')
    else:
        check('C subir a 22 m sobre la zona', False)

    T.command_long(mav, M.MAV_CMD_NAV_LAND)
    T.wait_msg(mav, 'HEARTBEAT', 90.0, lambda hb: not (hb.base_mode & M.MAV_MODE_FLAG_SAFETY_ARMED))
    finish('sim06')


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('sim01_real', 'sim05', 'sim06', 'sim07', 'abort'):
        print(__doc__)
        return 2
    scenario, ops_dir = sys.argv[1], sys.argv[2]
    if scenario == 'sim06':
        run_sim06(ops_dir)
    else:
        run_mission(scenario, ops_dir)
    return 1


if __name__ == '__main__':
    sys.exit(main())
