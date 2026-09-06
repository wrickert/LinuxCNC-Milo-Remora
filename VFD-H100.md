# Spindle VFD — Huanyang H100-1.5C2-1B

Identified 2026-09-05 from the nameplate. Everything below is read out of the **official
manual**, not forum posts — a copy is saved at
`Nextcloud/MiloCNC/VFD/H100 Series Operation Manual.pdf` (111 pp).

```
H100-1.5C2-1B
POWER:  1.5 kW
INPUT:  1PH 110 V 50/60 Hz
OUTPUT: 3PH 0-110 V 14 A 0-1000 Hz
```

⚠️ **Output is 0–110 V, not voltage-doubled.** This drive can only produce 110 V three-phase, so
the spindle must be a **110 V** unit. Most Chinese water-cooled spindles are 220 V; a 220 V
spindle here would never reach rated speed or power. Confirm off the spindle's own label.
✅ 0–1000 Hz covers the 24000 RPM spindle (400 Hz at 2-pole) with room to spare.
✅ Confirms the earlier note that the VFD is **110 V single-phase in** — no 240 V feed to design.

## Control terminals (photographed 2026-09-05)

| Terminal | Function |
|---|---|
| `485+` / `485-` | **RS485 — Modbus RTU** |
| `FA` / `FB` / `FC` | form-C relay output (NO / NC / common) |
| `AI1`, `AI2` | analog inputs (speed reference) |
| `AO` | analog output |
| `P12` | +12 V for digital inputs |
| `X1`–`X6` | digital inputs (`X6` shared with `Y1/PFO`) |
| `X6/Y1/PFO` | digital output / pulse-frequency output |
| `GND`, `PE` | common, earth |

Jumpers on the board: `J1 NPN/PNP` (digital input logic), `V0/AO` (analog output mode),
`CI/CV2` (AI2 current vs voltage).

## 🚨 Use `mb2hal`, NOT `hy_vfd`

`hy_vfd` is for the Huanyang **HY** series, which speaks a proprietary protocol with `PD###`
registers. `hy_gt_vfd` is for the **GT** series. **The H100 is neither** — it speaks standard
Modbus RTU with `F###` parameters. Reaching for `hy_vfd` because the badge says Huanyang is a
trap.

✅ **`mb2hal` ships with LinuxCNC** (`/usr/bin/mb2hal`) and `libmodbus5` is already installed, so
the Modbus path needs **no new dependencies**. `vfdmod` is a third-party build and is not needed.

## Drive parameters to set from the keypad

Modbus does nothing until the drive is told to take its orders from the serial port.

| Param | Meaning | Set to | Notes |
|---|---|---|---|
| `F001` | Control mode | **2** | 0=keypad, 1=external terminal, **2=communication port** |
| `F002` | Frequency setting selection | **2** | communication |
| `F163` | Communication address | **1** | range 0–250; **0 disables comms entirely** |
| `F164` | Baud rate | **3** | 0=4800, 1=9600, 2=19200, **3=38400** |
| `F165` | Data mode | **3** | **3 = 8N1 RTU** |
| `F169` | Frequency decimal point | **0** | `0201H` uses 1 decimal ⇒ units of 0.1 Hz |

🚨 **`F165=3` is 8N1, NOT 8E1.** A widely-cited LinuxCNC forum post lists these same parameter
values *and* describes the link as "38400 8E1" — those contradict each other. Per the manual:

```
0: 8N1 ASCII   1: 8E1 ASCII   2: 8O1 ASCII
3: 8N1 RTU     4: 8E1 RTU     5: 8O1 RTU
```

Set `F165=4` if you want 8E1. Mixing the forum's parity with `F165=3` fails to link at all.

## Register / coil map

**Holding registers**

