#!/system/bin/sh
# Shared state paths for Honor Charge Unlock.
#
# Everything this module writes lives under ONE directory. Before this it was
# ~20 loose `honor_charge_unlock.*` files plus a `/data/adb/camfix` directory at
# the top level of /data/adb, which is where other modules' and root apps' data
# sits - the top level is not ours to sprawl over.
#
# $ST/<name>            per-feature state (one line each, read back by the panel)
# $ST/conf              user config
# $ST/log               daemon log (verbose=1)
# $ST/pid               daemon pidfile
# $ST/paused            pause flag (touch/rm, checked every cycle)
# $ST/iface             snapshot of the vendor iin_limit rows we took over
# $ST/camfix/           generated camera config files used as bind-mount sources
# $ST/eidfix/           regenerated eSIM lib used as the bind-mount source
# $ST/diag.txt          action.sh diag dump
ST=/data/adb/honor_charge_unlock

# One-time move from the old flat layout. Safe to call on every start.
#
# When a name exists at BOTH paths, the flat one is not necessarily stale: a
# daemon still running the previous module version (a re-flashed zip, or the
# process that survived a flash until the next reboot) keeps writing the flat
# path, so its file is the live one and can be newer than the migrated copy.
# Keep whichever was touched last; the loser is deleted, never left behind at
# the top level.
#
# The bind-mounted camfix files are just renamed in place, so an existing mount
# keeps pointing at the same inode.
st_init() {
  mkdir -p "$ST" 2>/dev/null || return 1
  for p in /data/adb/honor_charge_unlock.*; do
    [ -f "$p" ] || continue
    n=${p##*/}; n=${n#honor_charge_unlock.}
    st_take "$p" "$ST/$n"
  done
  st_take /data/adb/honor_charge_unlock_diag.txt "$ST/diag.txt"
  for d in camfix eidfix; do
    [ -d "/data/adb/$d" ] || continue
    mkdir -p "$ST/$d" 2>/dev/null
    for p in /data/adb/$d/*; do
      [ -f "$p" ] || continue
      st_take "$p" "$ST/$d/${p##*/}"
    done
    rmdir "/data/adb/$d" 2>/dev/null
  done
}

# $1 = old flat path, $2 = $ST path
st_take() {
  [ -f "$1" ] || return 0
  if [ ! -e "$2" ]; then mv "$1" "$2" 2>/dev/null; return 0; fi
  if [ "$(stat -c %Y "$1" 2>/dev/null)" -gt "$(stat -c %Y "$2" 2>/dev/null)" ]; then
    mv -f "$1" "$2" 2>/dev/null
  else
    rm -f "$1" 2>/dev/null
  fi
}
