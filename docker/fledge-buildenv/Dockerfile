# fledge-buildenv: build environment for compiling IndyIQ C++ Fledge plugins.
#
# Provides:
#   * a C++17 toolchain, cmake, dpkg-dev
#   * Fledge source at $FLEDGE_ROOT (headers used by plugin CMakeLists)
#   * libplctag prebuilt into /usr/local (so plugin builds run make_deb with -s)
#
# Plugin .so files link only their own native deps (e.g. libplctag) + pthread;
# Fledge symbols are resolved when Fledge loads the plugin, so the Fledge source
# tree is needed for headers only — we deliberately do NOT build all of Fledge,
# keeping the image small and the build fast. Plugins that link Fledge shared
# libraries at build time can extend this image and run `make` in $FLEDGE_ROOT.
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
        dpkg-dev \
        pkg-config \
        libssl-dev \
        uuid-dev \
        rapidjson-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Fledge source (headers only — see note above).
ENV FLEDGE_ROOT=/opt/fledge
RUN git clone --depth 1 --branch "${FLEDGE_BRANCH}" "${FLEDGE_REPO}" "${FLEDGE_ROOT}"

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
