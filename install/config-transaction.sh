# Configuration recovery/import helpers. Normal command paths never erase errors.
ng_config_check() {
  local shell=/system/bin/sh
  [ -x "$shell" ] || shell=bash
  "$shell" -n "$1" 2>/dev/null
}

ng_source_config() {
  local ng_had_errexit=false
  case "$-" in *e*) ng_had_errexit=true;; esac
  set +e
  . "$1"
  if $ng_had_errexit; then set -e; fi
  return 0
}

ng_load_config() {
  if ng_config_check "$config"; then
    rm -f "$TMPDIR/.config-invalid"
    ng_source_config "$config"; return 0
  fi
  exec 5>"$TMPDIR/.ng-config.lock" || return 1
  timeout 5 flock 0 <&5 || return 1
  # Recheck after acquiring the mutex; another writer may already have repaired it.
  if ng_config_check "$config"; then
    flock -u 0 <&5; exec 5>&-; rm -f "$TMPDIR/.config-invalid"; ng_source_config "$config"; return 0
  fi
  cp -p "$config" "${config}.invalid" || return 1
  if [ -f "${config}.last-good" ] && ng_config_check "${config}.last-good"; then
    cp -p "${config}.last-good" "${config}.recover.$$" && mv "${config}.recover.$$" "$config" || return 1
    ng_source_config "$config"
    rm -f "$TMPDIR/.config-invalid"
  else
    # Keep the invalid source for repair and use defaults in memory only.
    . "$execDir/default-config.txt"
    touch "$TMPDIR/.config-invalid"
  fi
  flock -u 0 <&5
  exec 5>&-
}

ng_import_config() (
  local input=$1 normalized= candidate= name=
  [ -f "$input" ] || return 11
  if ! ${ng_config_locked:-false}; then
    exec 5>"$TMPDIR/.ng-config.lock" || return 1
    timeout 5 flock 0 <&5 || return 1
  fi
  normalized=$(mktemp "${config}.import.XXXXXX") || return 1
  candidate=$normalized.merged
  trap 'rm -f "$normalized" "$candidate"' EXIT
  trap 'exit 1' HUP INT TERM
  sed 's/\r$//' "$input" > "$normalized" || return 1
  ng_config_check "$normalized" && ng_config_check "$config" || return 11
  # Partial import replaces only supplied assignments and : name= script lines.
  # Unknown extension assignments are retained, with an explicit last value rule.
  awk '
    function key(line) {
      if (line ~ /^[a-zA-Z_][a-zA-Z_0-9]*=/) { sub(/=.*/, "", line); return "v:" line }
      if (line ~ /^:/ && index(line,";")) {
        sub(/^:[ \t]*/, "", line); sub(/;.*/, "", line); sub(/=$/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line); gsub(/^\047|\047$|^\042|\042$/, "", line)
        if (line!="") return "s:" tolower(line)
      }
      return ""
    }
    FNR==NR { k=key($0); if (k!="") { if (!(k in replacements)) order[++n]=k; replacements[k]=$0 } else if ($0 ~ /^:/) extra[++nx]=$0; next }
    { k=key($0); if (k!="" && k in replacements) { if (!(k in done)) print replacements[k]; done[k]=1 }
      else print; seen[$0]=1 }
    END { for(i=1;i<=n;i++) if(!(order[i] in done)) print replacements[order[i]]; for(i=1;i<=nx;i++) if(!(extra[i] in seen)) print extra[i] }
  ' "$normalized" "$config" > "$candidate" || return 1
  ng_config_check "$candidate" || return 11
  cp -p "$config" "${config}.last-good.new" && mv "${config}.last-good.new" "${config}.last-good" || return 1
  chmod 0600 "$candidate" && mv "$candidate" "$config"
)

ng_add_script() (
  local imported=$(mktemp "$TMPDIR/.ng-script.XXXXXX") || return 1
  trap 'rm -f "$imported"' EXIT
  printf '%s\n' "$*" > "$imported"
  ng_import_config "$imported"
)

ng_replace_config() (
  local input=$1 candidate=
  if ! ${ng_config_locked:-false}; then
    exec 5>"$TMPDIR/.ng-config.lock" || return 1
    timeout 5 flock 0 <&5 || return 1
  fi
  ng_config_check "$input" || return 11
  candidate=$(mktemp "${config}.replace.XXXXXX") || return 1
  trap 'rm -f "$candidate"' EXIT
  trap 'exit 1' HUP INT TERM
  cp "$input" "$candidate" || return 1
  # Repairing an invalid config must not overwrite its last valid backup.
  if ng_config_check "$config"; then
    cp -p "$config" "${config}.last-good.new" && mv "${config}.last-good.new" "${config}.last-good" || return 1
  fi
  chmod 0600 "$candidate" && mv "$candidate" "$config"
)

ng_delete_scripts() (
  local candidate=
  exec 5>"$TMPDIR/.ng-config.lock" || return 1
  timeout 5 flock 0 <&5 || return 1
  local ng_config_locked=true
  candidate=$(mktemp "${config}.delete.XXXXXX") || return 1
  trap 'rm -f "$candidate"' EXIT
  trap 'exit 1' HUP INT TERM
  sed -E "\#$1#d" "$config" > "$candidate" || return 11
  ng_replace_config "$candidate"
)
