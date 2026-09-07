#!/bin/bash
#
# octopus-reset.sh -- hardware-reset the Octopus and show its boot banner.
#
# WHEN YOU NEED THIS
# LinuxCNC refuses to come out of E-stop and nothing you press helps. The
# cause is remora.SPI-status staying FALSE: milo.hal wires it straight to
# iocontrol.0.emc-enable-in, so LinuxCNC re-asserts E-stop the instant you
# clear it. That is correct behaviour -- it will not enable a machine it
# cannot talk to.
#
# WHY A HARDWARE RESET IS THE FIX
# The Octopus firmware has a watchdog. If SPI traffic stops abnormally --
# LinuxCNC killed, a crash, control-box power pulled -- the board can land in
# WDRESET state. In WDRESET it still ACKNOWLEDGES the SPI reset command
# ("Reset SPI now" on its serial console) but rejects every data packet
# afterwards with "Communication data error". So the link looks half-alive and
# the frequency sweep shows the same failure at 500 kHz and at 4 MHz -- which
# is how you tell this apart from a loose wire. A loose wire always improves
# as you slow the clock. This does not.
#
# A NORMAL LinuxCNC EXIT DOES NOT CAUSE THIS. Verified 2026-09-06: after a
# clean shutdown the board sits in IDLE and the next SPI reset brings it back
# to RUNNING on its own. Only an abnormal stop wedges it. So if you find
# yourself running this often, something else is wrong -- suspect power.
#
# 🚨 remora.PRU-reset is an INPUT pin on the component and milo.hal leaves it
#    unnetted, so LinuxCNC cannot pulse the reset line itself. That is why
#    this has to be done outside LinuxCNC, and why the board can get stuck
#    with no software way out. Do not "fix" that by netting PRU-reset to
#    user-request-enable: the board takes ~3 s to boot and re-init the three
#    TMC2209 drivers, far longer than LinuxCNC waits for emc-enable-in, so
#    every E-stop clear would fail once and need a second press.
#
# Reset line: Pi GPIO25 -> Octopus PC_15, active low.
#
# SAFE TO RUN whenever LinuxCNC is stopped. It reboots the STM32 only; it does
# not move anything and does not touch the VFD.
set -euo pipefail

if pgrep -f 'milo\.ini' >/dev/null 2>&1; then
  echo "🚨 LinuxCNC is running. Close it first -- it holds the SPI link."
  exit 1
fi

stty -F /dev/ttyAMA0 115200 raw -echo 2>/dev/null || true
LOG=$(mktemp)
timeout 12 cat /dev/ttyAMA0 > "$LOG" 2>&1 &
CAP=$!
sleep 1

echo "resetting Octopus (GPIO25 -> PC_15)..."
pinctrl set 25 op dh
sleep 0.2
pinctrl set 25 dl
sleep 0.3
pinctrl set 25 dh
sleep 8

kill $CAP 2>/dev/null || true
wait $CAP 2>/dev/null || true

echo
echo "=== boot banner ==="
tr -d '\r' < "$LOG"

echo
echo "=== verdict ==="
ok=1
grep -q 'Deserialization succeeded'    "$LOG" || { echo "  🚨 config.txt did not parse"; ok=0; }
n=$(grep -c 'Testing connection to TMC driver...OK' "$LOG" || true)
[ "$n" -eq 3 ] || { echo "  🚨 only $n/3 TMC2209 drivers answered"; ok=0; }
grep -q 'Entering START state'         "$LOG" || { echo "  🚨 never reached START state"; ok=0; }
[ "$ok" -eq 1 ] && echo "  ✅ config parsed, 3/3 TMC2209 OK, board in START -- restart LinuxCNC"
rm -f "$LOG"
