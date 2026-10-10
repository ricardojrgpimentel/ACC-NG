# ACC-NG discovery, adapted from ACC dev 07a3a8d/e89c463 and final filters.
# No permission changes, writes to candidates or unbounded charger waits.
ng_control_allowed() {
  local path=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$path" in
    *parallel*|*/store_mode|*bq[0-9]*/current_max|*/uevent|*/current_now|*/voltage_now|*/capacity) return 1;;
  esac
  [ -f "$1" ]
}

ng_uint() {
  case "$1" in ''|*[!0-9]*|??????????*) return 1;; esac
  # Avoid shell octal arithmetic, including an OEM reading with leading zeroes.
  local value=$1
  while [ "${value#0}" != "$value" ] && [ "$value" != 0 ]; do value=${value#0}; done
  printf '%s\n' "$value"
}

ng_control_entry() {
  local kind=$1 file=$2 value= original= marker= line= scale=v canonical=
  ng_control_allowed "$file" || return 1
  canonical=$(readlink -f "$file") || return 1
  value=$(cat "$file" 2>/dev/null) || return 1
  value=$(ng_uint "$value") || return 1
  case "$kind" in current) marker=$TMPDIR/.mcc-custom;; voltage) marker=$TMPDIR/.volt-custom;; esac
  # A restart/re-discovery must not learn our personalised value as a default.
  if [ -f "$marker" ]; then
    while IFS= read -r line; do
      if [ "$(readlink -f "${line%%::*}" 2>/dev/null)" = "$canonical" ]; then
        original=$(ng_uint "${line#*::}") || return 1
        break
      fi
    done < "$marker"
  fi
  original=${original:-$value}
  case "$kind" in
    current)
      [ "$original" -gt 1 ] || return 1
      [ "$original" -lt 10000 ] || scale=v000
      ;;
    voltage)
      if [ "$original" -ge 3700 ] && [ "$original" -le 4600 ]; then scale=v
      elif [ "$original" -ge 3700000 ] && [ "$original" -le 4600000 ]; then scale=v000
      else return 1; fi
      ;;
    *) return 1;;
  esac
  printf '%s::%s::%s\n' "$file" "$scale" "$original"
}

ng_discover_controls() (
  trap - EXIT HUP INT TERM
  kind=$1 file= pattern= entry=
  case "$kind" in
    current) cache=$TMPDIR/ch-curr-ctrl-files; ready=$TMPDIR/.ch-curr-read;;
    voltage) cache=$TMPDIR/ch-volt-ctrl-files; ready=$TMPDIR/.ch-volt-read;;
    *) return 1;;
  esac
  exec 8>"$cache.lock" || return 1
  timeout 5 flock 0 <&8 || return 1
  # Empty caches are an observed lack of support, not a reason to scan forever.
  if [ -f "$ready" ] && [ -f "$cache" ]; then
    valid=true
    if [ "$kind" = current ]; then
      stored=$(cat "$ready")
      [ "${stored:-false}" = "${currentWorkaround:-false}" ] || valid=false
    fi
    seen=
    while IFS= read -r entry; do
      checked=$(ng_control_entry "$kind" "${entry%%::*}") || valid=false
      canonical=$(readlink -f "${entry%%::*}" 2>/dev/null) || canonical=
      case "$seen" in *"|$canonical|"*) valid=false;; esac
      seen="$seen|$canonical|"
    done < "$cache"
    $valid && return 0
  fi
  # Values captured without charging often are zero; leave discovery pending.
  if not_charging; then return 2; fi
  . "$execDir/ctrl-files.sh"
  [ ! -f "$dataDir/plugins/ctrl-files.sh" ] || . "$dataDir/plugins/ctrl-files.sh"
  trap 'rm -f "$cache.new" "$cache.seen"' EXIT
  : > "$cache.new" || return 1
  : > "$cache.seen" || return 1
  if [ "$kind" = current ]; then patterns=$(ls_curr_ctrl_files)
  else patterns=$(ls_volt_ctrl_files); fi
  printf '%s\n' "$patterns" | while IFS= read -r pattern; do
    case "$pattern" in ''|\#*) continue;; esac
    for file in $pattern; do
      if [ "$kind" = current ] && ${currentWorkaround:-false}; then
        case "$file" in *batt*) :;; *) continue;; esac
      fi
      ng_control_entry "$kind" "$file" || :
    done
  done | sort -u | while IFS= read -r entry; do
    canonical=$(readlink -f "${entry%%::*}") || continue
    grep -Fxq "$canonical" "$cache.seen" && continue
    printf '%s\n' "$canonical" >> "$cache.seen"
    printf '%s\n' "$entry"
  done > "$cache.new"
  mv "$cache.new" "$cache" || return 1
  printf '%s\n' "${currentWorkaround:-false}" > "$ready"
)

