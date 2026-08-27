# fledge-with-plugins: the fledge-runtime base image plus the full suite of
# IndyIQ Fledge plugins, all installed via their real .deb packages.
#
# Plugin packages declare `Depends: fledge (>=X)`, but this base image's
# Fledge core is built from source (make install), not installed via dpkg —
# so dpkg has no "fledge" package registered to satisfy that dependency. We
# register a lightweight equivs placeholder package (Package: fledge,
# Version: <actual running version, read from /etc/fledge-build>) so
# `apt-get install ./plugin.deb` resolves dependencies the normal way —
# including pulling in any other real system libraries a plugin needs (e.g.
# libfftw3 for fledge-filter-fft) from the distro repos — rather than using
# --force-depends, which would also silently ignore genuinely missing libs.
#
# debs/ is populated by build-fledge-image.yml, which downloads the latest
# successful .deb artifact from every onboarded plugin repo's indyiq/main
# run before this build starts. It is empty (gitignored) otherwise.
#
# BASE_IMAGE is RobRaesemann/fledge's own custom Fledge-core image (built by
# that repo's docker-publish.yml from its indyiq/main branch — not an
# official fledge-iot image), published public so this build can pull it.
# Latest published IndyIQ core (indyiq/main @ 338c653 — SQLite 3.53.4,
# aiohttp 3.14.3 / PyJWT pins). Digest so a retagged :indyiq-main cannot drift.
ARG BASE_IMAGE=ghcr.io/robraesemann/fledge@sha256:fb0f81588f5ee4597ad6d8993917bdc662c1bf87e16f03d9f032824b767f4fdc
FROM ${BASE_IMAGE}

# --- Microsoft ODBC Driver 18 for SQL Server (fledge-south-rdbms) -----------
# The rdbms plugin's pyodbc adapter loads this driver by name at connection
# time. It cannot be a Depends: of the plugin .deb — it lives in Microsoft's
# own apt repository under a EULA, not the distro repos — and it cannot be
# installed from the plugin's postinst either, because that runs while the
# outer `apt-get install /tmp/debs/*.deb` below holds the dpkg frontend lock.
# So it is installed here, as its own layer, before the plugin debs.
# ACCEPT_EULA=Y accepts the Microsoft licence terms non-interactively:
# https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl gnupg ca-certificates apt-transport-https; \
    . /etc/os-release; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor --yes -o /usr/share/keyrings/microsoft-prod.gpg; \
    curl -fsSL "https://packages.microsoft.com/config/${ID}/${VERSION_ID}/prod.list" \
        > /etc/apt/sources.list.d/mssql-release.list; \
    grep -q 'signed-by=' /etc/apt/sources.list.d/mssql-release.list \
        || sed -i 's|^deb \[|deb [signed-by=/usr/share/keyrings/microsoft-prod.gpg |' \
            /etc/apt/sources.list.d/mssql-release.list; \
    apt-get update; \
    ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 unixodbc; \
    rm -rf /var/lib/apt/lists/*; \
    odbcinst -q -d

# Kept below the driver layer so a new set of plugin debs doesn't invalidate it.
COPY debs/ /tmp/debs/

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends equivs python3-pip; \
    python3 -m pip install --break-system-packages --no-cache-dir 'async-timeout==5.0.1'; \
    mkdir -p /tmp/equivs && cd /tmp/equivs; \
    fledge_version="$(sed -n 's/^fledge_version=//p' /etc/fledge-build)"; \
    printf 'Package: fledge\nVersion: %s\nArchitecture: all\nMaintainer: IndyIQ\nDescription: Placeholder marking the source-built Fledge core as installed, for dpkg dependency tracking only.\n' "${fledge_version}" > fledge-equivs.control; \
    equivs-build fledge-equivs.control; \
    dpkg -i ./*.deb; \
    apt-get install -y /tmp/debs/*.deb; \
    # mqtt-sparkplug's postinst pins protobuf==3.7.0 (Scout: CVE-2026-0994,
    # CVE-2025-4565, CVE-2022-1941, CVE-2021-22570). 5.29.6 is the first 5.x
    # that closes all four; the plugin's checked-in sparkplug_b_pb2.py is 3.x
    # gencode and will not import, so regenerate from the .proto that shipped
    # in the .deb, then drop the codegen toolchain.
    python3 -m pip install --break-system-packages --no-cache-dir \
        'protobuf==5.29.6' 'grpcio-tools==1.71.2'; \
    spark_dir=/usr/local/fledge/python/fledge/plugins/south/mqtt_sparkplug/sparkplug_b; \
    python3 -m grpc_tools.protoc -I"${spark_dir}" --python_out="${spark_dir}" sparkplug_b.proto; \
    PYTHONPATH=/usr/local/fledge/python python3 -c "from fledge.plugins.south.mqtt_sparkplug.sparkplug_b import sparkplug_b_pb2; p=sparkplug_b_pb2.Payload(); p.metrics.add().name='t'"; \
    python3 -m pip uninstall -y --break-system-packages grpcio-tools grpcio; \
    apt-get purge -y equivs python3-pip; \
    apt-get autoremove -y --purge; \
    rm -rf /tmp/equivs /tmp/debs /root/.cache /var/lib/apt/lists/*; \
    chown -R fledge:fledge /usr/local/fledge

# --- Optional Loki logging ---
# Forward syslog (Fledge core, plugins, PostgreSQL) to a central Loki via a
# remote Alloy syslog receiver. Reuses the rsyslog already in the base image
# (omfwd is built in — no new package). Inert unless LOKI_SYSLOG_TARGET is set
# at runtime: the entrypoint wrapper renders the forward config only then and
# execs the base entrypoint (/usr/local/fledge/fledge.sh), so with the var
# unset behaviour is identical to the base image. See the Open-IIoT-GitOps
# alloy-syslog receiver and fledge-iot/docs/loki-syslog-forwarding.md.
COPY loki/90-loki-forward.conf.tmpl /etc/rsyslog.d/90-loki-forward.conf.tmpl
COPY loki/loki-forward-entrypoint.sh /usr/local/fledge/loki-forward-entrypoint.sh
RUN chmod +x /usr/local/fledge/loki-forward-entrypoint.sh
ENTRYPOINT ["/usr/local/fledge/loki-forward-entrypoint.sh"]
