#!/usr/bin/env bash
# Hermetic integration driver for claude-statusline's renderer and installer.
# The fake codex app-server validates the JSONL handshake without touching the
# active account; fake curl makes any accidental Anthropic fetch observable.
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
has() { # desc haystack needle
  case "$2" in
  *"$3"*) ok "$1" ;;
  *) no "$1 — missing: $3" ;;
  esac
}
lacks() { # desc haystack needle
  case "$2" in
  *"$3"*) no "$1 — unexpected: $3" ;;
  *) ok "$1" ;;
  esac
}
equals() { # desc actual expected
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    no "$1 — got '$2', expected '$3'"
  fi
}
strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[[:alpha:]]//g'
}
wait_for_file() {
  local path="$1" i
  for ((i = 0; i < 100; i++)); do
    [ -f "$path" ] && return 0
    sleep 0.05
  done
  return 1
}
wait_for_absent() {
  local path="$1" i
  for ((i = 0; i < 100; i++)); do
    [ ! -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}
wait_for_log() {
  local path="$1" i
  for ((i = 0; i < 100; i++)); do
    [ -s "$path" ] && return 0
    sleep 0.05
  done
  return 1
}
wait_for_codex_pct() {
  local cache_file="$1" expected="$2" i actual
  for ((i = 0; i < 100; i++)); do
    actual=$(jq -r '(.data.rateLimits.primary.usedPercent // .data.rateLimitsByLimitId.codex.primary.usedPercent // empty)' \
      "$cache_file" 2>/dev/null)
    [ "$actual" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}
wait_for_exact_file() {
  local path="$1" expected="$2" i actual
  for ((i = 0; i < 100; i++)); do
    actual=$(cat "$path" 2>/dev/null)
    [ "$actual" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}
file_metadata() {
  stat -c '%Y:%s:%i' "$1" 2>/dev/null || stat -f '%m:%z:%i' "$1" 2>/dev/null
}
codex_keychain_account() {
  local codex_home="$1" canonical digest
  canonical=$(cd "$codex_home" 2>/dev/null && pwd -P) || canonical="$codex_home"
  digest=$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}')
  printf 'cli|%s' "${digest:0:16}"
}
codex_login_metadata() {
  local status="${1:-Logged in using ChatGPT}" rc="${2:-0}"
  printf 'status:%s:' "$rc"
  printf '%s' "$status" | cksum | awk '{printf "%s:%s", $1, $2}'
}
write_codex_cache() { # cache_dir auth_metadata response_file
  local cache_dir="$1" auth_metadata="$2" response_file="$3"
  [ -z "$auth_metadata" ] && auth_metadata="${DEFAULT_CODEX_AUTH_METADATA:-}"
  mkdir -p "$cache_dir"
  jq -cn --arg authMetadata "$auth_metadata" --argjson data "$(jq -c . "$response_file")" \
    '{authMetadata: $authMetadata, data: $data}' \
    >"$cache_dir/statusline-codex-usage-cache.json"
}
run_statusline() { # provider cache_dir payload
  STATUSLINE_RATE_LIMIT_PROVIDER="$1" STATUSLINE_CACHE_DIR="$2" \
    bash "$SL" <<<"$3"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Keep ordinary Codex cache tests independent of the developer's real login.
# The dedicated auth-invalidation test overrides this with its own auth.json.
export CODEX_HOME="$WORK/no-auth-codex-home"
mkdir -p "$CODEX_HOME"
FAKE_BIN="$WORK/bin"
CODEX_LOG="$WORK/codex.log"
CURL_LOG="$WORK/curl.log"
mkdir -p "$FAKE_BIN"
: >"$CODEX_LOG"
: >"$CURL_LOG"

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
exit 1
EOF
chmod +x "$FAKE_BIN/curl"

cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "find-generic-password -s Codex Auth -a ${FAKE_CODEX_KEYCHAIN_ACCOUNT:-}" ] \
  && [ -f "${FAKE_CODEX_KEYCHAIN_METADATA_FILE:-}" ]; then
  cat "$FAKE_CODEX_KEYCHAIN_METADATA_FILE"
  exit 0
fi
exit 44
EOF
chmod +x "$FAKE_BIN/security"

cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "login status" ]; then
  [ -n "${FAKE_CODEX_LOGIN_SLEEP:-}" ] && sleep "$FAKE_CODEX_LOGIN_SLEEP"
  login_state="${FAKE_CODEX_LOGIN_STATUS:-logged-in}"
  [ -f "${FAKE_CODEX_LOGIN_STATUS_FILE:-}" ] && login_state=$(cat "$FAKE_CODEX_LOGIN_STATUS_FILE")
  if [ "$login_state" = "logged-out" ]; then
    printf '%s\n' 'Not logged in' >&2
    exit 1
  fi
  printf '%s\n' "${FAKE_CODEX_LOGIN_STATUS:-Logged in using ChatGPT}" >&2
  exit 0
fi
printf 'argv\t%s\n' "$*" >>"$FAKE_CODEX_LOG"
while IFS= read -r line; do
  printf 'json\t%s\n' "$line" >>"$FAKE_CODEX_LOG"
  method=$(printf '%s' "$line" | jq -r '.method // empty')
  case "$method" in
  initialize)
    printf '%s\n' '{"id":1,"result":{"userAgent":"fake","codexHome":"/fake"}}'
    ;;
  account/rateLimits/read)
    case "${FAKE_CODEX_MODE:-success}" in
    fail) exit 1 ;;
    slow) sleep "${FAKE_CODEX_SLEEP:-0.5}" ;;
    ignore-term)
      trap '' TERM
      while :; do sleep 0.1; done
      ;;
    rpc-error)
      jq -cn '{id: 2, error: {code: -32000, message: "authentication required"}}'
      continue
      ;;
    esac
    result=$(jq -c . "$FAKE_CODEX_RESPONSE_FILE")
    jq -cn --argjson result "$result" '{id: 2, result: $result}'
    ;;
  esac
