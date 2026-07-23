# Agent context

This repo follows Rubio-Enterprises standards. Run `/audit-standards` from a Claude Code session to check conformance, or `/onboard-repo` for greenfield setup.

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues for `Rubio-Enterprises/claude-statusline`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

Use the single-context layout: root `CONTEXT.md` plus repository-wide ADRs in `docs/adr/`. See `docs/agents/domain.md`.

## What this is

`claude-statusline` configures the Claude Code CLI statusline to show the model, context-window usage, 5h/7d rate limits, working directory, and git branch. It is a **fork of [kamranahmedse/claude-statusline](https://github.com/kamranahmedse/claude-statusline)** maintained under Rubio-Enterprises.

Two source files do the work:

- `bin/statusline.sh` — the statusline renderer (bash). Reads Claude Code's JSON
  payload on stdin, extracts model/context/usage/git/session data, and prints
  the two-line status string. Colors use ANSI **palette** codes (not 24-bit
  truecolor) so the line adapts to the active terminal theme.
- `bin/install.js` — the install/uninstall shim (`npx @kamranahmedse/claude-statusline`).
  Copies `statusline.sh` to `~/.claude/statusline.sh`, wires up
  `~/.claude/settings.json`, and backs up / restores any previous statusline.

## Fork / packaging notes

- **The package name stays `@kamranahmedse/claude-statusline`.** Upstream owns
  `package.json` (`bin -> ./bin/install.js`). Copier's fork `_skip_if_exists`
  preserves it on render — do NOT rescope the package.
- The only additive entries Rubio standards require in `package.json` are the
  audit-floor `scripts.lint` (`biome check .`), a no-op `scripts.test`, and the
  `@biomejs/biome` devDep so `npx biome` resolves deterministically. These let
  `check.sh` (NPM-LINT-SCRIPT-PRESENT + the §6.1 Rego "lint invokes biome"
  rule) and the lefthook biome hook pass without touching the package identity.
- This is an **npm** repo (a `package-lock.json` is committed). Run
  `npm install` after cloning so lefthook + biome resolve.

## Toolchain

- Lint/format floor: **Biome** (`biome.json`) for JS/TS/JSON; **shellcheck +
  shfmt** for `bin/statusline.sh`. `mise` pins every hook binary (`.mise.toml`),
  Node is pinned in `.tool-versions`.
- `mise run lint` delegates to `npm run lint`; the git hooks live in
  `lefthook.yml`.

## Gotchas

- `bin/statusline.sh` prints ANSI escapes via `printf '%b' "$var"` (the color
  vars hold literal `\033` escapes). Do **not** switch to `printf '%s'` — that
  would emit literal `\033` text instead of the escape. SC2059 is satisfied by
  `%b`, not by `%s` here.
- `used_tokens` / `total_tokens` are intentionally retained (SC2034 suppressed
  inline) so `format_tokens()` stays reachable for downstream line-assembly.
- `bin/install.js` legitimately uses `console.log` for installer output, so
  Biome's `noConsole` fires as a non-blocking **warning** (the rule allows
  `warn`/`error`); do not silence it by gutting the log helpers.
