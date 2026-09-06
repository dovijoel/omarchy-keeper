#!/bin/bash
# Shared helpers for the omarchy-keeper scripts. Source this file; do not run it.
#
# Everything here is deliberately boring bash: the scripts are launched from
# the Omarchy menu (Quickshell.execDetached) and from Hyprland keybindings,
# so they run without a terminal and must never block on a prompt.

OMARCHY_KEEPER_ICON=$'\U000f0306' # nf-md-key_variant

OMARCHY_KEEPER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-keeper"
OMARCHY_KEEPER_CONFIG="$OMARCHY_KEEPER_CONFIG_DIR/config"
OMARCHY_KEEPER_COMMANDER_CONFIG="$OMARCHY_KEEPER_CONFIG_DIR/commander.json"
OMARCHY_KEEPER_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-keeper"
OMARCHY_KEEPER_INDEX="$OMARCHY_KEEPER_CACHE_DIR/index.json"
OMARCHY_KEEPER_BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Defaults. The config file overrides these.
DEFAULT_ACTION="ask"            # ask | copy | type
CLIPBOARD_CLEAR_SECONDS="45"    # how long a copied secret stays on the clipboard
AUTH_MODE=""                    # password | password-2fa | sso (set during enrolment)
KEEPER_USER=""                  # Keeper account email
KEEPER_REGION="US"              # US | EU | AU | CA | JP | GOV
MENU_WIDTH="640"
MENU_MAXHEIGHT="560"
USE_DAEMON="1"                  # keep Commander warm in the background (instant lookups)
DAEMON_IDLE_SECONDS="1800"      # daemon exits after this long without requests

keeper_config_init() {
  mkdir -p "$OMARCHY_KEEPER_CONFIG_DIR" "$OMARCHY_KEEPER_CACHE_DIR"
  chmod 700 "$OMARCHY_KEEPER_CONFIG_DIR" "$OMARCHY_KEEPER_CACHE_DIR"
  if [[ ! -f $OMARCHY_KEEPER_CONFIG ]]; then
    cat >"$OMARCHY_KEEPER_CONFIG" <<CFG
# omarchy-keeper settings. KEY="value" lines; edited by omarchy-keeper-config.
DEFAULT_ACTION="ask"
CLIPBOARD_CLEAR_SECONDS="45"
AUTH_MODE=""
KEEPER_USER=""
KEEPER_REGION="US"
MENU_WIDTH="640"
MENU_MAXHEIGHT="560"
USE_DAEMON="1"
DAEMON_IDLE_SECONDS="1800"
CFG
    chmod 600 "$OMARCHY_KEEPER_CONFIG"
  fi
}

keeper_config_load() {
  keeper_config_init
  # shellcheck disable=SC1090
  source "$OMARCHY_KEEPER_CONFIG"
  [[ -n ${DEFAULT_ACTION:-} ]] || DEFAULT_ACTION="ask"
  [[ ${CLIPBOARD_CLEAR_SECONDS:-} =~ ^[0-9]+$ ]] || CLIPBOARD_CLEAR_SECONDS="45"
  [[ -n ${KEEPER_REGION:-} ]] || KEEPER_REGION="US"
  [[ ${MENU_WIDTH:-} =~ ^[0-9]+$ ]] || MENU_WIDTH="640"
  [[ ${MENU_MAXHEIGHT:-} =~ ^[0-9]+$ ]] || MENU_MAXHEIGHT="560"
  [[ ${USE_DAEMON:-} =~ ^[01]$ ]] || USE_DAEMON="1"
  [[ ${DAEMON_IDLE_SECONDS:-} =~ ^[0-9]+$ ]] || DAEMON_IDLE_SECONDS="1800"
}

keeper_config_set() {
  local key="$1" value="$2"
  keeper_config_init
  if [[ ! $key =~ ^[A-Z_]+$ ]]; then
    echo "omarchy-keeper: invalid config key: $key" >&2
    return 1
  fi
  if [[ $value == *$'\n'* || $value == *'"'* ]]; then
    echo "omarchy-keeper: invalid config value for $key" >&2
    return 1
  fi
  local line="$key=\"$value\""
  if grep -q "^$key=" "$OMARCHY_KEEPER_CONFIG"; then
    local escaped="${line//\\/\\\\}"
    escaped="${escaped//|/\\|}"
    escaped="${escaped//&/\\&}"
    sed -i "s|^$key=.*|$escaped|" "$OMARCHY_KEEPER_CONFIG"
  else
    printf '%s\n' "$line" >>"$OMARCHY_KEEPER_CONFIG"
  fi
}

keeper_region_server() {
  case "${1:-US}" in
    EU) echo "keepersecurity.eu" ;;
    AU) echo "keepersecurity.com.au" ;;
    CA) echo "keepersecurity.ca" ;;
    JP) echo "keepersecurity.jp" ;;
    GOV) echo "govcloud.keepersecurity.us" ;;
    *) echo "keepersecurity.com" ;;
  esac
}

