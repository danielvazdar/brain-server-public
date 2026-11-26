#!/usr/bin/env bash
# CI-box runner isolation (ops#89, Daniel 2026-11-16). Every GitHub runner on the CI-box (the Latitude
# since 2026-11-26, brain-server#34; the Inspiron `brain-old` before) runs as its own OS user, and none is in the `docker` group (= root). Runners whose
# jobs need Docker (Evemos) get a rootless Docker of their own (ci-docker@.service). Evemos's release
# image builds on its own runner and user, which alone writes the release layer cache; PR jobs can
# only read it. After every job a hook empties the runner's work folder and Docker (option A).
#
# Run from the laptop; it copies this folder to the CI-box and runs the step there as root:
#   ./ci-box.sh status                                read-only: runner -> user, idle/busy, Dockers
#   ./ci-box.sh prepare [--apply]                     packages, users, Dockers, hooks. No downtime.
#   ./ci-box.sh add <repo> <name> <labels> [--apply]  register a new runner, as user ci-<name>
#   ./ci-box.sh move <runner> [--apply]               one ghrunner runner -> its own user (~15 s off)
#   ./ci-box.sh undo <runner> [--apply]               the way back: a moved runner -> ghrunner again
#   ./ci-box.sh finish [--apply]                      ghrunner out of `docker`, root Docker stopped
#   ./ci-box.sh dropins [--apply]                     rewrite every runner's ci-box.conf, restart the idle ones
# Without --apply a step only prints what it would do. Nothing here deletes data: `finish` lists
# what is left over (ghrunner's home, root Docker's images) for Daniel to OK.
# Replaces add-runner.sh (moved to docs/archive/ 2026-11-16).
set -euo pipefail

HOST="${CI_BOX_HOST:-daniel@latitude.tailnet-example.ts.net}"  # CI_BOX_HOST=brain-old reaches the old box
FILES=(ci-box.sh ci-docker@.service dockerd-ports.sh job-completed.sh release-guard.sh)
GH_OWNER=danielvazdar
OLD_USER=ghrunner
OLD_HOME=/home/ghrunner
RELEASE_USER=ci-evemos-release
RELEASE_CACHE=/var/cache/ci-release
LIB=/usr/local/lib/ci-box
ROOTLESS_SH=/usr/local/bin/dockerd-rootless.sh
ROOTLESS_URL=https://raw.githubusercontent.com/moby/moby/docker-v29.1.3/contrib/dockerd-rootless.sh
ROOTLESS_SHA256=8eb00d61b5e78ffc0dcd628f056389b5859cc61d6fe3ce17b4a3a4b08143c8a5
PACKAGES=(uidmap rootlesskit slirp4netns)
# The runner units' sandbox. write_dropin and the sandbox smoke test both read it, so the test runs
# exactly what the runners get. No RestrictSUIDSGID= (2026-11-26, the move to the Latitude): on
# Ubuntu 26.04 GNU tar extracts through openat2(RESOLVE_BENEATH) with no fallback, and that filter
# answers openat2 with ENOSYS, so every job failed in "Set up job" unpacking actions/checkout.
# What it guarded stays covered: NoNewPrivileges= makes setuid bits inert inside jobs, runner homes
# are 750, and the shared writable mounts (/tmp, /dev/shm) are nosuid.
SANDBOX=(NoNewPrivileges=yes PrivateTmp=yes ProtectSystem=full ProtectKernelTunables=yes
         ProtectKernelModules=yes ProtectControlGroups=yes)

# Existing runner (its GitHub name) -> its own user. New runners are named after their user.
declare -A RUNNER_USER=(
  [brain]=ci-evemos-1 [brain-2]=ci-evemos-2 [ci-evemos-3]=ci-evemos-3 [ci-evemos-4]=ci-evemos-4
  [brain-client-a]=ci-client-a [brain-client-b]=ci-client-b
  [brain-kyuro]=ci-kyuro
)
# Only Evemos jobs use Docker (service Postgres, image builds). Every other runner gets none.
DOCKER_USERS=(ci-evemos-1 ci-evemos-2 ci-evemos-3 ci-evemos-4 "$RELEASE_USER")

