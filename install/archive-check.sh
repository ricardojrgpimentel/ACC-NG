# Only regular files/directories beneath one NG archive root are extracted.
ng_archive_valid() (
  local archive=$1 listing= root= details= errors=
  errors=$(mktemp "${archive}.check.XXXXXX") || return 1
  trap 'rm -f "$errors"' EXIT
  [ -s "$archive" ] || return 1
  listing=$(timeout 15 tar -tzf "$archive" 2>"$errors") || return 1
  [ ! -s "$errors" ] || return 1
  root=$(printf '%s\n' "$listing" | sed -n '1s|/.*||p')
  case "$root" in acc-ng-*|ACC-NG-*) :;; *) return 1;; esac
  printf '%s\n' "$listing" | awk -v root="$root" '
    $0 !~ /^[a-zA-Z0-9_.\/:+@=-]+$/ { bad=1 }
    $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /^\// { bad=1 }
    index($0, root "/") != 1 { bad=1 }
    END { exit bad }' || return 1
  details=$(timeout 15 tar -tvzf "$archive" 2>"$errors") || return 1
  [ ! -s "$errors" ] || return 1
  printf '%s\n' "$details" | awk '{ total += $3; count++ } total > 134217728 || count > 4096 { bad=1 } substr($0,1,1) != "-" && substr($0,1,1) != "d" { bad=1 } END { exit bad }'
)
