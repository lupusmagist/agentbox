# Normal install: `npm i -g` works, PATH is one list, push follows the shims Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `$AGENT_HOME` behaves like a normal `$USER_HOME`: `npm i -g <tool>` installs, the tool is on `PATH`, `agentbox home push` carries it to `$BASE_HOME`, and a new box has it — with no `--prefix`, no `npmg`, no hand-copied bundle.

**Architecture:** Four coupled fixes, in dependency order: (1) npm's global prefix moves into `$AGENT_HOME/.config/npm/npmrc` with `NPM_CONFIG_USERCONFIG`, because a `prefix` in `$AGENT_HOME/.npmrc` (or `NPM_CONFIG_PREFIX`) is what nvm vetoes; (2) one canonical `PATH` written in both the image ENV and `.bashrc`, so login and non-login shells agree; (3) `home push`/`home sync` derive what to carry from the bin shims (`~/.npm-global/bin`, `~/.local/bin`, `~/bin`) plus the stores they point at, instead of dropping `node_modules` and every symlink; (4) docs stop teaching `npmg`.

**Tech Stack:** Python 3.11 stdlib only (`bin/agentbox`); `Containerfile` + `dotfiles/` + `image/entrypoint.sh` for the image; bash acceptance suite; rootless podman; npm 10 / node 22 from the pinned base image; nvm 0.40.8 baked.

**Spec:** the agreed design in the session that produced this plan, plus the existing `docs/superpowers/plans/2026-10-26-app-local-state.md` (which fixed *where state lives*; this one fixes *what a home can hold and carry*).

## Terms (no other meaning is used anywhere in this plan)

| Term | Path |
|---|---|
| `$APP` | the checkout (`~/Apps/agentbox`) |
| `$USER_HOME` | the host user's `~` (`/home/danie`). Never read by agentbox, never pushed, never a push target |
| `$BASE_HOME` | `$APP/agent_home` — the **seed**; the only directory `home push` writes and `home sync` reads |
| `$BOX_HOME` | `<project>/.agentbox/home` — the host directory `home push` reads; `home sync` writes |
| `$AGENT_HOME` | `/home/agentbox` inside the box — exactly `$BOX_HOME`, bind-mounted |

"Inside the home" always means: resolved from `$BOX_HOME`, the result stays under `$BOX_HOME` (equivalently under `$AGENT_HOME` in the box — the paths are identical by construction).

## Global Constraints

- Python 3.11+ stdlib only, single file `bin/agentbox`; no new runtime deps; no new host tools.
- Exit codes unchanged: `0` ok, `1` runtime, `2` config, `3` image missing.
- `$USER_HOME` stays unread. No mount, env var, or config may point a box at it.
- Push/sync must keep refusing, unchanged: `.ssh`, `.cache`, `.history`, `.local/state`, `.pi`, `.gnupg`, `.netrc`, key-shaped names, credential-shaped contents, files over 50 MB.
- A symlink is carried only when its resolved target stays inside the home; anything else is skipped with a reason and reported.
- `defaults.toml` keeps every `SANDBOX_KEYS` entry; sandbox flags, mount model and `build_run_args` are **not** touched by this plan.
- The image must be rebuilt for Tasks 1, 2 and 5; `doctor` check 12 (baked `AGENT.md`) fails until then, by design.
- `nvm` behaviour must not regress: `nvm install <v>` and `nvm use <v>` must keep working with npm configured.

## Review Focus

- A tool installed with `npm i -g` while an older copy of the *same* tool sits in `~/.local/bin`: exactly one of them runs, and it is the one `command -v` names in **both** shell kinds.
- `nvm use 20` after npm has been used: node must actually switch, not print "incompatible with nvm" and silently stay on 22 (this is the exact failure a `prefix` in `$AGENT_HOME/.npmrc` causes).
- `home push` on a home where a shim points at `$USER_HOME` (e.g. `~/.local/bin/x -> /home/danie/tools/x`): must be skipped and reported, never copied as a dangling link into `$BASE_HOME`, where every future box would inherit it.
- A second `node_modules` outside the npm store (e.g. `$AGENT_HOME/.config/something/node_modules`): must still be treated as junk. Only `.npm-global` gets the carve-out.
- Push and sync must agree: anything `push` promotes must be something `sync` can bring back, or tool versions drift in one direction only.
- Cost: `npm i -g pi` is ~149 MB / ~15 000 files. `home push` must stay readable (capped listing) and must not re-read 15 000 files on every `--dry-run` needlessly.

