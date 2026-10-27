# agentbox

Hi, human here. This is a small app me, pi and Deepseek vide coded. It might(probibly does) have some issues but mostly it looks to be working.
This app tries to find middle ground between everything being fixed in the container, ease of configuration of the enviroment and persitance.  

Only the information that you put into the container is availible to the agent.

You run 'agentbox' in your project directory and your project directory gets linked to a container where you can run your AI agent.
Only one container is made for all your projects, the container $HOME is swapped out for the .agentbox directory that gets created in your project root on start in the project dir. Add the .agentbox/ and .agentbox to your project .gitignore, you dont need to keep it.

The initial container $HOME is copied from the agent_home directory in the agentbox app directory into the container. That means that any apps/config you need in the container you can add into the agent_home dir. Thats the hard way.  The easy way is to make a blank project, agentbox into it, load everything you normally use and then 'agentbox push' this config to the agent_home.  

Now every project you start will copy your config/apps into the container. (Existing projects=existing config. Look at instructions below on how to updates existing configs.)  

When you exit the container, it is stopped freeing up resources.  

Some notes:  
This tool is not realy made to run your app in a container. Run the agent in the container and fire up the app on your host.
Can you make work? Sure. Normal Podman(Docker) containers are used so everything is availible.
The apps installed in the container are baked in by agentbox build.(Set in tools.lock) This is by design. Change it to fit your needs.

Install TLDR:  
```
git clone https://github.com/lupusmagist/agentbox.git
cd agentbox
./install.sh
agentbox build
```
Run in your project with 'agentbox'  

What is still missing:  
Home directory profiles.  
Container profiles.  
Selective network disable. (Allow connections to local network but not Internet)  

AI slop to follow with the usage and instructions.  

-----------------------------------------------------------------------------------------------------------------------
A rootless container per project, with its own writable `$HOME`, that you enter by typing
`agentbox` in the project directory.

Nothing is installed for you to make disappear: the image, the settings and the shell defaults are
files in a git repository, so a new machine is one clone, one build, and a box that behaves exactly
like the last one. The container itself is disposable — it holds nothing you would miss, and
`agentbox rm && agentbox` is a normal repair.

```
~/projects/api $ agentbox
agentbox: wrote /home/you/projects/api/.agentbox.toml (network online; edit it to tighten or disconnect this project)
agentbox: creating agentbox-api-4b9dc84f
agentbox: the base at ~/projects/agentbox/agent_home is empty — this box starts from the defaults (configure it, then 'agentbox home push')
agentbox: project=api network=online lab=off
/home/agentbox/project $
```

(With no terminal attached — a script, a pipe, CI — it prints the container name and returns instead of
handing over a shell.)

Inside, `/home/agentbox` is yours and the project is at `~/project`. The root filesystem is
read-only, the only capability is `NET_RAW` (so `ping` works), there is no docker socket and no host
`~/.ssh`, and the network is the one thing a project file decides.

Requirements: Linux with **rootless** Podman (`crun`), Python 3.11+, subordinate UID/GID ranges,
cgroups v2, and `git`. Developed on Fedora 44 with SELinux enforcing, where it is tested;
`install.sh` checks each prerequisite before it links anything.

## The four names

These are the only paths this project talks about, and confusing them is the source of most of its
edge cases.

| Name | Where it is | What it is |
| --- | --- | --- |
| `$APP` | the checkout, e.g. `~/projects/agentbox` | the application: `bin/agentbox`, `defaults.toml`, `local.toml`, `tools.lock`, `Containerfile`, `agent_home/`. Everything the tool needs is here and nowhere else |
| `$USER_HOME` | your shell's `~` | **never read.** The tool and the base take nothing from it; the only write is the `install.sh` PATH link, which `--no-link` skips |
| `$BASE_HOME` | `$APP/agent_home/` | gitignored payload. Copied into a box's home when it is created; never mounted |
| `$BOX_HOME` | `<project>/.agentbox/home/` | the per-project copy the box runs on: writes, keys, cache, history. Gitignored inside the project, and refused if git tracks it |
| `$AGENT_HOME` | `/home/agentbox` inside the box | the container's view of `$BOX_HOME` |

So: `$BASE_HOME` seeds `$BOX_HOME` once, `$BOX_HOME` is mounted at `$AGENT_HOME`, and `home
push`/`sync` copy between `$BOX_HOME` and `$BASE_HOME`. Nothing reads `$USER_HOME`, not even a
config file — machine-level settings live in `$APP/local.toml`.

