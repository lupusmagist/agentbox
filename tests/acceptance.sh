#!/usr/bin/env bash
# End-to-end acceptance for agentbox: real boxes, real files, nothing mocked.
#
#   bash tests/acceptance.sh           # build assumed, cleans up after itself
#   KEEP=1 bash tests/acceptance.sh    # leave the boxes behind to inspect
#
# Uses a throwaway base under $WORK, so your own agent_home/ is never touched.
set -u
PASS=0; FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s   [%s]\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$(eval "$2" 2>&1 | head -1)"; fi; }
group(){ printf '\n== %s\n' "$1"; }

# No `exec` subcommand any more: run inside the box with podman, addressing it by
# the label on the project directory. Keeps the checks readable.
boxname(){ podman ps -a --filter "label=io.agentbox.path=$PWD" --format '{{.Names}}'; }
XIN(){ [ "${1:-}" = "--" ] && shift; podman exec -e TERM=dumb "$(boxname)" "$@"; }
# Enter the box through a pty, then leave. Needed because `agentbox` only takes
# over the terminal when it has one, which is exactly the path that stops the box.
leave_box(){ printf 'exit\n' | ( cd "$1" && python3 -c 'import pty,sys; sys.exit(pty.spawn([sys.argv[1]]))' "$AB" ) >/dev/null 2>&1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
AB=${AGENTBOX_BIN:-$REPO/bin/agentbox}
WORK="${TMPDIR:-/tmp}/agentbox-acceptance"
A="$WORK/demoX"; B="$WORK/other"; BASE="$WORK/base"
export AGENTBOX_HOME_BASE="$BASE"      # never write into the real agent_home/
export AGENTBOX_LOCAL="$WORK/local.toml"   # ...nor a real local.toml in the checkout
# XDG_DATA_HOME is deliberately NOT redirected: podman keeps its storage under it,
# and a storage tree inside $WORK is full of root-owned files that the user cannot
# delete afterwards (the suite would leave an undeletable directory behind).

# tear down first: deleting a project dir under a live container strips its
# SELinux label and the container can no longer start a process in it
for d in "$A" "$B" "$WORK/amb/one/delta" "$WORK/amb/two/delta"; do
    (cd "$d" 2>/dev/null && "$AB" rm >/dev/null 2>&1)
done
rm -rf "$WORK"; mkdir -p "$A" "$B"

printf 'schema = 1\nnetwork = "none"\n' > "$A/.agentbox.toml"
printf 'schema = 1\nnetwork = "none"\n' > "$B/.agentbox.toml"
(cd "$A" && git init -q && echo hi > README.md)

# a base to seed from: one dotfile, one config, one CLI and one key (never pushed)
mkdir -p "$BASE/.config/demo" "$BASE/.local/bin" "$BASE/.ssh"
echo "from-base" > "$BASE/.config/demo/conf"
printf '#!/bin/sh\necho base-tool\n' > "$BASE/.local/bin/basetool"
chmod +x "$BASE/.local/bin/basetool"
echo "PRIVATE KEY" > "$BASE/.ssh/id_ed25519"
# your own shell config: it must win over the skel default
printf 'export BASETEST=from-base\n' > "$BASE/.bashrc"

group "creation: a box whose \$HOME is the project's own"
(cd "$A" && "$AB" </dev/null >/dev/null 2>&1)
NAME="agentbox-demox-$(printf %s "$A" | sha256sum | cut -c1-8)"
check "container runs, name derived from the path" \
  "podman ps --format '{{.Names}}' | grep -qx $NAME"
check "\$HOME is /home/agentbox" \
  "[ \"\$(cd $A && XIN sh -c 'echo \$HOME')\" = /home/agentbox ]"
check "the shell starts in ~/project" \
  "[ \"\$(cd $A && XIN pwd)\" = /home/agentbox/project ]"
check "project files are visible at ~/project" \
  "(cd $A && XIN test -f ./README.md)"
check "the box reports its home and project" \
  "(cd $A && XIN agentbox-info | grep -q 'code        /home/agentbox/project')"

group "the project config is mandatory, and networking is on by default"
C="$WORK/fresh"; rm -rf "$C"; mkdir -p "$C"; echo x > "$C/app.py"; (cd "$C" && git init -q .)
(cd "$C" && "$AB" status >/dev/null 2>&1)
check "status never writes the config" "[ ! -e $C/.agentbox.toml ]"
(cd "$C" && "$AB" </dev/null >/dev/null 2>&1)
check "starting a box writes the config before it runs" "[ -e $C/.agentbox.toml ]"
check "the new config defaults to network online" \
  "grep -qx 'network = \"online\"' $C/.agentbox.toml"
check "so the box has a default route" \
  "(cd $C && XIN sh -c 'ip route | grep -q default')"
check "ping works (raw socket, the one capability)" \
  "(cd $C && XIN sh -c 'ping -c1 -W3 1.1.1.1 >/dev/null 2>&1')"
check "npm can install a global CLI into the home" \
  "(cd $C && XIN sh -c 'npm i -g --prefix \$HOME/.npm-global cowsay >/dev/null 2>&1 && test -x \$HOME/.npm-global/bin/cowsay')"
check "nvm installs another node version into the home" \
  "(cd $C && XIN sh -c '. \$HOME/.nvm/nvm.sh && nvm install 18 >/dev/null 2>&1 && nvm use 18 >/dev/null 2>&1 && node -v' | grep -q '^v18')"
check "traceroute works too" \
  "(cd $C && XIN sh -c 'traceroute -n -m1 1.1.1.1 2>&1 | head -1' | grep -q 'traceroute to')"
printf 'schema = 1\nnetwork = "none"\n' > "$C/.agentbox.toml"
(cd "$C" && "$AB" </dev/null >/dev/null 2>&1)
check "turning it off in the file disconnects the box" \
  "(cd $C && ! XIN sh -c 'ip route | grep -q default')"
(cd "$C" && "$AB" rm >/dev/null 2>&1); rm -rf "$C"

group "home: seeded from the base, writable, per project"
check "base config arrived in the box" \
  "(cd $A && XIN sh -c 'grep -qx from-base ~/.config/demo/conf')"
check "base CLI arrived and is executable" \
  "(cd $A && XIN sh -c '~/.local/bin/basetool' | grep -qx base-tool)"
check "a key in the base is never seeded into a box" \
  "(cd $A && XIN sh -c 'test ! -e ~/.ssh')"
check "writes to the home land on the host, inside the project" \
  "(cd $A && XIN sh -c 'echo written > ~/.config/demo/mine') && \
   grep -qx written $A/.agentbox/home/.config/demo/mine"
check "the home is writable inside the box" \
  "(cd $A && XIN sh -c 'echo x > ~/.config/ok && test -s ~/.config/ok')"
check "the box has a .bashrc" \
  "(cd $A && XIN sh -c 'test -s ~/.bashrc')"
check "the base's .bashrc wins over the skel default" \
  "(cd $A && XIN bash -ic 'echo \$BASETEST' 2>/dev/null | grep -qx from-base)"
check "bash is the login shell" \
  "(cd $A && XIN sh -c 'getent passwd 1000 | cut -d: -f7' | grep -qx /bin/bash)"
check "bash starts without errors" \
  "(cd $A && XIN bash -ic 'exit 0' 2>/dev/null)"
check "the image ships no zsh" \
  "! podman run --rm --entrypoint sh localhost/agentbox/base:current -c 'command -v zsh'"
check ".cache lives inside the home" \
  "[ -d $A/.agentbox/home/.cache ]"
check "files are owned 1000:1000" \
  "[ \"\$(stat -c %u:%g $A/.agentbox/home/.config/demo/conf)\" = 1000:1000 ]"

group "home: git safety"
check ".agentbox/ does not show up in git status" \
  "! (cd $A && git status --porcelain | grep -q '.agentbox/')"
check ".git/info/exclude carries the pattern" \
  "grep -qx '.agentbox/' $A/.git/info/exclude"
(cd "$A" && echo leak > .agentbox/leak.txt && git add -f .agentbox/leak.txt >/dev/null 2>&1)
(cd "$A" && "$AB" status >/dev/null 2>&1); rc=$?
check "a tracked box home is refused (exit 2)" "[ $rc -eq 2 ]"
check "the refusal names the fix" \
  "(cd $A && \"$AB\" status 2>&1 | grep -q 'git rm -r --cached')"
(cd "$A" && git rm -q --cached .agentbox/leak.txt >/dev/null 2>&1; rm -f .agentbox/leak.txt)

group "home push: box -> base, scoped and refusing secrets"
(cd "$A" && XIN sh -c 'echo pushed > ~/.config/demo/pushed; \
   mkdir -p ~/.cache && echo junk > ~/.cache/junk.bin; \
   ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C t 2>/dev/null || true')
check "push --dry-run lists changes" \
  "(cd $A && \"$AB\" home push --dry-run 2>&1 | grep -q '.config/demo/pushed')"
check "push --dry-run copies nothing" \
  "! [ -e $BASE/.config/demo/pushed ]"
(cd "$A" && "$AB" home push > $WORK/push.log 2>&1)
check "push copied the change into the base" \
  "grep -qx pushed $BASE/.config/demo/pushed"
check "push never copies .ssh (base key untouched)" \
  "[ \"\$(cat $BASE/.ssh/id_ed25519)\" = PRIVATE\ KEY ] && [ \"\$(ls $BASE/.ssh | wc -l)\" = 1 ]"
check "push never copies .cache" \
  "! [ -e $BASE/.cache/junk.bin ]"
check "push says existing boxes are unaffected" \
  "grep -qi 'existing boxes' $WORK/push.log"

group "a new box inherits the base; an existing one does not"
(cd "$B" && "$AB" </dev/null >/dev/null 2>&1)
check "new box has what was pushed" \
  "(cd $B && XIN sh -c 'grep -qx pushed ~/.config/demo/pushed')"
(cd "$A" && XIN sh -c 'echo only-a > ~/.config/demo/only-a' >/dev/null 2>&1)
check "the other project cannot see it" \
  "(cd $B && XIN sh -c 'test ! -e ~/.config/demo/only-a')"
(cd "$A" && "$AB" home push >/dev/null 2>&1)
check "pushing again reaches the base, not the existing box" \
  "[ -e $BASE/.config/demo/only-a ] && (cd $B && XIN sh -c 'test ! -e ~/.config/demo/only-a')"
check "sync --dry-run reports the gap" \
  "(cd $B && \"$AB\" home sync --dry-run 2>&1 | grep -q '.config/demo/only-a')"
(cd "$B" && "$AB" home sync >/dev/null 2>&1)
check "sync closes the gap" \
  "(cd $B && XIN sh -c 'grep -qx only-a ~/.config/demo/only-a')"
(cd "$B" && XIN sh -c 'echo mine > ~/.config/demo/pushed' >/dev/null 2>&1)
(cd "$B" && "$AB" home sync >/dev/null 2>&1)
check "sync keeps a file the box changed" \
  "(cd $B && XIN sh -c 'grep -qx mine ~/.config/demo/pushed')"
(cd "$B" && "$AB" home sync --force >/dev/null 2>&1)
check "sync --force overwrites it from the base" \
  "(cd $B && XIN sh -c 'grep -qx pushed ~/.config/demo/pushed')"

group "sandbox: what a box cannot do"
check "rootfs is read-only" \
  "(cd $A && XIN sh -c 'touch /nope' 2>&1 | grep -q 'Read-only file system')"
check "CapEff is exactly NET_RAW" \
  "[ \"\$(cd $A && XIN awk '/^CapEff/{print \$2}' /proc/self/status)\" = 0000000000002000 ]"
check "not root" "[ \"\$(cd $A && XIN id -u)\" = 1000 ]"
check "no network when network = none" \
  "! (cd $A && XIN curl -sS -m 3 -o /dev/null https://example.com)"
check "no docker socket" \
  "(cd $A && XIN sh -c 'test ! -e /var/run/docker.sock')"
check "no /dev/kvm in a default box" \
  "(cd $A && XIN sh -c 'test ! -e /dev/kvm')"
check "the host ~/.ssh is not mounted" \
  "! podman inspect $NAME --format '{{range .Mounts}}{{.Source}} {{end}}' | grep -q \"$HOME/.ssh\""
(cd $A && XIN sh -c "echo probe > ~/project/probe.txt")
check "a project cannot see another project's files" \
  "(cd $B && XIN sh -c 'test ! -e ~/project/probe.txt')"

group "tooling: pinned, on PATH, and offline-capable"
check "no agent CLI is baked" \
  "(cd $A && XIN sh -c 'for t in pi claude codex opencode; do command -v \$t && exit 1; done; true')"
check "qemu and qemu-img are installed" \
  "(cd $A && XIN sh -c 'qemu-system-x86_64 --version && qemu-img --version')"
check "network tooling is installed" \
  "(cd $A && XIN sh -c 'for t in ping traceroute netstat ifconfig ss; do command -v \$t || exit 1; done')"
check "vim is the editor (no nvim)" \
  "(cd $A && XIN sh -c 'command -v vim; ! command -v nvim')"
check "the box image carries only the essentials" \
  "(cd $A && XIN sh -c 'for t in uv direnv tmux cargo go nvim zsh; do command -v \$t && exit 1; done; true')"
check "node 22 comes from the image" \
  "(cd $A && XIN sh -c 'node -v' | grep -q '^v22\\.')"
check "nvm is seeded and runs" \
  "(cd $A && XIN sh -c 'test -s \$HOME/.nvm/nvm.sh && . \$HOME/.nvm/nvm.sh && nvm --version' | grep -qE '^0\\.')"
check "no global npm prefix is configured (it would break nvm)" \
  "(cd $A && XIN sh -c 'test -z \"\$(npm config get prefix 2>/dev/null | grep npm-global)\"')"
check "a commit works with the environment identity" \
  "(cd $A && XIN sh -c 'echo x > committed.txt && git add committed.txt && \
     git commit -qm probe && git log -1 --format=%ae' | grep -qx agent@agentbox.local)"
check "no git credential helper" \
  "(cd $A && XIN sh -c 'test -z \"\$(git config --get credential.helper)\"')"

group "agent contract"
check "~/AGENT.md matches the repo" \
  "(cd $A && XIN sh -c 'sha256sum ~/AGENT.md' | cut -d' ' -f1 | grep -qx \$(sha256sum $REPO/AGENT.md | cut -d' ' -f1))"
check "~/AGENTS.md is present too" "(cd $A && XIN sh -c 'test -s ~/AGENTS.md')"
check "AGENT.md is not writable" \
  "(cd $A && XIN sh -c 'echo x >> ~/AGENT.md' 2>&1 | grep -qi 'denied\|Read-only')"
check "agentbox-info reports the network mode" \
  "(cd $A && XIN agentbox-info | grep -q 'network     none')"
check "agentbox-info explains the cache is disposable" \
  "(cd $A && XIN agentbox-info | grep -q 'never pushed to the base')"

group "config: tighten-only, drift detection, secrets"
printf 'schema = 1\nnetwork = "none"\nmemory = "2g"\n' > "$A/.agentbox.toml"
(cd "$A" && "$AB" </dev/null >/dev/null 2>&1)   # reconciles the box with the config
check "a tightened memory limit is enforced" \
  "[ \"\$(cd $A && XIN cat /sys/fs/cgroup/memory.max)\" = 2147483648 ]"
printf 'schema = 1\nnetwork = "none"\nmemory = "64g"\n' > "$A/.agentbox.toml"
(cd "$A" && "$AB" status >/dev/null 2>&1); rc=$?
check "loosening a limit exits 2" "[ $rc -eq 2 ]"
check "the refusal names the ceiling" \
  "(cd $A && \"$AB\" status 2>&1 | grep -q 'would loosen the sandbox')"
printf 'schema = 1\nnetwork = "none"\n' > "$A/.agentbox.toml"
check "--network online overrides for one run" \
  "[ \"\$(cd $A && \"$AB\" --network online status | awk '/^network/{print \$2}')\" = online ]"
(cd "$A" && XIN true >/dev/null 2>&1)
(cd "$A" && printf 'schema = 1\nnetwork = "none"\nfoo = 1\n' > .agentbox.toml && "$AB" status >/dev/null 2>&1); rc=$?
check "an unknown project key exits 2" "[ $rc -eq 2 ]"
printf 'schema = 1\nnetwork = "none"\n' > "$A/.agentbox.toml"

group "state lives in \$APP, not in \$USER_HOME"
printf 'schema = 1\n[sandbox]\nmemory = "2g"\n' > "$WORK/local.toml"
check "local.toml supplies the ceiling" \
  "(cd $A && \"$AB\" status 2>&1 | grep -qE 'memory +2g')"
mkdir -p "$WORK/tight" && printf 'schema = 1\nnetwork = "none"\nmemory = "8g"\n' > "$WORK/tight/.agentbox.toml"
(cd "$WORK/tight" && "$AB" status >/dev/null 2>&1); rc=$?
check "the project may not exceed a local.toml ceiling (exit 2)" "[ $rc -eq 2 ]"
check "the refusal still names the ceiling" \
  "(cd $WORK/tight && \"$AB\" status 2>&1 | grep -q 'would loosen the sandbox')"
printf 'schema = 1\n[sandbox]\nmemory = "2g"\nmemroy = "1g"\n' > "$WORK/local.toml"
(cd "$A" && "$AB" status >/dev/null 2>&1); rc=$?
check "an unknown local.toml [sandbox] key exits 2" "[ $rc -eq 2 ]"
check "the refusal names local.toml" \
  "(cd $A && \"$AB\" status 2>&1 | grep -q 'local.toml')"
printf 'schema = 1\n[sandbox]\nmemory = "2g"\n' > "$WORK/local.toml"
printf 'schema = 1\n[sandbox]\nmemory = "2g"\n' > "$WORK/unreadable.toml"
chmod 000 "$WORK/unreadable.toml"
(cd "$A" && AGENTBOX_LOCAL="$WORK/unreadable.toml" "$AB" status >/dev/null 2>&1); rc=$?
check "an unreadable local.toml exits 2, not a traceback" "[ $rc -eq 2 ]"
chmod 644 "$WORK/unreadable.toml"
FAKE="$WORK/fakehome"; mkdir -p "$FAKE/.config/agentbox" "$FAKE/.local/share/agentbox"
check "a missing local.toml is simply absent config" \
  "(cd $A && AGENTBOX_LOCAL=$WORK/nope.toml \"$AB\" status 2>&1 | grep -qE 'memory +4g')"
check "settings never come from \$USER_HOME" \
  "(cd $A && HOME=$FAKE \"$AB\" status 2>&1 | grep -qE 'network +none')"
printf '[sandbox]\nmemory = "1g"\n' > "$FAKE/.config/agentbox/config.toml"
check "a leftover \$USER_HOME config exits 2" \
  "(cd $A && HOME=$FAKE \"$AB\" status >/dev/null 2>&1; [ \$? -eq 2 ])"
check "the refusal names local.toml and the file to move" \
  "(cd $A && HOME=$FAKE \"$AB\" status 2>&1 | grep -q 'local.toml' && \
    cd $A && HOME=$FAKE \"$AB\" status 2>&1 | grep -q '.config/agentbox/config.toml')"
check "doctor is still reachable with a leftover config" \
  "(cd $A && HOME=$FAKE \"$AB\" doctor 2>&1 | grep -q 'no leftovers') && \
   [ \"\$(cd $A && HOME=$FAKE \"$AB\" doctor >/dev/null 2>&1; echo \$?)\" != 2 ]"
check "cleanup commands still work with a leftover config" \
  "(cd $A && HOME=$FAKE \"$AB\" ls >/dev/null 2>&1)"
rm -f "$FAKE/.config/agentbox/config.toml"
check "the base is \$APP/agent_home when no override is set" \
  "(cd $A && env -u AGENTBOX_HOME_BASE \"$AB\" home | head -1 | grep -qx '$REPO/agent_home')"

group "leaving the shell releases the box"
(cd "$A" && "$AB" </dev/null >/dev/null 2>&1)
check "the box is running before we enter" \
  "[ \"\$(cd $A && podman inspect \$(boxname) --format '{{.State.Status}}')\" = running ]"
leave_box "$A"
check "exiting the shell stops the box" \
  "[ \"\$(cd $A && podman inspect \$(boxname) --format '{{.State.Status}}')\" = exited ]"
check "the next agentbox starts it again" \
  "(cd $A && \"$AB\" </dev/null >/dev/null 2>&1) && \
   [ \"\$(cd $A && podman inspect \$(boxname) --format '{{.State.Status}}')\" != exited ]"
check "the interactive shell loads the base .bashrc" \
  "(cd $A && XIN bash -ic 'echo -n \$BASETEST' 2>/dev/null | grep -qx from-base)"
check "a login shell loads it too, via .bash_profile" \
  "(cd $A && XIN bash -lc 'echo -n \$BASETEST' 2>/dev/null | grep -qx from-base)"

group "history: per box, survives recreation"
(cd "$A" && XIN sh -c 'echo "echo marker-a" >> ~/.history/bash_history')
(cd "$A" && "$AB" rm >/dev/null 2>&1 && "$AB" </dev/null >/dev/null 2>&1)
check "history survived rm + recreate" \
  "(cd $A && XIN sh -c 'grep -q marker-a ~/.history/bash_history')"
check "the other project has its own history" \
  "! (cd $B && XIN sh -c 'grep -q marker-a ~/.history/bash_history')"

group "reset: one command back to a fresh home"
(cd "$B" && "$AB" home reset --yes >/dev/null 2>&1)
check "reset deleted the box home" "[ ! -d $B/.agentbox/home ]"
check "reset removed the container that held it" \
  "! podman ps -a --format '{{.Names}}' | grep -q agentbox-other"
(cd "$B" && "$AB" </dev/null >/dev/null 2>&1)
check "the next start re-seeds it from the base" \
  "(cd $B && XIN sh -c 'grep -qx from-base ~/.config/demo/conf')"

group "selection: any box by name, from anywhere"
cd /
TABLE=$("$AB" ls)
case "$TABLE" in
  NAME*) ok "ls prints a NAME column" ;;
  *)     bad "ls prints a NAME column" "$(printf '%s' "$TABLE" | head -1)" ;;
