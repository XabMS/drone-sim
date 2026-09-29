#!/usr/bin/env bash
# Carga los entornos de ROS 2 y del workspace antes de ejecutar el comando.
set -e
source "/opt/ros/${ROS_DISTRO}/setup.bash"
if [ -f /ws/install/setup.bash ]; then
    source /ws/install/setup.bash
fi
exec "$@"