`$AGENT_HOME` behaves like a normal home: `npm i -g <tool>` installs into `~/.npm-global`, the tool
is on `PATH` (that directory is first, ahead of `~/.local/bin` and `~/bin`), and `agentbox home push`
carries it to `$BASE_HOME` so the next box starts with it.

## Installation

```bash
git clone https://github.com/<you>/agentbox.git ~/projects/agentbox
~/projects/agentbox/install.sh        # checks prerequisites, links `agentbox` onto your PATH
agentbox build                        # builds the image; the first one takes a few minutes
agentbox doctor                       # expect: all checks passed
```

`install.sh` links the CLI rather than copying it, so the checkout you edit is the one you run.
`--bin DIR` links elsewhere; `--no-link` runs the checks only.

The image it builds is deliberately small: Debian, `git curl ca-certificates procps
build-essential python3` (with venv and pip) `fzf ripgrep highlight vim less jq unzip xz-utils
openssh-client iproute2 iputils-ping traceroute net-tools qemu-system-x86 qemu-utils`, plus `bash`,
one neutral `.bashrc` and `AGENT.md`. Node 22 comes from the pinned base image, and `nvm`
(pinned by commit) is seeded into each box's home so `nvm install 20` works without root. `npm i -g
<tool>` works with no flag or helper: the global prefix (`~/.npm-global`) is set in
`~/.config/npm/npmrc` via `NPM_CONFIG_USERCONFIG`, not in `~/.npmrc`, because nvm refuses `nvm use`
when that file sets a prefix. The package
list is the `packages` array in `tools.lock` — edit it there, not in the `Containerfile`. There is **no agent
CLI**, no editor configuration, no shell framework and no version manager — those are your choices,
and they belong in your `$BASE_HOME` (below), not in an image everyone shares.

If `agentbox doctor` is not all green, stop there: it is diagnosing the host and the image, and
nothing in a box will be more informative.

## Usage

### Enter a box, leave a box

```bash
cd ~/projects/api
agentbox                 # writes .agentbox.toml if missing, creates the box, enters bash
exit                     # back on the host — and the box stops
```

**Leaving the shell stops the container.** It holds no state worth keeping, so holding memory and
pids between sessions buys nothing, and a process that wedged your editor or a build cannot outlive
the shell that started it: `exit`, then `agentbox` again, and you are back in control. Starting a
stopped box takes well under a second.

The first run in a project writes `.agentbox.toml` and builds a `$HOME` for it. Both are persistent;
everything else in the container is disposable.

### Look at what exists

```bash
agentbox ls              # every box: NAME, project, state, kind, network, path
agentbox status          # this project: container, image, home, base, network, limits
agentbox status api      # ...or any other box, from anywhere
agentbox logs            # the box's startup output (what failed to seed, if anything)
```

`status` never creates or changes anything. The **NAME** column from `ls` is accepted by `status`,
`stop`, `rm` and `logs`, so you can clean up after a project you have already deleted.

### Stop, remove, recover

```bash
agentbox stop            # stop a box you are not in (or left behind by a crash)
agentbox rm              # delete the container; the project and its home are untouched
agentbox rm --home       # ...and delete this project's home (keys included)
agentbox rm && agentbox  # the universal repair; costs seconds and loses nothing that matters
agentbox gc              # stopped boxes older than 14 days (report only; --apply to remove)
```

### Configure a project

`.agentbox.toml` in the project root is the only source of a box's settings, and `agentbox` writes
it before it starts anything:

```toml
schema = 1

network = "online"      # "online" | "none"
memory  = "4g"          # ceilings: tighten-only, never above defaults.toml
cpus    = 4
pids    = 512

