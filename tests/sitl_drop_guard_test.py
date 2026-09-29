#!/usr/bin/env python3
"""Prueba de integración de drop_guard en PX4 SITL (simulador SIH, sin Gazebo).

Recorre los casos clave del diseño con el dron volando de verdad en simulación:
  A. Suelta pedida con el dron desarmado            -> DENIED, NOT_ARMED
  B. Suelta a 20 m sobre el centro de la zona        -> ACCEPTED
  C. Cambio de DG_LAT_E7 en vuelo y nueva suelta     -> ACCEPTED (zona capturada, cambio ignorado)
  D. Suelta a ~50 m del centro                       -> DENIED, OUTSIDE_RADIUS
  E. Orden de cierre                                 -> ACCEPTED
  F. Suelta a 8 m de altura sobre el centro          -> DENIED, BELOW_BAND

Uso: python3 tests/sitl_drop_guard_test.py [url]   (por defecto udpin:127.0.0.1:14550)
Sale con código 0 si todos los casos pasan.
"""

import math
import struct
import sys
import time

from pymavlink import mavutil

M = mavutil.mavlink
REASON = {0: 'OK', 1: 'DISABLED', 2: 'NOT_ARMED', 3: 'PARAMS_INVALID', 4: 'POS_STALE',
          5: 'POS_INVALID', 6: 'EPH_HIGH', 7: 'EPV_HIGH', 8: 'HOME_INVALID',
          9: 'OUTSIDE_RADIUS', 10: 'BELOW_BAND', 11: 'ABOVE_BAND'}
RESULT = {M.MAV_RESULT_ACCEPTED: 'ACCEPTED', M.MAV_RESULT_DENIED: 'DENIED'}

results = []


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


def wait_msg(mav, mtype, timeout=10.0, cond=None):
    end = time.time() + timeout
    while time.time() < end:
        m = mav.recv_match(type=mtype, blocking=True, timeout=max(0.1, end - time.time()))
        if m is not None and (cond is None or cond(m)):
            return m
    return None


def command_long(mav, cmd, p1=0, p2=0, p3=0, p4=0, p5=0, p6=0, p7=0):
    mav.mav.command_long_send(mav.target_system, mav.target_component, cmd, 0, p1, p2, p3, p4, p5, p6, p7)
    return wait_msg(mav, 'COMMAND_ACK', 5.0, lambda a: a.command == cmd)


def set_param(mav, name, value, is_int):
    if is_int:
        raw = struct.unpack('<f', struct.pack('<i', int(value)))[0]  # codificación bytewise de PX4
        ptype = M.MAV_PARAM_TYPE_INT32
    else:
        raw = float(value)
        ptype = M.MAV_PARAM_TYPE_REAL32
    for _ in range(3):
        mav.mav.param_set_send(mav.target_system, mav.target_component, name.encode(), raw, ptype)
        ack = wait_msg(mav, 'PARAM_VALUE', 3.0, lambda m: m.param_id == name)
        if ack is not None:
            got = struct.unpack('<i', struct.pack('<f', ack.param_value))[0] if is_int else ack.param_value
            if (is_int and got == int(value)) or (not is_int and abs(got - value) < 1e-3):
                return True
    raise RuntimeError(f'no se pudo fijar {name}')


def check_release(mav, case, expected_result, expected_reason=None):
    ack = command_long(mav, M.MAV_CMD_DO_GRIPPER, 1, M.GRIPPER_ACTION_RELEASE)
    if ack is None:
        results.append((case, False, 'sin COMMAND_ACK'))
        log(f'{case}: FALLA (sin respuesta)')
        return
    reason = getattr(ack, 'result_param2', None)
    ok = (ack.result == expected_result) and (expected_reason is None or reason == expected_reason)
    detail = f'{RESULT.get(ack.result, ack.result)}, motivo {REASON.get(reason, reason)}'
    results.append((case, ok, detail))
    log(f'{case}: {"PASA" if ok else "FALLA"} ({detail})')


def goto(mav, lat, lon, alt_amsl, home_alt, target_rel, tol=1.0, timeout=60):
    mav.mav.command_int_send(mav.target_system, mav.target_component, M.MAV_FRAME_GLOBAL, M.MAV_CMD_DO_REPOSITION,
                             0, 0, -1, 1, 0, math.nan, int(lat * 1e7), int(lon * 1e7), alt_amsl)
    end = time.time() + timeout
    while time.time() < end:
        g = wait_msg(mav, 'GLOBAL_POSITION_INT', 2.0)
        if g is None:
            continue
        d = haversine(lat, lon, g.lat * 1e-7, g.lon * 1e-7)
        rel = g.relative_alt / 1000.0
        if d < tol and abs(rel - target_rel) < tol:
            time.sleep(2.0)  # estabilizar
            return True
    return False