APPLY=0
CHANGED=0              # a file install_file looked at differs from what is installed
DOCKER_UNIT_CHANGED=0  # ...and it was the ci-docker unit or its drop-in: running Dockers restart

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
plan() { printf '  %s  %s\n' "$( ((APPLY)) && echo 'do  ' || echo 'would')" "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

has_docker() { local u; for u in "${DOCKER_USERS[@]}"; do [[ $u == "$1" ]] && return 0; done; return 1; }
sock_of()    { printf 'unix:///run/ci-docker-%s/docker.sock' "$1"; }
as_user()    { local u=$1; shift; sudo -u "$u" -H env DOCKER_HOST="$(sock_of "$u")" "$@"; }

all_users() { printf '%s\n' "${RUNNER_USER[@]}" "$RELEASE_USER" | sort -u; }

# ---------------------------------------------------------------- laptop side

send_registration_token() {
  local repo=$1
  [[ "$repo" =~ ^[a-z0-9-]+$ ]] || die "bad repo name: $repo"
  # Short-lived (1 h) token: over stdin into a 600 file on the box, never printed or on argv.
  gh api -X POST "repos/$GH_OWNER/$repo/actions/runners/registration-token" --jq .token \
    | ssh "$HOST" 'umask 077; cat > ~/.ci-box-runner-token'
}

latest_runner_release() {
  local notes version sha
  notes="$(gh api repos/actions/runner/releases/latest --jq '.tag_name + "\n" + .body')"
  version="$(head -1 <<<"$notes")"; version="${version#v}"
  sha="$(grep -oP 'linux-x64 -->\K[0-9a-f]{64}' <<<"$notes")"
  [[ "$version" =~ ^[0-9.]+$ && -n "$sha" ]] || die "could not read the runner release"
  printf 'RUNNER_VERSION=%s RUNNER_SHA=%s' "$version" "$sha"
}

laptop_main() {
  local here extra_env=""
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tar -C "$here" -cf - "${FILES[@]}" | ssh "$HOST" 'mkdir -p ~/ci-box && tar -C ~/ci-box -xf -'
  if [[ "${1:-}" == add ]]; then
    extra_env="$(latest_runner_release)"
    if [[ " $* " == *" --apply "* ]]; then send_registration_token "${2:-}"; fi
  fi
  # shellcheck disable=SC2029 # expanded here on purpose: the args are quoted with %q
  ssh "$HOST" "sudo env CI_BOX_REMOTE=1 $extra_env bash ~/ci-box/ci-box.sh $(printf '%q ' "$@")"
}

# ---------------------------------------------------------------- box helpers

# Show what would change in $dest, and install $src there on --apply.
install_file() {
  local src=$1 dest=$2 mode=$3
  if [[ -f $dest ]] && cmp -s "$src" "$dest"; then ok "$dest unchanged"; return 0; fi
  plan "install $dest"
  if [[ -f $dest ]]; then diff -u "$dest" "$src" | sed 's/^/        /' || true
  else sed 's/^/        + /' "$src"; fi
  CHANGED=1
  if ((APPLY)); then install -D -m "$mode" -o root -g root "$src" "$dest"; fi
}

runner_dir_of() {  # $1 runner name, $2 base dir glob → the runner folder whose .runner names it
  local f
  for f in $2/.runner; do
    [[ -f $f ]] || continue
    if grep -qE "\"agentName\"[[:space:]]*:[[:space:]]*\"$1\"" "$f"; then dirname "$f"; return 0; fi
  done
  return 1
}

unit_busy() {  # a Runner.Worker process exists only while the runner is running a job
  local cg pid
  cg="$(systemctl show -p ControlGroup --value "$1")"
  [[ -n $cg && -f /sys/fs/cgroup$cg/cgroup.procs ]] || return 1
  while read -r pid; do
    if [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == Runner.Worker ]]; then return 0; fi
  done <"/sys/fs/cgroup$cg/cgroup.procs"
  return 1
}

