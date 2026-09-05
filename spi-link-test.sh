#!/bin/bash
# Corrected Remora SPI link test.
#
# The old test only set SPI-enable. remora-spi.c gates spi_transfer() on
# SPI-enable AND (a RISING EDGE on SPI-reset OR SPIstatus already true).
# SPIstatus starts false, so without the reset edge no transfer ever happens
# and SPI-status reads FALSE regardless of the hardware.

cat > /tmp/spitest-fixed.hal <<'HAL'
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

stty -F /dev/ttyAMA0 115200 raw -echo
: > /tmp/oct4.log
timeout 14 cat /dev/ttyAMA0 > /tmp/oct4.log 2>&1 &
CAPPID=$!
sleep 1

echo "=== corrected test: SPI-enable + rising edge on SPI-reset ==="
halrun -f /tmp/spitest-fixed.hal 2>&1 | grep -E "SPI-status|BAUDR"

sleep 3
kill $CAPPID 2>/dev/null
wait $CAPPID 2>/dev/null

echo
echo "=== Octopus serial during the corrected test ==="
echo "bytes: $(wc -c < /tmp/oct4.log)"
sort /tmp/oct4.log | uniq -c | sort -rn | head -6
