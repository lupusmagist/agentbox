#!/bin/sh
# agentbox entrypoint: prepare the writable home, then hand over to CMD/exec.
#
# $HOME is a bind mount owned by you, so everything here is ordinary file work
# that must stay idempotent: a box may be started many times.
set -eu

mkdir -p "$HOME/.cache" "$HOME/.local/bin" "$HOME/.local/share" \
         "$HOME/.history" "$HOME/bin" "${NVM_DIR:-$HOME/.nvm}" 2>/dev/null || true

# The default shell config, for a home that has none. -n: never overwrite what
# you already have, including anything that came from agent_home/.
for f in .bashrc .bash_profile; do
    [ -e "$HOME/$f" ] || cp -n "/opt/agentbox/skel/$f" "$HOME/$f" 2>/dev/null || true
done

# the agent contract lives in the image; link it into the home
for f in AGENT.md AGENTS.md; do
    [ -e "$HOME/$f" ] || ln -s /opt/agentbox/AGENT.md "$HOME/$f" 2>/dev/null || true
done

# nvm ships in the image, but its state has to be writable, so each home gets its
# own copy on first start. Without this, `nvm install 20` fails on a read-only
# root filesystem, which is the whole reason it is here.
if [ -d /opt/agentbox/pinned/nvm ] && [ ! -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    mkdir -p "${NVM_DIR:-$HOME/.nvm}" 2>/dev/null || true
    cp -R /opt/agentbox/pinned/nvm/. "${NVM_DIR:-$HOME/.nvm}/" 2>/dev/null || true
    chmod -R u+rwX "${NVM_DIR:-$HOME/.nvm}" 2>/dev/null || true
fi

if [ "${AGENTBOX_QUIET:-0}" != "1" ]; then
    printf 'agentbox: project=%s network=%s lab=%s\n' \
        "${AGENTBOX_PROJECT:-?}" "${AGENTBOX_NETWORK:-?}" "${AGENTBOX_LAB:-0}"
    printf 'agentbox: home=%s  project=%s/project\n' "$HOME" "$HOME"
    printf 'agentbox: read ~/AGENT.md (capabilities + limits), then project/AGENTS.md (project rules)\n'
    printf 'agentbox: run `agentbox-info` for live state\n'
fi

exec "$@"
