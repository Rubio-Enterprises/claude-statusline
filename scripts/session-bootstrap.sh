#!/usr/bin/env bash
# scripts/session-bootstrap.sh — repo-owned SessionStart bootstrap, invoked by
# scripts/claude-session-start.sh step (8) after the pinned toolchain is up.
# This file is NOT managed by the rubio-standards template. Contract (see the
# hook): abort-proof, stdout is Claude's context so emit at most ONE
# actionable line there, chatter to stderr, always end in exit 0.
#
# Current job: cloud marketplace-health check. scripts/cloud-setup.sh
# pre-seeds the carrier's plugin marketplaces into the environment snapshot
# (workaround for the platform's SKIP_PLUGIN_MARKETPLACE=true — see that
# script's pre-seed section). Every failure mode there is non-fatal by
# design, so a failed pre-seed (expired GH_PAT, network-policy block, a
# snapshot predating the workaround) would otherwise surface only as
# silently missing plugins. This check turns that into one actionable NOTE
# at session start. Delete this check when the pre-seed workaround goes.
set -euo pipefail

# Cloud sessions only: locally Claude Code syncs marketplaces natively and
# ~/.claude/plugins is none of our business. Also skip during the snapshot
# build itself — cloud-setup.sh invokes the SessionStart hook (and therefore
# this file) BEFORE its pre-seed section runs, so the state this check
# inspects does not exist yet at that point; cloud-setup.sh marks that
# invocation with CLOUD_SETUP_BUILD=1.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ -z "${CLOUD_SETUP_BUILD:-}" ] || exit 0

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
carrier="$repo_root/.claude/settings.json"
registry="$HOME/.claude/plugins/known_marketplaces.json"
clones="$HOME/.claude/plugins/marketplaces"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$carrier" ] || exit 0

# A marketplace is healthy only if BOTH halves of its pre-seed exist: the
# clone on disk and its entry in the registry Claude Code reads at startup.
missing=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ ! -d "$clones/$name/.git" ] ||
    ! jq -e --arg n "$name" 'has($n)' "$registry" >/dev/null 2>&1; then
    missing="$missing $name"
  fi
done <<EOF
$(jq -r '
  (.extraKnownMarketplaces // {})
  | to_entries[]
  | select(.value.source | type == "object" and .source == "github")
  | .key
' "$carrier" 2>/dev/null)
EOF

# A healthy marketplace is still not enough: each enabled plugin must also be
# installed into the plugin cache, or startup resolution drops it with
# "plugin-cache-miss" (a live-session test showed exactly this: 2 seeded
# marketplaces, 0 plugins loaded). Only flag plugins whose marketplace IS
# healthy — the missing ones are already reported above.
uncached=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  mkt="${entry##*@}"
  case " $missing " in *" $mkt "*) continue ;; esac
  [ -d "$clones/$mkt/.git" ] || continue
  [ -d "$HOME/.claude/plugins/cache/$mkt/${entry%@*}" ] || uncached="$uncached $entry"
done <<EOF
$(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key' "$carrier" 2>/dev/null)
EOF

issues=""
[ -n "$missing" ] && issues="missing marketplaces:$missing"
[ -n "$uncached" ] && issues="${issues:+$issues; }uncached plugins:$uncached"
if [ -n "$issues" ]; then
  printf 'NOTE: cloud plugin pre-seed incomplete — %s. The affected plugins/skills will not load. Check GH_PAT in the environment settings, then bump CACHE_EPOCH in the Setup-script wrapper and re-save to rebuild (see scripts/cloud-setup.sh).\n' "$issues"
fi

exit 0
