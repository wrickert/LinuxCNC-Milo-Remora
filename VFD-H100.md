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
