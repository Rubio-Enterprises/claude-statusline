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
orange='\033[93m'
green='\033[32m'
cyan='\033[36m'
red='\033[31m'
bred='\033[91m' # bright red (slot 9) — top effort tier
yellow='\033[33m'
white='\033[37m'
magenta='\033[35m'
dim='\033[2m'
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
    result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
    [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //; s/\.//g')
    ;;
  datetime)
    result=$(date -j -r "$epoch" +"%a %-m/%-d @ %l:%M%p" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
    [ -z "$result" ] && result=$(date -d "@$epoch" +"%a %-m/%-d @ %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
    ;;
  *)
    result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
    ;;
  esac
  printf "%s" "$result"
}

# ── Extract JSON data ───────────────────────────────────
# Shorten the display name to an id-like token: lowercase, split off a
# "(… context)" suffix as "[…]" first (so dots inside the size survive, e.g.
# 1.5M → [1.5m]), then hyphenate the spaces/dots in the remaining name.
# "Opus 4.8 (1M context)" → "opus-4-8[1m]"; "Opus 4.8" → "opus-4-8".
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"' | tr '[:upper:]' '[:lower:]')
model_ctx=""
ctx_re='\(([^[:space:])]+)[[:space:]]context\)$'
if [[ "$model_name" =~ $ctx_re ]]; then
  model_ctx="[${BASH_REMATCH[1]}]"
  model_name=${model_name%%(*}
fi
model_name="$(echo "$model_name" | sed -E 's/[[:space:]]+$//; s/[ .]/-/g')${model_ctx}"

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

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

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Thinking ──
pct_color=$(color_for_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_status_markers=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  # Detached HEAD: symbolic-ref is empty, so fall back to the short SHA — this
  # also un-gates the status markers below, which key off a non-empty branch.
  [ -z "$git_branch" ] && git_branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

  # Ahead/behind vs upstream (output: "<behind>\t<ahead>"); listed first so
  # the cluster reads (branch ↑N ↓N +S ~M ?U !C). Empty when no upstream.
  ab=$(git -C "$cwd" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
  if [ -n "$ab" ]; then
    read -r behind ahead <<<"$ab"
    [ "${ahead:-0}" -gt 0 ] && git_status_markers+=" ${cyan}↑${ahead}${reset}"
    [ "${behind:-0}" -gt 0 ] && git_status_markers+=" ${blue}↓${behind}${reset}"
  fi

  # Tally working-tree state from porcelain v1 ("XY path"). A file can be both
  # staged (X) and modified (Y) — e.g. "MM" — so it counts in both columns.
  porcelain=$(git -C "$cwd" status --porcelain 2>/dev/null)
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

session_duration=""
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
  start_epoch=$(to_epoch "$session_start")
  if [ -n "$start_epoch" ]; then
    now_epoch=$(date +%s)
    elapsed=$((now_epoch - start_epoch))
    if [ "$elapsed" -ge 3600 ]; then
      session_duration="$((elapsed / 3600))h$(((elapsed % 3600) / 60))m"
    elif [ "$elapsed" -ge 60 ]; then
      session_duration="$((elapsed / 60))m"
    else
      session_duration="${elapsed}s"
    fi
  fi
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="${pct_color}${pct_used}%${reset}"
line1+="${sep}"
case "$effort" in
low) line1+="${dim}⠄ ${effort}${reset}" ;;
medium) line1+="${yellow}⠆ ${effort}${reset}" ;;
high) line1+="${green}⠦ ${effort}${reset}" ;;
xhigh) line1+="${magenta}⠶ ${effort}${reset}" ;;
max) line1+="${bred}⠿ ${effort}${reset}" ;;
ultracode) line1+="${blue}◆ ${effort}${reset}" ;;
auto) line1+="${cyan}◎ ${effort}${reset}" ;;
*) line1+="${dim}⠆ ${effort}${reset}" ;;
esac
line1+="${sep}"
line1+="${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
  line1+=" ${green}(${git_branch}${reset}${git_status_markers}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
  line1+="${sep}"
  line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi

# ── OAuth token resolution ──────────────────────────────
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
#  DATA SOURCING LAYER
#
#  5h / 7d  : stdin-first. Claude Code v2.1.80+ ships rate-limit data in the
#             stdin JSON (.rate_limits.{five_hour,seven_day}.{used_percentage,
#             resets_at}); resets_at is Unix epoch seconds. Zero network, no
#             cache, immune to 429. Falls back to the API cache when stdin
#             lacks rate_limits (first render of a session, or CC < 2.1.80).
#  refresh  : single-flight via an mkdir lock, so with N concurrent sessions
#             exactly ONE invocation performs the curl per api_ttl window; the
#             rest serve cache/stdin instantly (stale-while-revalidate). The
#             hot path NEVER blocks on the network.
# ════════════════════════════════════════════════════════

