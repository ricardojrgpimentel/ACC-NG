# ACC-NG control ownership. Keep original values until a successful reset.
# Adapted from ACC dev 39a2208/4b1bfd4; permission handling replaces 4999c63.

write_control() (
  trap - EXIT HUP INT TERM
  mode= changed=false controlFile=$2
  [ -f "$2" ] || return 1
  # Most root writes need no permission change. Never change the OEM owner.
  if { printf '%s\n' "$1" > "$2"; } 2>/dev/null; then
    return 0
  fi
  mode=$(stat -L -c '%a' "$2" 2>/dev/null) || return 1
  case "$mode" in ''|*[!0-7]*) return 1;; esac
  trap 'if $changed; then chmod "$mode" "$controlFile" || exit 1; fi' EXIT
  trap 'exit 1' HUP INT TERM
  changed=true
  chmod u+w "$2" || return 1
  printf '%s\n' "$1" > "$2"
)


apply_limit() (
  trap - EXIT HUP INT TERM
  # Subshell variables also remain available to EXIT traps after a nested exit.
  kind=$1 action=$2 marker= entry= file= value= original= saved=
  failed=0 applied=0 oppositeValue=
  pendingFile= pendingOriginal=
  shift 2
  case "$kind" in
    current) marker=$TMPDIR/.mcc-custom;;
    voltage) marker=$TMPDIR/.volt-custom;;
    temperature) marker=$TMPDIR/.tl-custom;;
    *) return 1;;
  esac

  # CLI and daemon can apply the same limit concurrently. Bound the lock wait.
  exec 9>"$marker.lock" || return 1
  # mksh closes auxiliary descriptors for child commands; pass the lock on stdin.
  timeout 5 flock 0 <&9 || return 1
  finish_limit() {
    # A signal/explicit exit during a write must not discard its original value.
    if [ "$action" != default ] && [ -f "$marker.new" ]; then
      if [ -n "$pendingFile" ] && [ -z "$saved" ] \
        && [ "$(cat "$pendingFile" 2>/dev/null)" != "$pendingOriginal" ]; then
        printf '%s::%s\n' "$pendingFile" "$pendingOriginal" >> "$marker.new"
      fi
      if [ -s "$marker.new" ]; then
        mv "$marker.new" "$marker" || exit 1
      else
        rm -f "$marker.new"
      fi
    else
      rm -f "$marker.new"
    fi
  }
  trap finish_limit EXIT
  trap 'exit 1' HUP INT TERM

  if [ "$action" = default ]; then
    [ -s "$marker" ] || return 0
    : > "$marker.new" || return 1
    while IFS= read -r entry; do
      file=${entry%%::*}
      original=${entry#*::}
      if write "$original" "$file" && [ "$(cat "$file")" = "$original" ]; then
        applied=$((applied + 1))
      else
        printf '%s\n' "$entry" >> "$marker.new"
        failed=1
      fi
    done < "$marker"
  else
    if [ -f "$marker" ]; then
      cat "$marker" > "$marker.new" || return 1
    else
      : > "$marker.new" || return 1
    fi
    for entry in "$@"; do
      case "$entry" in *::*::*) :;; *) continue;; esac
      file=${entry%%::*}
      value=${entry#*::}; value=${value%%::*}
      original=
      while IFS= read -r saved; do
        if [ "${saved%%::*}" = "$file" ]; then
          original=${saved#*::}
          break
        fi
      done < "$marker.new"
      if [ -z "$original" ]; then
        original=$(cat "$file" 2>/dev/null) || { failed=1; continue; }
        [ -n "$original" ] || { failed=1; continue; }
        saved=
      fi
      pendingFile=$file
      pendingOriginal=$original
      if write "$value" "$file" && [ "$(cat "$file")" = "$value" ]; then
        [ -n "$saved" ] || printf '%s::%s\n' "$file" "$original" >> "$marker.new"
        applied=$((applied + 1))
      else
        # A refused readback can still have changed the node. Keep its snapshot
        # for recovery, while reporting failure to the caller.
        if [ -z "$saved" ] && [ "$(cat "$file" 2>/dev/null)" != "$original" ]; then
          printf '%s::%s\n' "$file" "$original" >> "$marker.new"
        fi
        failed=1
      fi
      pendingFile=
    done
    [ "$applied" -gt 0 ] || failed=1
  fi

  if [ -s "$marker.new" ]; then
    mv "$marker.new" "$marker" || return 1
  else
    rm -f "$marker" "$marker.new" || return 1
  fi
  return "$failed"
)
