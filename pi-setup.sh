#!/usr/bin/env bash
# Milo — one-shot Pi setup.
#
# Takes a freshly flashed LinuxCNC Raspberry Pi image to a working Remora host.
# Written 2026-09-04 so that a reflash costs an evening, not a session.
#
#   Image: image_2026-01-21-raspios-lcnc-2.9.8-trixie-arm64.zip
#          md5 705b7f3c2f7b385f6cb094d05e01070e
#          (Raspberry Pi OS Trixie, LinuxCNC 2.9.8, kernel 6.12.34+rpt-rpi-v8-rt)
#
#   Run ON the Pi:   bash pi-setup.sh
#   Idempotent — safe to re-run.
#
# ⚠️ DO NOT let rpi-update or a kernel upgrade run on this machine. The image
#    ships 6.12.34-rt, which is the known-good one; 6.12.47 was reported to
#    crash. This script deliberately does not upgrade anything but what it needs.

set -euo pipefail

REPO_URL="https://github.com/wrickert/LinuxCNC-Milo-Remora.git"
REPO_DIR="$HOME/LinuxCNC-Milo-Remora"
REMORA_DIR="$HOME/Remora"
CFG_DIR="$HOME/linuxcnc/configs/milo"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "0. Sanity checks"
grep -q PREEMPT_RT /proc/version \
  && echo "  ✅ kernel is PREEMPT_RT: $(uname -r)" \
  || echo "  ⚠️  kernel is NOT PREEMPT_RT: $(uname -r)"
command -v halcompile >/dev/null \
  && echo "  ✅ halcompile present" \
  || { echo "  ❌ halcompile missing — is this the LinuxCNC image?"; exit 1; }

