#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
  printf "Claude"
  exit 0
fi

# ── Colors ──────────────────────────────────────────────
# Use ANSI palette codes (not 24-bit truecolor) so the statusline adapts
# to whichever terminal theme is active — readable on both light and dark
# backgrounds without per-theme hardcoding. Orange has no ANSI slot, so it
# falls back to bright yellow (slot 11), which renders as orange-ish in
# most palettes.
blue='\033[34m'
bblue='\033[94m'
orange='\033[93m'
green='\033[32m'
cyan='\033[36m'
red='\033[31m'
bred='\033[91m' # bright red (slot 9) — top effort tier
yellow='\033[33m'
white='\033[37m'
magenta='\033[35m'
dim='\033[2m'
default_fg='\033[39m'
reset='\033[m'

# Keep separator escape-free: Claude Code's statusline renderer truncates
# by raw byte count without subtracting ANSI escape widths, so on narrow
# terminals every saved byte pushes the truncation cliff further right.
# The separator inherits the surrounding fg color (default after reset).
sep=" │ "

# ── Helpers ─────────────────────────────────────────────
format_tokens() {
  local num=$1
  if [ "$num" -ge 1000000 ]; then
    awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
  elif [ "$num" -ge 1000 ]; then
    awk "BEGIN {printf \"%.0fk\", $num / 1000}"
  else
    printf "%d" "$num"
  fi
}

# Compact a context-window size for the model badge: 1000000 → "1m",
# 1500000 → "1.5m", 200000 → "200k". A whole number drops its ".0" so a
# suffix derived from the window size matches the "(1M context)" style
# already parsed verbatim out of display names.
format_ctx_size() {
  local num=$1
  if [ "$num" -ge 1000000 ]; then
    awk "BEGIN {v = $num / 1000000; if (v == int(v)) printf \"%dm\", v; else printf \"%.1fm\", v}"
  elif [ "$num" -ge 1000 ]; then
    awk "BEGIN {v = $num / 1000; if (v == int(v)) printf \"%dk\", v; else printf \"%.0fk\", v}"
  else
    printf "%d" "$num"
  fi
}

color_for_pct() {
  local pct=$1
  if [ "$pct" -ge 90 ]; then
    printf '%b' "$red"
  elif [ "$pct" -ge 70 ]; then
    printf '%b' "$yellow"
  elif [ "$pct" -ge 50 ]; then
    printf '%b' "$orange"
  else
    printf '%b' "$green"
  fi
}

# Color the model segment by family, classified from the already-normalized
# model_name (sourced live from Claude Code's own .model.display_name). Substring
# match also covers legacy claude-3-* ids; the "Claude" default and any
# non-Anthropic model fall through to the terminal's default foreground.
# fable is the top-of-the-line flagship → bright red (slot 9) so it stands out
# above opus's magenta; cases are ordered by tier, highest first.
color_for_model() {
  case "$1" in
  *fable*) printf '%b' "$bred" ;;
  *opus*) printf '%b' "$magenta" ;;
  *sonnet*) printf '%b' "$blue" ;;
  *haiku*) printf '%b' "$cyan" ;;
  *) printf '%b' "$default_fg" ;;
  esac
}

