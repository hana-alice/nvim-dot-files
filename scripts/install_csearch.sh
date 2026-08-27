#!/bin/sh

set -eu

task_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_repo_root=$(dirname -- "$task_script_dir")
task_tool_dir="$task_repo_root/tools/cindex-uefilter"
task_install_bin=${GOBIN:-}

if ! command -v go >/dev/null 2>&1; then
  printf '%s\n' 'error: Go >= 1.22 is required to install csearch' >&2
  exit 1
fi

if [ -z "$task_install_bin" ]; then
  task_go_path=$(go env GOPATH)
  task_go_path=${task_go_path%%:*}
  task_install_bin="$task_go_path/bin"
fi

mkdir -p "$task_install_bin"

printf 'Installing cindex-uefilter into %s\n' "$task_install_bin"
GOBIN="$task_install_bin" go -C "$task_tool_dir" install ./...

printf 'Installing csearch v1.2.0 into %s\n' "$task_install_bin"
GOBIN="$task_install_bin" go install github.com/google/codesearch/cmd/csearch@v1.2.0

test -x "$task_install_bin/cindex-uefilter"
test -x "$task_install_bin/csearch"

printf '%s\n' 'Installed cindex-uefilter and csearch successfully.'
printf 'Binary directory: %s\n' "$task_install_bin"
