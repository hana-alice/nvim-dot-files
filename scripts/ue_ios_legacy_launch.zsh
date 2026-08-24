#!/bin/zsh

set -u

IOS_DEPLOY=""
DEVICE_ID=""
TRANSPORT="usb"
BUNDLE_ID=""
APP_PATH=""
JSON_OUTPUT=""

fail() {
  print -u2 -r -- "[FAIL] $*"
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --ios-deploy)
      (( $# >= 2 )) || fail "$1 requires a value"
      IOS_DEPLOY="$2"
      shift 2
      ;;
    --device)
      (( $# >= 2 )) || fail "$1 requires a value"
      DEVICE_ID="$2"
      shift 2
      ;;
    --transport)
      (( $# >= 2 )) || fail "$1 requires a value"
      TRANSPORT="$2"
      shift 2
      ;;
    --bundle-id)
      (( $# >= 2 )) || fail "$1 requires a value"
      BUNDLE_ID="$2"
      shift 2
      ;;
    --app)
      (( $# >= 2 )) || fail "$1 requires a value"
      APP_PATH="$2"
      shift 2
      ;;
    --json-output)
      (( $# >= 2 )) || fail "$1 requires a value"
      JSON_OUTPUT="$2"
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -x "$IOS_DEPLOY" ]] || fail "ios-deploy is missing or not executable: $IOS_DEPLOY"
[[ "$DEVICE_ID" =~ '^[A-Fa-f0-9-]+$' ]] || fail "invalid legacy IOS device identifier"
[[ "$TRANSPORT" == "usb" || "$TRANSPORT" == "network" ]] || fail "IOS transport must be usb or network"
[[ "$BUNDLE_ID" =~ '^[A-Za-z0-9.-]+$' ]] || fail "invalid IOS bundle identifier"
[[ -d "$APP_PATH" && -f "$APP_PATH/Info.plist" ]] || fail "prepared signed IOS app is unavailable: $APP_PATH"
[[ -n "$JSON_OUTPUT" && -d "${JSON_OUTPUT:h}" ]] || fail "launch result directory is unavailable"

local_bundle=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist" 2>&1)
(( $? == 0 )) || fail "could not read the prepared app bundle identifier: $local_bundle"
[[ "$local_bundle" == "$BUNDLE_ID" ]] || fail "prepared app bundle $local_bundle does not match installed bundle $BUNDLE_ID"

typeset -a transport_args
transport_args=()
if [[ "$TRANSPORT" == "usb" ]]; then
  transport_args=(--no-wifi)
fi

print -r -- "[IOS launch] starting $BUNDLE_ID on $DEVICE_ID through legacy MobileDevice ($TRANSPORT)"
launch_output=$("$IOS_DEPLOY" \
  --id "$DEVICE_ID" \
  "${transport_args[@]}" \
  --timeout 20 \
  --noinstall \
  --justlaunch \
  --faster-path-search \
  --bundle "$APP_PATH" 2>&1)
launch_code=$?
print -r -- "$launch_output"
(( launch_code == 0 )) || fail "ios-deploy launch failed (exit=$launch_code): $launch_output"

pid=""
pid_pattern='pid:[[:space:]]*(-?[0-9]+)'
last_pid_output=""
for _ in {1..40}; do
  last_pid_output=$("$IOS_DEPLOY" \
    --id "$DEVICE_ID" \
    "${transport_args[@]}" \
    --bundle_id "$BUNDLE_ID" \
    --get_pid 2>&1)
  if [[ "$last_pid_output" =~ $pid_pattern ]] && (( match[1] > 0 )); then
    pid="$match[1]"
    break
  fi
  sleep 0.25
done

[[ -n "$pid" ]] || fail "launch returned success but no running process was found: $last_pid_output"
print -r -- "{\"deviceIdentifier\":\"$DEVICE_ID\",\"bundleIdentifier\":\"$BUNDLE_ID\",\"processIdentifier\":$pid}" > "$JSON_OUTPUT"
print -r -- "[OK] IOS app running (pid=$pid)"