build_bar() {
  local pct=$1
  local width=$2
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100

  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  local bar_color
  bar_color=$(color_for_pct "$pct")

  local filled_str="" empty_str=""
  for ((i = 0; i < filled; i++)); do filled_str+="●"; done
  for ((i = 0; i < empty; i++)); do empty_str+="○"; done

  printf '%b' "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

# Accept BOTH an all-digits epoch (stdin's resets_at / session start) and an
# ISO-8601 string (the API's resets_at). Returns epoch seconds, non-zero on fail.
to_epoch() {
  local val="$1"
  [ -z "$val" ] || [ "$val" = "null" ] && return 1

  # Pure epoch seconds (stdin schema) — return as-is.
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "$val"
    return 0
  fi

  # ISO string (API schema). GNU date first.
  local epoch
  epoch=$(date -d "${val}" +%s 2>/dev/null)
  if [ -n "$epoch" ]; then
    echo "$epoch"
    return 0
  fi

  local stripped="${val%%.*}"
  stripped="${stripped%%Z}"
  stripped="${stripped%%+*}"
  stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

  if [[ "$val" == *"Z"* ]] || [[ "$val" == *"+00:00"* ]] || [[ "$val" == *"-00:00"* ]]; then
    epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
  else
    epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
  fi

  if [ -n "$epoch" ]; then
    echo "$epoch"
    return 0
  fi

  return 1
}

format_reset_time() {
  local iso_str="$1"
  local style="$2"
  [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return

  local epoch
  epoch=$(to_epoch "$iso_str")
  [ -z "$epoch" ] && return

  local result=""
  case "$style" in
  time)
    result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null)
    [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null)
    result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
    ;;
  datetime)
    result=$(date -j -r "$epoch" +"%a %-m/%-d @ %l:%M%p" 2>/dev/null)
    [ -z "$result" ] && result=$(date -d "@$epoch" +"%a %-m/%-d @ %l:%M%P" 2>/dev/null)
    result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
    ;;
  *)
    result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
    [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
    result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
    ;;
  esac
  printf "%s" "$result"
}

# ── Extract JSON data ───────────────────────────────────
# Shorten the display name to an id-like token: lowercase, drop any redundant
# "(… context)" tail (Opus's distinct 1M model carries one; without this it
# would hyphenate into the name as "opus-4-8-(1m-context)"), then hyphenate
# the spaces/dots in what remains. The context badge itself is NOT read from
# the name — it comes from context_window_size below, the single source of
# truth. The regex stays narrow (only "(… context)") so a future qualifier
# like "(Preview)" survives.
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"' | tr '[:upper:]' '[:lower:]')
ctx_re='\([^[:space:])]+[[:space:]]context\)$'
[[ "$model_name" =~ $ctx_re ]] && model_name=${model_name%%(*}
model_name="$(echo "$model_name" | sed -E 's/[[:space:]]+$//; s/[ .]/-/g')"

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

# Badge the context window when it exceeds the 200k default — "[1m]" for a 1M
# session (Opus's 1M model or Sonnet's 1M beta alike), nothing for a standard
# one. Deriving from context_window_size keeps the badge in lockstep with the
# same value the context-usage % meters against.
[ "$size" -gt 200000 ] 2>/dev/null && model_name+="[$(format_ctx_size "$size")]"

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$((input_tokens + cache_create + cache_read))

# Pre-formatted token counts retained for line-assembly use below / by
# downstream forks. shellcheck SC2034 (assigned-but-unused) is suppressed
# rather than deleting them, which would orphan format_tokens().
# shellcheck disable=SC2034
used_tokens=$(format_tokens "$current")
# shellcheck disable=SC2034
total_tokens=$(format_tokens "$size")

if [ "$size" -gt 0 ]; then
  pct_used=$((current * 100 / size))
else
  pct_used=0
fi

effort="default"
settings_path="$HOME/.claude/settings.json"
if [ -f "$settings_path" ]; then
  effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

# ── Display identity: model │ Git state │ working directory ──
pct_color=$(color_for_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
if [ "$cwd" = "$HOME" ]; then
  display_cwd="~"
elif [[ "$cwd" == "$HOME/"* ]]; then
  display_cwd="~${cwd#"$HOME"}"
else
  display_cwd="$cwd"
fi

git_branch=""
git_status_markers=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  # Detached HEAD: symbolic-ref is empty, so fall back to the short SHA — this
  # also un-gates the status markers below, which key off a non-empty branch.
  [ -z "$git_branch" ] && git_branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

  # Ahead/behind vs upstream (output: "<behind>\t<ahead>"); listed first so
  # the cluster reads (↑N ↓N +S ~M ?U !C) branch. Empty when no upstream.
  ab=$(git -C "$cwd" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
  if [ -n "$ab" ]; then
    read -r behind ahead <<<"$ab"
    [ "${ahead:-0}" -gt 0 ] && git_status_markers+=" ${cyan}↑${ahead}${reset}"
    [ "${behind:-0}" -gt 0 ] && git_status_markers+=" ${blue}↓${behind}${reset}"
  fi

  # Tally working-tree state from porcelain v1 ("XY path"). A file can be both
  # staged (X) and modified (Y) — e.g. "MM" — so it counts in both columns.
  porcelain=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
  if [ -n "$porcelain" ]; then
    n_staged=0
    n_modified=0
    n_untracked=0
    n_conflict=0
    while IFS= read -r line; do
      xy=${line:0:2}
      case "$xy" in
      "??") n_untracked=$((n_untracked + 1)) ;;
      DD | AU | UD | UA | DU | AA | UU) n_conflict=$((n_conflict + 1)) ;;
      *)
        [ "${xy:0:1}" != " " ] && n_staged=$((n_staged + 1))
        [ "${xy:1:1}" != " " ] && n_modified=$((n_modified + 1))
        ;;
      esac
    done <<<"$porcelain"
    [ "$n_staged" -gt 0 ] && git_status_markers+=" ${green}+${n_staged}${reset}"
    [ "$n_modified" -gt 0 ] && git_status_markers+=" ${yellow}~${n_modified}${reset}"
    [ "$n_untracked" -gt 0 ] && git_status_markers+=" ${dim}?${n_untracked}${reset}"
    [ "$n_conflict" -gt 0 ] && git_status_markers+=" ${red}!${n_conflict}${reset}"
  fi
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
  skip_perms="${orange}⚡${reset}  "
