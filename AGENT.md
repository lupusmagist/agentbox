# AGENT.md

You are in **agentbox**: one rootless Podman container per project. This file is baked into the
image and read-only. It says what this environment is, so you don't spend turns discovering it.

**Run `agentbox-info` first.** It prints this box's live facts — network mode, home, project path,
limits, capabilities, what is on `PATH`. Everything below is the invariant it is reporting.

## Project context comes first

Before anything else, read what belongs to *this* project:

1. `~/project/AGENTS.md` — if present, it carries the project's own conventions and traps.
2. `~/project/docs/agent/INDEX.md` — if present, that is where to start.

If neither exists there is no extra context. Do not invent domain rules, and do not look for another
project's notes: nothing from another project is mounted here.

## What you can write

| Path | |
|---|---|
| `$AGENT_HOME` — your `$HOME`, `/home/agentbox` | **yours.** `.config`, `.local`, `bin`, `.cache`, `.history`, `.ssh`, everything |
| `~/project` | the project, bind-mounted from the host. **This is where work belongs** |
| `/tmp`, `/run`, `/var/tmp` | tmpfs — gone when the box stops |

On the host, `$AGENT_HOME` is this project's `$BOX_HOME` (`<project>/.agentbox/home/`), which was
seeded from the human's `$BASE_HOME` (`<checkout>/agent_home/`) when the box was created.

Everything else is read-only: `/` (the root filesystem), `/opt/agentbox` (the image),
`/opt/agentbox/pinned` if present. Writes outside the table fail with
`Read-only file system`; `/tmp` writes succeed and then disappear, which is worse.

`~/project/.agentbox/` is the host's view of your home (`$BOX_HOME`) — the same files you see at
`~`. You *can* write there, but don't: it exists so the human can see and copy your home, never as
project content. Never commit it, and never copy it into `~/project`.

Your home is **per project**. It was copied from the human's `$BASE_HOME` when this box was created,
and it belongs to this box alone: an edit never reaches another project. So if a tool or config you
need is missing, the answer is not "the other project has it" — it isn't mounted.

## Hard facts

| Fact | What it means for you |
|---|---|
| uid `1000`, `HOME=/home/agentbox`, user `agentbox` | you are never root |
| `sudo` absent, `su` present but needs a password you don't have | no privilege escalation, and no point trying |
| root filesystem read-only | install nothing outside your home; do not edit `/etc` |
| `CapEff` is `0000000000002000` — **only** `NET_RAW` | enough for `ping` and ICMP. Not enough for: `unshare -m` (`Operation not permitted`), `ip link add … type dummy` (`EPERM`), `ip tuntap` (no `/dev/net/tun`), `mount` ("must be superuser"), bridges, veth. Raw sockets reach this container's own network namespace, never a host interface |
| no `docker`, `podman`, `buildah`, no socket | there is no container runtime in here and no way to add one |
| no `systemctl`, `service`, no init | nothing to start or enable as a service |
| `qemu-system-x86_64` and `qemu-img` are installed; **no** `virsh`, `lxc-start`, `incus`, `systemd-nspawn`, `containerlab` | QEMU is the one virtualisation path here (see below). No libvirt socket, no container runtimes, no lab tooling |
| no `iptables`, `nft` | no packet filtering or NAT rules of your own |
| the host's `~/.ssh` is not here | `~/.ssh` exists only if the human put keys there |

If a task needs a container runtime, a multi-node lab topology or root, say so in one sentence and
propose the version that runs outside the box — a machine reachable over the network. Do not build a
half-working substitute and call it a test.

## QEMU, the one virtualisation path that works

`qemu-system-x86_64` (10.0.x) and `qemu-img` are installed. KVM is a device node, not a capability:

- **Lab box** (`agentbox-info` shows `lab 1`): `/dev/kvm` exists → `-accel kvm` runs near-native.
- **Default box**: no `/dev/kvm` → `-accel tcg`, roughly 10–30× slower. Fine for "does this image
  boot and answer ssh", useless for throughput or timing.
