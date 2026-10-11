# Restore a dated NG module snapshot, keeping the user's current configuration.
ng_rollback() (
  trap - EXIT HUP INT TERM
  local snapshot=${1-} selected= candidate= staged= previous= target=
  if [ -z "$snapshot" ]; then
    for candidate in $(ls -1dt "$dataDir"/backup/* 2>/dev/null); do
      [ -f "$candidate/module/module.prop" ] && [ -f "$candidate/module/service.sh" ] || continue
      selected=$candidate
      break
    done
    snapshot=$selected
  fi
  case "$snapshot" in "$dataDir"/backup/*) :;; *) return 11;; esac
  snapshot=$(readlink -f "$snapshot") || return 11
  case "$snapshot" in "$dataDir"/backup/*) :;; *) return 11;; esac
  [ "$(sed -n 's/^id=//p' "$snapshot/module/module.prop")" = acc ] &&
    [ "$(sed -n 's/^ngApiVersion=//p' "$snapshot/module/module.prop")" = 1 ] || return 11
  for candidate in "$snapshot/module/"*.sh; do
    /system/bin/sh -n "$candidate" || return 11
  done
  target=$(readlink -f "$execDir") || return 1
  case "$target" in /data/adb/modules/acc|/data/adb/vr25/acc) :;; *) return 11;; esac
  staged=$(mktemp -d "${target}.rollback.XXXXXX") || return 1
  previous=${staged}.previous
  trap 'rm -rf "$staged"' EXIT
  trap 'exit 1' HUP INT TERM
  cp -a "$snapshot/module/." "$staged/" || return 1
  "$TMPDIR/acca" -D stop >/dev/null 2>&1 || :
  mv "$target" "$previous" || return 1
  if ! mv "$staged" "$target"; then
    mv "$previous" "$target"
    "$target/service.sh" --init
    return 1
  fi
  # Keep the replaced module as a fresh rollback snapshot, never delete it.
  candidate=$dataDir/backup/rollback-$(date +%Y%m%d-%H%M%S)-$$
  mkdir -p "$candidate"
  mv "$previous" "$candidate/module" || return 1
  cp -p "$config" "$candidate/config.txt" || return 1
  "$target/service.sh" --init
)