fi

model_color=$(color_for_model "$model_name")
context_segment="${pct_color}${pct_used}%${reset}"
effort_segment=""
case "$effort" in
low) effort_segment="${dim}${default_fg}⠄ ${effort}${reset}" ;;
medium) effort_segment="${cyan}⠆ ${effort}${reset}" ;;
high) effort_segment="${blue}⠦ ${effort}${reset}" ;;
xhigh) effort_segment="${magenta}⠶ ${effort}${reset}" ;;
max) effort_segment="${bred}⠿ ${effort}${reset}" ;;
ultracode) effort_segment="${bblue}◆ ${effort}${reset}" ;;
auto) effort_segment="${cyan}◎ ${effort}${reset}" ;;
*) effort_segment="${dim}${default_fg}⠆ ${effort}${reset}" ;;
esac

line1="${model_color}${model_name}${reset}"
if [ -n "$git_branch" ]; then
  if [ -n "$git_status_markers" ]; then
    git_status_markers=${git_status_markers# }
    line1+="${sep}${blue}(${reset}${git_status_markers}${blue}) ${git_branch}${reset}"
  else
    line1+="${sep}${blue}${git_branch}${reset}"
  fi
fi
line1+="${sep}${skip_perms}${dim}${default_fg}${display_cwd}${reset}"

# ── OAuth token resolution (Claude provider only) ──────
get_oauth_token() {
  local token=""

  if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    echo "$CLAUDE_CODE_OAUTH_TOKEN"
    return 0
  fi

  if command -v security >/dev/null 2>&1; then
    local blob
    blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if [ -n "$blob" ]; then
      token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        echo "$token"
        return 0
      fi
    fi
  fi

  local creds_file="${HOME}/.claude/.credentials.json"
  if [ -f "$creds_file" ]; then
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
      echo "$token"
      return 0
    fi
  fi

  if command -v secret-tool >/dev/null 2>&1; then
    local blob
    blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
    if [ -n "$blob" ]; then
      token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        echo "$token"
        return 0
      fi
    fi
  fi

  echo ""
}

# ════════════════════════════════════════════════════════
#  RATE-LIMIT DATA SOURCING
#
#  claude : stdin-first 5h/7d data, then the existing Anthropic usage API
#           cache fallback. TTL: 15 minutes.
#  codex  : app-server account/rateLimits/read only. Claude stdin rate_limits
#           are deliberately ignored. TTL: 5 minutes.
#  other  : no rate-limit data and no provider fetch.
#
#  Both providers use isolated cache/lock paths and the same host-wide mkdir
#  single-flight plus stale-while-revalidate behavior. All refresh work is
#  detached from the statusline hot path.
# ════════════════════════════════════════════════════════

rate_limit_provider="${STATUSLINE_RATE_LIMIT_PROVIDER:-claude}"
cache_dir="${STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline}"
lock_maxage="${STATUSLINE_LOCK_MAXAGE:-30}"
max_stale_age="${STATUSLINE_MAX_STALE_AGE:-3600}"
ua_version="${STATUSLINE_UA_VERSION:-2.1.156}"
cache_file=""
lock_dir=""
provider_ttl=""
auth_state_file=""
auth_lock_dir=""
failure_file=""
codex_auth_probe_ttl="${STATUSLINE_CODEX_AUTH_PROBE_TTL:-5}"
codex_failure_ttl="${STATUSLINE_CODEX_FAILURE_TTL:-30}"

case "$rate_limit_provider" in
claude)
  # Keep the historical Claude paths for backward-compatible cache reuse.
  cache_file="${cache_dir}/statusline-usage-cache.json"
  lock_dir="${cache_dir}/statusline-refresh.lock"
  provider_ttl="${STATUSLINE_CLAUDE_TTL:-${STATUSLINE_API_TTL:-900}}"
  ;;