| Address | Access | Meaning |
|---|---|---|
| `0000H`–`00FFH` | R/W | Inverter parameters `F000`–`F255` (e.g. `F100` = `0064H`) |
| `0200H` | W | Main control bits; BIT0–BIT7 mirror coils `0048H`–`004FH`, BIT8 = virtual input enable |
| `0201H` | W | **Given frequency** (setpoint, active when `F002=2`) — 0.1 Hz units |
| `0204H` | W | `EDO` digital output control; **BIT3 = the `FA`/`FB`/`FC` relay** |
| `0205H` | W | `EAO` analog output `AO` |
| `0210H` | R | Main status bits, BIT0–BIT15 mirror coils `0000H`–`000FH` |
| `0211H` | R | Digital terminal status; BIT0–BIT5 = `X1`–`X6`, BIT11 = relay |
| `0220H`–`022DH` | R | **Mapping input registers — `0220H` is output frequency** |
| `022EH` / `022FH` | R | `AI1` / `AI2` analog input (0–100.00 %) |
| `0230H` | R | `PFI` pulse input |

**Coils**

| Coil | Access | Meaning |
|---|---|---|
| `0000H` | R | Operation: 0 = stop, 1 = operating |
| `0002H` | R | Direction: 0 = forward, 1 = reverse |
| `0003H` | R | **In operation** — the useful "running" flag |
| `0005H` | R | In forward / reverse rotation |
| `0048H` | W | Operation enable — write `FF00` to activate |
| `0049H` | W | **Forward** — write `FF00` |
| `004AH` | W | **Reverse** — write `FF00` |

## 🚨 EEPROM wear — do not poll-write the F-parameters

Straight from the manual:

> Rewrite inverter parameters (for example F100) to be stored in EEPROM. Still save after power
> failure. **But parameters cannot be rewritten frequently, otherwise EEPROM memory may be
> damaged.** Rewriting communication-specific variables (variables after `0200H`) only modifies
> values in RAM.

So the `mb2hal` config must only ever write **`0200H` and above** (and the coils, which are a
separate Modbus address space). A config that writes a speed setpoint into an `F` parameter every
servo cycle will destroy the drive's EEPROM. Read-only access to `F` parameters is fine.

## Why Modbus rather than analog + relay

The HAL deliberately leaves `spindle.0.at-speed` unwired, because without a real signal G-code
plunges the moment `M3` is issued rather than waiting for the spindle to spool up. Modbus gives
actual output frequency from `0220H`, so `at-speed` becomes genuine feedback.