---

### Task 1: npm's global prefix moves out of `$AGENT_HOME/.npmrc`

**Files:**
- Modify: `Containerfile` (seed `~/.config/npm/npmrc`, add `NPM_CONFIG_USERCONFIG` to the `ENV` block near `NVM_DIR`)
- Modify: `image/entrypoint.sh` (seed the npmrc beside `.bashrc`)
- Modify: `dotfiles/npmrc` (rewrite the comment: this file is now installed at `.config/npm/npmrc`, not `.npmrc`)
- Modify: `dotfiles/bashrc` (drop the `npmg` function)
- Test: `tests/acceptance.sh` (replace the `npmg` assertion in the `an empty base falls back to the image defaults` group)

**Interfaces:**
- The box contract after this task: `NPM_CONFIG_USERCONFIG=$AGENT_HOME/.config/npm/npmrc` is in the environment of every process; that file contains exactly `prefix=${HOME}/.npm-global`; `$AGENT_HOME/.npmrc` does not exist; `npm config get prefix` prints `$AGENT_HOME/.npm-global` in `sh -c` and `bash -lc`.

- [ ] **Step 1: Write the failing tests**

Replace the `npmg` check in the empty-base group (`grep -n npmg tests/acceptance.sh` finds it around line 321) with a group-level set of assertions using a local package, no network:

```bash
group "npm: a normal global install, no --prefix, no helper"
mkdir -p "$WORK/tiny"
printf '{"name":"agentbox-probe","version":"1.0.0","bin":{"agentbox-probe":"cli.js"}}\n' \
  > "$WORK/tiny/package.json"
printf '#!/usr/bin/env node\nconsole.log("probe ok")\n' > "$WORK/tiny/cli.js"
chmod +x "$WORK/tiny/cli.js"
tar -C "$WORK/tiny" -czf "$WORK/tiny.tgz" .      # a tarball, so npm copies rather than links
cp "$WORK/tiny.tgz" "$A/tiny.tgz"                # $A is the project mount: visible in the box
check "no global prefix is configured in ~/.npmrc" \
  "(cd $A && XIN sh -c 'test ! -e ~/.npmrc')"
check "npm's prefix is the home's npm-global" \
  "[ \"\$(cd $A && XIN npm config get prefix)\" = /home/agentbox/.npm-global ]"
check "NPM_CONFIG_USERCONFIG points at the home" \
  "(cd $A && XIN sh -c 'case \$NPM_CONFIG_USERCONFIG in /home/agentbox/.config/npm/npmrc) ;; *) exit 1;; esac')"
check "NPM_CONFIG_PREFIX is not set (nvm would refuse)" \
  "(cd $A && XIN sh -c 'test -z \"\${NPM_CONFIG_PREFIX:-}\"')"
(cd "$A" && XIN sh -c 'npm i -g ~/project/tiny.tgz' >/dev/null 2>&1)
check "a bare 'npm i -g' installs into the home" \
  "(cd $A && XIN sh -c 'test -x ~/.npm-global/bin/agentbox-probe')"
check "the installed binary runs, from a non-login shell" \
  "(cd $A && XIN sh -c 'agentbox-probe' | grep -qx 'probe ok')"
check "the installed binary runs, from a login shell" \
  "(cd $A && XIN bash -lc 'agentbox-probe' | grep -qx 'probe ok')"
check "the npmg helper is gone" \
  "! (cd $A && XIN bash -ic 'command -v npmg' >/dev/null 2>&1)"
```

`XIN` runs `podman exec` without `-i`/`-t`. `$WORK` is a host temp dir and is **not** visible in the box, so the tarball is copied into the project (`$A/tiny.tgz` → `/home/agentbox/project/tiny.tgz`) first; the suite deletes `$A` at the end.

- [ ] **Step 2: Run to watch it fail**

