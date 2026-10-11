# Incoming power: 0 connected, 1 disconnected, 2 unknown.
# Shared with events and the frontend. An unreadable/invalid source cannot
# prove unplug; a valid connected source wins over incomplete other sources.
ng_power_state() {
  local file= value= type= name= seen=false unknown=false
  for file in "${1:-.}"/*/online; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    name=${file%/online}; name=${name##*/}
    name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    case "$name" in battery|bms|otg) continue;; esac
    type=$(cat "${file%/online}/type" 2>/dev/null) || type=
    type=$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')
    case "$type" in battery|bms|otg|usb_otg|usb_dfp) continue;; esac
    value=$(cat "$file" 2>/dev/null) || { unknown=true; continue; }
    case "$value" in 1) return 0;; 0) seen=true;; *) unknown=true;; esac
  done
  if $seen && ! $unknown; then
    # Some OEM switches cut the supply's online bit together with input power.
    # Readback of our own OFF write makes physical unplug unprovable.
    local marker=${TMPDIR:-/dev/.vr25/acc}/.ng-input-paused entry= path= off=
    if [ -s "$marker" ]; then
      entry=$(cat "$marker" 2>/dev/null) || return 2
      path=${entry%%::*}; off=${entry#*::}
      case "$path" in ''|*[!a-zA-Z0-9_./:-]*) return 2;; esac
      case "$path" in /*) :;; *) path=${1:-.}/$path;; esac
      value=$(cat "$path" 2>/dev/null) || return 2
      [ "$value" != "$off" ] || return 2
    fi
    return 1
  fi
  return 2
}
