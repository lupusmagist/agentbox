# agentbox base image. Built by `agentbox build`; every ARG comes from tools.lock.
#
# Minimal on purpose. This image carries the OS, a small set of essential
# command-line tools, and the agent CLI. Everything that is a preference --
# editor plugins, shell framework, version managers, language toolchains -- is
# installed by the operator into their own $HOME (`agent_home/`, copied per
# project and mounted at /home/agentbox). See DESIGN.md 16.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Tool pins are declared next to the layer that consumes them, never above the
# apt block: an ARG added at the top changes the instruction stream and throws
# away the (multi-minute) package layer every time a tool is added.
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

# The package list is a build argument so that tools.lock is the single source of
# truth. Editing it here instead would leave the lockfile describing an image that
# does not exist, which is how a "change" becomes a no-op that still succeeds.
ARG PACKAGES
RUN test -n "${PACKAGES}" || (echo "PACKAGES build arg is empty" >&2; exit 1); \
    apt-get update && apt-get install -y --no-install-recommends ${PACKAGES} \
 && rm -rf /var/lib/apt/lists/* \
 && find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec chmod a-s {} + || true

# uid 1000 must exist and be called 'agentbox'. Base images often ship their own
# uid 1000 (node has 'node'), so rename whatever is there instead of colliding.
RUN set -eux; \
    if getent group 1000 >/dev/null; then \
        groupmod -n agentbox "$(getent group 1000 | cut -d: -f1)" || true; \
    else groupadd -g 1000 agentbox; fi; \
    if getent passwd 1000 >/dev/null; then \
        usermod -l agentbox -d /home/agentbox -m -s /bin/bash \
            "$(getent passwd 1000 | cut -d: -f1)" || true; \
    else useradd -u 1000 -g 1000 -M -d /home/agentbox -s /bin/bash agentbox; fi

# HOME is a mount point at runtime; the image only provides the mount point
# itself plus the directory the project appears in, so nothing has to be
# created inside a bind-mounted path (those land root-owned).
RUN mkdir -p /home/agentbox/project /opt/agentbox/pinned/bin /opt/agentbox/bin \
             /opt/agentbox/skel \
 && chown -R 1000:1000 /home/agentbox

# --- no agent CLI is baked ---------------------------------------------------
# Which agent you run is your choice, and every agent is installable into a
# home: `npm i -g <agent>`, a release binary in ~/.local/bin, a venv. Baking one
# would publish the author's choice as everybody's default (DESIGN.md 16).

# --- nvm: other node versions, pinned by commit ------------------------------
# node 22 itself is the base image's own. This is here so `nvm install 20` works
# without root and without fetching nvm from the internet inside a sandbox.
ARG NVM_COMMIT
RUN git clone -q https://github.com/nvm-sh/nvm /opt/agentbox/pinned/nvm \
 && git -C /opt/agentbox/pinned/nvm checkout -q ${NVM_COMMIT} \
 && rm -rf /opt/agentbox/pinned/nvm/.git \
 && test -s /opt/agentbox/pinned/nvm/nvm.sh

# --- shell: plain bash, no framework ----------------------------------------
# bash comes with the base image. No zsh, no oh-my-zsh, no theme: a shell
# environment is a preference and belongs in agent_home/ (§16).
COPY dotfiles/bashrc /opt/agentbox/skel/.bashrc
# so that `bash -l` (or anything that starts a login shell) also gets .bashrc
COPY dotfiles/bash_profile /opt/agentbox/skel/.bash_profile
COPY AGENT.md /opt/agentbox/AGENT.md
COPY image/ /opt/agentbox/

RUN chmod 0755 /opt/agentbox/entrypoint.sh /opt/agentbox/bin/agentbox-info

ENV HOME=/home/agentbox USER=agentbox LOGNAME=agentbox SHELL=/bin/bash \
    NVM_DIR=/home/agentbox/.nvm \
    XDG_CACHE_HOME=/home/agentbox/.cache \
    PATH=/opt/agentbox/bin:/opt/agentbox/pinned/bin:/home/agentbox/.local/bin:/home/agentbox/bin:/home/agentbox/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /home/agentbox/project
USER 1000:1000
ENTRYPOINT ["/opt/agentbox/entrypoint.sh"]
CMD ["sleep", "infinity"]