esac
BOXA=$(printf '%s\n' "$TABLE" | awk '$2=="demox"{print $1}' | head -1)
[ -n "$BOXA" ] && ok "ls exposes the container name ($BOXA)" \
  || bad "ls exposes the container name"
"$AB" status demoX >/dev/null 2>&1 && ok "status by project name from /" \
  || bad "status by project name from /"
"$AB" stop "$BOXA" >/dev/null 2>&1 && ok "stop by container name from /" \
  || bad "stop by container name from /"
[ "$(podman inspect "$BOXA" --format '{{.State.Status}}' 2>/dev/null)" = exited ] \
  && ok "the box is exited after stop" || bad "the box is exited after stop"
"$AB" rm demoX >/dev/null 2>&1 && ok "rm by project name from /" \
  || bad "rm by project name from /"
podman inspect "$BOXA" >/dev/null 2>&1 && bad "the box is gone after rm" \
  || ok "the box is gone after rm"
check "rm left the project's home alone" "[ -d $A/.agentbox/home ]"
"$AB" stop nosuchbox >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an unknown selector exits 2" || bad "an unknown selector exits 2" "rc=$rc"
"$AB" stop nosuchbox 2>&1 | grep -q "no box matches" \
  && ok "the refusal says what exists" || bad "the refusal says what exists"