codex)
  cache_file="${cache_dir}/statusline-codex-usage-cache.json"
  lock_dir="${cache_dir}/statusline-codex-refresh.lock"
  auth_state_file="${cache_dir}/statusline-codex-auth-metadata"
  auth_lock_dir="${cache_dir}/statusline-codex-auth-refresh.lock"
  failure_file="${cache_dir}/statusline-codex-refresh-failed"
  provider_ttl="${STATUSLINE_CODEX_TTL:-300}"
  ;;
esac

# mtime in epoch seconds, portable (GNU stat -c, then BSD stat -f).
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Codex auth metadata is enough to notice an active-account change without
# opening auth.json or exposing any credential value. File-backed auth uses
# stat metadata. On macOS, keyring-backed auth hashes only the item's public
# attributes (security omits the secret unless explicitly asked for -w/-g).
codex_direct_auth_metadata() {
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local auth_file="${codex_home}/auth.json"
  if [ -f "$auth_file" ]; then
    printf 'file:'
    stat -c '%Y:%s:%i' "$auth_file" 2>/dev/null || stat -f '%m:%z:%i' "$auth_file" 2>/dev/null
    return
  fi

  local canonical_home digest keychain_account keychain_metadata metadata_hash
  if command -v security >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
    canonical_home=$(cd "$codex_home" 2>/dev/null && pwd -P) || canonical_home="$codex_home"
    digest=$(printf '%s' "$canonical_home" | shasum -a 256 | awk '{print $1}')
    if [ -n "$digest" ]; then
      keychain_account="cli|${digest:0:16}"
      if keychain_metadata=$(security find-generic-password -s "Codex Auth" -a "$keychain_account" 2>/dev/null); then
        metadata_hash=$(printf '%s' "$keychain_metadata" | shasum -a 256 | awk '{print $1}')
        [ -n "$metadata_hash" ] && printf 'keychain:%s' "$metadata_hash"
        return
      fi
    fi
  fi
}