Run: `bash tests/acceptance.sh 2>&1 | sed -n '/npm: a normal global/,/^==/p'`
Expected: FAIL on "npm's prefix is the home's npm-global" (prints `/usr/local`), "a bare 'npm i -g' installs" (ENOENT/read-only), "NPM_CONFIG_USERCONFIG points at the home" (empty), and "the npmg helper is gone".

- [ ] **Step 3: Implement**

`dotfiles/npmrc` — rewrite to the installed location and the real reason:

```
# npm's global prefix lives in the home, because /usr/local is read-only here.
#
# This file is installed as ~/.config/npm/npmrc and reached through
# NPM_CONFIG_USERCONFIG. It is deliberately NOT ~/.npmrc: nvm refuses
# `nvm use` when ~/.npmrc (or NPM_CONFIG_PREFIX) sets a prefix, and the whole
# point is that `npm i -g` and `nvm use 20` both work without a helper.
prefix=${HOME}/.npm-global
```

`Containerfile`, in the `RUN mkdir -p /home/agentbox/project …` layer add `/home/agentbox/.config/npm`, and beside the existing skel copies:

```dockerfile
COPY dotfiles/npmrc /opt/agentbox/skel/.config/npm/npmrc
```

and in the `ENV` block, after `NVM_DIR`:

```dockerfile
    NPM_CONFIG_USERCONFIG=/home/agentbox/.config/npm/npmrc \
```

`image/entrypoint.sh`, after the `.bashrc`/`.bash_profile` seed loop:

```sh
# npm's global prefix: seeded, never overwritten, and never in ~/.npmrc (nvm)
mkdir -p "$HOME/.config/npm" 2>/dev/null || true
[ -e "$HOME/.config/npm/npmrc" ] || \
    cp -n /opt/agentbox/skel/.config/npm/npmrc "$HOME/.config/npm/npmrc" 2>/dev/null || true
```

`dotfiles/bashrc`: delete the `npmg` block and its comment (the `PATH` export is replaced in Task 2; leave it for now).

- [ ] **Step 4: Rebuild, then verify**

Run: `cd $APP && ./bin/agentbox build && bash tests/acceptance.sh 2>&1 | tail -4`
Expected: the npm group is all `ok`; `0 failed`.
Manual nvm proof (network, not in the suite):
```bash
cd ~/projects/testing/agentbox_test_1 && agentbox home reset --yes && agentbox </dev/null
B=$(agentbox ls | awk 'NR==2{print $1}')
podman exec -e TERM=dumb "$B" bash -lc 'nvm install 20 >/dev/null 2>&1; nvm use 20; node -v'
```
Expected: `Now using node v20.20.2` and `v20.20.2` (not the "incompatible with nvm" message, not 22).

- [ ] **Step 5: Commit**

```bash
git switch -c normal-install
git add Containerfile image/entrypoint.sh dotfiles/npmrc dotfiles/bashrc tests/acceptance.sh
git commit -m "npm: global prefix via NPM_CONFIG_USERCONFIG so npm i -g and nvm use both work"
```

---

### Task 2: one canonical PATH

**Files:**
- Modify: `Containerfile` (`ENV PATH=…` near the bottom)
- Modify: `dotfiles/bashrc` (replace the `PATH` export)
- Test: `tests/acceptance.sh`, new checks in the npm group or the tooling group

**Interfaces:**
- Canonical order, user first: `$AGENT_HOME/.npm-global/bin`, `$AGENT_HOME/.local/bin`, `$AGENT_HOME/bin`, `/opt/agentbox/bin`, `/opt/agentbox/pinned/bin`, `/usr/local/sbin`, `/usr/local/bin`, `/usr/sbin`, `/usr/bin`, `/sbin`, `/bin`.
- `nvm use` is allowed to prepend its own version dir; nothing else may reorder the list.

- [ ] **Step 1: Write the failing tests**

```bash
group "PATH: one list, same in every shell"
check "the image PATH and a login shell agree on the user prefix" \
  "[ \"\$(cd $A && XIN sh -c 'echo \$PATH')\" = \"\$(cd $A && XIN bash -lc 'echo \$PATH')\" ]"
check "npm installs win over ~/.local/bin" \
  "(cd $A && XIN sh -c 'echo \$PATH' | grep -q '^/home/agentbox/.npm-global/bin:/home/agentbox/.local/bin:/home/agentbox/bin:')"
check "/opt/agentbox/bin survives a login shell" \
  "(cd $A && XIN bash -lc 'command -v agentbox-info')"
check "no directory appears twice" \
  "! (cd $A && XIN sh -c 'echo \$PATH' | tr ':' '\n' | sort | uniq -d | grep -q .)"
```