# extra mounts must resolve inside this project; read-only unless you say otherwise
# mounts = ["./fixtures:/fixtures:ro"]
```

That is the whole file. It exists for the things that genuinely differ per project — network
access, how much of the machine it may use, and extra mounts. Anything else is either a preference
(belongs in your `$BASE_HOME`) or hardening (machine-level, in `$APP/defaults.toml` for every
machine, or `$APP/local.toml` for this one). A key the tool does
not honour is a hard error naming what it does accept, never a silent ignore.

The full precedence, lowest to highest: built-in → `defaults.toml` → `local.toml` →
`.agentbox.toml` → command line. A project may tighten a limit but never raise one above the
machine profile in `[sandbox]`; `local.toml` is that profile's per-machine overlay and is
gitignored, so a `git pull` cannot conflict with it.

**Network is on by default.** Most projects fetch something in their first minute. Set
`network = "none"` for a project that should not reach out, or pass `--network none` for a single
run. Be clear about the trade: `none` is the only mode that stops an outbound connection, so with
`online` a compromised agent can send the project anywhere it can reach.

`--lab` adds `/dev/kvm`, so `qemu-system-x86_64 -accel kvm` runs at near-native speed instead of
`-accel tcg` software emulation (10–30× slower, fine for booting an image and ssh-ing in). Guest
networking is user-mode only — no tap devices, no bridges — so reach a guest through a port forward.
LXC, containerlab and podman-in-podman cannot work here: they need capabilities every box drops.

## `$BASE_HOME` and `$BOX_HOME`

Every box has a real `$AGENT_HOME` at `/home/agentbox`. It is not a shared volume and not a bind
mount of your `$USER_HOME`; it is a **copy of `$BASE_HOME`**, made when the box is created:

```
$APP/agent_home/                      $BASE_HOME: yours, gitignored, the seed
<project>/.agentbox/home/             $BOX_HOME: one box's copy, writable, gitignored
```

`$BASE_HOME` is what new boxes start from. `$BOX_HOME` is what a box writes to, and it is the only
host directory a box ever sees (plus the project itself). Nothing is shared between boxes, so a
config change or an installed tool in one project cannot surprise another.

### Build your base, once

A fresh clone has an empty base — the repository ships the mechanism, not somebody's config. So the
first box is where you make it yours:

```bash
cd ~/projects/anything
agentbox                     # creates the box and your $HOME

# inside, set it up the way you work:
npm i -g @anthropic-ai/claude-code   # or whichever agent you use
mkdir -p ~/.config/nvim && cp /somewhere/init.lua ~/.config/nvim/
vim ~/.bashrc                 # aliases, prompt, PATH