wait_listening() {  # $1 unit, $2 epoch seconds it was started at
  local _
  for _ in $(seq 1 30); do
    if journalctl -u "$1" --since "@$2" --no-pager -q | grep -q 'Listening for Jobs'; then return 0; fi
    sleep 2
  done
  return 1
}

# The root-owned drop-in that runs a runner unit as its own user, hardened, with the hooks.
write_dropin() {
  local user=$1 release=$2
  say "# Written by ci-box.sh (ops#89). Root-owned, so a job can't switch any of this off."
  if has_docker "$user"; then
    printf '[Unit]\nWants=ci-docker@%s.service\nAfter=ci-docker@%s.service\n\n' "$user" "$user"
  fi
  cat <<EOF
[Service]
User=$user
Group=$user
WorkingDirectory=/home/$user/actions-runner
ExecStart=
ExecStart=/home/$user/actions-runner/runsvc.sh
Environment=ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$LIB/job-completed.sh
EOF
  printf '%s\n' "${SANDBOX[@]}"
  if has_docker "$user"; then say "Environment=DOCKER_HOST=$(sock_of "$user")"; fi
  if ((release)); then
    say "Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=$LIB/release-guard.sh"
    release_priority
  fi
}

# The release build no longer waits for one of the two ci-heavy slots (E-81), so it runs at half
# a test job's share when both compete, and gets all spare CPU when the box is quiet.
release_priority() { printf 'Nice=10\nCPUWeight=10\nIOWeight=10\n'; }

# ---------------------------------------------------------------- prepare

step_packages() {
  local p missing=()
  for p in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then ok "packages ${PACKAGES[*]} installed"; return 0; fi
  plan "apt-get install ${missing[*]}"
  if ((APPLY)); then DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${missing[@]}"; fi
}

step_rootless_script() {
  if [[ -f $ROOTLESS_SH ]] && echo "$ROOTLESS_SHA256  $ROOTLESS_SH" | sha256sum -c --status; then
    ok "$ROOTLESS_SH present (docker-v29.1.3, sha256 checked)"; return 0
  fi
  plan "install $ROOTLESS_SH from moby docker-v29.1.3 (sha256 $ROOTLESS_SHA256)"
  ((APPLY)) || return 0
  local tmp; tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$ROOTLESS_URL"
  echo "$ROOTLESS_SHA256  $tmp" | sha256sum -c --status || { rm -f "$tmp"; die "dockerd-rootless.sh checksum mismatch"; }
  install -m 755 -o root -g root "$tmp" "$ROOTLESS_SH"
  rm -f "$tmp"
}

step_user() {
  local u=$1
  if id "$u" &>/dev/null; then
    ok "user $u exists"
  else
    plan "useradd $u (own group, home 750, no login shell, not in docker)"
    ((APPLY)) || return 0
    useradd --create-home --user-group --shell /usr/sbin/nologin "$u"
  fi
  if [[ "$(stat -c %a "/home/$u" 2>/dev/null)" != 750 ]]; then
    plan "chmod 750 /home/$u"
    if ((APPLY)); then chmod 750 "/home/$u"; fi
  fi
  if id -nG "$u" | grep -qw docker; then die "$u is in the docker group; that is what ops#89 removes"; fi
  if has_docker "$u"; then
    grep -q "^$u:" /etc/subuid && grep -q "^$u:" /etc/subgid \
      || die "$u has no /etc/subuid or /etc/subgid range; rootless Docker needs one"
  fi
}

