# Configuration recovery/import helpers. Normal command paths never erase errors.
ng_config_check() {
  local shell=/system/bin/sh
  [ -x "$shell" ] || shell=bash
  "$shell" -n "$1" 2>/dev/null
}

ng_load_config() {
  if ng_config_check "$config"; then . "$config"; return $?; fi
  exec 5>"$TMPDIR/.ng-config.lock" || return 1
  timeout 5 flock 0 <&5 || return 1
  # Recheck after acquiring the mutex; another writer may already have repaired it.
  if ng_config_check "$config"; then
    flock -u 0 <&5; exec 5>&-; . "$config"; return $?
  fi
  cp -p "$config" "${config}.invalid" || return 1
  if [ -f "${config}.last-good" ] && ng_config_check "${config}.last-good"; then
    cp -p "${config}.last-good" "${config}.recover.$$" && mv "${config}.recover.$$" "$config" || return 1
    . "$config"
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
  exec 5>"$TMPDIR/.ng-config.lock" || return 1
  timeout 5 flock 0 <&5 || return 1
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
      if (line ~ /^:[ ;]*[a-zA-Z_][a-zA-Z_0-9]*=/) { sub(/^:[ ;]*/, "", line); sub(/=.*/, "", line); return "s:" line }
      return ""
    }
    FNR==NR { k=key($0); if (k!="") { if (!(k in replacements)) order[++n]=k; replacements[k]=$0 }; next }
    { k=key($0); if (k!="" && k in replacements) { if (!(k in done)) print replacements[k]; done[k]=1 }
      else print }
    END { for(i=1;i<=n;i++) if(!(order[i] in done)) print replacements[order[i]] }
  ' "$normalized" "$config" > "$candidate" || return 1
  ng_config_check "$candidate" || return 11
  cp -p "$config" "${config}.last-good.new" && mv "${config}.last-good.new" "${config}.last-good" || return 1
  chmod 0600 "$candidate" && mv "$candidate" "$config"
)
