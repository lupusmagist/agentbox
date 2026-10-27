# The box's canonical PATH, for login shells.
#
# /etc/profile (and so every `bash -l`, `su -`, or tool that starts a login
# shell) rewrites PATH from scratch, which dropped /opt/agentbox/bin and left
# the order different from the one the image ENV gives non-login processes.
# This file puts it back, so `sh -c` and `bash -lc` agree.
#
# Order: what you installed, then the image's own tools, then the system.
#   ~/.npm-global/bin   npm i -g
#   ~/.local/bin        downloaded binaries
#   ~/bin               your scripts
#   /opt/agentbox/bin   agentbox-info
#   /opt/agentbox/pinned/bin
# nvm prepends its own version directory on `nvm use`, the one sanctioned
# exception; nothing else may reorder this list. Keep it identical to the ENV
# PATH in the Containerfile.
export PATH="/home/agentbox/.npm-global/bin:/home/agentbox/.local/bin:/home/agentbox/bin:/opt/agentbox/bin:/opt/agentbox/pinned/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