The analog path would need the **expansion board wired** (Remora has no analog output — the plan
routes `remora.SP.0` → firmware PWM on `PB_6` → the board's PWM-to-0-10 V input), *plus* a
run/stop relay, *plus* a separate at-speed input. Three subsystems that do not exist yet, versus
two wires. The relay and `Y1/PFO` remain available as fallbacks.

## Wiring

`485+` → adapter `A`, `485-` → adapter `B`. A CH341 USB-RS485 adapter is on hand; the Pi has
`ch341.ko` (`CONFIG_USB_SERIAL_CH341=m`) so it enumerates as `/dev/ttyUSB0` with no setup.

⚠️ **Reference the port as `/dev/serial/by-id/...`, never `/dev/ttyUSB0`.** The number shifts
depending on what else is plugged in, and a USB card reader has already been on this Pi today. A
config pinned to `ttyUSB0` works until the day it silently addresses something else.

⚠️ Run the RS485 pair on its own from the Pi, not through the Octopus — the Octopus has no RS485,
and keeping the spindle link off the Remora path means a comms fault cannot disturb motion.
⚠️ Check for an RS485 **termination resistor** jumper on the drive; some Huanyangs need it set
before Modbus works at all.

## Still open

- Confirm the spindle is 110 V (see the warning at the top).
- `mbpoll` (Debian package, not yet installed) for register verification before writing HAL.
- Which coil/bit combination the drive actually accepts for run — `0049H = FF00` versus `0200H`
  with BIT8 set. The manual gives both forms; test before trusting either.

## ✅ Modbus VERIFIED LIVE on the bench (2026-09-05)

Talking to the drive from the Pi over a CH340/CH341 adapter at **38400 8N1, slave 1**.
Adapter enumerates as `/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0`.

All six parameters confirmed **read back from the drive**, not just set:

| Param | Read | Meaning |
|---|---|---|
| `F001` | 2 | control mode = communication ✅ |
| `F002` | 2 | frequency source = communication ✅ |
| `F163` | 1 | address ✅ |
| `F164` | 3 | 38400 baud ✅ |
| `F165` | 3 | **8N1** RTU ✅ |
| `F169` | 0 | `0201H` in 0.1 Hz units ✅ |

Live state read cleanly: `0210H`=0 (stopped), `0211H`=0, `0220H`=0 (output freq), `0200H`=0,
`0201H`=0, coils `0000H`–`0007H` all 0.

🚨 **Coils only respond to function 01 (read coils).** Function 02 (read discrete inputs) gets
**no reply at all**. In `mbpoll` terms that is `-t 0`, not `-t 1`. `mb2hal` must be configured
accordingly or the status reads will silently never arrive.

⚠️ **The 4-register read limit is real** — keep `mb2hal` transactions to ≤4 registers.

### Frequency limits — already correct

| Param | Raw | Actual | Note |
|---|---|---|---|
| `F004` reference frequency | 4000 | **400.0 Hz** | correct for 24000 RPM at 2-pole |
| `F005` **max operating frequency** | 4000 | **400.0 Hz** | ✅ **not** left at the 50.0 Hz default |
| `F006` intermediate freq | 5 | 0.5 Hz | |
| `F007` minimum frequency | 5 | 0.5 Hz | |
| `F011` lower freq limit | 0 | 0 | |

🚨 **`F005` at its factory default of 50.0 Hz would silently cap the spindle at 3000 RPM.** It is
correctly set here, but check it on any replacement drive.
⚠️ `F100` is **"Frequency XVI setting"** — a multi-segment speed preset, **not** a maximum. Do not
scale RPM off it (reads 450 here, which is meaningless for scaling).
⚠️ `F003` reads 198.6 Hz but is irrelevant: with `F002=2` the setpoint comes from `0201H`.

### 🚨 OPEN: `F008` maximum voltage reads 380.0 V

`F008` = `3800` ⇒ **380.0 V**, which is the 380 V-class factory default — on a drive whose
nameplate says `OUTPUT: 3PH 0-110V`. The V/F curve would command 380 V at 400 Hz, be clamped to
the 110 V the drive can actually produce, and the spindle would run under-volted over most of its
range (weak and hot, not dangerous).

**Do not change it until the spindle's nameplate is read** — `F008` and the spindle-voltage
question are the same question:
- spindle is **110 V** ⇒ set `F008` ≈ `1100`, and drive/spindle match
- spindle is **220 V** ⇒ wrong drive entirely, and `F008` is the least of it

Other V/F values as found: `F009` intermediate voltage 14.0 V, `F010` low-frequency torque boost
5.0 %.

### RPM ⇄ register scaling for `mb2hal`

`F169=0` ⇒ `0201H` is in 0.1 Hz units, and 400.0 Hz = 24000 RPM (2-pole), so:

```
0201H value = RPM / 6          24000 RPM -> 4000 -> 400.0 Hz
RPM         = 0220H value * 6  (output frequency readback)
```

`spindle.0.at-speed` = |commanded − actual| within a tolerance, both via that conversion.

## ✅ FIRST SPIN-UP — spindle runs and stops over Modbus (2026-09-06)

The spindle spun under Modbus control and stopped cleanly. Verified stopped afterwards: `0200H`
control bits, `0201H` setpoint, `0210H` status, `0220H` output frequency and **all eight status
coils** are back to `0`.

**Working command set (confirmed on hardware):**

| Action | Modbus | mbpoll |
|---|---|---|
| Set speed | reg `0201H` (513), units 0.1 Hz | `-t 4 -r 513 <hz*10>` |
| Start forward | coil `0049H` (73) | `-t 0 -r 73 1` |
| Stop | coil `0049H` = 0 | `-t 0 -r 73 0` |
| Read actual speed | reg `0220H` (544), units 0.1 Hz | `-t 4 -r 544 -c 1` |

✅ **`0220H` is trustworthy for `at-speed`** — measured 2026-09-06: commanded 1000, it reported
`0` → `900` → `1000` and held `1000` steady for 10 s, then `0` after stop. It tracks the command
exactly, so `spindle.0.at-speed` can be real feedback rather than a timer.

📌 **Coil `0049H` (Forward) alone is sufficient to start** — `0048H` (Operation) was not required.
The manual documents both forms; this is the one that works.

### 🚨 CORRECTION — the ramp is 3.5 s, not 35 s

`F014`/`F015` read **350**, and I first recorded that as **35.0 s** (unit 0.1 s). **That was wrong.**
The measured spin-up reached 100 Hz in **about 2 seconds**, and the stop took about 2 as well —
so the unit is **0.01 s** and `350` = **3.50 s** to the 400 Hz reference.

⚠️ **The manual contradicts itself on this.** Its summary table gives the range as `0.1~650.00s`
(two decimals, which is correct) while the detail section says `0.1~6500.0s` (one decimal). Only
the machine settles it. Measured behaviour wins.

⇒ At 100 Hz that is **~0.9 s** of ramp, not 9 s. The spindle is at speed **fast**. Do not plan on
having several seconds to react during spin-up.
⚠️ For an immediate stop use the **e-stop** (interrupts AC into the control box), not the Modbus
stop — the Modbus stop still decelerates on the `F015` ramp.

🚨 **Any script that starts the spindle MUST trap its own exit.** `spindle-test.sh` writes the
stop command on `EXIT INT TERM`, so a crash, a Ctrl-C or a dropped ssh session cannot leave the
spindle running. Do not write a spindle script without this.

### Spindle / machine facts
- **Air-cooled** — no coolant interlock needed (a water-cooled spindle would have required the
  pump proven running before any spin-up).
- Physical stop is an **e-stop interrupting AC into the control box** — independent of the serial
  link and of any software.

### Next: wire it into HAL with `mb2hal`
`0220H` gives real output frequency, so `spindle.0.at-speed` becomes genuine feedback rather than
a timer. RPM ⇄ register: `0201H = RPM / 6`, and `RPM = 0220H * 6` (400.0 Hz = 24000 RPM).

## ✅✅ SPINDLE FULLY INTEGRATED INTO LINUXCNC (2026-09-06)

`M3 S6000` from MDI, watched live in HAL:

```
time      on     cmd RPM  reg out  actual RPM  at-speed  errs
12:01:42  FALSE  0        0        0           TRUE      0/0   <- idle
12:02:25  TRUE   6000     1000     0           FALSE     0/0   <- M3: drops instantly
12:02:26  TRUE   6000     1000     2106        FALSE     0/0
12:02:26  TRUE   6000     1000     5394        FALSE     0/0
12:02:27  TRUE   6000     1000     6000        TRUE      0/0   <- reached speed
```

Verified by that single run:
- **Scaling both ways** — 6000 RPM → register `1000` (÷6), and feedback reads back **exactly 6000**
- **`at-speed` is real feedback** — FALSE the instant `M3` is issued, TRUE only when the drive
  confirms it arrived. Unwired it defaults TRUE, which is why G-code would otherwise plunge into
  stationary metal.
- **Zero Modbus errors** on both transactions throughout
- **~2 s ramp**, consistent with the corrected `F014` = 3.50 s figure

### Setup gotchas worth not rediscovering
1. **`mb2hal` cannot open `/dev/serial/by-id/...`** — 49-char path, fixed-size buffers, fails with
   `cannot connect to link, ret[-1] fd[-1]`. `mbpoll` opens the same path fine, which is what
   isolated it. Use the short symlink from `99-milo-vfd.rules` → `/dev/milo-vfd`.
2. **`linuxcnc_debug.txt` is not truncated between runs.** Errors in it may be from a *previous*
   attempt. Check its mtime against the clock, or `: > ~/linuxcnc_debug.txt` before testing.
3. **`deploy.sh` catches hand-edits on the Pi.** A `sed` made there during testing survived until
   the next deploy overwrote it — which is the point of the repo being the source of truth.