- [ ] **Step 2: Run to watch it fail**

Expected: "agree on the user prefix" FAIL (login shell drops `/opt/agentbox/*` and reorders), "npm installs win" FAIL (`.local/bin` is first in the image ENV), "/opt/agentbox/bin survives" FAIL (login shell has no `agentbox-info`).

- [ ] **Step 3: Implement**

`Containerfile`, replacing the current `PATH=` line:

```dockerfile
    PATH=/home/agentbox/.npm-global/bin:/home/agentbox/.local/bin:/home/agentbox/bin:/opt/agentbox/bin:/opt/agentbox/pinned/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

`dotfiles/bashrc`, replacing `export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"`:

```bash
# One canonical PATH, written out rather than prepended: a login shell runs
# /etc/profile first, which throws away the image's PATH, and prepending to
# whatever is left is how /opt/agentbox/bin disappeared and the order drifted.
# npm first, so the tool you installed with `npm i -g` is the one that runs;
# ~/bin and ~/.local/bin are for tools npm did not install. nvm prepends its own
# version dir on `nvm use`, which is the one sanctioned exception.
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/bin:/opt/agentbox/bin:/opt/agentbox/pinned/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

- [ ] **Step 4: Rebuild and verify**

Run: `./bin/agentbox build && bash tests/acceptance.sh 2>&1 | tail -4`
Expected: `0 failed`; the PATH group all `ok`.
Manual: `podman exec -e TERM=dumb <box> bash -lc 'echo $PATH'` and `sh -c 'echo $PATH'` print the same string.

- [ ] **Step 5: Commit**

```bash
git add Containerfile dotfiles/bashrc tests/acceptance.sh
git commit -m "path: one canonical order, identical in login and non-login shells"
```

---

### Task 3: `home push`/`sync` follow the shims instead of dropping them

**Files:**
- Modify: `bin/agentbox` `HOME_PUSH_DEFAULT` (`:245`), `HOME_NEVER`/`JUNK_DIRS`/`home_rel_allowed` (`:247-262`), `home_plan` (`:264-300`), `cmd_home` (`:1040-1100`)
- Test: `tests/acceptance.sh`, new group after `state lives in $APP`

**Interfaces:**
- Produces: `SHIM_DIRS = (".npm-global/bin", ".local/bin", "bin")`.
- Produces: `shim_store_roots(home: Path) -> tuple[str, ...]` — sorted relative roots referenced by *resolvable* in-home symlinks found in `SHIM_DIRS`: for a target under the home, the root is its first component unless that is `.local`, in which case the first three (`.local/share/<name>`); targets outside the home contribute nothing.
- Produces: `classify_symlink(home: Path, path: Path) -> tuple[str, str | None]` — `("inside", rel)` when the link's target exists and lives under `home`, `("dangling", None)` when it does not exist, `("outside", None)` otherwise. An absolute target starting `/home/agentbox/` is first mapped to `home/<rest>` (host-side, `/home/agentbox` only exists inside a box); any other absolute target is outside.
- Changes: `home_rel_allowed(rel, extra_roots=())` — `node_modules` is allowed when `rel` starts with `.npm-global/`; `.local/share/<name>` allowed when listed in `extra_roots`; everything else as today.
- Changes: `home_plan(src, dst, paths=None, limit=…)` — `paths=None` means `HOME_PUSH_DEFAULT + shim_store_roots(src)`; symlinks are no longer unconditionally skipped: an in-home link whose target exists is copied (its store root is already in `paths`), a link whose target is missing is skipped with reason `dangling symlink`, and a link pointing outside the home is skipped with `symlink outside the home`.
- Changes: `cmd_home` uses `paths=None` for both `push` and `sync` so the two directions cannot diverge.

- [ ] **Step 1: Write the failing tests**

```bash
group "install travels: npm -> box -> base -> new box"
(cd "$A" && XIN sh -c 'npm i -g ~/project/tiny.tgz' >/dev/null 2>&1)
check "dry run lists the npm store and the shim" \
  "(cd $A && \"$AB\" home push --dry-run 2>&1 | grep -q '.npm-global/lib/node_modules/agentbox-probe' && \
    cd $A && \"$AB\" home push --dry-run 2>&1 | grep -q '.npm-global/bin/agentbox-probe')"