def haversine(lat0, lon0, lat1, lon1):
    r = 6371000.0
    p0, p1 = math.radians(lat0), math.radians(lat1)
    dp, dl = p1 - p0, math.radians(lon1 - lon0)
    a = math.sin(dp / 2) ** 2 + math.cos(p0) * math.cos(p1) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else 'udpin:127.0.0.1:14550'
    mav = mavutil.mavlink_connection(url, source_system=255)
    log(f'esperando latido en {url}')
    mav.wait_heartbeat(timeout=60)
    log(f'conectado al sistema {mav.target_system}')

    # Esperar una posición global con home válido
    home = None
    for _ in range(60):
        command_long(mav, M.MAV_CMD_REQUEST_MESSAGE, M.MAVLINK_MSG_ID_HOME_POSITION)
        home = wait_msg(mav, 'HOME_POSITION', 2.0)
        if home is not None:
            break
    if home is None:
        log('sin HOME_POSITION: EKF no listo')
        return 2
    hlat, hlon, halt = home.latitude * 1e-7, home.longitude * 1e-7, home.altitude * 1e-3
    log(f'home: {hlat:.7f}, {hlon:.7f}, {halt:.1f} m')

    # Zona de suelta centrada en home, banda de 15 a 30 m, radio 10 m
    set_param(mav, 'DG_ENABLE', 1, True)
    set_param(mav, 'DG_LAT_E7', home.latitude, True)
    set_param(mav, 'DG_LON_E7', home.longitude, True)
    set_param(mav, 'DG_RADIUS', 10.0, False)
    set_param(mav, 'DG_ALT_MIN', 15.0, False)
    set_param(mav, 'DG_ALT_MAX', 30.0, False)
    set_param(mav, 'DG_ZONE_HASH', 4242, True)
    set_param(mav, 'MIS_TAKEOFF_ALT', 20.0, False)
    log('parámetros DG_* fijados')

    check_release(mav, 'A desarmado', M.MAV_RESULT_DENIED, 2)

    # Armar y despegar
    for _ in range(20):
        ack = command_long(mav, M.MAV_CMD_COMPONENT_ARM_DISARM, 1)
        if ack is not None and ack.result == M.MAV_RESULT_ACCEPTED:
            break
        time.sleep(2)
    command_long(mav, M.MAV_CMD_NAV_TAKEOFF, 0, 0, 0, math.nan, math.nan, math.nan, math.nan)
    log('despegando a 20 m')
    if not goto(mav, hlat, hlon, halt + 20.0, halt, 20.0, tol=1.5, timeout=90):
        log('no alcanzó 20 m')
        return 2

    check_release(mav, 'B en zona a 20 m', M.MAV_RESULT_ACCEPTED, 0)

    # Mover la zona 111 m al norte con el dron armado: debe ignorarse
    set_param(mav, 'DG_LAT_E7', home.latitude + 10000, True)
    check_release(mav, 'C zona movida en vuelo (ignorado)', M.MAV_RESULT_ACCEPTED, 0)

    # Alejarse ~50 m al norte
    lat50 = hlat + (50.0 / 6371000.0) * 180.0 / math.pi
    if goto(mav, lat50, hlon, halt + 20.0, halt, 20.0, tol=2.0, timeout=90):
        check_release(mav, 'D a 50 m del centro', M.MAV_RESULT_DENIED, 9)
    else:
        results.append(('D a 50 m del centro', False, 'no llegó a la posición'))

    ack = command_long(mav, M.MAV_CMD_DO_GRIPPER, 1, M.GRIPPER_ACTION_GRAB)
    ok = ack is not None and ack.result == M.MAV_RESULT_ACCEPTED
    results.append(('E cierre', ok, RESULT.get(ack.result, ack.result) if ack else 'sin respuesta'))
    log(f'E cierre: {"PASA" if ok else "FALLA"}')

    # Volver al centro pero a 8 m: por debajo de la banda
    if goto(mav, hlat, hlon, halt + 8.0, halt, 8.0, tol=1.5, timeout=90):
        check_release(mav, 'F en zona a 8 m', M.MAV_RESULT_DENIED, 10)
    else:
        results.append(('F en zona a 8 m', False, 'no llegó a la posición'))

    command_long(mav, M.MAV_CMD_NAV_LAND)
    log('aterrizando')
    wait_msg(mav, 'HEARTBEAT', 90.0, lambda h: not (h.base_mode & M.MAV_MODE_FLAG_SAFETY_ARMED))

    print('\nRESUMEN')
    for case, ok, detail in results:
        print(f'  {"PASA " if ok else "FALLA"}  {case:38s} {detail}')
    passed = sum(1 for _, ok, _ in results if ok)
    print(f'{passed}/{len(results)} casos pasan')
    return 0 if passed == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