keeper_notify() {
  omarchy-notification-send --app-name Keeper -g "$OMARCHY_KEEPER_ICON" "$@" 2>/dev/null || true
}

keeper_installed() {
  command -v keeper >/dev/null 2>&1
}

# Fails (with a notification pointing at the enrolment flow) unless Keeper
# Commander is installed and has been enrolled at least once.
keeper_require() {
  if ! keeper_installed; then
    keeper_notify -u critical "Keeper Commander is not installed" \
      "Open Keeper → Log in / re-authenticate to install and enrol" \
      --exec omarchy-keeper-login
    return 1
  fi
  if [[ ! -f $OMARCHY_KEEPER_COMMANDER_CONFIG ]]; then
    keeper_notify -u critical "Keeper is not enrolled on this device" \
      "Open Keeper → Log in / re-authenticate to sign in once" \
      --exec omarchy-keeper-login
    return 1
  fi
}

# ---- warm daemon -------------------------------------------------------------
# bin/omarchy-keeper-daemon keeps Commander logged in and synced in memory so
# lookups answer in milliseconds instead of the ~8 s a fresh CLI login costs.

keeper_daemon_socket() {
  printf '%s\n' "${XDG_RUNTIME_DIR:-/tmp}/omarchy-keeper-${UID}.sock"
}

keeper_daemon_request() {
  local sock
  sock=$(keeper_daemon_socket)
  command -v socat >/dev/null 2>&1 || return 1
  [[ -S $sock ]] || return 1
  printf '%s\n' "$1" | timeout 90 socat -t 90 - UNIX-CONNECT:"$sock" 2>/dev/null
}

keeper_daemon_ping() {
  local resp
  resp=$(keeper_daemon_request '{"op":"ping"}') || return 1
  [[ $resp == *'"pong"'* ]]
}

keeper_daemon_autostart() {
  [[ $USE_DAEMON == 1 ]] || return 1
  command -v socat >/dev/null 2>&1 || return 1
  local stamp="$OMARCHY_KEEPER_CACHE_DIR/daemon.starting"
  # Only one starter at a time; a stale stamp older than 90 s is ignored.
  if [[ -f $stamp ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 90 )); then
    return 1
  fi
  touch "$stamp"
  ( "$OMARCHY_KEEPER_BIN_DIR/omarchy-keeper-daemon" start >/dev/null 2>&1; rm -f "$stamp" ) </dev/null >/dev/null 2>&1 &
  disown
  return 1
}

# Runs one Commander command and prints its stdout. Tries the warm daemon
# first; otherwise (or if the daemon reports a failure) runs the CLI so the
# usual error handling and notifications apply.
keeper_run() {
  if [[ $USE_DAEMON == 1 ]]; then
    if [[ -S $(keeper_daemon_socket) ]]; then
      local req resp
      req=$(printf '%s\0' "$@" | jq -Rsc 'split("\u0000") | .[:-1] | {op: "run", args: .}')
      if resp=$(keeper_daemon_request "$req") && [[ -n $resp ]]; then
        if [[ $(jq -r '.ok' <<<"$resp" 2>/dev/null) == true ]]; then
          jq -rj '.output' <<<"$resp"
          return 0
        fi
      fi
    else
      keeper_daemon_autostart
    fi
  fi
  keeper_run_cli "$@"
}

# The plain CLI path: one Commander process per command. Any failure is
# turned into a notification; auth failures point at omarchy-keeper-login so
# a lapsed persistent-login session is one click away.
keeper_run_cli() {
  local out err rc
  err=$(mktemp)
  out=$(timeout 120 keeper --batch-mode --config "$OMARCHY_KEEPER_COMMANDER_CONFIG" "$@" </dev/null 2>"$err")
  rc=$?
  local errtext
  errtext=$(<"$err")
  rm -f "$err"
  if (( rc != 0 )) || [[ $out == *"Email:"* || $out == *"Password:"* ]]; then
    local combined="$out"$'\n'"$errtext"
    if [[ $combined =~ Email:|Password|Two-Factor|two-factor|2FA|[Ll]ogin|[Aa]uthenticat|[Nn]ot\ logged ]]; then
      keeper_notify -u critical "Keeper session has expired" \
        "Click to sign in again" --exec omarchy-keeper-login
    else
      local last
      last=$(printf '%s\n' "$combined" | grep -v '^\s*$' | tail -n 1)
      keeper_notify -u critical "Keeper command failed" "${last:-keeper $1 exited with status $rc}"
    fi
    return 1
  fi
  printf '%s\n' "$out"
}

keeper_index_fresh() {
  [[ -s $OMARCHY_KEEPER_INDEX ]] && jq -e 'type == "array"' "$OMARCHY_KEEPER_INDEX" >/dev/null 2>&1
}

