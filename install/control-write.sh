write() {
  local i=y
  local f=$dataDir/logs/write.log
  blacklisted=false
  if [ -f "$2" ]; then
    case "$(grep -E "^(#$2|$2)$" $f 2>/dev/null || :)" in
      \#*) blacklisted=true; i=x;;
      */*) write_control "$(eval "echo $1")" "$2" || i=x;;
      *) echo \#$2 >> $f
         write_control "$(eval "echo $1")" "$2" || i=x
         sed -i "s|^#$2$|$2|" $f;;
    esac
  else
    i=x
  fi
  f="$(cat $2)" 2>/dev/null || :
  rm $TMPDIR/.nowrite 2>/dev/null || :
  if [ -n "$f" ]; then
    [ "$f" != "$oppositeValue" ] || { touch $TMPDIR/.nowrite; i=x; }
  fi
  if [ -n "${exitCode_-}" ]; then
    [ -n "${swValue-}" ] && swValue="$swValue, $f" || swValue="$f"
  fi
  [ $i = x ] && return ${3-1} || {
    for i in 1 2 3; do
      usleep 330000
      write_control "$(eval "echo $1")" "$2" || return 1
    done
  }
}
