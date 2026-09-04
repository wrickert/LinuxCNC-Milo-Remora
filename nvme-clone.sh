#!/bin/bash
# Clone the running SD card (mmcblk0) onto the NVMe (nvme0n1) on the Milo Pi.
# The SD is left completely untouched and stays a bootable fallback.
set -euo pipefail

SRC_DISK=/dev/mmcblk0
DST_DISK=/dev/nvme0n1
NEW_DISKID=0x1a2b3c4d          # must differ from the SD's 0xb3a878db
DST_BOOT=${DST_DISK}p1
DST_ROOT=${DST_DISK}p2
MNT=/mnt/nvme-target

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "0. Safety checks"
[ "$(findmnt -no SOURCE /)" = "/dev/mmcblk0p2" ] || { echo "ABORT: root is not mmcblk0p2"; exit 1; }
if mount | grep -q "^${DST_DISK}"; then echo "ABORT: something on $DST_DISK is mounted"; exit 1; fi
[ -b "$DST_DISK" ] || { echo "ABORT: $DST_DISK missing"; exit 1; }
echo "  root=$(findmnt -no SOURCE /)  target=$DST_DISK ($(lsblk -bdno SIZE $DST_DISK) bytes)"

say "1. Partition the NVMe (MBR, 512M boot + rest root)"
sfdisk --delete "$DST_DISK" >/dev/null 2>&1 || true
sfdisk "$DST_DISK" <<EOF
label: dos
label-id: $NEW_DISKID
unit: sectors

start=16384, size=1048576, type=c, bootable
start=1064960, type=83
EOF
partprobe "$DST_DISK"; sleep 2
sfdisk -l "$DST_DISK"

say "2. Format"
mkfs.vfat -F 32 -n bootfs "$DST_BOOT"
mkfs.ext4 -F -L rootfs "$DST_ROOT"

say "3. Mount target"
mkdir -p "$MNT"
mount "$DST_ROOT" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "$DST_BOOT" "$MNT/boot/firmware"

say "4. rsync rootfs (-x stops at other filesystems)"
rsync -aHAXx --numeric-ids --info=progress2 \
  --exclude='/lost+found' \
  --exclude='/var/swap' \
  --exclude='/tmp/*' \
  --exclude='/mnt/*' \
  --exclude='/media/*' \
  / "$MNT/"

say "5. rsync boot partition"
rsync -aHX --info=progress2 /boot/firmware/ "$MNT/boot/firmware/"

say "6. Recreate empty mountpoint dirs"
mkdir -p "$MNT"/{proc,sys,dev,run,tmp,mnt,media}
chmod 1777 "$MNT/tmp"

say "7. Rewrite PARTUUIDs on the CLONE only"
NEWBOOT=$(blkid -s PARTUUID -o value "$DST_BOOT")
NEWROOT=$(blkid -s PARTUUID -o value "$DST_ROOT")
echo "  new boot PARTUUID: $NEWBOOT"
echo "  new root PARTUUID: $NEWROOT"

sed -i "s|PARTUUID=b3a878db-01|PARTUUID=$NEWBOOT|g; s|PARTUUID=b3a878db-02|PARTUUID=$NEWROOT|g" \
  "$MNT/etc/fstab"
sed -i "s|root=PARTUUID=b3a878db-02|root=PARTUUID=$NEWROOT|g" \
  "$MNT/boot/firmware/cmdline.txt"

echo "  --- clone /etc/fstab ---";           cat "$MNT/etc/fstab"
echo "  --- clone cmdline.txt ---";          cat "$MNT/boot/firmware/cmdline.txt"
echo "  --- SD /etc/fstab (must be UNCHANGED) ---"; cat /etc/fstab

say "8. Verify cmdline.txt is still ONE line"
lines=$(wc -l < "$MNT/boot/firmware/cmdline.txt")
echo "  newline count: $lines (1 is correct)"

say "9. Sync + unmount"
sync
umount "$MNT/boot/firmware"
umount "$MNT"
rmdir "$MNT"

say "DONE - NVMe is now bootable. SD untouched."
