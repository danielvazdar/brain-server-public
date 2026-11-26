#!/bin/sh
# Started by dockerd-rootless.sh (its DOCKERD= hook) inside the rootless Docker's own network
# namespace, just before dockerd (ops#89). Each CI user's Docker publishes ports from its own block
# of 1,000, so two runners' containers never ask for the same host port. Docker picks published ports
# from ip_local_port_range, which is per network namespace; every Docker started at 32768 before.
# The same range serves the namespace's outgoing connections (image builds), hence 1,000, not less.
# Blocks sit below the host's own ephemeral range (32768+): uid 1004 -> 14000-14999.
# ci-box.sh's smoke test checks the same formula.
set -eu
uid="$(id -u "${CI_DOCKER_USER:?set by ci-docker@.service}")"
lo=$((10000 + (uid % 1000) * 1000))
hi=$((lo + 999))
if [ "$hi" -ge 32768 ]; then
  echo "dockerd-ports: uid $uid gives $lo-$hi, inside the host's ephemeral range" >&2
  exit 1
fi
sysctl -w net.ipv4.ip_local_port_range="$lo $hi"
exec dockerd "$@"