# Other keyring backends expose no safe account-specific public metadata. Probe
# their non-secret login state asynchronously and bound the CLI in case keyring
# access stalls. This detects login/logout without putting Codex on the render
# hot path; direct account-to-account switches converge on the normal cache TTL.
codex_login_status_metadata() {
  command -v codex >/dev/null 2>&1 || return 1
  local output pid i login_rc login_status
  output="${auth_state_file}.probe.$$.${RANDOM}"
  codex login status >"$output" 2>&1 &
  pid=$!
  for ((i = 0; i < 20; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      login_rc=$?
      login_status=$(cat "$output" 2>/dev/null)
      rm -f "$output"
      printf 'status:%s:' "$login_rc"
      printf '%s' "$login_status" | cksum | awk '{printf "%s:%s", $1, $2}'
      return 0
    fi
    sleep 0.05
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -f "$output"
  return 1
}

write_codex_auth_state_atomic() {
  local metadata="$1" tmp
  tmp="${auth_state_file}.tmp.$$.${RANDOM}"
  printf '%s' "$metadata" >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$auth_state_file" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
}

refresh_codex_auth_state() {
  local now lmtime lock_age metadata
  if ! mkdir "$auth_lock_dir" 2>/dev/null; then
    now=$(date +%s)
    lmtime=$(file_mtime "$auth_lock_dir")
    [ -z "$lmtime" ] && lmtime=$now
    lock_age=$((now - lmtime))
    [ "$lock_age" -lt "$lock_maxage" ] && return 1
    rmdir "$auth_lock_dir" 2>/dev/null || return 1
    mkdir "$auth_lock_dir" 2>/dev/null || return 1
  fi
  metadata=$(codex_login_status_metadata)
  [ -n "$metadata" ] && write_codex_auth_state_atomic "$metadata"
  rmdir "$auth_lock_dir" 2>/dev/null
}

trigger_codex_auth_probe() {
  local state_mtime state_age
  [ "$rate_limit_provider" = "codex" ] || return 0
  [ -n "$(codex_direct_auth_metadata)" ] && return 0
  if [ -f "$auth_state_file" ]; then
    state_mtime=$(file_mtime "$auth_state_file")
    [ -n "$state_mtime" ] && state_age=$(($(date +%s) - state_mtime))
    [ -n "${state_age:-}" ] && [ "$state_age" -lt "$codex_auth_probe_ttl" ] && return 0
  fi
  (refresh_codex_auth_state >/dev/null 2>&1 &) >/dev/null 2>&1
}

codex_auth_metadata() {
  local metadata
  metadata=$(codex_direct_auth_metadata)
  if [ -n "$metadata" ]; then
    printf '%s' "$metadata"
  elif [ -f "$auth_state_file" ]; then
    cat "$auth_state_file" 2>/dev/null
  fi
}

# Atomic cache write: temp-then-mv in the SAME dir (same filesystem → atomic
# rename), so a concurrent reader never sees a truncated file.
write_cache_atomic() {
  local payload="$1" tmp
  tmp="${cache_file}.tmp.$$.${RANDOM}"
  printf '%s' "$payload" >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$cache_file" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

fetch_claude() {
  local token
  token=$(get_oauth_token)
  [ -z "$token" ] || [ "$token" = "null" ] && return 1
  curl -s --max-time 5 \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/${ua_version}" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null
}

# Run one Codex app-server instance, complete the JSONL initialize handshake,
# request the active account's rate limits, and stop after a caller-side
# deadline. Keeping stdin open until response id=2 arrives avoids app-server
# exiting before its asynchronous account request completes.
fetch_codex() {
  command -v codex >/dev/null 2>&1 || return 1

  local timeout_seconds="${STATUSLINE_CODEX_TIMEOUT:-5}"
  local scratch fifo output server_pid deadline initialized=false response=""
  scratch="${cache_dir}/codex-fetch.$$.${RANDOM}"
  fifo="${scratch}.in"
  output="${scratch}.out"
  mkfifo "$fifo" 2>/dev/null || return 1
  : >"$output" || {
    rm -f "$fifo"
    return 1
  }

  codex app-server --stdio <"$fifo" >"$output" 2>/dev/null &
  server_pid=$!
  exec 3>"$fifo"
  printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-statusline","version":"1"},"capabilities":{"experimentalApi":true}}}' >&3

  deadline=$(($(date +%s) + timeout_seconds))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if ! $initialized && jq -s -e 'any(.[]; .id == 1 and .result != null)' "$output" >/dev/null 2>&1; then
      printf '%s\n' '{"method":"initialized"}' '{"id":2,"method":"account/rateLimits/read","params":null}' >&3
      initialized=true
    fi
    if $initialized && jq -s -e 'any(.[]; .id == 2 and .result != null)' "$output" >/dev/null 2>&1; then
      response=$(jq -s -c 'map(select(.id == 2 and .result != null)) | last.result' "$output" 2>/dev/null)
      break
    fi
    if $initialized && jq -s -e 'any(.[]; .id == 2 and .error != null)' "$output" >/dev/null 2>&1; then
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.05
  done

  exec 3>&-
  # EOF is the normal shutdown signal. Give app-server the remainder of the
  # caller-side deadline to exit cleanly; kill only a process that outlives it.
  while kill -0 "$server_pid" 2>/dev/null && [ "$(date +%s)" -le "$deadline" ]; do
    sleep 0.05
  done
  if kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null
  fi
  wait "$server_pid" 2>/dev/null
  rm -f "$fifo" "$output"

  [ -n "$response" ] && printf '%s' "$response"
}

fetch_provider() {
  case "$rate_limit_provider" in
  claude) fetch_claude ;;
  codex) fetch_codex ;;
  *) return 1 ;;
  esac
}