done
EOF
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export FAKE_CODEX_LOG="$CODEX_LOG"
export FAKE_CURL_LOG="$CURL_LOG"
DEFAULT_CODEX_AUTH_METADATA=$(codex_login_metadata)
export DEFAULT_CODEX_AUTH_METADATA
far=4102444800
far2=4102531200
past=1
base_payload=$(printf '{"model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":50000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":90000}},"cwd":"%s"}' "$ROOT")

printf '%s\n' "[1] Claude default provider regression"
claude_cache="$WORK/claude-default"
mkdir -p "$claude_cache"
printf '{"five_hour":{"utilization":12,"resets_at":%s},"seven_day":{"utilization":40,"resets_at":%s}}\n' "$far" "$far" \
  >"$claude_cache/statusline-usage-cache.json"
claude_payload=$(printf '%s' "$base_payload" | jq -c --argjson far "$far" '. + {rate_limits:{five_hour:{used_percentage:23.5,resets_at:$far},seven_day:{used_percentage:61.2,resets_at:$far}}}')
out=$(STATUSLINE_CACHE_DIR="$claude_cache" bash "$SL" <<<"$claude_payload")
plain=$(printf '%s' "$out" | strip_ansi)
has "default provider keeps normalized model" "$plain" "opus-4-8[1m]"
has "default provider keeps context usage" "$plain" "15%"
has "Claude stdin renders current window" "$plain" "cur."
has "Claude stdin renders weekly window" "$plain" "wk."
has "Claude current percentage rounds" "$plain" "24%"
has "Claude weekly percentage rounds" "$plain" "61%"
lacks "Claude mode has no Codex general label" "$plain" "gen."
lacks "Claude mode has no Codex Spark label" "$plain" "spark."
partial_reset_payload=$(printf '%s' "$claude_payload" | jq -c 'del(.rate_limits.five_hour.resets_at, .rate_limits.seven_day.resets_at)')
partial_reset=$(STATUSLINE_CACHE_DIR="$claude_cache" bash "$SL" <<<"$partial_reset_payload" | strip_ansi)
partial_reset_line=${partial_reset#*$'\n'}
if [[ "$partial_reset_line" =~ cur\..*24%.*(am|pm) ]]; then
  ok "Claude cache fills missing current reset independently"
else
  no "Claude cache did not fill the live current percentage reset"
fi
if [[ "$partial_reset_line" =~ wk\..*61%.*@.*(am|pm) ]]; then
  ok "Claude cache fills missing weekly reset independently"
else
  no "Claude cache did not fill the live weekly percentage reset"
fi
first_line=${plain%%$'\n'*}
second_line=${plain#*$'\n'}
if [ "$ROOT" = "$HOME" ]; then
  expected_cwd="~"
elif [[ "$ROOT" == "$HOME/"* ]]; then
  expected_cwd="~${ROOT#"$HOME"}"
else
  expected_cwd="$ROOT"
fi
has "cwd remains trailing and conditionally home-abbreviated" "$first_line" "$expected_cwd"
case "$second_line" in
"15% │ "*) no "effort precedes context on the second line — got '$second_line'" ;;
*" │ 15% │ "*) ok "effort precedes context on the second line" ;;
*) no "effort precedes context on the second line — got '$second_line'" ;;
esac