(cd "$A" && "$AB" home push >/dev/null 2>&1)
check "the shim arrived in the base" \
  "[ -L $BASE/.npm-global/bin/agentbox-probe ]"
check "the shim resolves inside the base" \
  "[ -x $BASE/.npm-global/lib/node_modules/agentbox-probe/cli.js ]"
(cd "$B" && "$AB" </dev/null >/dev/null 2>&1)
check "a new box runs the inherited tool" \
  "(cd $B && XIN sh -c 'agentbox-probe' | grep -qx 'probe ok')"
(cd "$B" && XIN sh -c 'test -x ~/.npm-global/bin/agentbox-probe' >/dev/null 2>&1)
check "it is on PATH without anyone fixing PATH" \
  "(cd $B && XIN sh -c 'command -v agentbox-probe' | grep -q '^.npm-global/bin/')"
check "sync brings a base-only tool into an existing box" \
  "(cd $B && XIN sh -c 'rm -rf ~/.npm-global/lib/node_modules/agentbox-probe ~/.npm-global/bin/agentbox-probe' && \
    cd $B && \"$AB\" home sync >/dev/null 2>&1 && cd $B && XIN sh -c 'agentbox-probe' | grep -qx 'probe ok')"
(cd "$A" && XIN sh -c 'ln -sf /etc/hostname ~/.local/bin/outside')
check "a symlink leaving the home is refused, with a reason" \
  "(cd $A && \"$AB\" home push --dry-run 2>&1 | grep -q 'symlink outside the home')"
check "it is not published into the base" \
  "[ ! -e $BASE/.local/bin/outside ] && [ ! -L $BASE/.local/bin/outside ]"
(cd "$A" && XIN sh -c 'ln -sf /home/agentbox/no-such-path ~/.local/bin/dangling')
check "a dangling symlink is refused, with a reason" \
  "(cd $A && \"$AB\" home push --dry-run 2>&1 | grep -q 'dangling symlink')"
(cd "$A" && XIN sh -c 'mkdir -p ~/.config/other/node_modules/x && echo n > ~/.config/other/node_modules/x/index.js')
check "node_modules outside the npm store is still junk" \
  "(cd $A && \"$AB\" home push --dry-run 2>&1 | grep -q '.config/other/node_modules/x/index.js  \[keys/cache/junk\]')"
check "the secrets refusal still holds for the npm tree" \
  "(cd $A && XIN sh -c 'printf \"OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz\\n\" > ~/.npm-global/lib/node_modules/agentbox-probe/.env' && \
    cd $A && \"$AB\" home push --dry-run 2>&1 | grep -qi 'looks like a secret')"
```

Note `.npm-global/bin/agentbox-probe` is a **relative** symlink (`../lib/node_modules/...`), which is what npm writes. A hand-made link in the box is absolute — `/home/agentbox/.npm-global/...` — and must still work, because that is the path the user sees inside `$AGENT_HOME`:

```bash
(cd "$A" && XIN sh -c 'ln -sf /home/agentbox/.npm-global/lib/node_modules/agentbox-probe/cli.js ~/.local/bin/abs-probe')
check "an absolute link into \$AGENT_HOME is accepted" \
  "(cd $A && \"$AB\" home push --dry-run 2>&1 | grep -q '.local/bin/abs-probe')"
```

This is the one place the two spellings of the same directory must be reconciled: `home push` reads `$BOX_HOME` on the host, where `/home/agentbox` does not exist, so the prefix is mapped before the inside/outside decision.

- [ ] **Step 2: Run to watch it fail**

Expected: "dry run lists the npm store and the shim" FAIL (`nothing to push`, 15 000 files skipped), "the shim arrived" FAIL, "a new box runs the inherited tool" FAIL, "an absolute link that points inside the home is accepted" FAIL (`[symlink]` skip).

- [ ] **Step 3: Implement**

In `bin/agentbox`:

```python
HOME_PUSH_DEFAULT = (".bashrc", ".bash_profile", ".profile", ".gitconfig",
                     ".dir_colors", ".config", "bin", ".local/bin", ".npm-global")