# Single-flight: acquire an atomic mkdir lock, fetch, write cache, release.
# The unique owner marker makes cleanup race-safe: an old process can remove
# only its own marker, and rmdir refuses to delete a replacement owner's lock.
# Returns 0 if THIS process did the refresh; 1 if another holds a live lock.
refresh_singleflight() {
  local lock_token owner_marker stale_marker="" now lmtime lock_age
  lock_token="${BASHPID:-$$}-${RANDOM}"
  owner_marker="${lock_dir}/owner-${lock_token}"

  if ! mkdir "$lock_dir" 2>/dev/null; then
    now=$(date +%s)
    lmtime=$(file_mtime "$lock_dir")
    [ -z "$lmtime" ] && lmtime=$now
    lock_age=$((now - lmtime))
    [ "$lock_age" -lt "$lock_maxage" ] && return 1

    for stale_marker in "$lock_dir"/owner-*; do
      [ -e "$stale_marker" ] || stale_marker=""
      break
    done
    [ -n "$stale_marker" ] && rm -f "$stale_marker" 2>/dev/null
    rmdir "$lock_dir" 2>/dev/null || return 1
    mkdir "$lock_dir" 2>/dev/null || return 1
  fi

  : >"$owner_marker" 2>/dev/null || {
    rmdir "$lock_dir" 2>/dev/null
    return 1
  }

  local resp cache_payload auth_metadata refresh_succeeded=false
  resp=$(fetch_provider)
  case "$rate_limit_provider" in
  claude)
    if [ -n "$resp" ] && echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
      write_cache_atomic "$resp"
    fi
    ;;
  codex)
    if [ -n "$resp" ] && echo "$resp" |
      jq -e '(.rateLimits != null) or ((.rateLimitsByLimitId // {}) | length > 0)' >/dev/null 2>&1; then
      auth_metadata=$(codex_direct_auth_metadata)
      if [ -z "$auth_metadata" ]; then
        auth_metadata=$(codex_login_status_metadata)
        [ -n "$auth_metadata" ] && write_codex_auth_state_atomic "$auth_metadata"
      fi
      cache_payload=$(jq -cn --arg authMetadata "$auth_metadata" --argjson data "$resp" \
        '{authMetadata: $authMetadata, data: $data}')
      write_cache_atomic "$cache_payload" && refresh_succeeded=true
    fi
    if $refresh_succeeded; then
      rm -f "$failure_file" 2>/dev/null
    else
      : >"$failure_file" 2>/dev/null
    fi
    ;;
  esac
  rm -f "$owner_marker" 2>/dev/null
  rmdir "$lock_dir" 2>/dev/null
  return 0
}