mkdir -p "$WORK/amb/one/delta" "$WORK/amb/two/delta"
for d in "$WORK/amb/one/delta" "$WORK/amb/two/delta"; do
    (cd "$d" && printf 'schema = 1\n' > .agentbox.toml && "$AB" </dev/null >/dev/null 2>&1)
done
cd /
"$AB" rm delta >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an ambiguous project name exits 2" \
  || bad "an ambiguous project name exits 2" "rc=$rc"
"$AB" rm delta 2>&1 | grep -q "belong to projects called" \
  && ok "the ambiguity message lists both boxes" || bad "the ambiguity message lists both boxes"
for n in $(printf '%s\n' "$("$AB" ls)" | awk '$2=="delta"{print $1}'); do
    "$AB" rm "$n" >/dev/null 2>&1
done

group "an empty base falls back to the image defaults"
E="$WORK/empty"; mkdir -p "$E"; printf 'schema = 1\n' > "$E/.agentbox.toml"
(cd "$E" && AGENTBOX_HOME_BASE="$WORK/nobase" "$AB" </dev/null >/dev/null 2>&1)
check "a box with no base still gets a shell config" \
  "(cd $E && AGENTBOX_HOME_BASE=$WORK/nobase XIN sh -c 'grep -q agentbox ~/.bashrc')"