# ── Configurable paths / knobs (env-overridable for tuning) ──
cache_dir="${STATUSLINE_CACHE_DIR:-/tmp/claude}"
cache_file="${cache_dir}/statusline-usage-cache.json"
lock_dir="${cache_dir}/statusline-refresh.lock"
api_ttl="${STATUSLINE_API_TTL:-900}"        # 15 min — 5h/7d cache-fallback TTL
lock_maxage="${STATUSLINE_LOCK_MAXAGE:-30}" # reclaim a lock held longer than this
ua_version="${STATUSLINE_UA_VERSION:-2.1.156}"
mkdir -p "$cache_dir"

# mtime in epoch seconds, portable (GNU stat -c, then BSD stat -f).
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
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

# Fetch the raw oauth/usage JSON on stdout. Returns non-zero without a token.
do_fetch() {
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

# Single-flight: acquire an atomic mkdir lock, fetch, write cache, release.
# Returns 0 if THIS process did the refresh; 1 if another holds a live lock.
refresh_singleflight() {
  if ! mkdir "$lock_dir" 2>/dev/null; then
    # Lock exists. A lock the winner JUST created may not have its PID
    # written yet — so a GRACE window treats a young lock as live
    # regardless of PID (without it, N losers would all tear down the
    # winner's fresh lock and each fetch — a PID-file TOCTOU). Past grace
    # we consult PID liveness; lock_maxage is the final backstop for a
    # hung / PID-less / PID-reused holder.
    local now lmtime lock_age grace owner_pid reclaim=0
    now=$(date +%s)
    lmtime=$(file_mtime "$lock_dir")
    [ -z "$lmtime" ] && lmtime=$now
    lock_age=$((now - lmtime))
    grace=3
    [ "$grace" -gt "$lock_maxage" ] && grace="$lock_maxage"

    [ "$lock_age" -lt "$grace" ] && return 1 # young lock → live winner

    owner_pid=$(cat "${lock_dir}/pid" 2>/dev/null)
    if [ -n "$owner_pid" ] && [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
      kill -0 "$owner_pid" 2>/dev/null || reclaim=1
    fi
    [ "$lock_age" -ge "$lock_maxage" ] && reclaim=1

    if [ "$reclaim" -eq 1 ]; then
      rm -rf "$lock_dir" 2>/dev/null
      mkdir "$lock_dir" 2>/dev/null || return 1 # lost the reclaim race
    else
      return 1
    fi
  fi

  # We hold the lock. Stamp our PID FIRST so racing peers past grace see a
  # live owner, then fetch and (only on a valid response) atomically cache.
  printf '%s' "$$" >"${lock_dir}/pid" 2>/dev/null
  local resp
  resp=$(do_fetch)
  if [ -n "$resp" ] && echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
    write_cache_atomic "$resp"
  fi
  rm -rf "$lock_dir" 2>/dev/null
  return 0
}

# Kick a refresh in the background (detached, output redirected) so the hot
# path serves stale this render and picks up fresh data next render.
trigger_refresh() {
  (refresh_singleflight >/dev/null 2>&1 &) >/dev/null 2>&1
}

# ── Load whatever cache we have (5h/7d fallback) ──
cache_data=""
if [ -f "$cache_file" ]; then
  cache_data=$(cat "$cache_file" 2>/dev/null)
  echo "$cache_data" | jq -e . >/dev/null 2>&1 || cache_data=""
fi

# ── Is the API cache stale? ──
api_cache_stale=true
if [ -f "$cache_file" ]; then
  cmtime=$(file_mtime "$cache_file")
  now=$(date +%s)
  [ -n "$cmtime" ] && [ "$((now - cmtime))" -lt "$api_ttl" ] && api_cache_stale=false
fi

# ── Does stdin carry rate_limits (CC ≥ 2.1.80)? ──
stdin_has_rl=false
if echo "$input" | jq -e '.rate_limits.five_hour.used_percentage != null' >/dev/null 2>&1; then
  stdin_has_rl=true
fi

# ── Refresh decision: API cache stale, or stdin can't cover 5h/7d and we
#    have no usable cache. Always non-blocking (single-flighted in the bg). ──
if $api_cache_stale || { ! $stdin_has_rl && [ -z "$cache_data" ]; }; then
  trigger_refresh
fi

# ── Resolve 5h / 7d: stdin-first, then API-cache fallback ──
five_pct=""
five_reset=""
seven_pct=""
seven_reset=""
if $stdin_has_rl; then
  five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
  five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  seven_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
  seven_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
fi
if [ -n "$cache_data" ]; then
  [ -z "$five_pct" ] && five_pct=$(echo "$cache_data" | jq -r '.five_hour.utilization // empty')
  [ -z "$five_reset" ] && five_reset=$(echo "$cache_data" | jq -r '.five_hour.resets_at // empty')
  [ -z "$seven_pct" ] && seven_pct=$(echo "$cache_data" | jq -r '.seven_day.utilization // empty')
  [ -z "$seven_reset" ] && seven_reset=$(echo "$cache_data" | jq -r '.seven_day.resets_at // empty')
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=5

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

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0