SHIM_DIRS = (".npm-global/bin", ".local/bin", "bin")
```

```python
def classify_symlink(home: Path, path: Path) -> tuple[str, str | None]:
    """("inside", rel) | ("dangling", None) | ("outside", None).

    /home/agentbox is the same directory as $BOX_HOME, but only inside a box;
    on the host side (where push runs) it has to be spelled as $BOX_HOME.
    """
    try:
        raw = os.readlink(path)
    except OSError:
        return ("outside", None)
    if raw.startswith(BOX_HOME + "/"):
        target = home / raw[len(BOX_HOME) + 1:]
    elif os.path.isabs(raw):
        target = Path(raw)
    else:
        target = path.parent / raw
    if not target.exists():
        return ("dangling", None)
    try:
        return ("inside", target.resolve().relative_to(home.resolve()).as_posix())
    except ValueError:
        return ("outside", None)


def shim_store_roots(home: Path) -> tuple[str, ...]:
    """Store roots a home's shims point at: .npm-global, .local/share/<name>."""
    roots = set()
    for d in SHIM_DIRS:
        bindir = home / d
        if not bindir.is_dir():
            continue
        for entry in sorted(bindir.iterdir()):
            if not entry.is_symlink():
                continue
            kind, rel = classify_symlink(home, entry)
            if kind != "inside" or not rel:
                continue
            parts = Path(rel).parts
            roots.add("/".join(parts[:3]) if parts[0] == ".local" else parts[0])
    return tuple(sorted(roots))
```

`home_rel_allowed` gains the carve-outs and loses nothing:

```python
def home_rel_allowed(rel: str, extra_roots=()) -> bool:
    for never in HOME_NEVER:
        if rel == never or rel.startswith(never + "/"):
            return False
    if rel.startswith(".npm-global/"):
        return not KEY_SHAPED.search(Path(rel).name)
    for root in extra_roots:
        if rel == root or rel.startswith(root + "/"):
            return not KEY_SHAPED.search(Path(rel).name)
    if any(part in JUNK_DIRS for part in Path(rel).parts):
        return False
    return not KEY_SHAPED.search(Path(rel).name)
