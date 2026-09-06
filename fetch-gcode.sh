#!/bin/bash
#
# fetch-gcode.sh — pull CAM/Milo from Nextcloud into ~/gcode on the mill Pi.
#
# WHY A PULL AND NOT A SYNC CLIENT
# This Pi is a realtime machine controller. The full nextcloud-desktop client
# runs permanently — Qt GUI, inotify watches, periodic network polling. Adding
# a persistent background process doing disk and network I/O to a machine that
# has to hit realtime deadlines buys nothing: the workflow is "CAM at the
# desktop, walk over, pull the file", which is a pull, not a sync. A daemon
# that wedges also announces itself as a missing file mid-job; a pull you
# invoke either works or visibly doesn't.
#
# WHY rclone AND NOT nextcloudcmd
# 🚨 nextcloudcmd is BIDIRECTIONAL. There is no --download-only option (I
#    assumed one existed; it does not). Under nextcloudcmd anything that
#    happened to ~/gcode would propagate back to Nextcloud — INCLUDING
#    DELETIONS. A corrupted or emptied local folder would destroy the CAM
#    output upstream.
#    `rclone copy` is strictly one-way: per its own docs it "doesn't delete
#    files from the destination", and it never writes to the source.
#    ⚠️ Use `copy`, NEVER `sync` — rclone's `sync` IS destructive.
# (davfs2 was rejected outright: a WebDAV mount blocks on network loss, and a
#  blocked filesystem call on a machine controller is a bad failure mode.)
#
# 🚨 SCOPE IS THE SAFETY FEATURE. This pulls ONLY CAM/Milo. Programs for the
#    PrintNC or the mill at work are never present on this machine, so G-code
#    from the wrong post-processor cannot be opened by accident. That is a
#    structural guarantee, not a habit. Do NOT widen this to CAM/.
#
# Credentials live in rclone's config with the password obscured, never on the
# command line — arguments are visible to any user in `ps`.
#
set -euo pipefail

REMOTE="milo-nc"          # rclone remote name (see rclone config)
REMOTE_PATH="CAM/Milo"
LOCAL="$HOME/gcode"

mkdir -p "$LOCAL"

if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:"; then
  echo "ERROR: rclone remote '${REMOTE}' is not configured."
  echo
  echo "Run:  rclone config"
  echo "    n) new remote      name: ${REMOTE}"
  echo "    type: webdav"
  echo "    url:  https://192.168.1.105:4435/remote.php/dav/files/wrickert/"
  echo "    vendor: nextcloud"
  echo "    user: wrickert"
  echo "    pass: <Nextcloud APP password, not the account password>"
  exit 1
fi

echo "Pulling ${REMOTE}:${REMOTE_PATH}  ->  ${LOCAL}"
echo

rclone copy "${REMOTE}:${REMOTE_PATH}" "$LOCAL" \
  --progress \
  --no-traverse \
  --transfers 4 \
  --contimeout 15s \
  --timeout 60s \
  --retries 2

echo
echo "G-code now available in ${LOCAL}:"
find "$LOCAL" -maxdepth 2 -type f \
  \( -iname '*.ngc' -o -iname '*.nc' -o -iname '*.gcode' -o -iname '*.tap' \) \
  -printf '  %TY-%Tm-%Td %TH:%TM  %8s  %P\n' | sort -r | head -20
echo
echo "Open in Axis from: ${LOCAL}"
