#!/usr/bin/env bash
# regenerate-lint-config.sh — rebuild this repo's GENERATED lint configs from the
# org floor merged with its committed `*.local` sidecars.
#
# WHY THIS EXISTS:
# The generated configs (`ruff.toml`, `biome.jsonc`, `.yamllint`,
# `.markdownlint-cli2.jsonc`) are floor ⊕ delta merges. The floor lives in the
# standards template, not in this repo, so refreshing one needs a render. The
# only way to do that used to be `copier update`, which diff-applies the ENTIRE
# template across the repo, runs migrations, and drags unrelated template drift
# into your branch — absurdly heavy for "I changed one rule in a .local file".
#
# This script runs the SAME recipe the org CI gate runs (`.github`'s
# `lint-format.yml`): resolve the standards channel, render the template into a
# scratch dir with this repo's answers and its committed `.local` sidecars
# seeded, let the `_tasks` merge hooks compose floor ⊕ delta, then copy back
# ONLY the config files. Nothing else in the repo is touched.
#
# Running the identical recipe as the gate is the point: "regenerated locally"
# and "passes the config drift check" are then the same computation. A
# hand-rolled lighter merge could diverge from the gate, which is the exact bug
# class this replaces.
#
# USAGE:
#   mise run lint-config        # regenerate in place
#   mise run lint-config -- --check   # exit 1 if anything is stale (no writes)
#
# Requires: copier + yq (both mise-pinned in this repo), git, and — only to read
# the `ring` property — gh. Without gh (or offline gh), the channel falls back to
# `stable`, exactly as the gate's own fail-safe does.

set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
fi

if [ ! -f .copier-answers.yml ]; then
  echo "regenerate-lint-config: no .copier-answers.yml here; run from the repo root." >&2
  exit 1
fi

# The four Pattern F configs. Each is written solely by its `merge-*.sh` hook, so
# whatever the render produces IS the canonical content. `biome.json` is absent
# by design: the rendered Biome target is `biome.jsonc` (strict JSON forbids the
# @generated banner comment, and a comment in `biome.json` makes Biome silently
# fall back to its own defaults).
CONFIGS=(ruff.toml biome.jsonc .yamllint .markdownlint-cli2.jsonc)
SIDECARS=(ruff.toml.local biome.json.local .yamllint.local .markdownlint-cli2.jsonc.local)

resolve_channel() {
  # Same rule as the gate: `ring == canary` -> canary, everything else (incl.
  # unset, `fleet`, or an unreadable property) -> stable. Never fail here; a
  # wrong-but-safe channel beats aborting a local regeneration.
  local slug ring
  if ! command -v gh >/dev/null 2>&1; then
    echo stable
    return 0
  fi
  slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  if [ -z "$slug" ]; then
    echo stable
    return 0
  fi
  ring="$(gh api "repos/$slug/properties/values" \
    --jq '.[] | select(.property_name=="ring") | .value' 2>/dev/null || true)"
  if [ "$ring" = "canary" ]; then
    echo canary
  else
    echo stable
  fi
}

yq_bin() {
  if command -v yq >/dev/null 2>&1; then
    printf 'yq'
  elif command -v mise >/dev/null 2>&1; then
    printf 'mise exec -- yq'
  else
    echo "regenerate-lint-config: yq not found; run 'mise install' first." >&2
    exit 1
  fi
}

copier_bin() {
  if command -v copier >/dev/null 2>&1; then
    printf 'copier'
  elif command -v mise >/dev/null 2>&1; then
    printf 'mise exec -- copier'
  else
    echo "regenerate-lint-config: copier not found; run 'mise install' first." >&2
    exit 1
  fi
}

YQ="$(yq_bin)"
COPIER="$(copier_bin)"

SRC="$($YQ -r '._src_path' .copier-answers.yml)"
if [ -z "$SRC" ] || [ "$SRC" = "null" ]; then
  echo "regenerate-lint-config: .copier-answers.yml has no _src_path." >&2
  exit 1
fi

CHANNEL="$(resolve_channel)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RENDER_DIR="$WORK/render"
mkdir -p "$RENDER_DIR"

# Strip copier's `_`-prefixed metadata so it only sees question answers (the gate
# does the same before its render).
$YQ 'with_entries(select(.key | test("^_") | not))' .copier-answers.yml >"$WORK/answers.yml"

# Seed the committed sidecars so the merge hooks compose floor ⊕ delta rather
# than floor-only. Without this the regenerated config would silently DROP every
# declared repo carve-out.
for sidecar in "${SIDECARS[@]}"; do
  if [ -f "$sidecar" ]; then
    cp "$sidecar" "$RENDER_DIR/$sidecar"
  fi
done

echo "regenerate-lint-config: rendering standards@$CHANNEL from $SRC"
if ! $COPIER copy --vcs-ref="$CHANNEL" --data-file "$WORK/answers.yml" \
  --defaults --trust --quiet "$SRC" "$RENDER_DIR"; then
  echo "regenerate-lint-config: render failed (offline? bad channel?)." >&2
  echo "  Your committed configs are unchanged." >&2
  exit 1
fi

stale=0
changed=()
for cfg in "${CONFIGS[@]}"; do
  rendered="$RENDER_DIR/$cfg"
  # Not every config applies to every repo (ruff.toml only for has_python, and
  # so on). A config the render did not produce is not this repo's concern.
  [ -f "$rendered" ] || continue

  if [ -f "$cfg" ] && cmp -s "$cfg" "$rendered"; then
    continue
  fi

  stale=1
  changed+=("$cfg")
  if [ "$CHECK_ONLY" -eq 0 ]; then
    cp "$rendered" "$cfg"
  fi
done

if [ "$stale" -eq 0 ]; then
  echo "regenerate-lint-config: every generated config is already current."
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "regenerate-lint-config: STALE generated config: ${changed[*]}" >&2
  echo "  These files do not match the standards floor ⊕ this repo's *.local sidecars." >&2
  echo "  Fix: mise run lint-config   (then commit the regenerated file)" >&2
  exit 1
fi

echo "regenerate-lint-config: regenerated ${changed[*]}"
echo "  Commit the regenerated file(s) alongside the .local change that caused it."
