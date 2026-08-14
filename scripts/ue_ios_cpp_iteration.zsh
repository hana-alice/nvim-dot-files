#!/bin/zsh

# Nvim-owned iOS C++ iteration helper. It never edits project or engine code:
# cache state lives under <engine>/.cache/nvim-ue and all Unreal inputs remain
# read-only. AOT reuse is fail-closed: no manifest, changed input, missing output,
# ambiguous adapter, or checksum failure always means a full AOT pass.

emulate -L zsh
setopt NO_UNSET PIPE_FAIL NULL_GLOB

die() {
  print -u2 -r -- "[UE iOS] $1"
  exit "${2:-64}"
}

discover_aot_build_file() {
  local project_dir="$1"
  local -a candidates matches
  candidates=("$project_dir"/Plugins/*/Source/*/*.build.cs(N.))
  local candidate
  for candidate in "${candidates[@]}"; do
    if /usr/bin/grep -Fq 'GetEnvironmentVariable("bSkipAOTProcess")' "$candidate"; then
      matches+=("$candidate")
    fi
  done
  (( ${#matches[@]} == 1 )) || return 1
  print -r -- "$matches[1]"
}

discover_script_assemblies_dir() {
  local project_dir="$1"
  local -a matches
  matches=("$project_dir"/Content/*/ScriptAssemblies(N/))
  (( ${#matches[@]} == 1 )) || return 1
  print -r -- "$matches[1]"
}

collect_aot_inputs() {
  local project_dir="$1"
  local plugin_root="$2"
  local script_assemblies
  script_assemblies=$(discover_script_assemblies_dir "$project_dir") || return 1
  local runtime_dir="$plugin_root/ThirdParty/mono/runtime/IOS/Release"
  local compiler_dir="$plugin_root/Tools/AOTCompiler/IOS"
  local postprocess_dir="$plugin_root/Tools/AssmblySourcePostprocess"

  AOT_INPUTS=(
    "$script_assemblies"/*.dll(N.)
    "$runtime_dir"/*.dll(N.)
    "$compiler_dir"/**/*(N.)
    "$postprocess_dir"/**/*(N.)
    "$AOT_BUILD_FILE"
  )
  (( ${#AOT_INPUTS[@]} > 1 ))
}

write_fingerprint() {
  local destination="$1"
  local sdk_path clang_version
  sdk_path=$("$XCRUN" --sdk iphoneos --show-sdk-path 2>/dev/null) || return 1
  clang_version=$("$XCRUN" clang --version 2>/dev/null) || return 1
  clang_version=${clang_version%%$'\n'*}

  {
    print -r -- "schema=ue-ios-aot-v1"
    print -r -- "project=$PROJECT_DIR"
    print -r -- "target=$TARGET_NAME"
    print -r -- "configuration=$CONFIGURATION"
    print -r -- "sdk=$sdk_path"
    print -r -- "clang=$clang_version"
    local input
    for input in "${AOT_INPUTS[@]}"; do
      /usr/bin/shasum -a 256 "$input" || return 1
    done
  } >| "$destination"
}

outputs_are_present() {
  local manifest="$1"
  [[ -s "$manifest" ]] || return 1
  local line expected output actual found=false
  while IFS= read -r line; do
    expected=${line%% *}
    output=${line#*  }
    [[ -n "$expected" && "$output" != "$line" && -f "$output" ]] || return 1
    actual=$(/usr/bin/shasum -a 256 "$output") || return 1
    [[ "${actual%% *}" == "$expected" ]] || return 1
    found=true
  done < "$manifest"
  [[ "$found" == true ]]
}

invalidate_cache() {
  local path
  for path in "$@"; do
    if [[ -f "$path" ]]; then
      /bin/mv -f "$path" "$path.invalid"
    fi
  done
}

run_build() {
  local project_dir="" cache_dir="" target_name="" configuration="" xcrun=""
  while (( $# > 0 )); do
    case "$1" in
      --project-dir) project_dir="${2:-}"; shift 2 ;;
      --cache-dir) cache_dir="${2:-}"; shift 2 ;;
      --target) target_name="${2:-}"; shift 2 ;;
      --configuration) configuration="${2:-}"; shift 2 ;;
      --xcrun) xcrun="${2:-}"; shift 2 ;;
      --) shift; break ;;
      *) die "unknown build option: $1" ;;
    esac
  done
  [[ -d "$project_dir" ]] || die "project directory does not exist: $project_dir" 66
  [[ -n "$cache_dir" && -n "$target_name" && -n "$configuration" ]] || die "incomplete build context"
  [[ -x "$xcrun" ]] || die "xcrun is unavailable: $xcrun" 69
  (( $# > 0 )) || die "native Build.sh argv is missing"

  PROJECT_DIR="$project_dir"
  TARGET_NAME="$target_name"
  CONFIGURATION="$configuration"
  XCRUN="$xcrun"
  unset bDisableAOT
  unset bSkipAOTProcess

  /bin/mkdir -p "$cache_dir" || die "cannot create AOT cache directory" 73
  local key_line key
  key_line=$(print -rn -- "$project_dir|$target_name|$configuration" | /usr/bin/shasum -a 256) \
    || die "cannot derive AOT cache key" 74
  key=${key_line%% *}
  local fingerprint="$cache_dir/$key.sha256"
  local output_manifest="$cache_dir/$key.outputs"
  local fingerprint_tmp
  fingerprint_tmp=$(/usr/bin/mktemp "$cache_dir/$key.fingerprint.XXXXXX") \
    || die "cannot allocate AOT fingerprint" 74

  local cache_ready=false cache_hit=false
  local build_file
  if build_file=$(discover_aot_build_file "$project_dir"); then
    AOT_BUILD_FILE="$build_file"
    local plugin_root=${build_file:h}
    plugin_root=${plugin_root:h}
    plugin_root=${plugin_root:h}
    AOT_OUTPUT_DIR="$plugin_root/ThirdParty/mono/lib/IOS/Release"
    if collect_aot_inputs "$project_dir" "$plugin_root" && write_fingerprint "$fingerprint_tmp"; then
      cache_ready=true
      if [[ -s "$fingerprint" ]] \
        && /usr/bin/cmp -s "$fingerprint_tmp" "$fingerprint" \
        && outputs_are_present "$output_manifest"; then
        cache_hit=true
      fi
    fi
  fi

  if [[ "$cache_hit" == true ]]; then
    export bSkipAOTProcess=true
    print -r -- "[UE iOS] AOT cache hit: verified inputs and outputs; reusing AOT artifacts"
  else
    invalidate_cache "$fingerprint" "$output_manifest"
    print -r -- "[UE iOS] AOT cache miss: running the full AOT process"
  fi

  "$@"
  local build_code=$?
  if (( build_code != 0 )); then
    /bin/rm -f "$fingerprint_tmp"
    return "$build_code"
  fi

  if [[ "$cache_hit" == true ]]; then
    /bin/rm -f "$fingerprint_tmp"
    return 0
  fi

  if [[ "$cache_ready" == true ]]; then
    local plugin_root=${AOT_BUILD_FILE:h}
    plugin_root=${plugin_root:h}
    plugin_root=${plugin_root:h}
    if collect_aot_inputs "$project_dir" "$plugin_root" && write_fingerprint "$fingerprint_tmp"; then
      local -a outputs
      outputs=("$AOT_OUTPUT_DIR"/*.embeddedframework.zip(N.))
      if (( ${#outputs[@]} > 0 )); then
        local output_tmp
        output_tmp=$(/usr/bin/mktemp "$cache_dir/$key.outputs.XXXXXX") \
          || die "cannot allocate AOT output manifest" 74
        : >| "$output_tmp"
        local output
        for output in "${outputs[@]}"; do
          /usr/bin/shasum -a 256 "$output" >> "$output_tmp" || die "cannot fingerprint AOT output" 74
        done
        /bin/mv -f "$fingerprint_tmp" "$fingerprint"
        /bin/mv -f "$output_tmp" "$output_manifest"
        print -r -- "[UE iOS] AOT cache refreshed: ${#outputs[@]} verified framework artifact(s)"
        return 0
      fi
    fi
  fi

  /bin/rm -f "$fingerprint_tmp"
  print -r -- "[UE iOS] AOT cache not updated: adapter inputs or framework outputs were incomplete"
  return 0
}

run_symbols() {
  local xcrun="" binary=""
  while (( $# > 0 )); do
    case "$1" in
      --xcrun) xcrun="${2:-}"; shift 2 ;;
      --binary) binary="${2:-}"; shift 2 ;;
      *) die "unknown symbols option: $1" ;;
    esac
  done
  [[ -x "$xcrun" ]] || die "xcrun is unavailable: $xcrun" 69
  [[ -f "$binary" ]] || die "IOS binary does not exist; run :UEBuildIOS first: $binary" 66

  local dsym="$binary.dSYM"
  print -r -- "[UE iOS] Generating dSYM on demand (no ZIP): $dsym"
  "$xcrun" dsymutil "$binary" -o "$dsym" || return $?

  local binary_probe dsym_probe binary_uuids dsym_uuids
  binary_probe=$("$xcrun" dwarfdump --uuid "$binary") || return $?
  dsym_probe=$("$xcrun" dwarfdump --uuid "$dsym") || return $?
  print -r -- "[UE iOS] Binary UUID"
  print -r -- "$binary_probe"
  print -r -- "[UE iOS] dSYM UUID"
  print -r -- "$dsym_probe"

  binary_uuids=$(print -r -- "$binary_probe" | /usr/bin/awk '/UUID:/{print $2}' | /usr/bin/sort)
  dsym_uuids=$(print -r -- "$dsym_probe" | /usr/bin/awk '/UUID:/{print $2}' | /usr/bin/sort)
  [[ -n "$binary_uuids" && "$binary_uuids" == "$dsym_uuids" ]] \
    || die "dSYM UUID does not match the current IOS binary" 65
  print -r -- "[UE iOS] dSYM UUID verification passed"
}

(( $# > 0 )) || die "expected subcommand: build or symbols"
subcommand="$1"
shift
case "$subcommand" in
  build) run_build "$@" ;;
  symbols) run_symbols "$@" ;;
  *) die "unknown subcommand: $subcommand" ;;
esac
