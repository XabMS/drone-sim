# drone-sim — imagen de simulación (DOC-10, hito S1)
# Ubuntu 24.04 + ROS 2 Jazzy + Gazebo Harmonic + PX4 SITL + Micro XRCE-DDS Agent + px4_msgs
#
# Versiones fijadas por ARG (Plan de gestión de configuración, §5).
# Antes de congelar la baseline, comprobar la última release estable de PX4
# y usar la rama de px4_msgs que le corresponde.

FROM osrf/ros:jazzy-desktop

ARG PX4_TAG=v1.17.0
ARG PX4_MSGS_BRANCH=release/1.17
ARG XRCE_AGENT_TAG=v2.4.3

ENV DEBIAN_FRONTEND=noninteractive \
    ROS_DISTRO=jazzy \
    PX4_DIR=/opt/PX4-Autopilot

# --- Utilidades básicas -------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo git curl wget lsb-release gnupg ca-certificates \
        python3-pip python3-yaml python3-colcon-common-extensions \
        iproute2 iputils-ping nano mesa-utils \
        libyaml-cpp-dev nlohmann-json3-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Gazebo Harmonic (pareja oficial de ROS 2 Jazzy) --------------------------
RUN curl -sSL https://packages.osrfoundation.org/gazebo.gpg \
        -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/gazebo-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        gz-harmonic ros-jazzy-ros-gz \
    && rm -rf /var/lib/apt/lists/*

# --- PX4-Autopilot (solo SITL, sin toolchain NuttX) ----------------------------
RUN git clone --recursive --shallow-submodules --depth 1 --branch ${PX4_TAG} \
        https://github.com/PX4/PX4-Autopilot.git ${PX4_DIR} \
    && bash ${PX4_DIR}/Tools/setup/ubuntu.sh --no-nuttx \
    && rm -rf /var/lib/apt/lists/*

# Compilación previa de SITL para que el primer arranque sea rápido
RUN cd ${PX4_DIR} && make px4_sitl

# --- Micro XRCE-DDS Agent (puente uORB <-> ROS 2) ------------------------------
RUN git clone --depth 1 --branch ${XRCE_AGENT_TAG} \
        https://github.com/eProsima/Micro-XRCE-DDS-Agent.git /tmp/xrce-agent \
    && cmake -S /tmp/xrce-agent -B /tmp/xrce-agent/build \
    && cmake --build /tmp/xrce-agent/build -j"$(nproc)" \
    && cmake --install /tmp/xrce-agent/build \
    && ldconfig \
    && rm -rf /tmp/xrce-agent

# --- Workspace ROS 2 con px4_msgs precompilado ---------------------------------
# Los paquetes propios se montan en /ws/src/drone al arrancar el contenedor.
RUN mkdir -p /ws/src \
    && git clone --depth 1 --branch ${PX4_MSGS_BRANCH} \
        https://github.com/PX4/px4_msgs.git /ws/src/px4_msgs \
    && bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash && cd /ws && colcon build --packages-select px4_msgs"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /ws
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
