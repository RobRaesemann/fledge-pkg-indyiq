# fledge-buildenv: build environment for compiling IndyIQ C++ Fledge plugins.
#
# Provides:
#   * a C++ toolchain, cmake, dpkg-dev
#   * Fledge source at $FLEDGE_ROOT, with its C libraries pre-built
#     (cmake_build/C/lib/*.so — common-lib, services-common-lib,
#     filters-common-lib, etc.) so plugins that link against Fledge
#     (via FindFledge.cmake, e.g. fledge-south-s2opcua needing common-lib)
#     don't need to compile Fledge itself on every plugin CI run.
#   * libplctag prebuilt into /usr/local (so plugin builds run make_deb with -s)
#
# Building Fledge's C tree is a one-time cost paid only when this image itself
# is rebuilt (Dockerfile change / weekly / manual) — never per plugin build.
#
# Build:
#   docker build -t ghcr.io/robraesemann/fledge-buildenv:latest \
#     --build-arg FLEDGE_BRANCH=v3.1.0 docker/fledge-buildenv
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG FLEDGE_REPO=https://github.com/fledge-iot/fledge.git
ARG FLEDGE_BRANCH=v3.1.0
ARG LIBPLCTAG_VERSION=2.6.15

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        sudo \
        dpkg-dev \
        pkg-config \
        libssl-dev \
        uuid-dev \
        rapidjson-dev \
        ca-certificates \
        wget \
        autoconf \
        automake \
        libtool \
    && rm -rf /var/lib/apt/lists/*

# Fledge source, with its C libraries pre-built (see note above).
ENV FLEDGE_ROOT=/opt/fledge
RUN git clone --depth 1 --branch "${FLEDGE_BRANCH}" "${FLEDGE_REPO}" "${FLEDGE_ROOT}"

# Fledge's own requirements.sh installs everything its C build needs (Boost,
# libpq-dev, python3-dev, etc.) — reused as-is instead of hand-maintaining a
# duplicate package list that would drift out of sync with upstream Fledge.
# apt-get update is needed again here: the previous layer's package index was
# dropped by its own `rm -rf /var/lib/apt/lists/*`.
RUN apt-get update \
    && cd "${FLEDGE_ROOT}" && ./requirements.sh \
    && rm -rf /var/lib/apt/lists/*

# Full C build (mirrors fledge-iot/fledge's own Dockerfile). Populates
# cmake_build/C/lib/*.so, which FindFledge.cmake in plugin repos reads
# directly — no `make install` needed.
RUN cd "${FLEDGE_ROOT}" && make -j"$(nproc)" c_build

# libplctag prebuilt so plugin builds can skip requirements.sh (make_deb -s).
RUN set -eux; \
    workdir="$(mktemp -d)"; \
    git clone --depth 1 --branch "v${LIBPLCTAG_VERSION}" \
        https://github.com/libplctag/libplctag.git "${workdir}/libplctag"; \
    cmake -S "${workdir}/libplctag" -B "${workdir}/libplctag/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local; \
    cmake --build "${workdir}/libplctag/build" --target install; \
    ldconfig; \
    rm -rf "${workdir}"

WORKDIR /work
