import spidev

tx = [0xAA, 0x55] + [i & 0xFF for i in range(62)]

for mode in (0, 1, 2, 3):
    s = spidev.SpiDev()
    s.open(0, 0)
    s.max_speed_hz = 1000000
    s.mode = mode
    rx = s.xfer2(list(tx))
    s.close()
    nz = [b for b in rx if b != 0x00]
    head = " ".join("%02X" % b for b in rx[:16])
    print("mode %d: nonzero=%3d  first16: %s" % (mode, len(nz), head))