# Kick a refresh in the background so this render only ever reads stdin/cache.
trigger_refresh() {
  local failure_mtime failure_age
  if [ -n "$failure_file" ] && [ -f "$failure_file" ]; then
    failure_mtime=$(file_mtime "$failure_file")
    [ -n "$failure_mtime" ] && failure_age=$(($(date +%s) - failure_mtime))
    [ -n "${failure_age:-}" ] && [ "$failure_age" -lt "$codex_failure_ttl" ] && return 0
  fi
  (refresh_singleflight >/dev/null 2>&1 &) >/dev/null 2>&1
}

cache_data=""
cache_age=""
cache_is_fresh=false
cache_auth_valid=true
now=$(date +%s)

if [ -n "$cache_file" ]; then
  mkdir -p "$cache_dir"
  trigger_codex_auth_probe
  if [ -f "$cache_file" ]; then
    cmtime=$(file_mtime "$cache_file")
    [ -n "$cmtime" ] && cache_age=$((now - cmtime))
    raw_cache=$(cat "$cache_file" 2>/dev/null)
    if echo "$raw_cache" | jq -e . >/dev/null 2>&1; then
      if [ "$rate_limit_provider" = "codex" ]; then
        cached_auth_metadata=$(echo "$raw_cache" | jq -r '.authMetadata // ""')
        current_auth_metadata=$(codex_auth_metadata)
        if [ -n "$current_auth_metadata" ]; then
          [ "$cached_auth_metadata" != "$current_auth_metadata" ] && cache_auth_valid=false
        else
          case "$cached_auth_metadata" in
          file:* | keychain:*) cache_auth_valid=false ;;
          esac
        fi
        $cache_auth_valid && cache_data=$(echo "$raw_cache" | jq -c '.data // empty')
      else
        cache_data="$raw_cache"
      fi
    fi
  fi

  if [ -n "$cache_data" ] && [ -n "$cache_age" ] && [ "$cache_age" -lt "$provider_ttl" ] && $cache_auth_valid; then
    cache_is_fresh=true
  fi
  if [ -z "$cache_age" ] || [ "$cache_age" -gt "$max_stale_age" ] || ! $cache_auth_valid; then
    cache_data=""
  fi

  if ! $cache_is_fresh; then
    trigger_refresh
  fi
fi

# Cached windows are displayable only until their own reset epoch. Missing
# reset metadata preserves the historical Claude fallback behavior.
cache_window_valid() {
  local reset_at="$1" reset_epoch
  [ -z "$reset_at" ] || [ "$reset_at" = "null" ] && return 0
  reset_epoch=$(to_epoch "$reset_at") || return 1
  [ "$reset_epoch" -gt "$now" ]
}

rate_lines=""
bar_width=5

