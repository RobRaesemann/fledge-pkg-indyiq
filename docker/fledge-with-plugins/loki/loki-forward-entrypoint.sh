#!/bin/bash
# =============================================================================
# loki-forward-entrypoint.sh — opt-in syslog->Loki forwarding wrapper.
#
# Renders the rsyslog forward ruleset ONLY when LOKI_SYSLOG_TARGET is set, then
# hands off to the base entrypoint (fledge.sh), which starts rsyslog and Fledge
# as before. When the variable is unset this wrapper is a no-op and behaviour is
# identical to the base image. See docs/loki-syslog-forwarding.md.
#
# Env:
#   LOKI_SYSLOG_TARGET  host[:port] of the Alloy syslog receiver. Empty => off.
#   FLEDGE_SITE         Loki `site` label (default: unknown).
#   FLEDGE_NODE         Loki `node` label (default: container hostname).
# =============================================================================
set -e

if [ -n "${LOKI_SYSLOG_TARGET}" ]; then
  host="${LOKI_SYSLOG_TARGET%%:*}"
  port="${LOKI_SYSLOG_TARGET##*:}"
  # Allow "host" with no ":port" -> default to the Alloy syslog receiver port.
  [ "$host" = "$port" ] && port=1514
  site="${FLEDGE_SITE:-unknown}"
  node="${FLEDGE_NODE:-$(hostname)}"

  # Substitute site/node at render time (rsyslog templates don't expand shell
  # env), producing a plain static config that rsyslogd picks up on start.
  sed -e "s|__TARGET_HOST__|${host}|g" \
      -e "s|__TARGET_PORT__|${port}|g" \
      -e "s|__SITE__|${site}|g" \
      -e "s|__NODE__|${node}|g" \
      /etc/rsyslog.d/90-loki-forward.conf.tmpl \
      > /etc/rsyslog.d/90-loki-forward.conf

  echo "loki-forward: forwarding syslog to ${host}:${port} (site=${site} node=${node})"
fi

exec /bin/bash /usr/local/fledge/fledge.sh "$@"
