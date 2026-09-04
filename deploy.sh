#!/bin/bash
#
# deploy.sh — push this repo's config onto the Milo Pi, from the desktop.
#
# This repo is the source of truth. The Pi is a deploy target, not a place
# where configs are authored. The whole reason the original SPI/Remora build
# is stranded on one SD card is that it only ever existed on the machine — so
# edit here, commit, deploy; don't edit on the Pi.
#
# Usage:  ./deploy.sh            deploy and verify
#         ./deploy.sh --check    verify only, change nothing
#
set -euo pipefail

PI=cnc@192.168.1.42
CFG=/home/cnc/linuxcnc/configs/milo
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# repo path : filename as it must land in the Pi's config dir
FILES=(
  "milo.ini:milo.ini"
  "milo.hal:milo.hal"
  "octopus/config.txt:octopus-config.txt"
)

say "0. Reachability"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$PI" 'echo "  connected to $(hostname), root=$(findmnt -no SOURCE /)"'

if [ "$CHECK_ONLY" -eq 0 ]; then
  say "1. Deploy"
  for pair in "${FILES[@]}"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    scp -q "$REPO_DIR/$src" "$PI:$CFG/$dst"
    echo "  $src -> $CFG/$dst"
  done
else
  say "1. Deploy SKIPPED (--check)"
fi

say "2. Verify byte-for-byte"
fail=0
for pair in "${FILES[@]}"; do
  src="${pair%%:*}"; dst="${pair##*:}"
  if ssh -o BatchMode=yes "$PI" "cat $CFG/$dst" 2>/dev/null | diff -q "$REPO_DIR/$src" - >/dev/null; then
    echo "  ✅ $dst matches"
  else
    echo "  ❌ $dst DIFFERS"
    ssh -o BatchMode=yes "$PI" "cat $CFG/$dst" 2>/dev/null | diff -u "$REPO_DIR/$src" - | head -20 || true
    fail=1
  fi
done

say "3. Effective SPI settings on the Pi"
# SPI_clk_div is accepted and silently ignored; only SPI_freq takes effect.
ssh -o BatchMode=yes "$PI" "grep -n 'loadrt remora-spi' $CFG/milo.hal" | sed 's/^/  /'

say "4. Reminders"
cat <<'EOF'
  - octopus-config.txt on the Pi is a REFERENCE COPY. The Octopus reads its
    own microSD; the Pi never reads this file. Copy it to the board's card as
    "config.txt" by hand after changing it.
  - After changing config, refresh the SD fallback:  sudo ./sync-to-sd.sh
EOF

exit $fail
