# App-local state: remove `$USER_HOME` config and data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** All agentbox configuration and state lives inside the app directory; nothing under `$USER_HOME` is read at runtime.

**Architecture:** Delete the two `$USER_HOME`-based paths (`CONF_DIR`, `DATA`) and replace the user config layer with `$APP/local.toml` (gitignored, machine-local overrides). Delete `image.json`; `doctor` reads the lock hash from the image label the build already writes. A leftover `$USER_HOME/.config/agentbox/config.toml` becomes a hard error instead of a silent ignore, and `doctor`'s existing leftovers check learns about both old paths.

**Tech Stack:** Python 3.11 stdlib only, one file (`bin/agentbox`); bash acceptance suite (`tests/acceptance.sh`); rootless podman; no new dependencies.

**Spec:** this plan's spec is the agreed design in the session that produced it (terms table, six numbered decisions, implications list). Terms used throughout:

| Term | Path | Role |
|---|---|---|
| `$APP` | the checkout | `bin/agentbox`, `defaults.toml`, `local.toml`, `tools.lock`, `Containerfile`, `agent_home/` |
| `$USER_HOME` | host `~` | never read at runtime; written only by `install.sh --bin` |
| `$BASE_HOME` | `$APP/agent_home` | gitignored payload, copied into `$BOX_HOME` at creation |
| `$BOX_HOME` | `<project>/.agentbox/home` | per-box instance on the host, bind-mounted as `$AGENT_HOME` |
| `$AGENT_HOME` | `/home/agentbox` | the container's view of `$BOX_HOME` |

## Global Constraints

- Python 3.11+ stdlib only, single file `bin/agentbox`; no new runtime files, no new dependencies.
- Exit codes unchanged: `0` ok, `1` runtime failure, `2` config error, `3` image missing.
- Nothing under `$USER_HOME` may be read at runtime — not config, not state, not dotfiles. The only permitted write is `install.sh`'s PATH link (`--bin`, `--no-link`).
- `$BASE_HOME` (`$APP/agent_home`) stays where it is and stays gitignored; `$APP/local.toml` is added to `.gitignore`.
- `defaults.toml` remains the tracked, shared profile and must keep every `SANDBOX_KEYS` entry (doctor check 8). `local.toml` is an overrides layer on top of it, never a replacement.
- Out of scope, deliberately: sandbox flags, mount model, `home push`/`sync` filters and the "normal install" follow-up. Do not touch `build_run_args`, `home_rel_allowed`, `HOME_PUSH_DEFAULT`, `ensure_home`.

## Review Focus

- A leftover `$USER_HOME/.config/agentbox/config.toml` that carried `[sandbox]` hardening: a reasonable person expects to be told, not to have it silently stop applying. Must exit 2 naming the file and `local.toml`.
- A mistyped key in `$APP/local.toml`: must exit 2 naming **`local.toml`** and the key, not `defaults.toml`.
- `doctor` against an image built by an older agentbox (no `io.agentbox.lock` label): must FAIL with "rebuild", never pass silently — today's `image.json` check already vanishes silently when the file is missing, and that must not survive as a label-shaped variant. Pinned by `image_lock_label()`'s contract, which is exercised by a read-only label probe in Task 5.
- `AGENTBOX_LOCAL` or `AGENTBOX_HOME_BASE` pointing at a nonexistent path: no traceback; a missing `local.toml` is simply absent config, a missing `$BASE_HOME` is what `status` already reports as "none yet".
- A project `.agentbox.toml` raising a limit that `local.toml` lowered: refused by the existing tightening rule, with the ceiling now coming from `local.toml`.

---

### Task 1: `$APP/local.toml` replaces the `$USER_HOME` config layer

**Files:**
- Modify: `bin/agentbox:37-38` (delete `DATA`, `CONF_DIR`), `:32-33` (add `LOCAL_CONFIG`), `:165-175` (`base_home`), `:420-486` (`merged_config`), `:1288+` (`main`), `:940-1040` (`home` help text mention of `BASE_HOME` only if it interpolates), `:152-163` (comment block)
- Modify: `.gitignore`
- Test: `tests/acceptance.sh:26-29` (env), new group after `:241`

**Interfaces:**
- Produces: `local_config() -> Path` — `$AGENTBOX_LOCAL` if set, else `LOCAL_CONFIG` (`$APP/local.toml`).
- Produces: `legacy_paths() -> tuple[Path, ...]` — `(Path.home()/".config"/"agentbox", Path.home()/".local"/"share"/"agentbox")`; consumed by Task 2.
- Produces: `refuse_legacy_state() -> None` — `die(..., EXIT_CONFIG)` when `legacy_paths()[0]/"config.toml"` exists.
- Changes: `base_home() -> Path` keeps the `AGENTBOX_HOME_BASE` override and drops the config-file lookup entirely.
- Changes: `merged_config(root, cli=None) -> dict` layering is now builtin → `defaults.toml [defaults]` → `local.toml [defaults]` → `<project>/.agentbox.toml` → CLI, and `[sandbox]` is applied from `defaults.toml` then `local.toml` (local last, then CLI).