printf '%s\n' "[2] Codex JSONL fetch and weekly bucket rendering"
response="$WORK/codex-response.json"
cat >"$response" <<EOF
{
  "rateLimits": {
    "limitId": "codex",
    "limitName": null,
    "primary": {"usedPercent": 31, "windowDurationMins": 10080, "resetsAt": $far},
    "secondary": {"usedPercent": 99, "windowDurationMins": 300, "resetsAt": $far},
    "credits": {"hasCredits": true, "balance": "123.45"}
  },
  "rateLimitsByLimitId": {
    "codex": {
      "limitId": "codex",
      "limitName": null,
      "primary": {"usedPercent": 31, "windowDurationMins": 10080, "resetsAt": $far},
      "secondary": {"usedPercent": 99, "windowDurationMins": 300, "resetsAt": $far}
    },
    "opaque-spark-id": {
      "limitId": "future_internal_name",
      "limitName": "GPT-5.3-Codex-Spark",
      "primary": {"usedPercent": 98, "windowDurationMins": 300, "resetsAt": $far},
      "secondary": {"usedPercent": 72, "windowDurationMins": 10080, "resetsAt": $far2}
    },
    "other-model": {
      "limitId": "other-model",
      "limitName": "Unrelated Model",
      "primary": {"usedPercent": 88, "windowDurationMins": 10080, "resetsAt": $far}
    }
  },
  "rateLimitResetCredits": {"availableCount": 3, "credits": [{"id": "ignored"}]}
}
EOF
export FAKE_CODEX_RESPONSE_FILE="$response"
: >"$CODEX_LOG"
: >"$CURL_LOG"
codex_cache="$WORK/codex-fetch"
codex_payload=$(printf '%s' "$base_payload" | jq -c --argjson far "$far" '. + {rate_limits:{five_hour:{used_percentage:97,resets_at:$far},seven_day:{used_percentage:96,resets_at:$far}}}')
first=$(run_statusline codex "$codex_cache" "$codex_payload" | strip_ansi)
lacks "cold Codex render stays non-blocking" "$first" "gen."
if wait_for_file "$codex_cache/statusline-codex-usage-cache.json"; then
  ok "background Codex refresh writes isolated cache"
else
  no "background Codex refresh did not write cache"
fi
second=$(run_statusline codex "$codex_cache" "$codex_payload" | strip_ansi)
has "Codex renders canonical general weekly bucket" "$second" "gen."
has "Codex renders general usedPercent" "$second" "31%"
has "Codex finds Spark by human limitName" "$second" "spark."
has "Codex renders Spark weekly usedPercent" "$second" "72%"
case "$second" in
*"gen."*"spark."*) ok "Codex renders general before Spark" ;;
*) no "Codex did not render general before Spark" ;;
esac
lacks "Codex ignores general short window" "$second" "99%"
lacks "Codex ignores Spark short window" "$second" "98%"
lacks "Codex ignores unrelated weekly model bucket" "$second" "88%"
lacks "Codex ignores Claude stdin current label" "$second" "cur."
lacks "Codex ignores Claude stdin weekly label" "$second" "wk."
lacks "Codex ignores Claude stdin percentages" "$second" "97%"
if [ ! -s "$CURL_LOG" ]; then
  ok "Codex provider never calls Anthropic curl"
else
  no "Codex provider unexpectedly called curl"
fi
argv=$(grep '^argv' "$CODEX_LOG" | cut -f2- | head -1)
equals "Codex uses one-shot app-server stdio" "$argv" "app-server --stdio"
methods=$(grep '^json' "$CODEX_LOG" | cut -f2- | jq -r '.method' | tr '\n' ' ')
equals "Codex sends initialize, initialized, read JSONL sequence" "$methods" "initialize initialized account/rateLimits/read "
read_request=$(grep '^json' "$CODEX_LOG" | cut -f2- | jq -c 'select(.method == "account/rateLimits/read")')
equals "Codex read request uses id=2 and null params" "$read_request" '{"id":2,"method":"account/rateLimits/read","params":null}'