# Emits "<icon>\t<title>\t<login> · <host> · <uid>" rows for the record picker.
# The UID rides at the end of the subtext so it comes back as the stable key.
# An optional filter matches every space-separated word against the title,
# login and URL, case-insensitively.
keeper_index_rows() {
  local filter="${1:-}"
  if ! keeper_index_fresh || ! jq -e '.[0] | has("host")' "$OMARCHY_KEEPER_INDEX" >/dev/null 2>&1; then
    if ! keeper_index_fresh; then
      keeper_notify "Loading your Keeper vault…" "First run takes a few seconds"
    fi
    "$OMARCHY_KEEPER_BIN_DIR/omarchy-keeper-sync" || return 1
  fi
  jq -r --arg icon "$OMARCHY_KEEPER_ICON" --arg filter "$filter" '
    ($filter | ascii_downcase | split(" ") | map(select(length > 0))) as $words
    | .[]
    | ((.title // "") + " " + (.login // "") + " " + (.url // "") | ascii_downcase) as $hay
    | select(all($words[]; . as $w | $hay | contains($w)))
    | ($icon + "\t"
       + (if (.title // "") == "" then "(untitled)" else .title end)
       + "\t"
       + ([.login, .host] | map(select(. != null and . != "")) | join(" · "))
       + (if (.login // "") == "" and (.host // "") == "" then "" else " · " end)
       + .record_uid)
  ' "$OMARCHY_KEEPER_INDEX"
}

# A stdin-driven twin of omarchy-menu-select. The stock command hands every
# option to perl as an argument and dies with "Argument list too long" on big
# vaults, so the payload is built with jq from stdin instead. Returns the
# selection ("label" or "label\tsubtext") on stdout; exit 1 on cancel.
OMARCHY_KEEPER_PAYLOAD_LIMIT=120000 # bytes; a single argv entry may not exceed 128 KiB

keeper_menu_select() {
  local prompt="$1" width="${2:-$MENU_WIDTH}" maxheight="${3:-$MENU_MAXHEIGHT}"
  local selection_file done_file payload
  selection_file=$(mktemp)
  done_file=$(mktemp)
  rm -f "$done_file"
  payload=$(jq -Rs --arg prompt "$prompt" --arg sel "$selection_file" --arg done "$done_file" \
    --argjson width "$width" --argjson maxheight "$maxheight" '
    {mode: "select", prompt: $prompt,
     options: (split("\n") | map(select(length > 0))),
     selectionFile: $sel, doneFile: $done, width: $width, maxHeight: $maxheight}')
  if (( ${#payload} > OMARCHY_KEEPER_PAYLOAD_LIMIT )); then
    rm -f "$selection_file"
    return 2
  fi
  omarchy-shell shell summon omarchy.menu "$payload" >/dev/null
  # Poll for the answer, but give up after two minutes so a menu that never
  # opened (another picker still owns it) cannot leave zombie processes behind.
  local waited=0
  while [[ ! -e $done_file ]]; do
    sleep 0.05
    waited=$(( waited + 1 ))
    if (( waited > 2400 )); then
      rm -f "$selection_file"
      return 1
    fi
  done
  local rc=1
  if [[ -s $selection_file ]]; then
    cat "$selection_file"
    rc=0
  fi
  rm -f "$selection_file" "$done_file"
  return $rc
}

# Puts text on the clipboard flagged as sensitive (Omarchy's clipboard history
# skips it) and clears it again after $CLIPBOARD_CLEAR_SECONDS. The wl-copy
# process is what owns the clipboard; killing it is what clears it.
keeper_copy_sensitive() {
  local text="$1" seconds="${2:-$CLIPBOARD_CLEAR_SECONDS}"
  setsid bash -c '
    printf "%s" "$1" | wl-copy --type text/plain --sensitive --foreground &
    pid=$!
    sleep "$2"
    kill "$pid" 2>/dev/null
  ' _ "$text" "$seconds" >/dev/null 2>&1 </dev/null &
  disown
}

# Types text into the focused window with wtype; never touches the clipboard.
keeper_type_text() {
  local text="$1"
  # Give the overlay or menu time to close and focus to return to the target.
  sleep 0.35
  printf '%s' "$text" | wtype -d 8 -
}

keeper_open_url() {
  local url="$1"
  [[ $url =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]] || url="https://$url"
  setsid xdg-open "$url" >/dev/null 2>&1 </dev/null &
  disown
}

# Extracts a field from `keeper get <uid> --format json` output, covering both
# typed records (fields[]/custom[]) and legacy records (top-level keys).
keeper_json_field() {
  local json="$1" field="$2"
  jq -r --arg f "$field" '
    def first_value: if type == "array" then (.[0] // "") else (. // "") end;
    def typed: ((.fields // []) + (.custom // []))
               | map(select(.type == $f or .label == $f))
               | .[0].value // empty | first_value;
    (typed // empty),
    (if $f == "login" then (.login // empty) else empty end),
    (if $f == "url" then (.login_url // .url // empty) else empty end),
    (if $f == "password" then (.password // empty) else empty end)
    | select(. != null and . != "")
  ' <<<"$json" 2>/dev/null | head -n 1
}