# The Pi's own record of whether it has ever been starved of volts.
if command -v vcgencmd >/dev/null; then
  T=$(vcgencmd get_throttled); V=$(( ${T#throttled=} ))
  (( (V >> 16) & 1 )) \
    && echo "  🔌 ⚠️  UNDER-VOLTAGE HAS OCCURRED ($T) — fix the supply before trusting anything" \
    || echo "  🔌 ✅ no under-voltage recorded ($T)"
fi

say "1. Persistent journal"
# 🚨 Raspberry Pi OS deliberately ships
#      /usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf  ->  Storage=volatile
#    to spare the SD card. Drop-ins apply in FILENAME ORDER, so a drop-in named
#    10-*.conf loses to it and logs still vanish on reboot. Ours must sort AFTER
#    40-, hence 99-. Testing for /var/log/journal existing is NOT a valid check:
#    the directory ships with the image, empty, while journald writes to /run.
#    That is exactly why the 2026-09-04 crash left no evidence.
#
#    Tradeoff, stated honestly: this puts log writes back on the SD card. On a
#    machine with a marginal supply that is extra exposure during a brownout.
#    It is enabled anyway because an undiagnosable crash costs more, and the
#    cap below keeps the volume small. Remove the file to revert.
JCONF=/etc/systemd/journald.conf.d/99-persistent.conf
if [ ! -f "$JCONF" ]; then
  sudo mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nStorage=persistent\nSystemMaxUse=200M\n' | sudo tee "$JCONF" >/dev/null
  sudo systemctl restart systemd-journald
  sudo journalctl --flush || true
fi
# Verify by where journald is ACTUALLY writing, not by config or directory.
if journalctl --header 2>/dev/null | grep -q "^File path: /var/log/journal"; then
  echo "  ✅ journald is writing to /var/log/journal — 'journalctl -b -1' will survive a crash"
else
  echo "  ⚠️  journald still on /run — check: systemd-analyze cat-config systemd/journald.conf | grep Storage"
fi

say "2. Timezone"
# The image ships Europe/London, which makes correlating logs with anything
# else needlessly annoying.
CURRENT_TZ=$(timedatectl show -p Timezone --value)
if [ "$CURRENT_TZ" != "America/Chicago" ]; then
  sudo timedatectl set-timezone America/Chicago
  echo "  ✅ $CURRENT_TZ -> America/Chicago"
else
  echo "  ✅ already America/Chicago"
fi

say "3. SPI"
grep -qE '^dtparam=spi=on' /boot/firmware/config.txt \
  && echo "  ✅ dtparam=spi=on already set" \
  || { echo 'dtparam=spi=on' | sudo tee -a /boot/firmware/config.txt >/dev/null
       echo "  ✅ added dtparam=spi=on — REBOOT REQUIRED"; }
ls /dev/spidev0.0 >/dev/null 2>&1 \
  && echo "  ✅ /dev/spidev0.0 present" \
  || echo "  ⚠️  /dev/spidev0.0 missing (expected until after a reboot)"

for g in spi gpio; do
  id -nG | tr ' ' '\n' | grep -qx "$g" \
    && echo "  ✅ in group '$g'" \
    || { sudo usermod -aG "$g" "$USER"; echo "  ✅ added to '$g' — LOG OUT AND BACK IN"; }
done

say "4. Remora component"
# rp1lib ships inside the component — there is nothing separate to build.
if [ -d "$REMORA_DIR/.git" ]; then
  git -C "$REMORA_DIR" pull --ff-only || true
else
  git clone --depth 1 https://github.com/scottalford75/Remora.git "$REMORA_DIR"
fi
( cd "$REMORA_DIR/LinuxCNC/Components" && sudo halcompile --install ./Remora-spi/remora-spi.c )
ls -l /usr/lib/linuxcnc/modules/remora-spi.so && echo "  ✅ component installed"

say "5. Machine config"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only || true
else
  git clone "$REPO_URL" "$REPO_DIR"
fi
mkdir -p "$CFG_DIR" "$HOME/linuxcnc/nc_files"
cp -v "$REPO_DIR/milo.ini" "$REPO_DIR/milo.hal" "$CFG_DIR/"
cp -v "$REPO_DIR/octopus/config.txt" "$CFG_DIR/octopus-config.txt"
[ -f "$CFG_DIR/tool.tbl" ] || printf 'T1 P1 D3.175 Z0.000 ;3.175mm endmill\n' > "$CFG_DIR/tool.tbl"

say "6. Link check"
cat <<'EOF'
  The SPI link is NOT verified by this script. To test it:

      cat > /tmp/spitest.hal <<'HAL'
      loadrt remora-spi SPI_freq=2000000 PRU_base_freq=40000
      loadrt threads name1=servo period1=1000000
      addf remora.read servo
      addf remora.write servo
      setp remora.SPI-enable 1
      setp remora.SPI-reset 0
      start
      loadusr -w sleep 1
      setp remora.SPI-reset 1
      loadusr -w sleep 3
      show pin remora.SPI-status
      HAL
      halrun -f /tmp/spitest.hal

  *** THE RISING EDGE ON SPI-reset IS MANDATORY. ***
  remora-spi.c gates the transfer on:

      if (SPIenable)
        if ( (SPIreset && !SPIresetOld) || SPIstatus )
            spi_transfer();

  SPIstatus starts FALSE, so a rising edge on SPI-reset is the ONLY thing
  that can trigger the first transfer. Setting SPI-enable alone calls
  spi_transfer() exactly never - the component sits silent, puts nothing on
  the wire, and SPI-status reads FALSE no matter how perfect the hardware is.

  An earlier version of this very test omitted the reset edge. It produced
  false "link is down" readings on 2026-09-04/05 and sent us chasing ribbon
  cables, board power and the microSD for two days. The link was fine.

  In milo.hal the edge comes from iocontrol.0.user-request-enable, i.e. it is
  generated when you enable the machine in LinuxCNC. Standalone tests have to
  supply it by hand.

  remora.SPI-status TRUE  = link up.
  remora.SPI-status FALSE = no valid packets. Check, in order:
      0. that you actually pulsed SPI-reset (see above - this is #1 by far)
      1. the SPI ribbon is plugged in
      2. the Octopus's microSD is inserted (config.txt)
      3. the Octopus has adequate power
      4. Pi GPIO 25 (header pin 22) -> Octopus PC_15 (EXP2-7)
  Do NOT chase the clock: SPI_clk_div is accepted and silently ignored.
EOF

say "Done"
cat <<'EOF'
  Remaining, and NOT done by this script:
    - octopus-config.txt must be copied onto the OCTOPUS's own microSD as
      "config.txt". The board reads it at boot; the Pi never does.
    - LinuxCNC will report "Using POSIX non-realtime" on this kernel. That is
      the /sys/kernel/realtime detection gap, not a fault in this setup.
      See README-config.md before spending time on it.
EOF
