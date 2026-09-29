#!/usr/bin/env python3
"""Escenarios automáticos del hito S2 contra PX4 SITL + config_manager + mission_manager ya arrancados.

  python3 s2_scenarios.py sim01          # misión nominal completa (suelta simulada)
  python3 s2_scenarios.py sim19_pause    # el piloto pulsa Pausa en crucero (DO_REPOSITION al punto actual)
  python3 s2_scenarios.py sim19_rtl      # el piloto ordena RTL en crucero
  python3 s2_scenarios.py sim20          # igual que sim01; lanzar con la configuración de Donostia

Las acciones del piloto se envían por MAVLink (UDP 14550), como lo haría QGroundControl.
Sale con código 0 si el escenario pasa.
"""

import math
import sys
import threading
import time

import rclpy
from rclpy.executors import SingleThreadedExecutor
from drone_interfaces.msg import MissionState
from drone_interfaces.srv import MissionCommand
from pymavlink import mavutil
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy

M = mavutil.mavlink
NAMES = ['PREFLIGHT', 'ARMING', 'TAKEOFF', 'CRUISE', 'APPROACH', 'DROP', 'RETURN', 'CONTINGENCY', 'COMPLETED']
RESULTS = {0: 'NONE', 1: 'COMPLETED', 2: 'ABORTED', 3: 'CONTINGENCY'}


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


class Watcher(Node):
    def __init__(self):
        super().__init__('s2_scenarios')
        qos = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE, durability=DurabilityPolicy.TRANSIENT_LOCAL)
        self.state = None
        self.history = []
        self.create_subscription(MissionState, '/drone/mission/state', self.on_state, qos)
        self.cli = self.create_client(MissionCommand, '/mission_manager/command')

    def on_state(self, m):
        if self.state is None or m.state != self.state.state:
            self.history.append((time.time(), NAMES[m.state], m.cause))
            log(f'  estado: {NAMES[m.state]:12s} ({m.cause})')
        self.state = m

    def command(self, cmd):
        self.cli.wait_for_service(timeout_sec=10.0)
        fut = self.cli.call_async(MissionCommand.Request(command=cmd))
        end = time.time() + 10.0
        while not fut.done() and time.time() < end:
            time.sleep(0.05)
        return fut.result()


def wait_for(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.2)
    return False


def gcs_position(mav):
    m = mav.recv_match(type='GLOBAL_POSITION_INT', blocking=True, timeout=5)
    return (m.lat * 1e-7, m.lon * 1e-7, m.alt * 1e-3) if m else None


def distance_m(a, b):
    r = 6371000.0
    dp = math.radians(b[0] - a[0])
    dl = math.radians(b[1] - a[1])
    x = math.sin(dp / 2) ** 2 + math.cos(math.radians(a[0])) * math.cos(math.radians(b[0])) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(x))


def main():
    scenario = sys.argv[1] if len(sys.argv) > 1 else 'sim01'
    rclpy.init()
    w = Watcher()
    executor = SingleThreadedExecutor()
    executor.add_node(w)
    spinner = threading.Thread(target=executor.spin, daemon=True)
    spinner.start()

    mav = mavutil.mavlink_connection('udpin:127.0.0.1:14550', source_system=255)
    mav.wait_heartbeat(timeout=30)

    log(f'Escenario {scenario}: esperando PREFLIGHT listo para iniciar')
    if not wait_for(lambda: w.state is not None and w.state.ready_to_start, 60):
        log(f'FALLA: no está listo ({list(w.state.preflight_blockers) if w.state else "sin estado"})')
        return 1
    res = w.command(MissionCommand.Request.START)
    log(f'START: {res.accepted} ({res.message})')
    if not res.accepted:
        return 1

    ok = False
    detail = ''
    if scenario in ('sim01', 'sim20'):
        wait_for(lambda: w.state.state == 8, 1500)
        seq = [h[1] for h in w.history]
        expected = ['ARMING', 'TAKEOFF', 'CRUISE', 'APPROACH', 'DROP', 'RETURN', 'COMPLETED']
        ok = all(s in seq for s in expected) and w.state.result == 1
        detail = ' -> '.join(seq)

    elif scenario in ('sim19_pause', 'sim19_rtl'):
        if not wait_for(lambda: w.state.state == 3, 120):
            log('FALLA: no llegó a CRUISE')
            return 1
        time.sleep(8.0)
        pos = gcs_position(mav)
        if scenario == 'sim19_pause':
            log('Piloto: PAUSA (DO_REPOSITION al punto actual, como QGroundControl)')
            mav.mav.command_int_send(1, 1, M.MAV_FRAME_GLOBAL, M.MAV_CMD_DO_REPOSITION, 0, 0,
                                     -1, 1, 0, math.nan, int(pos[0] * 1e7), int(pos[1] * 1e7), pos[2])
        else:
            log('Piloto: RTL')
            mav.mav.command_long_send(1, 1, M.MAV_CMD_NAV_RETURN_TO_LAUNCH, 0, 0, 0, 0, 0, 0, 0, 0)
        t0 = time.time()
        got = wait_for(lambda: w.state.state == 7, 10)
        reaction = time.time() - t0
        held = True
        if got and scenario == 'sim19_pause':
            time.sleep(10.0)
            after = gcs_position(mav)
            moved = distance_m(pos, after)
            held = moved < 15.0
            log(f'Tras la pausa el dron se ha movido {moved:.1f} m en 10 s (el MSN no debe reanudar la misión)')
            log('Piloto: RTL para terminar')
            mav.mav.command_long_send(1, 1, M.MAV_CMD_NAV_RETURN_TO_LAUNCH, 0, 0, 0, 0, 0, 0, 0, 0)
        wait_for(lambda: w.state.state == 8, 600)
        ok = got and held and w.state.result == 3
        detail = f'CONTINGENCY en {reaction:.1f} s; resultado {RESULTS.get(w.state.result)}'

    print(f'\n{"PASA " if ok else "FALLA"} {scenario}: {detail}')
    executor.shutdown()
    spinner.join(timeout=2.0)
    w.destroy_node()
    rclpy.try_shutdown()
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