check "and it starts in bash" \
  "(cd $E && AGENTBOX_HOME_BASE=$WORK/nobase XIN bash -ic 'exit 0' 2>/dev/null)"
check "the skel .bashrc defines the npmg helper" \
  "(cd $E && AGENTBOX_HOME_BASE=$WORK/nobase XIN bash -ic 'type -t npmg' 2>/dev/null | grep -qx function)"
check "the skel history settings are in effect" \
  "(cd $E && AGENTBOX_HOME_BASE=$WORK/nobase XIN bash -ic 'echo -n \$HISTFILE' 2>/dev/null | grep -q .history/bash_history)"
check "a login shell picks up the skel .bashrc too" \
  "(cd $E && AGENTBOX_HOME_BASE=$WORK/nobase XIN bash -lc 'echo -n \$HISTFILE' 2>/dev/null | grep -q .history/bash_history)"
(cd "$E" && AGENTBOX_HOME_BASE="$WORK/nobase" "$AB" rm >/dev/null 2>&1)

group "secrets: nothing credential-shaped is ever promoted to the base"
(cd "$A" && "$AB" </dev/null >/dev/null 2>&1)   # the selection group removed this box
(cd "$A" && XIN sh -c 'printf "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz\n" > ~/.config/demo/token.env; \
   printf "just a note\n" > ~/.config/demo/notes.txt')
