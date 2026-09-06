#!/bin/bash
#
# fetch-gcode.sh — copy CAM/Milo G-code from the Unraid NAS into ~/gcode.
#
# HOW THIS WORKS
# The desktop does CAM in FreeCAD and saves into its Nextcloud folder, which
# syncs to the server. This machine reads the resulting files straight off the
# Unraid share — no Nextcloud client, no app password, no sync daemon.
#
# 🚨 READING Nextcloud's data directory is safe. WRITING into it is not:
#    Nextcloud keeps a database index (oc_filecache) and files dropped in
#    directly stay invisible until `occ files:scan`. The mount is ro precisely
#    so that mistake cannot be made from here.
#
# WHY A LOCAL COPY RATHER THAN OPENING OFF THE MOUNT
# So the cut is independent of the network. Once a program is in ~/gcode, an
# NFS hiccup, a NAS reboot or someone unplugging a switch cannot affect a
# running job. Opening straight off the mount would work, but it puts the
# workshop network in the path of a machining operation for no benefit.
#
# MOUNT OPTIONS THAT MATTER (see /etc/fstab):
#   ro      the mill physically cannot write upstream — one-way is enforced by
#           the kernel, not by this script choosing the right rsync flags
#   soft,timeo=50,retrans=2
#           errors after ~5s instead of blocking forever. A *hard* NFS mount
#           (the default) hangs indefinitely on network loss.
#   x-systemd.automount
#           mounts on first access; no NFS connection is held while idle.
#
# ⚠️ NO --delete. Files removed upstream are left alone here. Stale G-code is
#    harmless; a program vanishing between loading and running is not.
#
set -euo pipefail

SRC="/mnt/nas-data/wrickert/files/CAM/Milo"
DST="$HOME/gcode"

mkdir -p "$DST"

# Touching the path triggers the automount. If the NAS is down this fails
# after the soft timeout rather than hanging.
if ! timeout 20 ls "$SRC" >/dev/null 2>&1; then
  echo "ERROR: cannot reach $SRC"
  echo
  echo "  Check:  systemctl status mnt-nas\\x2ddata.automount"
  echo "          findmnt /mnt/nas-data"
  echo "          ping 192.168.1.105"
  exit 1
fi

echo "Copying  $SRC"
echo "     ->  $DST"
echo

# -r -t : recurse, preserve times (for rsync's own change detection)
# NOT -a : files on the share are owned by the NFS squash user (99:users) and
#          this runs as cnc, so preserving ownership would fail. --chmod gives
#          sane local permissions instead.
rsync -rt --info=stats1,progress2 \
  --no-perms --no-owner --no-group \
  --chmod=F644,D755 \
  "$SRC/" "$DST/"

echo
echo "G-code now in $DST:"
find "$DST" -maxdepth 2 -type f \
  \( -iname '*.ngc' -o -iname '*.nc' -o -iname '*.gcode' -o -iname '*.tap' \) \
  -printf '  %TY-%Tm-%Td %TH:%TM  %8s  %P\n' | sort -r | head -20
echo
echo "Open in Axis from: $DST"
