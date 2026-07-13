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
ARG BASE_IMAGE=ghcr.io/robraesemann/fledge:indyiq-main
FROM ${BASE_IMAGE}

COPY debs/ /tmp/debs/

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends equivs; \
    mkdir -p /tmp/equivs && cd /tmp/equivs; \
    fledge_version="$(sed -n 's/^fledge_version=//p' /etc/fledge-build)"; \
    printf 'Package: fledge\nVersion: %s\nArchitecture: all\nMaintainer: IndyIQ\nDescription: Placeholder marking the source-built Fledge core as installed, for dpkg dependency tracking only.\n' "${fledge_version}" > fledge-equivs.control; \
    equivs-build fledge-equivs.control; \
    dpkg -i ./*.deb; \
    apt-get install -y /tmp/debs/*.deb; \
    apt-get purge -y equivs; \
    rm -rf /tmp/equivs /tmp/debs /var/lib/apt/lists/*; \
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
