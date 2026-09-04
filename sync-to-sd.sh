#!/bin/bash
#
# sync-to-sd.sh — refresh the SD card fallback from the running NVMe system.
#
# Once the Pi boots from the NVMe, the SD card in the slot stops being a
# fallback and starts being a stale disk. This copies the things that actually
# matter — the machine config and the compiled Remora component — onto it, so
# that pulling the NVMe still gets you a working machine rather than whatever
# the card happened to hold months ago.
#
# It does NOT touch the SD's /etc/fstab or cmdline.txt: those must keep
# pointing at the SD's own PARTUUIDs (b3a878db-*) or the card stops booting.
#
# Run ON THE PI, while booted from the NVMe:   sudo ./sync-to-sd.sh
#
set -euo pipefail

SD_ROOT_PART=/dev/mmcblk0p2
SD_BOOT_PART=/dev/mmcblk0p1
MNT=/mnt/sd-fallback
USER_NAME=cnc

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "0. Safety checks"
CURRENT_ROOT=$(findmnt -no SOURCE /)
echo "  booted from: $CURRENT_ROOT"
if [ "$CURRENT_ROOT" = "$SD_ROOT_PART" ]; then
  echo "ABORT: you are booted FROM the SD card. Nothing to sync onto itself."
  exit 1
fi
[ -b "$SD_ROOT_PART" ] || { echo "ABORT: $SD_ROOT_PART not present (no card in the slot?)"; exit 1; }

say "1. Mount the SD card"
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$SD_ROOT_PART" "$MNT"
mountpoint -q "$MNT/boot/firmware" || mount "$SD_BOOT_PART" "$MNT/boot/firmware"
echo "  mounted $SD_ROOT_PART -> $MNT"

# Confirm we mounted what we think we did before writing anything to it.
[ -f "$MNT/etc/fstab" ] || { echo "ABORT: $MNT does not look like a rootfs"; umount -R "$MNT"; exit 1; }

say "2. Machine config -> SD"
# --delete is safe here: scoped to the config dir only, never the rootfs.
rsync -aHAX --delete --info=stats1 \
  "/home/$USER_NAME/linuxcnc/configs/" \
  "$MNT/home/$USER_NAME/linuxcnc/configs/"
chown -R --reference="$MNT/home/$USER_NAME" "$MNT/home/$USER_NAME/linuxcnc"

say "3. Compiled Remora component -> SD"
if [ -f /usr/lib/linuxcnc/modules/remora-spi.so ]; then
  rsync -aHAX /usr/lib/linuxcnc/modules/remora-spi.so \
    "$MNT/usr/lib/linuxcnc/modules/remora-spi.so"
  echo "  copied remora-spi.so"
else
  echo "  ⚠️  remora-spi.so not installed on this system - skipped"
fi

say "4. Remora source tree -> SD"
if [ -d "/home/$USER_NAME/Remora" ]; then
  rsync -aHAX --delete "/home/$USER_NAME/Remora/" "$MNT/home/$USER_NAME/Remora/"
  chown -R --reference="$MNT/home/$USER_NAME" "$MNT/home/$USER_NAME/Remora"
  echo "  synced ~/Remora"
fi

say "5. Confirm the SD's own boot identity is untouched"
echo "  --- SD /etc/fstab ---"
grep PARTUUID "$MNT/etc/fstab" || true
echo "  --- SD cmdline.txt root= ---"
tr ' ' '\n' < "$MNT/boot/firmware/cmdline.txt" | grep '^root=' || true
echo "  (both must say b3a878db-* — if they say anything else, do NOT reboot on this card)"

say "6. Unmount"
sync
umount "$MNT/boot/firmware"
umount "$MNT"
rmdir "$MNT" 2>/dev/null || true

say "DONE — SD fallback refreshed"