```

Symlink classification in `home_plan` uses `classify_symlink()`: `inside` → `copy`, `dangling` → `skipped` with `dangling symlink`, `outside` → `skipped` with `symlink outside the home`. Pass `extra_roots` into `home_rel_allowed`.

`home_plan` changes: `paths=None` → build the list; for each candidate symlink use `classify_symlink(home, path)` — `inside` goes into `copy` (its store root is already in `paths` via `shim_store_roots`), `dangling`/`outside` go into `skipped` with those reasons; pass `extra_roots` into `home_rel_allowed`. `cmd_home` calls `home_plan(home, base)` / `home_plan(base, home)` with no explicit paths for `push`/`sync`, and keeps explicit `PATH` arguments meaning exactly those paths (documented behaviour), with `extra_roots` still computed.

- [ ] **Step 4: Rebuild and verify**

Run: `./bin/agentbox build && bash tests/acceptance.sh 2>&1 | tail -4`
Expected: `0 failed`, new group all `ok`. Then the real thing:

```bash
cd ~/projects/testing/agentbox_test_1 && agentbox home reset --yes
agentbox </dev/null                          # blank box
B=$(agentbox ls | awk 'NR==2{print $1}')
podman exec -e TERM=dumb "$B" sh -c 'npm i -g @earendil-works/pi-coding-agent'   # bare npm
podman exec -e TERM=dumb "$B" sh -c 'pi --version'
agentbox home push
mkdir -p ~/projects/testing/agentbox_test_2 && cd ~/projects/testing/agentbox_test_2 && agentbox </dev/null
C=$(agentbox ls | awk 'NR==2{print $1}')
podman exec -e TERM=dumb "$C" sh -c 'pi --version'
```
Expected: `pi --version` prints `1.4.0` in the first box **without** any `--prefix`, `npmg`, or tarball; `home push` reports the `.npm-global` tree; a brand-new project's box prints `1.4.0` too.

- [ ] **Step 5: Commit**

```bash
git add bin/agentbox tests/acceptance.sh
git commit -m "home: carry the shims and their stores, so npm-installed tools reach the base"
```

---

### Task 4: docs stop teaching a workaround

**Files:**
- Modify: `AGENT.md` (install section around `npmg`; the `.npmrc`/nvm paragraph; the env table if it lists `NPM_CONFIG_*`)
- Modify: `README.md` (the "deliberately no global npm prefix" paragraph, the image description, the `home push` section's "Never pushed" list — `node_modules` now travels inside `.npm-global`)
- Modify: `install.sh` (the `$BASE_HOME` block currently suggests `npmg`)

**Interfaces:** text only. `npm i -g <tool>` becomes the documented way; `nvm` compatibility stated with the reason it works.

- [ ] **Step 1: Write the failing check**

```bash
cd $APP
! grep -rn 'npmg' AGENT.md README.md install.sh dotfiles/ | grep -v 'gone'
grep -q 'NPM_CONFIG_USERCONFIG' AGENT.md README.md
```
Expected now: both fail (`npmg` is still taught in three files).

- [ ] **Step 2: Implement**

`AGENT.md`: in the install table, `npm i -g <tool>` (drop the `npmg` line and the sentence that `npm i -g` alone fails); replace the `.npmrc`/`NPM_CONFIG_PREFIX` paragraph with: the prefix lives in `~/.config/npm/npmrc`, reached via `NPM_CONFIG_USERCONFIG`, precisely so `npm i -g` and `nvm use` both work; note that under nvm the prefix is still the shared `~/.npm-global`.

`README.md`: same correction in the image description; in the `home push` "Never pushed" list, say `node_modules` is carried only inside `.npm-global`; add one line to the `$AGENT_HOME` section: a tool installed with `npm i -g` is on `PATH` and travels with `home push`.

`install.sh`: `npm i -g <agent>` in the `$BASE_HOME` block.

- [ ] **Step 3: Verify**

Run the Step 1 commands; both must pass (`npmg` absent, `NPM_CONFIG_USERCONFIG` present). Then `bash -n install.sh`, `./bin/agentbox --help >/dev/null`.

- [ ] **Step 4: Commit**

```bash
git add AGENT.md README.md install.sh
git commit -m "docs: npm i -g is the install path; explain the userconfig prefix"
```

---

### Task 5: prove it end to end and merge

**Files:** none (verification).

- [ ] **Step 1: Rebuild and full suite**

Run: `./bin/agentbox build && bash tests/acceptance.sh 2>&1 | tail -4`
Expected: `0 failed`; count above 120 by the new checks.

- [ ] **Step 2: `doctor`**

Run: `./bin/agentbox doctor` → every check `ok` or `warn` (warn 6 may still name `$USER_HOME` dirs on this host), exit 0.

- [ ] **Step 3: The acceptance statement, from blank**

```bash
cd ~/projects/testing/agentbox_test_1 && agentbox home reset --yes
agentbox </dev/null
B=$(agentbox ls | awk 'NR==2{print $1}')
podman exec -e TERM=dumb "$B" sh -c 'npm i -g @earendil-works/pi-coding-agent && pi --version'
podman exec -e TERM=dumb "$B" bash -lc 'nvm install 20 >/dev/null 2>&1; nvm use 20; node -v'
agentbox home push
mkdir -p ~/projects/testing/agentbox_test_2 && cd ~/projects/testing/agentbox_test_2 && agentbox </dev/null
C=$(agentbox ls | awk 'NR==2{print $1}')
podman exec -e TERM=dumb "$C" sh -c 'pi --version'
```
Expected: `1.4.0` from a bare `npm i -g`; `nvm use 20` switches node; `home push` carries ~15 000 files; the second box has `pi` without any extra step.

- [ ] **Step 4: Report and merge**

Report the suite count, the push size, and the two boxes. Merge with `git switch main && git merge --no-ff normal-install`, re-run the suite on the merged result, then `git branch -d normal-install` (only after your human partner picks the merge option).
