#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED on the Evemos release runner only (ops#89).
# That runner's user writes the release layer cache and logs in to GHCR to push the production
# image, so only a push to Evemos main may run there. Anything else (a PR, a manual run, another
# branch) fails here, before its first step runs.
set -u
want_repo=danielvazdar/evemos

if [[ "${GITHUB_REPOSITORY:-}" == "$want_repo" \
   && "${GITHUB_EVENT_NAME:-}" == push \
   && "${GITHUB_REF:-}" == refs/heads/main ]]; then
  exit 0
fi

echo "::error title=Release runner refused this job::Only a push to main of $want_repo may run on" \
  "the release runner. Got repo='${GITHUB_REPOSITORY:-?}' event='${GITHUB_EVENT_NAME:-?}'" \
  "ref='${GITHUB_REF:-?}'. See ops#89."
exit 1