step_files() {
  local here dropin
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  dropin="$(mktemp)"
  { say "[Service]"; release_priority; } >"$dropin"
  install_file "$here/ci-docker@.service" /etc/systemd/system/ci-docker@.service 644
  install_file "$dropin" "/etc/systemd/system/ci-docker@$RELEASE_USER.service.d/priority.conf" 644
  install_file "$here/dockerd-ports.sh" "$LIB/dockerd-ports.sh" 755
  DOCKER_UNIT_CHANGED=$CHANGED
  install_file "$here/job-completed.sh" "$LIB/job-completed.sh" 755
  install_file "$here/release-guard.sh" "$LIB/release-guard.sh" 755
  rm -f "$dropin"
  if ((CHANGED && APPLY)); then systemctl daemon-reload; fi
}

# Started empty on purpose: the old cache under ghrunner was writable by every PR job, which is
# the hole being closed, so nothing from it is carried over. The first release build is cold.
step_release_cache() {
  if [[ -d $RELEASE_CACHE ]]; then ok "$RELEASE_CACHE exists"; return 0; fi
  plan "mkdir $RELEASE_CACHE (owner $RELEASE_USER, 755: PR runners read, only release writes)"
  if ((APPLY)); then install -d -o "$RELEASE_USER" -g "$RELEASE_USER" -m 755 "$RELEASE_CACHE"; fi
}

smoke_test() {
  local u=$1 cid port ctx _ ready=0 lo
  lo=$((10000 + ($(id -u "$u") % 1000) * 1000))  # the block dockerd-ports.sh gives this user
  [[ "$(as_user "$u" docker info --format '{{json .SecurityOptions}}')" == *rootless* ]] \
    || die "$u: Docker is not running rootless"
  as_user "$u" docker pull -q postgres:16-alpine >/dev/null || die "$u: could not pull postgres:16-alpine"
  cid="$(as_user "$u" docker run -d --rm --tmpfs /var/lib/postgresql/data \
    -e POSTGRES_PASSWORD=ci-box-smoke-not-a-secret -p 127.0.0.1::5432 postgres:16-alpine)" \
    || die "$u: docker run failed (see journalctl -u ci-docker@$u)"
  port="$(as_user "$u" docker port "$cid" 5432/tcp | head -1)"; port="${port##*:}"
  if ((port < lo || port > lo + 999)); then
    as_user "$u" docker rm -f "$cid" >/dev/null || true
    die "$u: published port $port is outside its block $lo-$((lo + 999)); two runners could clash"
  fi
  for _ in $(seq 1 30); do
    if as_user "$u" docker exec "$cid" pg_isready -q -U postgres; then ready=1; break; fi
    sleep 2
  done
  if ((ready)) && timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port"; then
    as_user "$u" docker rm -f "$cid" >/dev/null
  else
    as_user "$u" docker rm -f "$cid" >/dev/null || true
    die "$u: service-style Postgres did not come up on 127.0.0.1:$port"
  fi
  ctx="$(mktemp -d)"; echo ok >"$ctx/ok"; printf 'FROM scratch\nCOPY ok /ok\n' >"$ctx/Dockerfile"
  chmod -R a+rX "$ctx"
  as_user "$u" docker buildx create --name ci-box-smoke --driver docker-container --bootstrap >/dev/null
  if as_user "$u" docker buildx build -q --builder ci-box-smoke --load -t ci-box-smoke:test "$ctx" >/dev/null; then
    as_user "$u" docker image rm ci-box-smoke:test >/dev/null
  else
    as_user "$u" docker buildx rm ci-box-smoke >/dev/null || true; rm -rf "$ctx"
    die "$u: buildx build failed"
  fi
  as_user "$u" docker buildx rm ci-box-smoke >/dev/null
  rm -rf "$ctx"
  ok "$u: rootless Docker passes (Postgres on 127.0.0.1:$port, buildx build)"
}

user_runner_busy() {  # the runner that uses $1's Docker, if it has one yet, is running a job
  local svc="/home/$1/actions-runner/.service"
  [[ -f $svc ]] && unit_busy "$(<"$svc")"
}

