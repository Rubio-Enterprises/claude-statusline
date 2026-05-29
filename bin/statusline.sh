#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

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
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
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
            result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            ;;
    esac
    printf "%s" "$result"
}

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
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
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
line1+="${sep}"
case "$effort" in
    high)   line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

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
#  extra    : API/cache only — not present in the stdin payload.
#  refresh  : single-flight via an mkdir lock, so with N concurrent sessions
#             exactly ONE invocation performs the curl per api_ttl window; the
#             rest serve cache/stdin instantly (stale-while-revalidate). The
#             hot path NEVER blocks on the network.
# ════════════════════════════════════════════════════════

# ── Configurable paths / knobs (env-overridable for tuning) ──
cache_dir="${STATUSLINE_CACHE_DIR:-/tmp/claude}"
cache_file="${cache_dir}/statusline-usage-cache.json"
lock_dir="${cache_dir}/statusline-refresh.lock"
api_ttl="${STATUSLINE_API_TTL:-900}"          # 15 min — extra_usage changes slowly
lock_maxage="${STATUSLINE_LOCK_MAXAGE:-30}"   # reclaim a lock held longer than this
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
    printf '%s' "$payload" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$cache_file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
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
        lmtime=$(file_mtime "$lock_dir"); [ -z "$lmtime" ] && lmtime=$now
        lock_age=$(( now - lmtime ))
        grace=3; [ "$grace" -gt "$lock_maxage" ] && grace="$lock_maxage"

        [ "$lock_age" -lt "$grace" ] && return 1   # young lock → live winner

        owner_pid=$(cat "${lock_dir}/pid" 2>/dev/null)
        if [ -n "$owner_pid" ] && [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
            kill -0 "$owner_pid" 2>/dev/null || reclaim=1
        fi
        [ "$lock_age" -ge "$lock_maxage" ] && reclaim=1

        if [ "$reclaim" -eq 1 ]; then
            rm -rf "$lock_dir" 2>/dev/null
            mkdir "$lock_dir" 2>/dev/null || return 1   # lost the reclaim race
        else
            return 1
        fi
    fi

    # We hold the lock. Stamp our PID FIRST so racing peers past grace see a
    # live owner, then fetch and (only on a valid response) atomically cache.
    printf '%s' "$$" > "${lock_dir}/pid" 2>/dev/null
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
    ( refresh_singleflight >/dev/null 2>&1 & ) >/dev/null 2>&1
}

# ── Load whatever cache we have (extra_usage always; 5h/7d fallback) ──
cache_data=""
if [ -f "$cache_file" ]; then
    cache_data=$(cat "$cache_file" 2>/dev/null)
    echo "$cache_data" | jq -e . >/dev/null 2>&1 || cache_data=""
fi

# ── Is the API cache stale? ──
api_cache_stale=true
if [ -f "$cache_file" ]; then
    cmtime=$(file_mtime "$cache_file"); now=$(date +%s)
    [ -n "$cmtime" ] && [ "$(( now - cmtime ))" -lt "$api_ttl" ] && api_cache_stale=false
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
five_pct=""; five_reset=""; seven_pct=""; seven_reset=""
if $stdin_has_rl; then
    five_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
    five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    seven_pct=$(echo "$input"  | jq -r '.rate_limits.seven_day.used_percentage // empty')
    seven_reset=$(echo "$input"| jq -r '.rate_limits.seven_day.resets_at // empty')
fi
if [ -n "$cache_data" ]; then
    [ -z "$five_pct" ]    && five_pct=$(echo "$cache_data"   | jq -r '.five_hour.utilization // empty')
    [ -z "$five_reset" ]  && five_reset=$(echo "$cache_data" | jq -r '.five_hour.resets_at // empty')
    [ -z "$seven_pct" ]   && seven_pct=$(echo "$cache_data"  | jq -r '.seven_day.utilization // empty')
    [ -z "$seven_reset" ] && seven_reset=$(echo "$cache_data"| jq -r '.seven_day.resets_at // empty')
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=10

if [ -n "$five_pct" ]; then
    five_n=$(echo "$five_pct" | awk '{printf "%.0f", $1}')
    five_reset_fmt=$(format_reset_time "$five_reset" "time")
    five_bar=$(build_bar "$five_n" "$bar_width")
    five_color=$(color_for_pct "$five_n")
    five_fmt=$(printf "%3d" "$five_n")
    rate_lines+="${white}current${reset} ${five_bar} ${five_color}${five_fmt}%${reset} ${dim}⟳${reset} ${white}${five_reset_fmt}${reset}"
fi

if [ -n "$seven_pct" ]; then
    seven_n=$(echo "$seven_pct" | awk '{printf "%.0f", $1}')
    seven_reset_fmt=$(format_reset_time "$seven_reset" "datetime")
    seven_bar=$(build_bar "$seven_n" "$bar_width")
    seven_color=$(color_for_pct "$seven_n")
    seven_fmt=$(printf "%3d" "$seven_n")
    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}weekly${reset}  ${seven_bar} ${seven_color}${seven_fmt}%${reset} ${dim}⟳${reset} ${white}${seven_reset_fmt}${reset}"
fi

# ── extra_usage (API/cache only — not in stdin) ─────────
if [ -n "$cache_data" ]; then
    extra_enabled=$(echo "$cache_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_enabled" = "true" ]; then
        extra_pct=$(echo "$cache_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_used=$(echo "$cache_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
        extra_limit=$(echo "$cache_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
        extra_bar=$(build_bar "$extra_pct" "$bar_width")
        extra_pct_color=$(color_for_pct "$extra_pct")

        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ -z "$extra_reset" ]; then
            extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        fi

        extra_col="${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}⟳${reset} ${white}${extra_reset}${reset}"
        [ -n "$rate_lines" ] && rate_lines+="\n"
        rate_lines+="${extra_col}"
    fi
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0