- [ ] **Step 1: Write the failing tests**

In `tests/acceptance.sh`, replace lines 26-29's `XDG_CONFIG_HOME` export (keep `AGENTBOX_HOME_BASE`, keep the `XDG_DATA_HOME` comment):

```bash
export AGENTBOX_HOME_BASE="$BASE"      # never write into the real agent_home/
export AGENTBOX_LOCAL="$WORK/local.toml"   # ...nor a real local.toml in the checkout
```

Add a group after the `config: tighten-only, drift detection, secrets` group:

```bash
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
rm -f "$FAKE/.config/agentbox/config.toml"
check "the base is \$APP/agent_home when no override is set" \
  "(cd $A && env -u AGENTBOX_HOME_BASE \"$AB\" home | head -1 | grep -qx '$REPO/agent_home')"
```

After editing, `grep -n XDG_ tests/acceptance.sh` must show nothing except the `XDG_DATA_HOME` comment: no remaining `XDG_CONFIG_HOME` export.

- [ ] **Step 2: Run the suite to watch the new checks fail**

Run: `bash tests/acceptance.sh 2>&1 | tail -30`
Expected: the new group reports FAIL for "local.toml supplies the ceiling" (`memory 4g`), "an unknown local.toml [sandbox] key exits 2" (exit 0), "a leftover $USER_HOME config exits 2" (exit 0), and pass for the rest. No other group regresses.

- [ ] **Step 3: Implement**

In `bin/agentbox`, delete lines 37-38 and add next to `BASE_HOME`:

```python
BASE_HOME = REPO / "agent_home"    # $BASE_HOME: copied into each box's $BOX_HOME
LOCAL_CONFIG = REPO / "local.toml"  # this machine's overrides, gitignored
```

Replace `base_home()` and add the two helpers directly after it:

```python
def base_home() -> Path:
    """$BASE_HOME. No config lookup: the app directory owns it."""
    env = os.environ.get("AGENTBOX_HOME_BASE")
    return Path(env).expanduser() if env else BASE_HOME


def local_config() -> Path:
    """$APP/local.toml: this machine's overrides. AGENTBOX_LOCAL is for tests."""
    env = os.environ.get("AGENTBOX_LOCAL")
    return Path(env).expanduser() if env else LOCAL_CONFIG


def legacy_paths() -> tuple[Path, ...]:
    """Where older agentbox versions kept state in $USER_HOME. Never read."""
    home = Path.home()
    return (home / ".config" / "agentbox", home / ".local" / "share" / "agentbox")


def refuse_legacy_state() -> None:
    old = legacy_paths()[0] / "config.toml"
    if not old.exists():
        return
    die(f"{old} is from an older agentbox and is no longer read.\n"
        f"       move its [defaults] and [sandbox] tables to {local_config()}:\n"
        f"         mv {old} {local_config()}\n"
        "       then delete the empty directory", EXIT_CONFIG)
```

In `merged_config`, replace the `user` lookup and both `[sandbox]` validation loops so the file name is accurate:

```python
    local = load_toml(local_config())
    ...
    for path, src in ((DEFAULTS_FILE, defaults), (local_config(), local)):
        for key in (src.get("sandbox") or {}):
            if key not in SANDBOX_KEYS:
                die(f"{path}: unknown [sandbox] key {key!r}", EXIT_CONFIG)
            cfg[key] = src["sandbox"][key]
```

The `[defaults]` merge becomes `for layer in (defaults.get("defaults", {}), local.get("defaults", {}), proj):`, the tightening comparison is unchanged, and the late `user.get("sandbox")` loop is deleted (the loop above already applies local last). Update the error text at old `:442` to use `{local_config()}`.

One deliberate semantic change, not just a move: the old user `[sandbox]` was applied *after* the project tightening check, so a project could slip above a ceiling the operator had set in `~/.config`. Applying `local.toml` before the check closes that hole; the `would loosen the sandbox` message and exit code stay identical.

In `main()`, after `args = p.parse_args(argv)` and before dispatch:

```python
    refuse_legacy_state()
```

