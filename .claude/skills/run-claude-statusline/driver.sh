#!/usr/bin/env bash
# Smoke driver for claude-statusline. Drives the two real surfaces an agent
# would touch and asserts on their output — this is the handle the SKILL.md
# points at, not the test suite (there isn't one).
#
#   1) bin/statusline.sh — the renderer. Reads Claude Code's JSON on stdin,
#      prints the two-line status string.
#   2) bin/install.js    — the install/uninstall shim. Wires ~/.claude.
#
# Hermetic by construction: isolates HOME and the rate-limit cache, pre-seeds
# a FRESH cache so statusline.sh's `api_cache_stale` is false and it never
# fires its background curl to api.anthropic.com. MISE_OFFLINE keeps the mise
# shims from hitting GitHub when HOME is swapped for the installer test.
#
# Usage:  bash .claude/skills/run-claude-statusline/driver.sh
# Exit:   0 = all assertions passed, 1 = at least one failed.
set -u
export MISE_OFFLINE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SL="$ROOT/bin/statusline.sh"
INSTALL="$ROOT/bin/install.js"

pass=0
fail=0
ok() {
  printf '  \033[32mok\033[0m   %s\n' "$1"
  pass=$((pass + 1))
}
no() {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  fail=$((fail + 1))
}
# Quoted needle in a case pattern is matched literally (globs disabled), so
# bracket-y model ids like "opus-4-8[1m]" assert correctly.
has() { # desc  haystack  needle
  case "$2" in
  *"$3"*) ok "$1" ;;
  *) no "$1 — missing: $3" ;;
  esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export STATUSLINE_CACHE_DIR="$WORK/cache"
mkdir -p "$STATUSLINE_CACHE_DIR"
far=4102444800 # ~year 2100, so the cache never looks stale
cat >"$STATUSLINE_CACHE_DIR/statusline-usage-cache.json" <<EOF
{"five_hour":{"utilization":12,"resets_at":$far},"seven_day":{"utilization":40,"resets_at":$far}}
EOF

echo "[1] statusline.sh — two-line layout (model · Git · cwd / context · effort · rates)"
payload=$(
  cat <<EOF
{"model":{"display_name":"Opus 4.8 (1M context)"},
 "context_window":{"context_window_size":1000000,
   "current_usage":{"input_tokens":50000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":90000}},
 "cwd":"$ROOT",
 "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":$far},
                "seven_day":{"used_percentage":61.2,"resets_at":$far}},
 "session":{"start_time":0}}
EOF
)
out=$(printf '%s' "$payload" | bash "$SL")
has "model id normalized → opus-4-8[1m]" "$out" "opus-4-8[1m]"
has "context usage → 15%" "$out" "15%"
has "5h rate limit → 24%" "$out" "24%"
has "7d rate limit → 61%" "$out" "61%"
plain=$(printf '%s' "$out" | perl -pe 's/\e\[[0-9;]*[[:alpha:]]//g')
first_line=${plain%%$'\n'*}
second_line=${plain#*$'\n'}
has "cwd is trailing and home-abbreviated" "$first_line" "~${ROOT#"$HOME"}"
case "$second_line" in
"15% │ "*) ok "context usage starts the second line" ;;
*) no "context usage starts the second line — got '$second_line'" ;;
esac
case "$plain" in
*"⏱ "*) no "session duration is omitted" ;;
*) ok "session duration is omitted" ;;
esac

echo "[2] statusline.sh — empty stdin degrades to 'Claude'"
out=$(printf '' | bash "$SL")
if [ "$out" = "Claude" ]; then
  ok "empty stdin → Claude"
else
  no "empty stdin → got '$out'"
fi

echo "[3] statusline.sh — model-family normalization"
for pair in "Fable 5:fable-5" "Sonnet 4.6:sonnet-4-6" "Haiku 4.5:haiku-4-5"; do
  m=${pair%%:*}
  want=${pair##*:}
  out=$(printf '{"model":{"display_name":"%s"},"cwd":"%s"}' "$m" "$ROOT" | bash "$SL")
  has "$m → $want" "$out" "$want"
done

echo "[4] install.js — install + uninstall roundtrip (throwaway HOME)"
# node is a hard dependency here (install.js is node); preflight it so a missing
# interpreter reads as "node absent" rather than "install.js misbehaved".
if ! command -v node >/dev/null 2>&1; then
  no "node not found — cannot run installer roundtrip"
else
  H="$WORK/home"
  mkdir -p "$H"
  HOME="$H" node "$INSTALL" >/dev/null 2>&1
  if [ -f "$H/.claude/statusline.sh" ]; then
    ok "install copied statusline.sh"
  else
    no "install: statusline.sh missing"
  fi
  if grep -q '"statusLine"' "$H/.claude/settings.json" 2>/dev/null; then
    ok "install wired settings.json"
  else
    no "install: settings.json not wired"
  fi
  HOME="$H" node "$INSTALL" --uninstall >/dev/null 2>&1
  if [ ! -f "$H/.claude/statusline.sh" ]; then
    ok "uninstall removed statusline.sh"
  else
    no "uninstall: statusline.sh remains"
  fi
  if ! grep -q '"statusLine"' "$H/.claude/settings.json" 2>/dev/null; then
    ok "uninstall unwired settings.json"
  else
    no "uninstall: statusLine hook still present in settings.json"
  fi
fi

echo
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
