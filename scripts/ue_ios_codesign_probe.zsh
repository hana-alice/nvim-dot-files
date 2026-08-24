#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ '^[[:xdigit:]]{40}$' ]]; then
  print -u2 -- "usage: ue_ios_codesign_probe.zsh <40-char signing identity SHA-1>"
  exit 64
fi

readonly identity="$1"
probe_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ue-ios-codesign.XXXXXX")

cleanup() {
  if [[ -n "${probe_root:-}" && -d "$probe_root" && "${probe_root:t}" == ue-ios-codesign.* ]]; then
    /bin/rm -rf -- "$probe_root"
  fi
}
trap cleanup EXIT HUP INT TERM

/bin/cp /usr/bin/true "$probe_root/probe"
if ! output=$(/usr/bin/codesign --force --sign "$identity" --timestamp=none "$probe_root/probe" 2>&1); then
  print -u2 -- "IOS signing private key is not usable by non-interactive /usr/bin/codesign."
  print -u2 -- "Unlock the login keychain and grant /usr/bin/codesign persistent access, then run :UEIOSSetup again."
  print -u2 -- "$output"
  exit 1
fi

/usr/bin/codesign --verify --strict "$probe_root/probe"
print -- "codesign private-key probe passed"