Add `local.toml` to `.gitignore` (first block, next to `agent_home/`).

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tests/acceptance.sh 2>&1 | tail -30`
Expected: `0 failed`, and the new group is all `ok`.

Then prove the suite kept its hands off the checkout: `git status --short` must list only `bin/agentbox`, `.gitignore`, `tests/acceptance.sh` and the untracked plan — no `local.toml`, no `agent_home/`.

- [ ] **Step 5: Commit**

```bash
git switch -c app-local-state
git add bin/agentbox .gitignore tests/acceptance.sh
git commit -m "config: keep every layer in \$APP, refuse leftover \$USER_HOME state"
```

---

### Task 2: `doctor` reads the lock hash from the image, and reports old `$USER_HOME` state

**Files:**
- Modify: `bin/agentbox:560-588` (`do_build`, drop the `image.json` write), `:543-550` (add label reader), `:1114-1130` (check 1), `:1205-1206` (check 6)
- Test: `tests/acceptance.sh`, `doctor` group at `:340`

**Interfaces:**
- Consumes: `legacy_paths()` from Task 1.
- Produces: `image_lock_label(ref: str = f"{IMAGE_REPO}:current") -> str | None` — `podman image inspect --format '{{index .Config.Labels "io.agentbox.lock"}}'`.
- Changes: check 1 compares `image_lock_label()` to `lock_hash()`; check 6's `left` list gains any `legacy_paths()` entry that exists. Check numbers and labels stay as they are (README says "twelve checks").

- [ ] **Step 1: Write the failing tests**

In the `doctor` group:

```bash
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
```

- [ ] **Step 2: Run to watch them fail**

Run: `bash tests/acceptance.sh 2>&1 | tail -20`
Expected: "doctor checks the label, not a state file" FAIL — with `image.json` deleted it cannot be satisfied until Step 3; the other three pass already (they pin behaviour that must not regress).

- [ ] **Step 3: Implement**

Add after `image_id()`:

```python
def image_lock_label(ref: str = f"{IMAGE_REPO}:current") -> str | None:
    """The lock hash baked into the image, so no state file can drift from it."""
    res = podman("image", "inspect", "--format",
                 '{{index .Config.Labels "io.agentbox.lock"}}', ref)
    out = res.stdout.strip()
    return out if res.returncode == 0 and out and out != "<no value>" else None
```

Delete the `DATA.mkdir(...)`/`image.json` block at the end of `do_build` (keep the `note`/`print`). Replace check 1's second half:

```python
    if img:
        have = image_lock_label()
        check(1, "image label matches lock hash", have == lock_hash(),
              f"lock {lock_hash()} vs image {have or 'no label'} — run 'agentbox build'")
```

Extend check 6's `left` list before `check(6, ...)`:

```python
    for p in legacy_paths():
        if p.exists():
            left.append(f"{p} (older agentbox state; safe to delete)")
```

- [ ] **Step 4: Verify**

Run: `bash tests/acceptance.sh 2>&1 | tail -20`
Expected: `0 failed`.
Run: `cd ~/projects/agentbox && ./bin/agentbox doctor | grep -E 'image label|leftovers'`
Expected: `ok 1 image label matches lock hash` and `ok 6 no leftovers from the old setup`.

- [ ] **Step 5: Commit**

```bash
git add bin/agentbox tests/acceptance.sh
git commit -m "doctor: read the lock hash from the image label; report old \$USER_HOME state"
```

---

### Task 3: `install.sh` and the CLI help speak the new terms

**Files:**
- Modify: `install.sh:118-133` (replace the stale `~/.config/agentbox/recipe` block), `install.sh:1-12` (usage comment)
- Modify: `bin/agentbox` `home` subcommand help (`:1345-1378`), the `$HOME` comment block (`:152-163`), `BASE_HOME` comment

**Interfaces:** none — text only. No command, flag or exit code changes.

- [ ] **Step 1: Write the failing check** (grep-based, run directly, no suite needed)

```bash
cd ~/projects/agentbox
! grep -rn 'recipe\|XDG_CONFIG_HOME\|\.local/share/agentbox\|\.config/agentbox' \
    install.sh bin/agentbox | grep -v legacy_paths | grep -v 'older agentbox'
./bin/agentbox home --help | grep -q 'BASE_HOME'
```
Expected now: both fail (installer still advertises `recipe/`, help says "base \$HOME").

- [ ] **Step 2: Implement**

Replace the installer's trailing block with the `$BASE_HOME` workflow:

```
Optional: build your $BASE_HOME, the dotfiles every new box starts from:

  cd <a project> && agentbox     # create a box and enter it
  ...install your tools, edit ~/.bashrc, npmg <agent>...
  exit
  agentbox home push             # make that the $BASE_HOME for new boxes

