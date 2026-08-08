---
name: run-claude-statusline
description: Build, run, test, and drive claude-statusline. Use when asked to run the statusline, render it, see what it outputs, smoke-test it, test the installer, or verify a change to bin/statusline.sh or bin/install.js.
---

`claude-statusline` is a two-part CLI: **`bin/statusline.sh`** renders Claude
Code's two-line status string from a JSON payload on stdin, and
**`bin/install.js`** is the install/uninstall shim that wires `~/.claude`.
There is no GUI and no server — you drive it by piping JSON into the renderer
and by running the installer against a throwaway `HOME`. The harness for both
is **`.claude/skills/run-claude-statusline/driver.sh`**; run it first.

All paths below are relative to the repo root.

## Prerequisites

Runtime deps the renderer and installer actually shell out to: `jq` (JSON),
`curl` (default Claude rate-limit fetch), `git` (branch), and optionally `codex`
when `STATUSLINE_RATE_LIMIT_PROVIDER=codex`. `node` runs the installer. The base
dependencies were already present in this container; on a bare Ubuntu box:

```bash
sudo apt-get update && sudo apt-get install -y jq curl git
# node 18+ for bin/install.js (this container: node 22)
```

## Setup

Nothing to build — `bin/statusline.sh` is plain bash. `npm install` is only
needed for the **dev** toolchain (biome + lefthook); skip it if you just want
to run the statusline.

```bash
npm install   # optional — only for `npm run lint` / git hooks
```

## Run (agent path)

**Drive everything with the integration driver.** It covers Claude and Codex
provider rendering/cache behavior, validates the Codex JSONL handshake through
a fake `codex` on `PATH`, checks fallbacks/model normalization, and runs an
install/uninstall roundtrip — all hermetic (no network, isolated cache):

```bash
bash .claude/skills/run-claude-statusline/driver.sh
# → 94 passed, 0 failed   (exit 0)
```

To see the **actual rendered line** for a payload (debugging a render change),
pipe JSON straight in. Pre-seed a fresh cache so it doesn't fire its
background rate-limit `curl`:

```bash
export STATUSLINE_CACHE_DIR=$(mktemp -d)
printf '{"five_hour":{"utilization":12,"resets_at":4102444800},"seven_day":{"utilization":40,"resets_at":4102444800}}' \
  > "$STATUSLINE_CACHE_DIR/statusline-usage-cache.json"
printf '%s' '{
  "model":{"display_name":"Opus 4.8 (1M context)"},
  "context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":150000}},
  "cwd":"'"$PWD"'",
  "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":4102444800},
                 "seven_day":{"used_percentage":61.2,"resets_at":4102444800}}}' \
  | bash bin/statusline.sh
# → opus-4-8[1m] │ 15% │ ⠆ default │ claude-statusline (branch) │ …
#   cur. ●○○○○ 24% …   │ wk. ●●●○○ 61% …
```

Test the **installer** without touching your real `~/.claude` — point `HOME`
at a temp dir:

```bash
H=$(mktemp -d)
HOME="$H" node bin/install.js              # installs into $H/.claude
HOME="$H" node bin/install.js --uninstall  # restores/cleans up
rm -rf "$H"
```

## Run (human path)

End users install the published package (fetches from npm, writes your real
`~/.claude` — don't run this just to test):

```bash
npx @kamranahmedse/claude-statusline             # install
npx @kamranahmedse/claude-statusline --uninstall # remove
```

## Test

The integration driver is the canonical automated suite and is wired through
both `npm test` and the repository-local `test-gate` workflow:

```bash
npm run lint   # biome check . — exit 0 (warnings/infos are non-blocking)
npm test       # 94 hermetic renderer/installer assertions
```

## Gotchas

- **Empty stdin is a feature, not a hang.** With no input, `statusline.sh`
  prints `Claude` and exits 0. Always pipe *something* in.
- **Cold cache fires a detached `curl`.** On first render of a session (no
  fresh cache, no `rate_limits` in stdin) the script kicks a background
  `curl` to `api.anthropic.com` (single-flighted, `--max-time 5`, output
  discarded). It never blocks the render, but for a hermetic/offline run
  pre-seed a fresh `$STATUSLINE_CACHE_DIR/statusline-usage-cache.json` (the
  driver does this) so `api_cache_stale` is false and no network is touched.
- **Model id is normalized, not the display name.** `"Opus 4.8 (1M context)"`
  → `opus-4-8[1m]`: lowercased, the `(… context)` suffix becomes `[…]`, and
  spaces/dots become dashes. Assert on the normalized form.
- **Swapping `HOME` can wake `mise`.** Running `HOME=$tmp node …` makes the
  mise shims re-resolve their pinned tools against an empty home and hit the
  GitHub API — you'll see `403 rate limit` WARN lines. Harmless (the install
  still works); prefix with `MISE_OFFLINE=1` to silence them (the driver
  does).
- **npm-only repo, but a stray `pnpm-lock.yaml` can appear.** `scripts/cloud-setup.sh`
  prefers `pnpm install` when pnpm is on `PATH`, which drops a `pnpm-lock.yaml`
  this repo doesn't track (the committed lockfile is `package-lock.json`).
  It's regenerable cruft — don't commit it.

## Troubleshooting

- **`Missing required dependencies: jq` (installer aborts):** install the
  missing tool — `sudo apt-get install -y jq` (or `curl`/`git`).
- **`jq: command not found` from `statusline.sh`:** same fix; `jq` does all
  the JSON parsing.
- **Renderer prints literal `\033[...m` instead of colors:** something is
  consuming the output with `printf '%s'`. The script emits escapes via
  `printf '%b'` on purpose — keep `%b`.