step_docker() {
  local u=$1 unit="ci-docker@$1.service" _ restart=0
  if ! systemctl is-active --quiet "$unit"; then plan "systemctl enable --now $unit"
  elif ((DOCKER_UNIT_CHANGED)); then plan "restart $unit (its unit changed)"; restart=1
  else ok "$unit running"; fi
  if ! ((APPLY)); then plan "smoke test $u (Postgres container on 127.0.0.1, buildx build)"; return 0; fi
  if ((restart)); then
    if user_runner_busy "$u"; then die "$u's runner is running a job; re-run when it is idle"; fi
    systemctl restart "$unit"
  fi
  systemctl is-active --quiet "$unit" || systemctl enable --now "$unit"
  for _ in $(seq 1 15); do [[ -S /run/ci-docker-$u/docker.sock ]] && break; sleep 2; done
  smoke_test "$u"
}

# What GitHub's "Set up job" does first, inside the runner sandbox: unpack an action's tarball.
sandbox_smoke_test() {
  local u=$1 p props=() out
  for p in "${SANDBOX[@]}"; do props+=(-p "$p"); done
  # shellcheck disable=SC2016 # expanded by the bash inside the unit
  if out="$(systemd-run --quiet --wait --pipe --collect -p User="$u" -p Group="$u" \
      -p WorkingDirectory="/home/$u" "${props[@]}" bash -c 'set -e; d=$(mktemp -d -p .)
      trap "rm -rf $d" EXIT; mkdir -p "$d/a/b"; echo ok > "$d/a/b/f"; tar -C "$d/a" -czf "$d/t.tgz" .
      mkdir "$d/x"; tar -C "$d/x" -xzf "$d/t.tgz"; cat "$d/x/b/f"' 2>&1)" && [[ $out == ok ]]; then
    ok "runner sandbox: tar unpacks as $u"
  else
    die "the runner sandbox breaks tar as $u, so every job would fail in 'Set up job': $out"
  fi
}

cmd_prepare() {
  say "== packages and rootless Docker script"
  step_packages
  step_rootless_script
  say "== users"
  local u; while read -r u; do step_user "$u"; done < <(all_users)
  u="$(all_users | head -1)"
  if id "$u" &>/dev/null; then sandbox_smoke_test "$u"; else plan "sandbox smoke test as $u"; fi
  say "== unit, hooks, release cache"
  step_files
  step_release_cache
  say "== rootless Docker per Evemos user"
  for u in "${DOCKER_USERS[@]}"; do step_docker "$u"; done
  if ! ((APPLY)); then say "Dry run: nothing changed. Re-run with --apply."; fi
}

# ---------------------------------------------------------------- move / add