$BASE_HOME lives at <this checkout>/agent_home and is gitignored.
```

In the CLI, change `home`'s one-line help to `"$BASE_HOME: push changes back, sync into a box"`, and in the long help replace "A box's $HOME is a copy of your base" with "A box's $AGENT_HOME ($BOX_HOME on the host) is a copy of your $BASE_HOME, taken when the box is created." Update the `$HOME` comment block to name `$BOX_HOME` and `$AGENT_HOME`, and note that `$BASE_HOME` is never mounted.

- [ ] **Step 3: Verify**

Run the Step 1 commands again; both must pass. Then `bash -n install.sh` (expect no output) and `./bin/agentbox --help | head -5` (unchanged).

- [ ] **Step 4: Commit**

```bash
git add install.sh bin/agentbox
git commit -m "docs: name \$BASE_HOME, \$BOX_HOME and \$AGENT_HOME; drop the stale recipe advice"
```

---

### Task 4: README and `AGENT.md` use the terms

**Files:**
- Modify: `README.md` (add a terms table near the top; rewrite "The base home and the box home" at `:129-150`; config precedence at `:112-120`; storage table at `:221-230`; troubleshooting entries that say "base home")
- Modify: `AGENT.md:31,35` and `:116` ("the human's base" → `$BASE_HOME`; add a one-line terms note)

**Interfaces:** none — documentation only. `AGENT.md` is baked into the image, so this task cannot be verified until Task 5 rebuilds.

- [ ] **Step 1: Implement**

README: add the five-row terms table (verbatim from this plan's Spec section). In the config section, state the precedence as builtin → `defaults.toml` → `local.toml` → `.agentbox.toml` → CLI, and that `local.toml` holds *this machine's* overrides and is gitignored. Add to the storage table: `| This machine's overrides | <checkout>/local.toml (gitignored) |`. In troubleshooting, add: "**I had settings in `~/.config/agentbox/config.toml`.** It is no longer read; `agentbox` exits 2 and tells you to move it to `local.toml`."

AGENT.md: where it says "`~/project/.agentbox/` is the host's view of your home", say `$BOX_HOME`; where it says the home "was copied from the human's base", say `$BASE_HOME`; leave the `npmg` install guidance untouched (that is the follow-up).

- [ ] **Step 2: Verify the text**

```bash
cd ~/projects/agentbox
grep -n '\$USER_HOME\|\$BASE_HOME\|\$BOX_HOME\|\$AGENT_HOME' README.md AGENT.md | head -30
grep -rn 'human.s base\|base home' README.md AGENT.md
```
Expected: the term table and uses are present; the second grep returns nothing.

- [ ] **Step 3: Commit**

```bash
git add README.md AGENT.md
git commit -m "docs: \$USER_HOME, \$BASE_HOME, \$BOX_HOME, \$AGENT_HOME"
```

---

### Task 5: Rebuild the image and prove the whole thing

**Files:** none (verification only).

**Interfaces:** consumes every earlier task.

- [ ] **Step 1: Rebuild, because `AGENT.md` is baked into the image**

Run: `cd ~/projects/agentbox && ./bin/agentbox build`
Expected: `built localhost/agentbox/base:<date>-<hash>` and a new image id.
Note for the operator: this retags `localhost/agentbox/base:current`, so every existing box on this machine becomes "stale" (doctor check 3 warns) until recreated with `agentbox rm && agentbox`.

- [ ] **Step 2: Full acceptance**

Run: `cd ~/projects/agentbox && bash tests/acceptance.sh 2>&1 | tail -5`
Expected: `0 failed` and a pass count higher than 103 by the number of checks added (13).

- [ ] **Step 3: Doctor, twice**

Run: `cd ~/projects/agentbox && ./bin/agentbox doctor` → all checks `ok`, exit 0.
Run: `HOME=$PWD/x ./bin/agentbox doctor | grep -E '^\S+ +6 '` → the leftovers check is `ok` when `$USER_HOME` state is absent.

- [ ] **Step 4: Prove the invariant**

```bash
cd ~/projects/agentbox
podman image inspect --format '{{index .Config.Labels "io.agentbox.lock"}}' \
    docker.io/library/busybox           # an image with no such label: empty output, rc 0
./bin/agentbox doctor | grep 'image label'   # ...which image_lock_label() maps to None, so check 1 would FAIL
git status --short                       # only the plan file, untracked
ls ~/.config/agentbox ~/.local/share/agentbox 2>&1   # must not exist (or only from an older run)
./bin/agentbox home | head -1            # $APP/agent_home
printf 'schema = 1\n[sandbox]\ncpus = 2\n' > /tmp/probe-local.toml
AGENTBOX_LOCAL=/tmp/probe-local.toml ./bin/agentbox status | grep cpus
```
Expected: `cpus 2` from `/tmp/probe-local.toml`, confirming the layer works without touching the checkout.

- [ ] **Step 5: Commit the plan**

```bash
git add docs/superpowers/plans/2026-10-26-app-local-state.md
git commit -m "docs: plan for app-local state"
```