by_id_only="$WORK/codex-by-id-only.json"
cat >"$by_id_only" <<EOF
{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":54,"windowDurationMins":10080,"resetsAt":$far}}}}
EOF
export FAKE_CODEX_RESPONSE_FILE="$by_id_only"
by_id_cache="$WORK/codex-by-id-only"
run_statusline codex "$by_id_cache" "$base_payload" >/dev/null
if wait_for_file "$by_id_cache/statusline-codex-usage-cache.json"; then
  ok "rateLimitsByLimitId-only response passes the cache gate"
else
  no "rateLimitsByLimitId-only response was not cached"
fi
by_id_rendered=$(run_statusline codex "$by_id_cache" "$base_payload" | strip_ansi)
has "rateLimitsByLimitId-only cache renders general usage" "$by_id_rendered" "54%"

printf '%s\n' "[3] Codex partial and irrelevant bucket behavior"
spark_only="$WORK/spark-only.json"
cat >"$spark_only" <<EOF
{"rateLimits":{"limitId":"legacy","primary":null},"rateLimitsByLimitId":{"any-id":{"limitId":"renamed","limitName":"Codex Spark","primary":{"usedPercent":43,"windowDurationMins":10080,"resetsAt":$far}}}}
EOF
partial_cache="$WORK/codex-partial"
write_codex_cache "$partial_cache" "" "$spark_only"
partial=$(run_statusline codex "$partial_cache" "$base_payload" | strip_ansi)
has "missing general bucket still shows Spark" "$partial" "spark."
has "partial Spark bucket shows its percentage" "$partial" "43%"
lacks "missing general bucket stays hidden" "$partial" "gen."
resetless="$WORK/resetless.json"
cat >"$resetless" <<EOF
{"rateLimits":{"limitId":"codex","primary":{"usedPercent":57,"windowDurationMins":10080,"resetsAt":null}},"rateLimitsByLimitId":{}}
EOF
resetless_cache="$WORK/codex-resetless"
write_codex_cache "$resetless_cache" "" "$resetless"
resetless_rendered=$(run_statusline codex "$resetless_cache" "$base_payload" | strip_ansi)
has "weekly Codex usage renders without reset metadata" "$resetless_rendered" "gen."
has "resetless Codex bucket keeps its percentage" "$resetless_rendered" "57%"
spark_id_only="$WORK/spark-id-only.json"
cat >"$spark_id_only" <<EOF
{"rateLimits":{"limitId":"legacy","primary":null},"rateLimitsByLimitId":{"codex-spark":{"limitId":"codex-spark","limitName":null,"primary":{"usedPercent":46,"windowDurationMins":10080,"resetsAt":$far}}}}
EOF
spark_id_cache="$WORK/codex-spark-id"
write_codex_cache "$spark_id_cache" "" "$spark_id_only"
spark_id_rendered=$(run_statusline codex "$spark_id_cache" "$base_payload" | strip_ansi)
has "Spark bucket falls back to its metered cache key" "$spark_id_rendered" "spark."
has "Spark ID fallback keeps its weekly percentage" "$spark_id_rendered" "46%"
irrelevant="$WORK/irrelevant.json"
cat >"$irrelevant" <<EOF
{"rateLimits":{"limitId":"codex","primary":{"usedPercent":51,"windowDurationMins":300,"resetsAt":$far}},"rateLimitsByLimitId":{"other":{"limitId":"other","limitName":"Other","primary":{"usedPercent":52,"windowDurationMins":10080,"resetsAt":$far}}}}
EOF
irrelevant_cache="$WORK/codex-irrelevant"
write_codex_cache "$irrelevant_cache" "" "$irrelevant"
none=$(run_statusline codex "$irrelevant_cache" "$base_payload" | strip_ansi)
lacks "no qualifying Codex general bucket hides rate lines" "$none" "gen."
lacks "no qualifying Codex Spark bucket hides rate lines" "$none" "spark."

printf '%s\n' "[4] Provider cache isolation and unknown provider"
shared_cache="$WORK/shared-cache"
mkdir -p "$shared_cache"
printf '{"five_hour":{"utilization":14,"resets_at":%s},"seven_day":{"utilization":41,"resets_at":%s}}\n' "$far" "$far" \
  >"$shared_cache/statusline-usage-cache.json"
write_codex_cache "$shared_cache" "" "$response"
claude_from_shared=$(run_statusline claude "$shared_cache" "$base_payload" | strip_ansi)
codex_from_shared=$(run_statusline codex "$shared_cache" "$codex_payload" | strip_ansi)
has "Claude reads only Claude cache" "$claude_from_shared" "cur."
has "Claude weekly cache remains available" "$claude_from_shared" "41%"
lacks "Claude does not read Codex cache" "$claude_from_shared" "gen."
has "Codex reads only Codex cache" "$codex_from_shared" "gen."
lacks "Codex does not read Claude cache" "$codex_from_shared" "cur."
: >"$CODEX_LOG"
: >"$CURL_LOG"
unknown_cache="$WORK/unknown"
unknown=$(run_statusline something-else "$unknown_cache" "$codex_payload" | strip_ansi)
lacks "unknown provider hides Claude rate lines" "$unknown" "cur."
lacks "unknown provider hides Codex rate lines" "$unknown" "gen."
if [ ! -s "$CODEX_LOG" ] && [ ! -s "$CURL_LOG" ]; then
  ok "unknown provider performs no provider fetch"
else
  no "unknown provider performed an unrelated fetch"
fi
if [ ! -d "$unknown_cache" ]; then
  ok "unknown provider does not initialize a rate-limit cache"
else
  no "unknown provider unexpectedly created a cache directory"
fi

printf '%s\n' "[5] Codex TTL, stale fallback, max age, and reset expiry"
ttl_cache="$WORK/codex-ttl"
write_codex_cache "$ttl_cache" "" "$response"
: >"$CODEX_LOG"
fresh=$(run_statusline codex "$ttl_cache" "$base_payload" | strip_ansi)
sleep 0.2
has "fresh Codex cache renders" "$fresh" "gen."
if [ ! -s "$CODEX_LOG" ]; then
  ok "fresh Codex cache honors 300-second TTL"
else
  no "fresh Codex cache unexpectedly refreshed"
fi
: >"$CODEX_LOG"
stale=$(FAKE_CODEX_MODE=fail STATUSLINE_CODEX_TTL=0 run_statusline codex "$ttl_cache" "$base_payload" | strip_ansi)
wait_for_log "$CODEX_LOG" || true
has "failed refresh serves valid same-provider stale cache" "$stale" "gen."
if [ -s "$CODEX_LOG" ]; then
  ok "expired Codex TTL triggers background refresh"
else
  no "expired Codex TTL did not trigger refresh"
fi
old_cache="$WORK/codex-too-old"
write_codex_cache "$old_cache" "" "$response"
touch -t 202001010000 "$old_cache/statusline-codex-usage-cache.json"
too_old=$(FAKE_CODEX_MODE=fail run_statusline codex "$old_cache" "$base_payload" | strip_ansi)
lacks "Codex cache older than one hour is hidden" "$too_old" "gen."
expired_response="$WORK/expired.json"
cat >"$expired_response" <<EOF
{"rateLimits":{"limitId":"codex","primary":{"usedPercent":67,"windowDurationMins":10080,"resetsAt":$past}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":67,"windowDurationMins":10080,"resetsAt":$past}}}}
EOF
expired_cache="$WORK/codex-reset-expired"
write_codex_cache "$expired_cache" "" "$expired_response"
expired=$(FAKE_CODEX_MODE=fail run_statusline codex "$expired_cache" "$base_payload" | strip_ansi)
lacks "Codex weekly window is hidden after its reset epoch" "$expired" "gen."

rpc_error_cache="$WORK/codex-rpc-error"
: >"$CODEX_LOG"
FAKE_CODEX_MODE=rpc-error run_statusline codex "$rpc_error_cache" "$base_payload" >/dev/null
if wait_for_file "$rpc_error_cache/statusline-codex-refresh-failed"; then
  ok "Codex JSON-RPC errors terminate refresh and record backoff"
else
  no "Codex JSON-RPC error did not finish within the bounded wait"
fi
first_error_fetches=$(grep -c '^argv' "$CODEX_LOG" || true)
FAKE_CODEX_MODE=rpc-error run_statusline codex "$rpc_error_cache" "$base_payload" >/dev/null
sleep 0.2
second_error_fetches=$(grep -c '^argv' "$CODEX_LOG" || true)
equals "Codex failure backoff suppresses repeated app-server starts" "$second_error_fetches" "$first_error_fetches"

term_cache="$WORK/codex-ignore-term"
FAKE_CODEX_MODE=ignore-term STATUSLINE_CODEX_TIMEOUT=1 \
  run_statusline codex "$term_cache" "$base_payload" >/dev/null
if wait_for_file "$term_cache/statusline-codex-refresh-failed"; then
  ok "Codex deadline escalates an ignored SIGTERM and completes refresh"
else
  no "Codex process ignored termination beyond the bounded deadline"
fi
if wait_for_absent "$term_cache/statusline-codex-refresh.lock"; then
  ok "forced app-server termination releases the refresh lock"
else
  no "forced app-server termination left the refresh lock behind"
fi

failure_auth_home="$WORK/codex-failure-auth-home"
mkdir -p "$failure_auth_home"
printf '{}\n' >"$failure_auth_home/auth.json"
failure_auth_cache="$WORK/codex-failure-auth"
FAKE_CODEX_MODE=rpc-error CODEX_HOME="$failure_auth_home" \
  run_statusline codex "$failure_auth_cache" "$base_payload" >/dev/null
wait_for_file "$failure_auth_cache/statusline-codex-refresh-failed" || true
printf ' \n' >>"$failure_auth_home/auth.json"
export FAKE_CODEX_RESPONSE_FILE="$response"
CODEX_HOME="$failure_auth_home" run_statusline codex "$failure_auth_cache" "$base_payload" >/dev/null
if wait_for_file "$failure_auth_cache/statusline-codex-usage-cache.json"; then
  ok "account change clears previous-account failure backoff"
else
  no "previous-account failure backoff blocked the new account refresh"
fi

printf '%s\n' "[6] Codex auth.json metadata invalidation"
auth_home="$WORK/codex-home"
mkdir -p "$auth_home"
printf '{}\n' >"$auth_home/auth.json"
auth_cache="$WORK/codex-auth"
auth_metadata="file:$(file_metadata "$auth_home/auth.json")"
write_codex_cache "$auth_cache" "$auth_metadata" "$response"
new_response="$WORK/codex-new-account.json"
cat >"$new_response" <<EOF
{"rateLimits":{"limitId":"codex","primary":{"usedPercent":44,"windowDurationMins":10080,"resetsAt":$far}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":44,"windowDurationMins":10080,"resetsAt":$far}}}}
EOF
export FAKE_CODEX_RESPONSE_FILE="$new_response"
printf ' \n' >>"$auth_home/auth.json"
: >"$CODEX_LOG"
auth_changed=$(CODEX_HOME="$auth_home" run_statusline codex "$auth_cache" "$base_payload" | strip_ansi)
lacks "changed auth metadata immediately invalidates old account cache" "$auth_changed" "31%"
lacks "invalidated auth cache is not displayed during refresh" "$auth_changed" "gen."
if wait_for_codex_pct "$auth_cache/statusline-codex-usage-cache.json" "44"; then
  ok "auth change triggers background active-account refresh"
else
  no "auth change did not complete a background refresh"
fi
auth_refreshed=$(CODEX_HOME="$auth_home" run_statusline codex "$auth_cache" "$base_payload" | strip_ansi)
has "refreshed active account cache is rendered" "$auth_refreshed" "gen."
has "refreshed active account percentage replaces old account" "$auth_refreshed" "44%"

auth_race_home="$WORK/codex-auth-race-home"
mkdir -p "$auth_race_home"
printf '{}\n' >"$auth_race_home/auth.json"
auth_race_cache="$WORK/codex-auth-race"
auth_race_log="$WORK/codex-auth-race.log"
: >"$auth_race_log"
FAKE_CODEX_LOG="$auth_race_log" FAKE_CODEX_MODE=slow FAKE_CODEX_SLEEP=0.5 \
  CODEX_HOME="$auth_race_home" run_statusline codex "$auth_race_cache" "$base_payload" >/dev/null
wait_for_log "$auth_race_log" || true
printf ' \n' >>"$auth_race_home/auth.json"
wait_for_file "$auth_race_cache/statusline-codex-refresh-failed" || true
if [ ! -f "$auth_race_cache/statusline-codex-usage-cache.json" ]; then
  ok "auth changes during fetch discard the mismatched response"
else
  no "auth change during fetch cached limits under the wrong account metadata"
fi

generic_race_home="$WORK/codex-generic-auth-race-home"
mkdir -p "$generic_race_home"
generic_status_file="$WORK/codex-generic-login-state"
printf '%s\n' 'logged-in' >"$generic_status_file"
export FAKE_CODEX_LOGIN_STATUS_FILE="$generic_status_file"
generic_race_cache="$WORK/codex-generic-auth-race"
generic_race_log="$WORK/codex-generic-auth-race.log"
: >"$generic_race_log"
FAKE_CODEX_LOG="$generic_race_log" FAKE_CODEX_MODE=slow FAKE_CODEX_SLEEP=0.5 \
  CODEX_HOME="$generic_race_home" run_statusline codex "$generic_race_cache" "$base_payload" >/dev/null
wait_for_log "$generic_race_log" || true
printf '%s\n' 'logged-out' >"$generic_status_file"
wait_for_absent "$generic_race_cache/statusline-codex-refresh.lock" || true
if [ ! -f "$generic_race_cache/statusline-codex-usage-cache.json" ]; then
  ok "generic-keyring logout during fetch discards old-account limits"
else
  no "generic-keyring logout cached the old account response"
fi
if [ ! -f "$generic_race_cache/statusline-codex-refresh-failed" ]; then
  ok "auth mismatch does not back off the newly active account"
else
  no "auth mismatch recorded failure backoff for the new account"
fi
unset FAKE_CODEX_LOGIN_STATUS_FILE

printf '%s\n' "[7] Keyring metadata switch and logout invalidation"
keyring_home="$WORK/codex-keyring-home"
mkdir -p "$keyring_home"
keyring_metadata="$WORK/codex-keyring-metadata"
printf '%s\n' 'mdat=v1' >"$keyring_metadata"
export FAKE_CODEX_KEYCHAIN_ACCOUNT
FAKE_CODEX_KEYCHAIN_ACCOUNT=$(codex_keychain_account "$keyring_home")
export FAKE_CODEX_KEYCHAIN_METADATA_FILE="$keyring_metadata"
keyring_cache="$WORK/codex-keyring"
export FAKE_CODEX_RESPONSE_FILE="$response"
CODEX_HOME="$keyring_home" run_statusline codex "$keyring_cache" "$base_payload" >/dev/null
for _ in {1..100}; do
  [ -f "$keyring_cache/statusline-codex-usage-cache.json" ] && break
  sleep 0.05
done
keyring_initial=$(CODEX_HOME="$keyring_home" run_statusline codex "$keyring_cache" "$base_payload" | strip_ansi)
has "keyring-backed cache renders" "$keyring_initial" "31%"
printf '%s\n' 'mdat=v2' >"$keyring_metadata"
export FAKE_CODEX_RESPONSE_FILE="$new_response"
keyring_changed=$(CODEX_HOME="$keyring_home" run_statusline codex "$keyring_cache" "$base_payload" | strip_ansi)
lacks "changed keyring metadata immediately hides old account cache" "$keyring_changed" "gen."
for _ in {1..100}; do
  refreshed_pct=$(jq -r '.data.rateLimits.primary.usedPercent // empty' \
    "$keyring_cache/statusline-codex-usage-cache.json" 2>/dev/null)
  [ "$refreshed_pct" = "44" ] && break
  sleep 0.05
done
keyring_refreshed=$(CODEX_HOME="$keyring_home" run_statusline codex "$keyring_cache" "$base_payload" | strip_ansi)
has "changed keyring account refreshes active limits" "$keyring_refreshed" "44%"
rm -f "$keyring_metadata"
keyring_logout=$(FAKE_CODEX_MODE=fail CODEX_HOME="$keyring_home" \
  run_statusline codex "$keyring_cache" "$base_payload" | strip_ansi)
lacks "keyring logout immediately hides previous account cache" "$keyring_logout" "gen."
unset FAKE_CODEX_KEYCHAIN_METADATA_FILE FAKE_CODEX_KEYCHAIN_ACCOUNT
status_cache="$WORK/codex-login-status"
write_codex_cache "$status_cache" "" "$response"
STATUSLINE_CODEX_AUTH_PROBE_TTL=0 run_statusline codex "$status_cache" "$base_payload" >/dev/null
logged_in_metadata=$(codex_login_metadata)
if wait_for_exact_file "$status_cache/statusline-codex-auth-metadata" "$logged_in_metadata"; then
  ok "detached login-status probe records logged-in state"
else
  no "detached login-status probe did not record logged-in state"
fi
if wait_for_absent "$status_cache/statusline-codex-auth-refresh.lock"; then
  ok "logged-in auth probe releases its single-flight lock"
else
  no "logged-in auth probe left its single-flight lock behind"
fi
FAKE_CODEX_LOGIN_STATUS=logged-out FAKE_CODEX_MODE=fail STATUSLINE_CODEX_AUTH_PROBE_TTL=0 \
  run_statusline codex "$status_cache" "$base_payload" >/dev/null
logged_out_metadata=$(codex_login_metadata "Not logged in" 1)
if wait_for_exact_file "$status_cache/statusline-codex-auth-metadata" "$logged_out_metadata"; then
  ok "detached login-status probe records logged-out state"
else
  no "detached login-status probe did not record logged-out state"
fi
status_logout=$(FAKE_CODEX_LOGIN_STATUS=logged-out FAKE_CODEX_MODE=fail \
  run_statusline codex "$status_cache" "$base_payload" | strip_ansi)
lacks "detached login-status probe invalidates keyring cache on logout" "$status_logout" "gen."

slow_probe_cache="$WORK/codex-slow-auth-probe"
write_codex_cache "$slow_probe_cache" "$logged_in_metadata" "$response"
printf '%s' "$logged_in_metadata" >"$slow_probe_cache/statusline-codex-auth-metadata"
slow_probe_output=$(FAKE_CODEX_LOGIN_SLEEP=2 STATUSLINE_CODEX_AUTH_PROBE_TTL=0 \
  run_statusline codex "$slow_probe_cache" "$base_payload" | strip_ansi)
has "slow login-status probing stays off the render hot path" "$slow_probe_output" "gen."
for _ in {1..100}; do
  [ -d "$slow_probe_cache/statusline-codex-auth-refresh.lock" ] && break
  sleep 0.05
done
if [ -d "$slow_probe_cache/statusline-codex-auth-refresh.lock" ]; then
  ok "slow login-status probe continues in the detached background"
else
  no "slow login-status probe did not start in the background"
fi
wait_for_absent "$slow_probe_cache/statusline-codex-auth-refresh.lock" || true

printf '%s\n' "[8] Host-wide Codex single-flight"
export FAKE_CODEX_RESPONSE_FILE="$response"
singleflight_cache="$WORK/codex-singleflight"
singleflight_log="$WORK/codex-singleflight.log"
: >"$singleflight_log"
FAKE_CODEX_LOG="$singleflight_log" FAKE_CODEX_MODE=slow FAKE_CODEX_SLEEP=4 \
  STATUSLINE_CACHE_DIR="$singleflight_cache" STATUSLINE_RATE_LIMIT_PROVIDER=codex \
  bash "$SL" <<<"$base_payload" >/dev/null
for _ in {1..100}; do
  owner_marker=$(printf '%s\n' "$singleflight_cache"/statusline-codex-refresh.lock/owner-* 2>/dev/null)
  [ -e "$owner_marker" ] && break
  sleep 0.05
done
sleep 3.2
for _ in 1 2 3 4; do
  FAKE_CODEX_LOG="$singleflight_log" FAKE_CODEX_MODE=slow FAKE_CODEX_SLEEP=4 \
    STATUSLINE_CACHE_DIR="$singleflight_cache" STATUSLINE_RATE_LIMIT_PROVIDER=codex \
    bash "$SL" <<<"$base_payload" >/dev/null &
done
wait
wait_for_file "$singleflight_cache/statusline-codex-usage-cache.json" || true
wait_for_absent "$singleflight_cache/statusline-codex-refresh.lock" || true
fetch_count=$(grep -c '^argv' "$singleflight_log" || true)
equals "concurrent cold renders launch one Codex app-server" "$fetch_count" "1"

stale_lock_cache="$WORK/codex-stale-lock"
mkdir -p "$stale_lock_cache/statusline-codex-refresh.lock"
stale_owner="$stale_lock_cache/statusline-codex-refresh.lock/owner-interrupted"
: >"$stale_owner"
STATUSLINE_LOCK_MAXAGE=0 run_statusline codex "$stale_lock_cache" "$base_payload" >/dev/null
if wait_for_file "$stale_lock_cache/statusline-codex-usage-cache.json"; then
  ok "stale owner marker is reclaimed with globbing disabled"
else
  no "stale owner marker permanently blocked refresh"
fi
if [ ! -e "$stale_owner" ]; then
  ok "stale owner marker cleanup removes the interrupted owner"
else
  no "stale owner marker survived lock reclamation"
fi

printf '%s\n' "[9] Shared stale/reset policy preserves fresh Claude stdin"
claude_stale_cache="$WORK/claude-stale"
mkdir -p "$claude_stale_cache"
printf '{"five_hour":{"utilization":81,"resets_at":%s},"seven_day":{"utilization":82,"resets_at":%s}}\n' "$far" "$far" \
  >"$claude_stale_cache/statusline-usage-cache.json"
touch -t 202001010000 "$claude_stale_cache/statusline-usage-cache.json"
: >"$CURL_LOG"
claude_stdin=$(CLAUDE_CODE_OAUTH_TOKEN=dummy run_statusline claude "$claude_stale_cache" "$claude_payload" | strip_ansi)
has "fresh Claude stdin survives over-age cache rejection" "$claude_stdin" "cur."
has "fresh Claude stdin current percentage remains" "$claude_stdin" "24%"
has "fresh Claude stdin weekly percentage remains" "$claude_stdin" "61%"
claude_expired_cache="$WORK/claude-reset-expired"
mkdir -p "$claude_expired_cache"
printf '{"five_hour":{"utilization":81,"resets_at":%s},"seven_day":{"utilization":82,"resets_at":%s}}\n' "$past" "$past" \
  >"$claude_expired_cache/statusline-usage-cache.json"
claude_expired=$(FAKE_CODEX_MODE=fail run_statusline claude "$claude_expired_cache" "$base_payload" | strip_ansi)
lacks "expired cached Claude current window is hidden" "$claude_expired" "cur."
lacks "expired cached Claude weekly window is hidden" "$claude_expired" "wk."

printf '%s\n' "[10] Existing renderer fallbacks and model normalization"
out=$(printf '' | bash "$SL")
equals "empty stdin degrades to Claude" "$out" "Claude"
for pair in "Fable 5:fable-5" "Sonnet 4.6:sonnet-4-6" "Haiku 4.5:haiku-4-5"; do
  model=${pair%%:*}
  want=${pair##*:}
  payload=$(printf '{"model":{"display_name":"%s"},"cwd":"%s"}' "$model" "$ROOT")
  out=$(run_statusline something-else "$WORK/model-cache" "$payload")
  has "$model normalizes to $want" "$out" "$want"
done

printf '%s\n' "[11] install.js install and uninstall roundtrip"
if ! command -v node >/dev/null 2>&1; then
  no "node not found — cannot run installer roundtrip"
else
  install_home="$WORK/home"
  mkdir -p "$install_home"
  HOME="$install_home" node "$INSTALL" >/dev/null 2>&1
  if [ -f "$install_home/.claude/statusline.sh" ]; then
    ok "install copied statusline.sh"
  else
    no "install: statusline.sh missing"
  fi
  if grep -q '"statusLine"' "$install_home/.claude/settings.json" 2>/dev/null; then
    ok "install wired settings.json"
  else
    no "install: settings.json not wired"
  fi
  HOME="$install_home" node "$INSTALL" --uninstall >/dev/null 2>&1
  if [ ! -f "$install_home/.claude/statusline.sh" ]; then
    ok "uninstall removed statusline.sh"
  else
    no "uninstall: statusline.sh remains"
  fi
  if ! grep -q '"statusLine"' "$install_home/.claude/settings.json" 2>/dev/null; then
    ok "uninstall unwired settings.json"
  else
    no "uninstall: statusLine hook still present in settings.json"
  fi
fi

if [ -n "${RUBIO_TEST_GATE_COUNT_OUTPUT:-}" ]; then
  printf '%s\n' "$pass" >"$RUBIO_TEST_GATE_COUNT_OUTPUT"
fi
printf '\n── %s passed, %s failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