exit
agentbox home push --dry-run  # list what would go into the base
agentbox home push            # make it the base for new boxes
```

From then on every **new** box starts with your agent, your editor config and your aliases.

### Push, sync, reset

| Command | Does |
| --- | --- |
| `agentbox home` | print where the base is |
| `agentbox home open` | ...and open it in your file manager |
| `agentbox home push [PATH…] [--dry-run]` | copy what you changed in this box into the base |
| `agentbox home sync [--dry-run] [--force]` | copy what changed in the base into this box |
| `agentbox home reset --yes` | delete this box's home (keys included) and its container |

**`push` reaches new boxes only.** A box that already exists keeps the copy it was given, and no
command silently rewrites it — that is what `sync` is for. `sync` keeps any file the box changed
itself; `--force` overwrites those with the base version.

With no `PATH`, `push` sends `~/.bashrc`, `~/.bash_profile`, `~/.profile`, `~/.gitconfig`,
`~/.dir_colors`, `~/.config`, `~/bin` and `~/.local/bin`. Name paths to send only those:

```bash
agentbox home push .config/nvim      # one directory
agentbox home push --dry-run         # list what would change, copy nothing
```

Some things never travel, whatever you name: `.ssh`, `.cache`, `.history`, `.local/state`,
`.pi`, `.venv`, `node_modules` outside `.npm-global`, symlinks that leave the home or dangle, files
over 50 MB, key-shaped file names
(`id_*`, `*.pem`, `.netrc`), and files whose **contents** look like a credential (`sk-…`, `ghp_…`,
`AKIA…`, `BEGIN … PRIVATE KEY`). Seeds skip `.cache` and `.ssh` for the same reason.

What a package manager installed does travel: `npm i -g <tool>` puts a shim in `~/.npm-global/bin`
and the package under `~/.npm-global/lib/node_modules`, and both are pushed — a shim only when it
points inside the home. `~/.local/bin` and `~/bin` travel the same way, so a tool in either is on
`PATH` in the next box without any extra step.

### Keys and private things

`<project>/.agentbox/home` is where keys belong — put them in its `.ssh/`. `.cache` is disposable:
it lives in the box home, is never seeded from the base and is never pushed to it.

`agentbox` also writes `.agentbox/` into `.git/info/exclude` (never into a tracked `.gitignore`)
and **refuses to run** if anything under `.agentbox/` is tracked, because that directory sits inside
the project and a careless `git add -A` would otherwise publish your keys. `doctor` re-checks it.

If you want the base to survive a disk failure, put it in its own private repository — it is
gitignored here, so nothing else will back it up.

## Commands

| Command | Does |
| --- | --- |
| `agentbox` | create this project's box if needed, then enter it (with no terminal: print its name) |
| `status [box]` | state, image, home, base, network, limits. Read-only |
| `ls` | every box on the machine |
| `stop [box]` | stop it, keep it for reuse |
| `rm [box] [--home]` | remove the container, optionally with this project's home |
| `logs [box] [-f] [--lab]` | the box's stdout, including seeding failures |
| `home ACTION [PATH…]` | the `$BASE_HOME` workflow above |
| `build` | build the image from `tools.lock` |
| `update` | report whether the pinned base is current; changes nothing |
| `doctor` | twelve checks for drift and leaks; exit 1 on failure |
| `gc [--apply]` | stopped boxes older than 14 days |

Global flags: `-V/--version`, `--network none|online`, `--lab`. Exit codes: `0` ok, `1` runtime
failure, `2` config error, `3` image missing.

## Where things are stored

| What | Path |
| --- | --- |
| `$APP`: CLI, image recipe, `AGENT.md`, `defaults.toml`, `local.toml` | the checkout, e.g. `~/projects/agentbox/` |
| Built image | `localhost/agentbox/base:current` (+ a dated tag carrying the lock hash) |
| `$BASE_HOME` | `<checkout>/agent_home/` (gitignored) |
| `$BOX_HOME` (becomes `$AGENT_HOME`), keys, cache, history | `<project>/.agentbox/home/` |
| Per-machine settings | `<checkout>/local.toml` (gitignored) |
| Project settings | `<project>/.agentbox.toml` |

Nothing is written to `$USER_HOME`. The built image is rebuildable, the container holds nothing,
and the box home is a copy. The only things that would hurt to lose are `$BASE_HOME` and your
project — which is why `$BASE_HOME` deserves its own repository.

## Troubleshooting

**Something is off and you don't know what.** `agentbox doctor` first, always. Twelve checks: image
matches `tools.lock`, no box home is tracked by git, no stale boxes, every mount source is one this
tool created, project directories still carry their SELinux label, no leftovers from an older setup,
box homes are a sane size, `defaults.toml` keeps every hardening key, no private keys in tracked
files, no host `~/.ssh` reachable from a box, no key-shaped file tracked in a project, and the baked
`AGENT.md` matches the repo copy.

**`crun: getcwd: Operation not permitted`.** The project directory was deleted or recreated under a
live container and lost its SELinux label. `agentbox` detects that and recreates the box.

**I had settings in `~/.config/agentbox/config.toml`.** That file is not read any more: `agentbox`
exits 2 and tells you to move its `[defaults]` and `[sandbox]` tables into `$APP/local.toml`. Only
the leftover is reported — nothing under `$USER_HOME` is read at runtime, and `doctor` lists any
remaining old directory as a warning — it is not read, but check what is in it before you delete it
(older versions kept user dotfiles under `~/.config/agentbox/`).

**A tool I installed in one project isn't in another.** Correct: a box home is a copy. `agentbox
home push` puts it in the base for new boxes, `agentbox home sync` brings an existing one up to
date.

**My shell changes don't show up elsewhere.** You edited `~/.bashrc` *inside* a box; that copy
belongs to that box. Push it, then sync.

**A container is wedged.** `agentbox rm && agentbox`.

## Development

```bash
./bin/agentbox --version          # version + a hash of the exact source
bash tests/acceptance.sh          # end-to-end checks against real containers, cleans up
KEEP=1 bash tests/acceptance.sh   # leave the test boxes behind to inspect
```

The CLI is a single stdlib-only Python file, so a fresh machine needs nothing but `python3`.
`install.sh` has no dependencies either.

`DESIGN.md` is the specification: threat model, why each flag is there, the `$HOME` model and what
it replaced, and the acceptance criteria — including the constraints the first build exposed
(pinned `HOME`, history outside `~/.local`, label drift when a project directory is replaced, and
why a copy-on-create home beats an overlay).

## License

Not chosen yet. Until a license file exists, treat this as all rights reserved.
