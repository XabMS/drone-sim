#!/usr/bin/env python3
"""Genera los datos de los escenarios S3: Toulouse con la zona de suelta a 150 m al norte del hub y una misión corta.

    python3 tests/make_s3_data.py SALIDA [OPS_DIR]      # OPS_DIR por defecto: $OPS_DIR (env_native.sh)

Escribe SALIDA/ops/toulouse.{yaml,geojson} y SALIDA/missions/s3_short.yaml. Parte de los ops/ reales de drone-ros y solo
mueve la zona de suelta: así los escenarios duran minutos y no se duplica ningún dato CC1. Estos ficheros son de prueba:
no se versionan y no sustituyen a ops/ ni missions/ de drone-ros.
"""

import json
import os
import shutil
import sys

import yaml

CITY = 'toulouse'
ZONE_ID = 'tls_dz_01'
ZONE_NORTH_M = 150.0       # zona de suelta respecto al hub
WAYPOINT_NORTH_M = 130.0   # waypoint de crucero, justo antes de la zona
CRUISE_ALT_M = 40.0
M_PER_DEG_LAT = 111194.9   # 2 * pi * R / 360 con R = 6371000 m


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    ops_dir = sys.argv[2] if len(sys.argv) > 2 else os.environ.get('OPS_DIR', '')
    if not os.path.isfile(os.path.join(ops_dir, f'{CITY}.yaml')):
        print(f'No encuentro {ops_dir}/{CITY}.yaml: haz antes source env_native.sh o pasa OPS_DIR', file=sys.stderr)
        return 1

    os.makedirs(os.path.join(out, 'ops'), exist_ok=True)
    os.makedirs(os.path.join(out, 'missions'), exist_ok=True)
    shutil.copy(os.path.join(ops_dir, f'{CITY}.yaml'), os.path.join(out, 'ops', f'{CITY}.yaml'))

    ops = yaml.safe_load(open(os.path.join(ops_dir, f'{CITY}.yaml')))
    hub = ops['hub']
    geojson_name = ops['geojson']
    gj = json.load(open(os.path.join(ops_dir, geojson_name)))
    moved = False
    for feature in gj['features']:
        if feature['properties'].get('role') == 'drop_zone' and feature['properties'].get('id') == ZONE_ID:
            feature['geometry']['coordinates'] = [hub['lon'], hub['lat'] + ZONE_NORTH_M / M_PER_DEG_LAT]
            moved = True
    if not moved:
        print(f'No hay zona {ZONE_ID} en {geojson_name}', file=sys.stderr)
        return 1
    with open(os.path.join(out, 'ops', geojson_name), 'w') as f:
        json.dump(gj, f, indent=1)

    mission = {
        'id': 's3_short', 'city': CITY, 'drop_zone': ZONE_ID, 'cruise_alt_m': CRUISE_ALT_M, 'payload_kg': 1.0,
        'route': [{'lat': round(hub['lat'] + WAYPOINT_NORTH_M / M_PER_DEG_LAT, 7), 'lon': hub['lon']}],
    }
    with open(os.path.join(out, 'missions', 's3_short.yaml'), 'w') as f:
        yaml.safe_dump(mission, f, sort_keys=False)
    print(f'Datos S3 en {out}: zona {ZONE_ID} a {ZONE_NORTH_M:.0f} m al norte del hub, misión s3_short')
    return 0


if __name__ == '__main__':
    sys.exit(main())
