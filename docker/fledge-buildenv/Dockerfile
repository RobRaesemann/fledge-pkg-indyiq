# syntax=docker/dockerfile:1
# fledge-buildenv: build environment for compiling IndyIQ C++ Fledge plugins.
#
# Provides:
#   * a C++ toolchain, cmake, dpkg-dev
#   * Fledge source at $FLEDGE_ROOT, with its C libraries pre-built
#     (cmake_build/C/lib/*.so — common-lib, services-common-lib,
#     filters-common-lib, etc.) so plugins that link against Fledge
#     (via FindFledge.cmake, e.g. fledge-south-s2opcua needing common-lib)
#     don't need to compile Fledge itself on every plugin CI run.
#   * libplctag library + headers in /usr/local (so plugin builds can
#     run make_deb with -s). Tools such as modbus_server are not installed.
#
# Building Fledge's C tree is a one-time cost paid only when this image itself
# is rebuilt (Dockerfile change / weekly / manual) — never per plugin build.
#
# Pins:
#   * ubuntu:24.04 by digest
#   * Fledge / notification / libplctag by commit SHA
#   * SQLite amalgamation from sqlite.org by URL + SHA-256
# Override any ARG at build time; git SHAs are verified after fetch.
#
# Build (RobRaesemann/fledge is private — pass a GitHub token):
#   GH_TOKEN=$(gh auth token) docker build \
#     --secret id=gh_token,env=GH_TOKEN \
#     -t fledge-buildenv:sha-338c653 docker/fledge-buildenv
#
# Plugin CI should pull the published image by digest, not :latest:
#   ghcr.io/robraesemann/fledge-buildenv@sha256:<digest>
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG DEBIAN_FRONTEND=noninteractive

ARG LIBPLCTAG_REPO=https://github.com/libplctag/libplctag.git
# v2.6.15^{} (annotated tag object is 7a87417; pin the peeled commit)
ARG LIBPLCTAG_COMMIT=30bc195b224004fb0fe43be4babc8a3443c58ac0

ARG NOTIFICATION_REPO=https://github.com/fledge-iot/fledge-service-notification.git
# v3.1.0
ARG NOTIFICATION_COMMIT=fba6f20e0a1b97aa4ea9a0446bf5ec465096f33e

# Official amalgamation (sqlite.org), not Dianomic's sqlite3-pkg fork.
# Compiled with the same limits Fledge's C storage plugin expects.
ARG SQLITE_URL=https://www.sqlite.org/2026/sqlite-autoconf-3530400.tar.gz
ARG SQLITE_SHA256=0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
ARG SQLITE_CFLAGS="-DSQLITE_MAX_COMPOUND_SELECT=900 -DSQLITE_MAX_ATTACHED=62 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ENABLE_COLUMN_METADATA -fno-common -fPIC"

