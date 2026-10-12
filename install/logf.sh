logf() {

  if tt "${1:-x}" "-*e*"; then

    . "$execDir/diagnostics.sh"
    ng_export_logs

  else
    if tt "${1:-x}" "-*a*"; then
      shift
      edit $log "$@"
    else
      edit $TMPDIR/accd-*.log "$@"
    fi
  fi
}
