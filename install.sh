#!/usr/bin/env bash
# agentbox installer: verifies prerequisites, links the CLI onto PATH, tells you
# what to do next. It does not need root and does not touch your dotfiles.
#
#   ./install.sh                 # link this checkout into ~/.local/bin
#   ./install.sh --bin ~/bin     # link somewhere else on your PATH
#   ./install.sh --no-link       # only run the checks (e.g. for CI)
#
# To keep a stable install separate from your working copy, clone once and run
# this from that clone; then develop elsewhere and `git pull` here to upgrade.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LINK=1
FAILED=0

usage() {
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bin)     BIN_DIR="${2:?--bin needs a directory}"; shift 2 ;;
        --no-link) LINK=0; shift ;;
        -h|--help) usage 0 ;;
        *)         echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$1"; FAILED=1; }

echo "Checking prerequisites"

# --- python 3.11+ (tomllib) -------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import tomllib' 2>/dev/null; then
        ok "python3 $(python3 -c 'import platform;print(platform.python_version())')"
    else
        bad "python3 is $(python3 -V 2>&1 | awk '{print $2}'); agentbox needs 3.11+ (tomllib)"
    fi
else
    bad "python3 not found (dnf install python3)"
fi

# --- podman, rootless ------------------------------------------------------
if command -v podman >/dev/null 2>&1; then
    ok "podman $(podman --version 2>/dev/null | awk '{print $3}')"
    if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
        ok "rootless podman"
    else
        bad "podman is running as root. agentbox requires rootless podman: it is the
        security boundary, and rootful podman leaks root-owned files into projects."
    fi
else
    bad "podman not found (dnf install podman)"
fi

# --- subordinate uid/gid range --------------------------------------------
if [ -r /etc/subuid ] && grep -q "^${USER}:" /etc/subuid; then
    ok "subuid range for $USER"
else
    warn "$USER has no subuid range; containers will fail to start.
        Fix: sudo usermod --add-subuids 524288-589823 --add-subgids 524288-589823 $USER
        then log out and back in."
fi

# --- cgroups v2 ------------------------------------------------------------
if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ]; then
    ok "cgroups v2"
else
    warn "cgroups v1 detected; memory/pid limits may behave differently"
fi

# --- SELinux ---------------------------------------------------------------
if command -v getenforce >/dev/null 2>&1; then
    mode=$(getenforce 2>/dev/null || echo Unknown)
    case "$mode" in
        Enforcing) ok "SELinux enforcing" ;;
        Permissive) warn "SELinux permissive; the :z relabels are harmless, but you lose a layer" ;;
        *)         warn "SELinux $mode" ;;
    esac
fi

# --- git (for 'agentbox home push' and the checkout itself) ----------------
if command -v git >/dev/null 2>&1; then
    ok "git $(git --version | awk '{print $3}')"
else
    warn "git not found; 'agentbox home push' will not work"
fi

# --- optional -------------------------------------------------------------
command -v skopeo >/dev/null 2>&1 && ok "skopeo (agentbox update)" \
    || warn "skopeo not found; 'agentbox update' needs it (dnf install skopeo)"

if [ "$FAILED" -ne 0 ]; then
    echo
    echo "Fix the failures above and re-run ./install.sh"
    exit 1
fi

# --- link ------------------------------------------------------------------
if [ "$LINK" -eq 1 ]; then
    mkdir -p "$BIN_DIR"
    ln -sfn "$REPO/bin/agentbox" "$BIN_DIR/agentbox"
    echo
    ok "linked $BIN_DIR/agentbox -> $REPO/bin/agentbox"
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR is not on PATH; add it to your shell profile" ;;
    esac
fi

cat <<EOF

Next:

  agentbox build          # build the base image (~10 min the first time)
  agentbox doctor         # 12 checks: image, volumes, mounts, secrets, ssh
  cd ~/projects/<a repo>
  agentbox                # create the box and enter it

Optional: build your \$BASE_HOME, the home every new box starts from. Do it
inside a box, so nothing in your own \$USER_HOME is involved:

  cd <a project> && agentbox     # create a box and enter it
  ...install your tools, edit ~/.bashrc, npm i -g <agent>...
  exit
  agentbox home push             # promote that to \$BASE_HOME for NEW boxes

\$BASE_HOME lives at this checkout's agent_home/ and is gitignored, so a
git pull never overwrites it. Existing boxes keep their own copy; inside one,
'agentbox home sync' brings them up to date.
EOF