# Toolchain + the Ubuntu packages Fledge's C build actually needs.
# Intentionally does not run upstream requirements.sh: that script clones
# unpinned sqlite3-pkg, upgrades pip from PyPI, and pulls avahi/krb5/cpulimit.
# python3-dev + python3-numpy are required by Fledge's python plugin-interface
# CMake dirs (FindPython3 NumPy). python3-pip is not; do not upgrade pip.
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y --no-install-recommends \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold; \
    apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        curl \
        ca-certificates \
        dpkg-dev \
        pkg-config \
        libssl-dev \
        uuid-dev \
        rapidjson-dev \
        autoconf \
        automake \
        libtool \
        libboost-dev \
        libboost-system-dev \
        libboost-thread-dev \
        libpq-dev \
        zlib1g-dev \
        libcurl4-openssl-dev \
        python3 \
        python3-dev \
        python3-numpy; \
    rm -rf /var/lib/apt/lists/*

# SQLite from sqlite.org, static, PIC, Fledge attach/compound-select limits.
# Installed to /usr/local so Fledge's storage plugin can -lsqlite3.
RUN set -eux; \
    workdir="$(mktemp -d)"; \
    curl -fsSL "${SQLITE_URL}" -o "${workdir}/sqlite.tar.gz"; \
    echo "${SQLITE_SHA256}  ${workdir}/sqlite.tar.gz" | sha256sum -c; \
    tar -xzf "${workdir}/sqlite.tar.gz" -C "${workdir}"; \
    src="$(echo "${workdir}"/sqlite-autoconf-*)"; \
    cd "${src}"; \
    CFLAGS="${SQLITE_CFLAGS}" ./configure \
        --prefix=/usr/local \
        --disable-shared \
        --disable-readline; \
    make -j"$(nproc)"; \
    make install; \
    rm -rf "${workdir}"

ENV FLEDGE_ROOT=/opt/fledge

# IndyIQ Fledge fork at the same commit as ghcr.io/robraesemann/fledge:sha-338c653.
# Declared here so bumping the pin does not rebuild apt/SQLite layers.
ARG FLEDGE_REPO=https://github.com/RobRaesemann/fledge.git
ARG FLEDGE_COMMIT=338c653a916487f5d445dd573608265410ec6d94

# Shallow fetch of a pinned commit, then drop .git. Fails if HEAD != COMMIT.
# Optional gh_token BuildKit secret: required because RobRaesemann/fledge is private.
# GitHub HTTPS wants basic auth as x-access-token:<token>, not a bearer header.
# Do not `set -x` here — it would print the token.
RUN --mount=type=secret,id=gh_token,required=false \
    set -eu; \
    export GIT_TERMINAL_PROMPT=0; \
    git init "${FLEDGE_ROOT}"; \
    fetch_url="${FLEDGE_REPO}"; \
    if [ -s /run/secrets/gh_token ]; then \
      token=$(cat /run/secrets/gh_token); \
      case "${FLEDGE_REPO}" in \
        https://*) fetch_url="https://x-access-token:${token}@${FLEDGE_REPO#https://}" ;; \
      esac; \
      echo "Fetching ${FLEDGE_COMMIT} from ${FLEDGE_REPO} (authenticated)"; \
    else \
      echo "Fetching ${FLEDGE_COMMIT} from ${FLEDGE_REPO}"; \
    fi; \
    git -C "${FLEDGE_ROOT}" remote add origin "${fetch_url}"; \
    git -C "${FLEDGE_ROOT}" fetch --depth 1 origin "${FLEDGE_COMMIT}"; \
    git -C "${FLEDGE_ROOT}" checkout --detach FETCH_HEAD; \
    actual="$(git -C "${FLEDGE_ROOT}" rev-parse HEAD)"; \
    test "${actual}" = "${FLEDGE_COMMIT}"; \
    rm -rf "${FLEDGE_ROOT}/.git"

# Full C build (mirrors fledge-iot/fledge's own Dockerfile). Populates
# cmake_build/C/lib/*.so, which FindFledge.cmake in plugin repos reads
# directly — no `make install` needed.
WORKDIR /opt/fledge
RUN make -j"$(nproc)" c_build

# libplctag library + headers only (no examples, tests, or protocol tools).
RUN set -eux; \
    workdir="$(mktemp -d)"; \
    git init "${workdir}/libplctag"; \
    git -C "${workdir}/libplctag" remote add origin "${LIBPLCTAG_REPO}"; \
    git -C "${workdir}/libplctag" fetch --depth 1 origin "${LIBPLCTAG_COMMIT}"; \
    git -C "${workdir}/libplctag" checkout --detach FETCH_HEAD; \
    actual="$(git -C "${workdir}/libplctag" rev-parse HEAD)"; \
    test "${actual}" = "${LIBPLCTAG_COMMIT}"; \
    cmake -S "${workdir}/libplctag" -B "${workdir}/libplctag/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTS=OFF \
        -DUSE_SANITIZERS=OFF; \
    cmake --build "${workdir}/libplctag/build" --target plctag_dyn --target plctag_static; \
    cmake --install "${workdir}/libplctag/build" --component runtime; \
    install -D -m 644 "${workdir}/libplctag/src/libplctag/lib/libplctag.h" \
        /usr/local/include/libplctag.h; \
    install -D -m 644 "${workdir}/libplctag/build/bin_dist/libplctag_static.a" \
        /usr/local/lib/libplctag_static.a; \
    if [ -f "${workdir}/libplctag/build/bin_dist/libplctag.pc" ]; then \
        install -D -m 644 "${workdir}/libplctag/build/bin_dist/libplctag.pc" \
            /usr/local/lib/pkgconfig/libplctag.pc; \
    fi; \
    ldconfig; \
    rm -rf "${workdir}" /usr/local/bin/tag_rw2 /usr/local/bin/modbus_server \
        /usr/local/bin/tag_rw_deprecated

# Notification service headers. Every fledge-rule-* plugin includes the
# notification server's own headers (builtin_rule.h and friends) and its
# CMakeLists hard-fails unless NOTIFICATION_SERVICE_INCLUDE_DIRS points at
# them. Only the headers are needed — nothing here is compiled. Pinned to the
# same commit as Fledge v3.1.0 so rule plugins match the notification .deb
# shipped in the combined image. Kept last so it doesn't invalidate the
# expensive layers.
ENV NOTIFICATION_SERVICE_ROOT=/opt/fledge-service-notification
RUN set -eux; \
    git init "${NOTIFICATION_SERVICE_ROOT}"; \
    git -C "${NOTIFICATION_SERVICE_ROOT}" remote add origin "${NOTIFICATION_REPO}"; \
    git -C "${NOTIFICATION_SERVICE_ROOT}" fetch --depth 1 origin "${NOTIFICATION_COMMIT}"; \
    git -C "${NOTIFICATION_SERVICE_ROOT}" checkout --detach FETCH_HEAD; \
    actual="$(git -C "${NOTIFICATION_SERVICE_ROOT}" rev-parse HEAD)"; \
    test "${actual}" = "${NOTIFICATION_COMMIT}"; \
    rm -rf "${NOTIFICATION_SERVICE_ROOT}/.git"
ENV NOTIFICATION_SERVICE_INCLUDE_DIRS=${NOTIFICATION_SERVICE_ROOT}/C/services/notification/include

WORKDIR /work
