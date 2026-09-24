# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Firmware development image for axoloty-embedded.
#
# Carries the pinned Swift toolchain and ESP-IDF, so the core, build, and
# broker tiers of Tools/verify.sh run without a host toolchain. Hardware
# tooling lives here, not in Core: phynics/axoloty's image carries only the
# host development tools.
#
# The image copies no repository source. The checkout is bind-mounted at
# /workspace (see devcontainer.json and docs/container-builds.md), and Core is
# fetched at the locked revision by Tools/prepare-core.sh into scratch space.
#
# An operator may instead provide ESP-IDF in their own environment: nothing in
# this repository requires this image, only the tools it installs.
ARG SWIFT_VERSION=6.4
ARG ESP_IDF_VERSION=v5.4
ARG ESPFLASH_VERSION=3.3.0
ARG NODE_VERSION=22.17.1
ARG CMAKE_VERSION=3.29.6
ARG CCACHE_VERSION=4.5.1-1

FROM swift:${SWIFT_VERSION}-jammy

ARG ESP_IDF_VERSION
ENV ESP_IDF_VERSION=${ESP_IDF_VERSION}
ARG ESPFLASH_VERSION
ARG NODE_VERSION
ARG CMAKE_VERSION

# ESP-IDF build prerequisites (ninja-build, python3, libusb), mosquitto for the
# managed-broker device harnesses, and CMake from pip because espressif/idf_swift
# requires CMake >= 3.29 and Ubuntu 22.04 ships 3.22. Some rootless Podman
# storage backends preserve a non-writable /tmp mode from the base image; apt
# needs it for its signed-repository configuration files.
RUN chmod 1777 /tmp \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        make \
        pkg-config \
        unzip \
        xz-utils \
        mosquitto \
        ninja-build \
        python3 \
        python3-pip \
        python3-venv \
        libusb-1.0-0-dev \
        libudev-dev \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir "cmake==${CMAKE_VERSION}"

# Node drives the repository's JavaScript validators, serial capture, and
# corpus generator. Jammy's Node 12 cannot parse their syntax.
RUN curl -fsSL -o /tmp/node.tar.xz \
        https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version

# Clone ESP-IDF at the pinned tag and materialize every submodule, so builds
# never download SDK dependencies at first use. `install.sh esp32c6` fetches
# only the RISC-V GCC toolchain, OpenOCD, and the Python environment for that
# target. The recursive checkout stays shallow and parallel: v5.4 has 23
# top-level submodules plus nested test dependencies.
ENV IDF_TOOLS_PATH=/opt/esp/tools
RUN git clone --depth 1 --filter=blob:none --branch ${ESP_IDF_VERSION} \
        https://github.com/espressif/esp-idf.git /opt/esp/idf \
    && cd /opt/esp/idf \
    && git submodule update --init --recursive --depth 1 --jobs 8 --recommend-shallow \
    && ./install.sh esp32c6 \
    && git config --system --add safe.directory /opt/esp/idf \
    && git config --system --add safe.directory /opt/esp/idf/components/openthread/openthread

# The ESP-IDF-supported compiler cache sits after the SDK layer, so a cache
# policy change never re-downloads the SDK, submodules, and compilers.
ARG CCACHE_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends "ccache=${CCACHE_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# espflash reads board information and flashes without the full IDF monitor.
RUN curl -fsSL -o /tmp/espflash.zip \
        https://github.com/esp-rs/espflash/releases/download/v${ESPFLASH_VERSION}/espflash-x86_64-unknown-linux-gnu.zip \
    && unzip -q -o /tmp/espflash.zip -d /tmp/espflash-extract \
    && install -m 0755 /tmp/espflash-extract/espflash /usr/local/bin/espflash \
    && rm -rf /tmp/espflash.zip /tmp/espflash-extract \
    && espflash --version

# Non-root user for device access. The dialout group owns /dev/ttyACM* on most
# Linux distributions.
RUN useradd --home-dir /tmp --no-create-home --shell /usr/sbin/nologin esp \
    && usermod -a -G dialout esp \
    && chown -R root:root "${IDF_TOOLS_PATH}" \
    && chmod -R a+rX "${IDF_TOOLS_PATH}"

ENV IDF_PATH=/opt/esp/idf
ENV PATH="${IDF_PATH}/tools:${PATH}"
# Tools/prepare-core.sh selects its container execution context from this.
ENV AXOLOTY_DEVCONTAINER=1

# Exercise the SDK as the non-root, no-home user the build runs as, so a
# HOME-dependent installation fails here rather than at the first build.
USER esp
RUN HOME=/tmp sh -c '. "${IDF_PATH}/export.sh" >/dev/null && idf.py --version'
USER root

WORKDIR /workspace