# The runner's self-update points `bin` and `externals` at bin.<version> by absolute path, so a
# moved runner would still exec from the old, now unreadable folder (2026-11-16: exit 126).
relink_runner() {  # $1 old folder, $2 new folder
  local link target
  for link in bin externals; do
    [[ -L $2/$link ]] || continue
    target="$(readlink "$2/$link")"
    if [[ $target == "$1"/* ]]; then ln -sfnT "${target#"$1"/}" "$2/$link"; chown -h "$(stat -c %U "$2")": "$2/$link"; fi
  done
}

rollback_move() {
  local unit=$1 old=$2 new=$3
  systemctl stop "$unit" || true
  rm -f "/etc/systemd/system/$unit.d/ci-box.conf"
  mv "$new" "$old" && chown -R "$OLD_USER:$OLD_USER" "$old"
  systemctl daemon-reload
  systemctl start "$unit"
}

cmd_move() {
  local name=${1:-} user dir unit new dropin since
  user="${RUNNER_USER[$name]:-}"
  [[ -n $user ]] || die "unknown runner '$name' (known: ${!RUNNER_USER[*]})"
  new="/home/$user/actions-runner"
  if runner_dir_of "$name" "$new" >/dev/null; then ok "$name already runs from $new"; return 0; fi
  dir="$(runner_dir_of "$name" "$OLD_HOME/actions-runner*")" || die "no folder for $name under $OLD_HOME"
  unit="$(<"$dir/.service")"
  id "$user" &>/dev/null || die "user $user missing: run prepare --apply first"
  [[ ! -e $new ]] || die "$new already exists"
  if has_docker "$user"; then
    systemctl is-active --quiet "ci-docker@$user.service" || die "ci-docker@$user is not running"
  fi
  if unit_busy "$unit"; then die "$name is running a job right now; try again when it is idle"; fi
  dropin="$(mktemp)"; write_dropin "$user" 0 >"$dropin"
  plan "stop $unit, move $dir -> $new (owner $user), add /etc/systemd/system/$unit.d/ci-box.conf:"
  sed 's/^/        /' "$dropin"
  if ! ((APPLY)); then rm -f "$dropin"; return 0; fi
  if unit_busy "$unit"; then rm -f "$dropin"; die "$name just picked up a job; try again when it is idle"; fi
  systemctl stop "$unit"
  mv "$dir" "$new"; chown -R "$user:$user" "$new"; relink_runner "$dir" "$new"
  install -D -m 644 -o root -g root "$dropin" "/etc/systemd/system/$unit.d/ci-box.conf"; rm -f "$dropin"
  systemctl daemon-reload
  since="$(date +%s)"; systemctl start "$unit"
  if ! wait_listening "$unit" "$since"; then
    rollback_move "$unit" "$dir" "$new"
    die "$name did not come back as $user; rolled back to $OLD_USER"
  fi
  ok "$name runs as $user and is listening for jobs"
}

# The way back from a move. The unit svc.sh wrote is never edited, so its WorkingDirectory= still
# names the old folder; only the drop-in and the folder move are undone.
cmd_undo() {
  local name=${1:-} user new unit old
  user="${RUNNER_USER[$name]:-}"
  [[ -n $user ]] || die "unknown runner '$name' (known: ${!RUNNER_USER[*]})"
  new="/home/$user/actions-runner"
  runner_dir_of "$name" "$new" >/dev/null || { ok "$name is not moved"; return 0; }
  unit="$(<"$new/.service")"
  old="$(sed -n 's/^WorkingDirectory=//p' "/etc/systemd/system/$unit")"
  [[ $old == "$OLD_HOME"/* && ! -e $old ]] || die "can't tell where $name came from (got '$old')"
  if unit_busy "$unit"; then die "$name is running a job right now; try again when it is idle"; fi
  plan "stop $unit, move $new -> $old (owner $OLD_USER), drop ci-box.conf, start it"
  ((APPLY)) || return 0
  rollback_move "$unit" "$old" "$new"
  ok "$name runs as $OLD_USER again"
}

install_runner() {  # $1 user $2 repo $3 labels $4 release(0/1)
  local user=$1 repo=$2 labels=$3 release=$4 dir="/home/$1/actions-runner" tarball token_file extra=()
  local ACTIONS_RUNNER_INPUT_TOKEN
  token_file="$(getent passwd "${SUDO_USER:?}" | cut -d: -f6)/.ci-box-runner-token"
  [[ -s $token_file ]] || die "no registration token on the box (the laptop side sends it on --apply)"
  ACTIONS_RUNNER_INPUT_TOKEN="$(<"$token_file")"; rm -f "$token_file"
  rm -rf "$dir"  # no .service yet (checked by the caller): a copy left by an earlier failed run
  install -d -o "$user" -g "$user" "$dir"
  cd "$dir"
  tarball="actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
  sudo -u "$user" curl -fsSL -o "$tarball" \
    "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$tarball"
  echo "$RUNNER_SHA  $tarball" | sha256sum -c --status || die "runner tarball checksum mismatch"
  sudo -u "$user" tar xzf "$tarball"; rm -f "$tarball"
  if ((release)); then extra=(--no-default-labels); fi
  # The token goes in through the environment, never on a command line.
  export ACTIONS_RUNNER_INPUT_TOKEN
  sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u "$user" ./config.sh --unattended --replace \
    --url "https://github.com/$GH_OWNER/$repo" --name "$user" --labels "$labels" --work _work "${extra[@]}"
  unset ACTIONS_RUNNER_INPUT_TOKEN
  chmod 600 .credentials .credentials_rsaparams  # config.sh writes them world-readable
  ./svc.sh install "$user" >/dev/null
}

cmd_add() {
  local repo=${1:-} name=${2:-} labels=${3:-} user release=0 unit since dropin
  [[ $repo =~ ^[a-z0-9-]+$ && $name =~ ^[a-z0-9-]+$ && $labels =~ ^[a-z0-9,-]+$ ]] \
    || die "usage: add <repo> <name> <labels>   e.g. add evemos evemos-release release"
  [[ -n ${RUNNER_VERSION:-} && -n ${RUNNER_SHA:-} ]] || die "run add from the laptop (it looks up the runner release)"
  user="ci-$name"
  if [[ ",$labels," == *,release,* ]]; then release=1; fi
  if ((release)) && [[ $user != "$RELEASE_USER" ]]; then die "the release runner must be named ${RELEASE_USER#ci-}"; fi
  if has_docker "$user"; then
    systemctl is-active --quiet "ci-docker@$user.service" || die "ci-docker@$user not running: prepare --apply first"
  fi
  [[ ! -e /home/$user/actions-runner/.service ]] || die "$user already has an installed runner"
  plan "register runner $user on $GH_OWNER/$repo, labels '$labels'$( ((release)) && echo ' only (no self-hosted label)'), runner v$RUNNER_VERSION"
  dropin="$(mktemp)"; write_dropin "$user" "$release" >"$dropin"; sed 's/^/        /' "$dropin"
  if ! ((APPLY)); then rm -f "$dropin"; return 0; fi
  id "$user" &>/dev/null || step_user "$user"
  install_runner "$user" "$repo" "$labels" "$release"
  unit="$(<"/home/$user/actions-runner/.service")"
  install -D -m 644 -o root -g root "$dropin" "/etc/systemd/system/$unit.d/ci-box.conf"; rm -f "$dropin"
  systemctl daemon-reload
  since="$(date +%s)"; systemctl start "$unit"
  wait_listening "$unit" "$since" || die "$unit did not start listening; see journalctl -u $unit"
  ok "$user registered and listening for jobs"
  # 2026-11-16 (ops#121): ci-evemos-3/4 and the release runner went unwatched for days because
  # brain-server's outside check has a fixed list. Both lists must name it, in the same order.
  say "  next  add ${unit%.service} to the outside check, same position in both lists:"
  say "        brain-server ~/brain-monitor.sh CI_RUNNERS, and this box's forced command in"
  say "        /etc/ssh/authorized_keys/daniel; then run server/tests/test-monitor-ci-host.sh"
}

# ---------------------------------------------------------------- dropins

# Brings every installed runner's ci-box.conf up to what write_dropin writes now. A runner running a
# job is skipped, never interrupted: re-run until nothing is left.
cmd_dropins() {
  local f unit conf user new since skipped=()
  for f in /etc/systemd/system/actions.runner.*.service; do
    unit="$(basename "$f")"; conf="/etc/systemd/system/$unit.d/ci-box.conf"
    [[ -f $conf ]] || continue
    user="$(sed -n 's/^User=//p' "$conf")"
    new="$(mktemp)"; write_dropin "$user" "$([[ $user == "$RELEASE_USER" ]] && echo 1 || echo 0)" >"$new"
    if cmp -s "$new" "$conf"; then ok "$unit drop-in unchanged"; rm -f "$new"; continue; fi
    plan "update $conf, restart $unit"
    diff -u "$conf" "$new" | sed 's/^/        /' || true
    if ! ((APPLY)); then rm -f "$new"; continue; fi
    if unit_busy "$unit"; then skipped+=("$unit"); rm -f "$new"; continue; fi
    install -m 644 -o root -g root "$new" "$conf"; rm -f "$new"
    systemctl daemon-reload
    since="$(date +%s)"; systemctl restart "$unit"
    wait_listening "$unit" "$since" || die "$unit did not start listening again; see journalctl -u $unit"
    ok "$unit restarted with the new drop-in"
  done
  ((${#skipped[@]} == 0)) || die "busy, left as they were (re-run later): ${skipped[*]}"
  if ! ((APPLY)); then say "Dry run: nothing changed. Re-run with --apply."; fi
}

# ---------------------------------------------------------------- status / finish

cmd_status() {
  local f unit u state busy
  printf '%-62s %-20s %-8s %s\n' UNIT USER STATE JOB
  for f in /etc/systemd/system/actions.runner.*.service; do
    unit="$(basename "$f")"
    u="$(systemctl show -p User --value "$unit")"; state="$(systemctl is-active "$unit" || true)"
    busy=idle; if unit_busy "$unit"; then busy=busy; fi
    printf '%-62s %-20s %-8s %s\n' "$unit" "$u" "$state" "$busy"
  done
  for u in "${DOCKER_USERS[@]}"; do
    printf 'ci-docker@%-20s %s\n' "$u" "$(systemctl is-active "ci-docker@$u.service" || true)"
  done
  printf 'root docker.service: %s · %s in docker group: %s\n' "$(systemctl is-active docker.service || true)" \
    "$OLD_USER" "$(id -nG "$OLD_USER" 2>/dev/null | grep -qw docker && echo yes || echo no)"
}

cmd_finish() {
  local f unit left=()
  for f in /etc/systemd/system/actions.runner.*.service; do
    unit="$(basename "$f")"
    if [[ "$(systemctl show -p User --value "$unit")" == "$OLD_USER" ]]; then left+=("$unit"); fi
  done
  ((${#left[@]} == 0)) || die "still running as $OLD_USER: ${left[*]}"
  if id -nG "$OLD_USER" 2>/dev/null | grep -qw docker; then
    plan "gpasswd -d $OLD_USER docker"
    if ((APPLY)); then gpasswd -d "$OLD_USER" docker; fi
  else ok "$OLD_USER not in docker"; fi
  if systemctl is-enabled --quiet docker.service 2>/dev/null || systemctl is-active --quiet docker.service; then
    plan "systemctl disable --now docker.socket docker.service (root Docker; no runner uses it now)"
    if ((APPLY)); then systemctl disable --now docker.socket docker.service; fi
  else ok "root Docker stopped and disabled"; fi
  say "Left on disk, for Daniel to OK deleting (nothing reads them now):"
  du -sh "$OLD_HOME" /var/lib/docker 2>/dev/null | sed 's/^/        /'
  if ! ((APPLY)); then say "Dry run: nothing changed. Re-run with --apply."; fi
}

# ---------------------------------------------------------------- main

box_main() {
  [[ $EUID -eq 0 ]] || die "runs as root on the CI-box; start it from the laptop"
  cd /
  local step=${1:-} a args=()
  shift || true
  for a in "$@"; do if [[ $a == --apply ]]; then APPLY=1; else args+=("$a"); fi; done
  case "$step" in
    status)  cmd_status ;;
    prepare) cmd_prepare ;;
    add)     cmd_add "${args[@]}" ;;
    move)    cmd_move "${args[@]}" ;;
    undo)    cmd_undo "${args[@]}" ;;
    finish)  cmd_finish ;;
    dropins) cmd_dropins ;;
    *) die "usage: ci-box.sh status | prepare | add <repo> <name> <labels> | move <runner> | undo <runner> | finish | dropins  [--apply]" ;;
  esac
}

if [[ "${CI_BOX_REMOTE:-}" == 1 ]]; then box_main "$@"; else laptop_main "$@"; fi
