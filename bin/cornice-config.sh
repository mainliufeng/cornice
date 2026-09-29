#!/usr/bin/env bash
# Shared helpers for the CLIs that write our config.json.
#
# Sourced, not executed:
#
#   . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/cornice-config.sh"
#
# The rules are the same as in cornice-bar: the user's file is the only thing we
# write, the edit is atomic (temp file + mv), and the shell is asked to reload so
# the change is visible immediately. Panels call these CLIs instead of touching
# the file, so there is exactly one writer.

cornice_config_file() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/cornice/config.json"
}

# The user's config file as-is (empty object when there is none).
#
# Edits read from here, never from the running shell: `cornice reload` is
# asynchronous, so reading the effective config and writing it back could revert
# an edit made a moment earlier (this happened: rename, then set, lost the name).
cornice_config_raw() {
  local file
  file=$(cornice_config_file)
  if [[ -s $file ]] && jq -e . "$file" >/dev/null 2>&1; then
    cat "$file"
  else
    echo '{}'
  fi
}

# The effective configuration (defaults merged with the user's file), as the
# running shell sees it. Only used as a fallback when the file itself has nothing
# to say (e.g. a fresh install whose defaults live in config/default.json).
cornice_effective_config() {
  timeout 5 cornice ipc shell config 2>/dev/null || echo '{}'
}

# cornice_config_any <jq-filter> — apply to the file, or to the effective config
# when the file is empty.
cornice_config_any() {
  local raw
  raw=$(cornice_config_raw)
  # A file that exists but cannot be read must stop the command: writing an array
  # derived from "nothing" is how a config gets silently emptied.
  if [[ $raw == "{}" && -s $(cornice_config_file) ]]; then
    echo "cornice: $(cornice_config_file) is not readable; refusing to derive state from nothing" >&2
    return 1
  fi
  if [[ $raw == "{}" ]]; then
    cornice_effective_config | jq -c "$1"
  else
    jq -c "$1" <<<"$raw"
  fi
}

# cornice_config_edit <jq-filter> [jq args…]
#
# Applies the filter to the user's config file and reloads the shell. The filter
# receives the file's object (an empty object when there is none).
cornice_config_edit() {
  local filter="$1"; shift
  local file dir tmp
  file=$(cornice_config_file)
  dir=$(dirname "$file")
  mkdir -p "$dir" || return 1
  if [[ ! -s $file ]] || ! jq -e . "$file" >/dev/null 2>&1; then
    # Seed an empty object (dropping a corrupt file would be worse than keeping
    # it, so a file that fails to parse is left alone and reported).
    if [[ -s $file ]]; then
      echo "cornice: $file is not valid JSON; refusing to edit it" >&2
      return 1
    fi
    printf '{}\n' >"$file" || return 1
  fi
  tmp=$(mktemp "$dir/.config.XXXXXX") || return 1
  if ! jq "$filter" "$@" "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # Safety net: keep the previous file, and refuse a write that loses top-level
  # keys (which is how a config can end up quietly emptied).
  local backup="${file}.previous"
  cp -f "$file" "$backup" 2>/dev/null || true
  mv "$tmp" "$file" || return 1
  if ! jq -e . "$file" >/dev/null 2>&1; then
    mv -f "$backup" "$file" 2>/dev/null
    echo "cornice: refusing to keep an unparsable config, restored the previous one" >&2
    return 1
  fi
  local before after
  before=$(jq 'keys | length' "$backup" 2>/dev/null || echo 0)
  after=$(jq 'keys | length' "$file" 2>/dev/null || echo 0)
  if ((after < before)); then
    mv -f "$backup" "$file" 2>/dev/null
    echo "cornice: the edit would have dropped $((before - after)) top-level key(s); restored the previous config" >&2
    return 1
  fi
  timeout 5 cornice reload >/dev/null 2>&1 || true
  return 0
}

# true when the given IANA zone exists in the system timezone database.
cornice_zone_exists() {
  [[ -n ${1:-} && -e /usr/share/zoneinfo/$1 ]]
}

# List two-letter codes are not zones; a directory (e.g. "Asia") is not one
# either, but -e passes for directories — so require a file.
cornice_zone_valid() {
  [[ -n ${1:-} && -f /usr/share/zoneinfo/$1 ]]
}
