#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED on every CI-box runner (ops#89, option A, Daniel 2026-11-16).
# Runs as the runner's own user after each job, so the next job starts from a clean slate:
# no checkout, downloaded action, tool or temp file, and no container, volume or network, is left.
# Tagged base images stay, so buildkit's ~350 MB image isn't downloaded again for every build
# (the runner re-pulls service images like postgres every job anyway).
# A clean-up problem shows as a warning on the run; it doesn't fail the tests.
set -uo pipefail

warn() { echo "::warning title=CI-box clean-up::$1 (ops#89)"; }

work="$HOME/actions-runner/_work"
if [[ -d "$work" ]]; then
  find "$work" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || warn "could not empty $work"
fi

if [[ -n "${DOCKER_HOST:-}" ]]; then
  ids=$(docker ps -aq) || warn "docker ps failed"
  if [[ -n "${ids:-}" ]]; then
    # shellcheck disable=SC2086 # one id per word
    docker rm -f $ids >/dev/null || warn "could not remove containers"
  fi
  docker network prune -f >/dev/null || warn "could not prune networks"
  docker volume prune -af >/dev/null || warn "could not prune volumes"
  docker image prune -f >/dev/null || warn "could not prune untagged images"
fi
exit 0