if [ "$rate_limit_provider" = "claude" ]; then
  stdin_has_rl=false
  if echo "$input" | jq -e '.rate_limits.five_hour.used_percentage != null' >/dev/null 2>&1; then
    stdin_has_rl=true
  fi

  five_pct=""
  five_reset=""
  seven_pct=""
  seven_reset=""
  five_from_cache=false
  seven_from_cache=false
  if $stdin_has_rl; then
    five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
    five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    seven_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
    seven_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
  fi
  if [ -n "$cache_data" ]; then
    if [ -z "$five_pct" ]; then
      five_pct=$(echo "$cache_data" | jq -r '.five_hour.utilization // empty')
      five_reset=$(echo "$cache_data" | jq -r '.five_hour.resets_at // empty')
      five_from_cache=true
    fi
    if [ -z "$seven_pct" ]; then
      seven_pct=$(echo "$cache_data" | jq -r '.seven_day.utilization // empty')
      seven_reset=$(echo "$cache_data" | jq -r '.seven_day.resets_at // empty')
      seven_from_cache=true
    fi
  fi

  $five_from_cache && ! cache_window_valid "$five_reset" && five_pct=""
  $seven_from_cache && ! cache_window_valid "$seven_reset" && seven_pct=""

  if [ -n "$five_pct" ]; then
    five_n=$(echo "$five_pct" | awk '{printf "%.0f", $1}')
    five_reset_fmt=$(format_reset_time "$five_reset" "time")
    five_bar=$(build_bar "$five_n" "$bar_width")
    five_color=$(color_for_pct "$five_n")
    rate_lines+="${white}cur.${reset} ${five_bar} ${five_color}${five_n}%${reset} ${white}${five_reset_fmt}${reset}"
  fi

  if [ -n "$seven_pct" ]; then
    seven_n=$(echo "$seven_pct" | awk '{printf "%.0f", $1}')
    seven_reset_fmt=$(format_reset_time "$seven_reset" "datetime")
    seven_bar=$(build_bar "$seven_n" "$bar_width")
    seven_color=$(color_for_pct "$seven_n")
    [ -n "$rate_lines" ] && rate_lines+="${sep}"
    rate_lines+="${white}wk.${reset} ${seven_bar} ${seven_color}${seven_n}%${reset} ${white}${seven_reset_fmt}${reset}"
  fi
elif [ "$rate_limit_provider" = "codex" ] && [ -n "$cache_data" ]; then
  codex_rows=$(echo "$cache_data" | jq -r '
    def buckets:
      (((.rateLimitsByLimitId // {}) | to_entries | map(.value + {cacheKey: .key})))
      + (if .rateLimits then [.rateLimits + {cacheKey: (.rateLimits.limitId // "")}] else [] end);
    def weekly($bucket):
      ([$bucket.primary, $bucket.secondary]
       | map(select(. != null and .windowDurationMins == 10080 and .usedPercent != null))
       | .[0]);
    buckets as $buckets
    | (first($buckets[] | select(.cacheKey == "codex" or .limitId == "codex")) // null) as $general
    | (first($buckets[] | select((.limitName // "" | ascii_downcase | contains("spark")))) // null) as $spark
    | [
        (weekly($general) as $window
         | select($window != null)
         | ["gen.", $window.usedPercent, ($window.resetsAt // "")]),
        (weekly($spark) as $window
         | select($window != null)
         | ["spark.", $window.usedPercent, ($window.resetsAt // "")])
      ]
    | .[] | @tsv
  ' 2>/dev/null)

  while IFS=$'\t' read -r label bucket_pct bucket_reset; do
    [ -z "$label" ] && continue
    cache_window_valid "$bucket_reset" || continue
    bucket_n=$(echo "$bucket_pct" | awk '{printf "%.0f", $1}')
    bucket_reset_fmt=$(format_reset_time "$bucket_reset" "datetime")
    bucket_bar=$(build_bar "$bucket_n" "$bar_width")
    bucket_color=$(color_for_pct "$bucket_n")
    [ -n "$rate_lines" ] && rate_lines+="${sep}"
    rate_lines+="${white}${label}${reset} ${bucket_bar} ${bucket_color}${bucket_n}%${reset}"
    [ -n "$bucket_reset_fmt" ] && rate_lines+=" ${white}${bucket_reset_fmt}${reset}"
  done <<<"$codex_rows"
fi

# ── Output ──────────────────────────────────────────────
line2="${effort_segment}${sep}${context_segment}"
[ -n "$rate_lines" ] && line2+="${sep}${rate_lines}"
printf "%b\n%b" "$line1" "$line2"

exit 0