(cd "$A" && "$AB" home push > "$WORK/push2.log" 2>&1)
check "a file that looks like a credential is not pushed" \
  "[ ! -e $BASE/.config/demo/token.env ]"
check "the ordinary file next to it is pushed" "[ -e $BASE/.config/demo/notes.txt ]"
check "push says why it refused" "grep -qi 'looks like a secret' $WORK/push2.log"
check "the refusal is visible in a dry run too" \
  "(cd $A && \"$AB\" home push --dry-run 2>&1 | grep -qi 'looks like a secret')"

group "doctor"
LOCKHASH=$(sha256sum "$REPO/tools.lock" | cut -c1-12)
check "the image carries the lock hash as a label" \
  "[ \"\$(podman image inspect --format '{{index .Config.Labels \"io.agentbox.lock\"}}' localhost/agentbox/base:current)\" = $LOCKHASH ]"
check "doctor checks the label, not a state file" \
  "(cd $A && \"$AB\" doctor 2>&1 | grep -q 'image label matches lock hash')"
FAKE="$WORK/fakehome"; mkdir -p "$FAKE/.local/share/agentbox"
check "old \$USER_HOME state is reported by doctor" \
  "(cd $A && HOME=$FAKE \"$AB\" doctor 2>&1 | grep -qiE 'warn +6 .*leftover')"
check "old \$USER_HOME state is not fatal" \
  "(cd $A && HOME=$FAKE \"$AB\" doctor 2>&1 | grep -E '^warn +6 ' >/dev/null)"
"$AB" doctor >/dev/null 2>&1 && ok "doctor passes with test boxes present" \
  || bad "doctor passes with test boxes present" "$("$AB" doctor 2>&1 | grep FAIL | head -1)"

echo
if [ "${KEEP:-0}" != "1" ]; then
    for d in "$A" "$B"; do (cd "$d" 2>/dev/null && "$AB" rm >/dev/null 2>&1); done
    rm -rf "$WORK"
fi
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