ng_resolve_limit() {
  local kind=$1 requested=$2 entry= file= value= original= cache=
  case "$kind" in current) cache=$TMPDIR/ch-curr-ctrl-files;; voltage) cache=$TMPDIR/ch-volt-ctrl-files;; esac
  while IFS= read -r entry; do
    file=${entry%%::*}; value=${entry#*::}; value=${value%%::*}; original=${entry##*::}
    ng_control_allowed "$file" || return 1
    case "$value" in v) value=$requested;; v000) value=$((requested * 1000));; *) return 1;; esac
    printf '%s::%s::%s\n' "$file" "$value" "$original"
  done < "$cache"
}

# Validate automatic candidates only. Explicit user switches retain their API.
ng_filter_switch() {
  local file= value= target= multiple=false
  [ "$#" -le 3 ] || multiple=true
  for file in $1; do
    ng_control_allowed "$file" || return 1
    value=$(cat "$file" 2>/dev/null) || return 1
    printf '%s\n' "$value" | grep -Eiq '^([0-9]+|0 [01]|(en|dis)abl(e|ed)|on|off)$' || return 1
    for target in "$2" "$3"; do
      case "$target" in */*)
        local reference=$target
        target=$(cat "$reference" 2>/dev/null) || return 1
        target=$(ng_uint "$target") || return 1
        case "$reference" in */num_system_temp*levels)
          [ "$target" -gt 0 ] || return 1
          local level=$(ng_uint "$value") || return 1
          [ "$level" -le "$target" ] || return 1;;
        esac;;
      esac
    done
    if $multiple; then printf '%s %s %s ' "$file" "$2" "$3"
    else printf '%s %s %s\n' "$file" "$2" "$3"; fi
  done
}

# Preserve current/voltage controls as automatic-switch candidates. Cached
# original values, not personalised readings, provide their restore value.
ng_add_limit_switches() (
  trap - EXIT HUP INT TERM
  [ -f "$TMPDIR/ch-switches" ] || return 0
  exec 8>"$TMPDIR/.ng-switches.lock" || return 1
  timeout 5 flock 0 <&8 || return 1
  temp=$TMPDIR/ch-switches.new.$$
  trap 'rm -f "$temp"' EXIT
  cat "$TMPDIR/ch-switches" > "$temp" || return 1
  for kind in current voltage; do
    case "$kind" in current) cache=$TMPDIR/ch-curr-ctrl-files;; voltage) cache=$TMPDIR/ch-volt-ctrl-files;; esac
    [ -s "$cache" ] || continue
    while IFS= read -r entry; do
      file=${entry%%::*}; scale=${entry#*::}; scale=${scale%%::*}; original=${entry##*::}
      checked=$(ng_control_entry "$kind" "$file") || continue
      if [ "$kind" = current ]; then
        printf '%s %s 0\n' "$file" "$original" >> "$temp"
        case "$scale" in v) low=10;; v000) low=10000;; *) continue;; esac
        printf '%s %s %s\n' "$file" "$original" "$low" >> "$temp"
      else
        printf '%s %s 3600mV\n' "$file" "$original" >> "$temp"
      fi
    done < "$cache"
  done
  sort -u "$temp" > "$temp.sorted" && mv "$temp.sorted" "$TMPDIR/ch-switches"
)