- **User-mode networking only.** There are no tap devices (`ip tuntap` cannot even open `/dev/net/tun`)
  and no bridges (`ip link add … type dummy` → `EPERM`), so a guest gets NAT plus explicit forwards:

  ```sh
  qemu-system-x86_64 -accel tcg -m 1024 -display none \
    -drive file=lab/disk.qcow2,if=virtio \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0
  # then: ssh -p 2222 user@127.0.0.1
  ```

- Keep disks in `~/project` (`./lab/disk.qcow2`) if they must survive the session; `/tmp` is wiped.
- There is no `virsh` and no libvirt socket: a VM on the host is reachable over the network, not
  through an API.

## Network

`agentbox-info` prints the mode, and it comes from the project's `.agentbox.toml` — you cannot change
it.

- **`online`** (the default) — outbound works: `curl`, `pip`, `npm`, `git fetch`, DNS. Inbound does
  not; nothing connects *to* this box.
- **`none`** — no route at all. Every one of those fails. The human chose that deliberately: do not
  retry, do not look for a proxy, and do not work around it. Work from what is vendored in the repo
  and list what you could not fetch.

## Tools

The image is deliberately minimal, so a missing tool is normal, not a broken box.

| Present | Absent (and why) |
|---|---|
| `bash` (no framework), `git`, `curl`, `ssh`/`scp`/`sftp`/`ssh-keygen`, `ping`, `traceroute`, `ss`/`netstat`/`ifconfig`, `fzf`, `rg`, `jq`, `less`, `vim` (not nvim), `python3` + `venv` + `pip`, `node` 22 + `npm`, `nvm`, `make`, `gcc`, `qemu-system-x86_64`, `qemu-img` | `apt`/`apt-get` exist but **need root**, so they cannot install anything; `uv`, `direnv`, `tmux`, `cargo`, `go`, `nvim` |

Installing something is fine — put it in your home, never in the project's dependency tree unless it
belongs there:

```sh
npm i -g <tool>                      # global installs land in ~/.npm-global; on PATH
nvm install 20 && nvm use 20         # other node versions; lands in ~/.nvm, no root
python3 -m venv .venv && .venv/bin/pip install <pkg>    # project-local, in ~/project
curl -fsSL <release-url> -o ~/.local/bin/<tool> && chmod +x ~/.local/bin/<tool>
```

`node` 22 and `npm` come from the image and are the default. `nvm` is seeded into `~/.nvm` on first
start, so `nvm install <version>` works and persists in this box; it does not touch the system node.
A global npm package is just `npm i -g <tool>`: the prefix (`~/.npm-global`) is configured in
`~/.config/npm/npmrc`, reached through `NPM_CONFIG_USERCONFIG`. It is deliberately not `~/.npmrc`,
because nvm refuses `nvm use` when that file (or `NPM_CONFIG_PREFIX`) sets a prefix. Both work, and
neither needs a flag, an alias or a `--prefix`. One difference from a host with nvm: the prefix is
shared, so `npm i -g` under `nvm use 20` still installs into `~/.npm-global`, not into the node
version's own directory — the tool stays on `PATH` whichever node you switch to.

`~/.local/bin` and `~/bin` are on `PATH` and win over the image. Project dependencies belong in the
project (`node_modules/`, `.venv/`) — do not hoist them into `~/.local`. List what you installed in
your summary; the human decides whether to promote it to their `$BASE_HOME` or add it to the image.

## Secrets and git

There is no secret injection. If a token is needed, it is either already in your environment or in a
file the human put in your home (`~/.ssh/…`, `~/.config/…`). Never write a credential into
`~/project`, and never commit one: the human's `agentbox home push` refuses credential-shaped files
for exactly this reason.

Commit freely. Commits are authored `Agent Box <agent@agentbox.local>` from the environment, on
purpose, so they stay filterable from the human's own. **You cannot push**: there are no credentials
here, and with `network = "none"` not even a route. Publishing is the human's action in their own
shell.

## Sanity check

```sh
agentbox-info                    # mode, home, project, limits, capabilities, tools
id -u                            # 1000
touch /probe 2>&1 | head -1      # "Read-only file system"
ip link add d0 type dummy        # "Operation not permitted"
ping -c1 -W2 1.1.1.1             # works when network = "online"
git -C ~/project status --short  # the project's current state
```

If any of those surprise you, re-read this file rather than probing further. Guessing at a sandbox
wastes turns; asking the human costs one.
