# Milo v1.5 → LinuxCNC: where the numbers came from

`milo.ini` and `milo.hal` are derived from the machine's own RepRapFirmware config,
not from guesswork. The RRF source is `Nextcloud/MiloCNC/RRF CDYV3 Files/sys/`.

**The `LLM/` folder is three AI-written drafts from Nov 2025 that were never validated
against the machine. They are kept only as history. Do not copy numbers out of them.**
One concrete example of why: `LLM/gpt/milo-remora.ini` sets `MAX_LINEAR_VELOCITY = 33.0`,
which is the **Z** axis limit applied to the whole machine. X and Y are twice that.

## What transferred, and what didn't

The Fly-CDYv3 has been replaced by a BTT Octopus v1.1. That splits the RRF config
cleanly in two:

| Transfers as-is | Does **not** transfer |
|---|---|
| Steps/mm, lead screw ratios | Pin names (`PC_7`, `PD_11`, `PB_10`, `PE_6`, `PB_9`) |
| Accelerations, max feeds | Driver current (`M906`) — Remora's `Current` is RMS mA; RRF's is ambiguous |
| Soft limits / travel | Motor direction (`M569 S0`) — relative to CDYv3 wiring |
| Which end of each axis homes | |
| Homing order and feeds | |
| Spindle max RPM and PWM frequency | |

Everything in the right-hand column is marked `TODO(pins)` in `milo.hal`.

## The derivation

| Machine fact | RRF source | LinuxCNC |
|---|---|---|
| X travel 0 → 335 mm | `M208 X0 S1` / `M208 X335 S0` | `[AXIS_X]` limits |
| Y travel 0 → 208 mm | `M208 Y0 S1` / `M208 Y208 S0` | `[AXIS_Y]` limits |
| Z travel −120 → 0 mm | `M208 Z-120 S1` / `M208 Z0 S0` | `[AXIS_Z]` limits |
| X/Y max 4000 mm/min | `M203 X4000 Y4000` | `MAX_VELOCITY = 66.667` mm/s |
| Z max 2000 mm/min | `M203 Z2000` | `MAX_VELOCITY = 33.333` mm/s |
| X/Y accel 300 mm/s² | `M201 X300 Y300` | `MAX_ACCELERATION = 300` |
| Z accel 200 mm/s² | `M201 Z200` | `MAX_ACCELERATION = 200` |
| X homes to min | `M574 X1 S1`, `homex.g` | `HOME_SEARCH_VEL = -30` |
| Y homes to max | `M574 Y2 S1`, `homey.g` | `HOME_SEARCH_VEL = +30`, `HOME = 208` |
| Z homes to max (=0) | `M574 Z2 S1`, `homez.g` | `HOME_SEARCH_VEL = +30`, `HOME = 0` |
| Z homes first | `homeall.g` calls `homez.g` first | `HOME_SEQUENCE`: Z=0, X=Y=1 |
| Home fast 1800 mm/min | `F{1800}` in `home*.g` | `HOME_SEARCH_VEL = 30` mm/s |
| Home slow 180 mm/min | `F{180}` in `home*.g` | `HOME_LATCH_VEL = 3` mm/s |
| Spindle 24000 RPM | `M950 R0 ... L24000` | `[SPINDLE_0] MAX_FORWARD_VELOCITY` |
| Spindle PWM 100 Hz | `M950 R0 ... Q100` | `remora.PWM.<N>.period` |

`M566` (jerk: X500 Y500 Z200 mm/min) has **no LinuxCNC equivalent** and is dropped.
LinuxCNC handles cornering with acceleration limits plus the G64 path-blending
tolerance instead. If corners feel harsh, tune `G64 P<n>` in your post, not the INI.

## ⚠️ Microstepping: drop 32 → 8 (not 16)

**Corrected.** An earlier version of this file said 16 microsteps and called it comfortable.
That was wrong, because it assumed the step-rate ceiling was Remora's 40 kHz base frequency.
It isn't. The stepgen needs **two base-thread cycles per pulse** (one high, one low), so the
real ceiling is **half the base frequency — 20 kHz at the stock 40 kHz**.

Required step rate at full rapid, from `M203 X4000 Y4000 Z2000`:

| Microsteps | X/Y steps/mm | Z steps/mm | Step rate at rapid | vs 20 kHz ceiling |
|---|---|---|---|---|
| 32 (RRF's setting) | 800 | 1600 | 53.3 kHz | far over |
| 16 | 400 | 800 | 26.7 kHz | **still over** |
| **8** | **200** | **400** | **13.3 kHz** | **OK, 1/3 headroom** |

`milo.ini` is written for **8 microsteps** — `SCALE` 200 / 200 / 400.

Exceeding the ceiling does not throw an error. Rapids just silently cap: at 16 microsteps X/Y
would top out at 20000 / 400 = 50 mm/s, i.e. 3000 mm/min against the 4000 the machine is
capable of. You would lose a quarter of your rapid speed and have nothing in a log to explain it.

**8 microsteps costs nothing here.** Resolution is 0.005 mm/step on X/Y and 0.0025 mm on Z, well
inside what the machine can actually hold. And TMC drivers interpolate internally to 256
microsteps regardless of the step input rate, so motor smoothness is unaffected — the
interpolation is doing that work either way.

**Correction: the base frequency is a config line, not a recompile.** `main.cpp` reads a
top-level `"Threads"` array from `config.txt`, so you can raise it without rebuilding firmware:

```json
"Threads":[ { "Thread": "Base", "Frequency": 80000 } ],
```

`PRU_BASEFREQ` in `Remora-OS6/configuration.h` is the *default* when that block is absent, and it
is confirmed at `40000` (the source comment shows it was raised from 24000, i.e. 40 kHz is the
tested value). Pushing to 80 kHz doubles how often the base ISR fires on the STM32 — beyond what
upstream ships as tested, and an overrunning base thread costs you steps. **Stay at 8 microsteps
and the stock 40 kHz unless something forces otherwise.** If you do raise it, `PRU_base_freq` in
`milo.hal` must be changed to match — the HAL parameter only tells the component what the
firmware is doing, it does not configure it.

Three things must agree on whichever you pick:
1. `SCALE` in `milo.ini`
2. the microstep setting in the Octopus's Remora config (or the driver jumpers, in standalone mode)
3. `PRU_base_freq` in `milo.hal` vs the firmware's compiled value

## The Octopus's config file — get it into this repo

Remora's pin map lives on the **Octopus's own microSD card**, in a file that must be named
`config.txt` (JSON content, despite the extension) and must stay on the card in the board.
Sample configs for this board are in the Remora repo under `Firmware/ConfigSamples/Octopus`.

It is the source of truth for:
- which STM32 pins carry SPI (the link is already proven working)
- stepgen pin assignments and their order, which must match the joint numbers in `milo.hal`
- PWM channels — answers "which output drives the expansion board"
- digital IO numbering — answers "which input is which endstop"
- the compiled base frequency, which settles the microstepping table above

**It survived the Pi's NVMe being pulled**, because it was never on the Pi. Copy it into this
repo. The whole reason the last attempt left nothing behind is that its configuration lived only
on hardware.

## What the flashed firmware tells us (FIRMWARE.CUR, 2025-11-08)

`Nextcloud/MiloCNC/Remora Firmware/FIRMWARE.CUR` is the running firmware, renamed by the
bootloader after flashing. Analysing it answers several things the config file could not.

- **Remora-OS6, SPI variant** — strings `Mbed-OS6`, `Remora-spi Driver`, `Remora PRU`.
  This matters: OS6 is the branch whose `configuration.h` we read `PRU_BASEFREQ 40000` from,
  so that number applies to *this* binary.
- **STM32F4 target** — `.\TARGET_STM32F4\drivers\SDIO\sdio_device.c`.
- **Almost certainly the F446 build, not F429.** `file` reports *initial SP at 0x20020000*,
  i.e. the stack starts at the top of 128 KB of SRAM. The F446 has 128 KB; an F429 build
  would place it at 0x20030000 for its 192 KB. Confirm against the chip marking before
  reflashing — flashing the wrong variant is the easy way to brick an afternoon.

### ✅ The firmware supports everything `octopus/config.txt` uses

Module type strings are compiled in, so they can be read straight out of the binary. All present:

`Stepgen` · `Reset Pin` · `Digital Pin` · `PWM` · `Switch` · `TMC2208` · `TMC2209` · `eStop` ·
`Blink` · `Encoder` · `QEI` · `Temperature` · `Motor Power` · `MCP4451` · `RCServo`

Thread names `Base` / `Servo` / `On load` and the `Threads` + `Frequency` keys are present too,
so the base-frequency override is available on this binary without reflashing.

Config keys present: `Comment`, `Joint Number`, `Step Pin`, `Direction Pin`, `Enable Pin`,
`RX pin`, `RSense`, `Current`, `Microsteps`, `Stealth chop`, `Stall sensitivity`, `Data Bit`,
`Mode`, `Modules`, `PV[i]`.

**So the new `octopus/config.txt` can be dropped straight onto the card — no reflash needed.**

> Note: a naive search makes `Servo` look absent. It is not — the linker tail-merges it into
> `RCServo`, and `Servo Pin` / `Servo thread object` are both in the binary.

### Spindle PWM schema

The PWM module's keys, read out of the firmware, are **`PWM Pin`** and **`PWM Max`**. So the
block will look like:

```json
{ "Thread": "Servo", "Type": "PWM",
  "Comment": "Spindle speed",
  "PWM Pin": "PB_6",
  "PWM Max": 24000 }
```

`PB_6` is the Octopus's servo/BLTouch control pin, which is where the Milo docs route the
expansion board's PWM IN — but nothing is wired yet, so this block is deliberately **not** in
`octopus/config.txt`. Add it when the expansion board goes in, and check the boot output: the
firmware prints per-module messages as it parses, so a mistyped key shows up there.

## ⚠️ Power: the current bench arrangement is temporary

**The Octopus is presently powered from the Pi**, and the Pi is on a USB-C PD supply that does
not deliver the full 5 A. That single supply is carrying the Pi 5, its SD card, and the Octopus's
logic rail.

**It browned out under load on 2026-09-04** — the Pi dropped off the network and needed a power
cycle. It is fine for bench work at idle and it is how the SPI link was proven, but it must not
survive into the built machine. The power-domain drawing stands: Pi on its own 5 V/5 A supply,
Octopus on 24 V, **ground bonded, no 5 V link between them**.

### ✅ Pi supply replaced later the same day — the Pi side is now clean

A better USB-C PD supply went on 2026-09-04 and it fixed the brownouts outright:

| | old supply (boot 12:27, ~4 h) | new supply (boot 16:41) |
|---|---|---|
| `vcgencmd get_throttled` | undervoltage bits set | **`0x0`** |
| `hwmon3: Undervoltage detected!` | 4 events | **none** |
| `EXT5V_V` | — | **5.176 V** |

`get_throttled` bits 16–19 are **sticky since boot**, so an all-clear reading after an hour of
uptime is real evidence, not a snapshot. Read it with `vcgencmd get_throttled` and the rail
directly with `vcgencmd pmic_read_adc | grep EXT5V`.

⚠️ **This clears the Pi, not the Octopus.** Candidate 3 in the SPI list below was "the Octopus is
not adequately powered, it is fed from the Pi, which is browning out". The Pi half of that is now
disproved. Whether the Octopus's own rail is adequate is still untested, and the split-supply
plan above is still the right end state.

## ⚠️ One more wire: the PRU reset line

`remora-spi.c` has:

```c
static int reset_gpio_pin = 25;   // RPI GPIO pin used to force watchdog reset of the PRU
```

Hardcoded — not a module parameter. So **Pi GPIO 25 (header pin 22) must go to the Octopus's
reset pin**, which `config.txt` declares as `PC_15`. Without it the watchdog cannot reset the
PRU, and the recovery path after an SPI fault does not work.

## HAL pin reference (read out of `remora-spi.c`, not guessed)

These are **every** pin and parameter the component creates. Anything not on this list does not
exist, however plausible it looks.

| HAL object | Dir | Notes |
|---|---|---|
| `remora.SPI-enable` / `.SPI-reset` | in | e-stop chain |
| `remora.SPI-status` | out | false when the link drops — the free watchdog |
| `remora.PRU-reset` | in | hardware reset line; component pulses it itself |
| `remora.joint.N.pos-cmd` / `.vel-cmd` / `.enable` | in | `%01d`, one digit |
| `remora.joint.N.pos-fb` / `.freq-cmd` / `.counts` | out | |
| `remora.joint.N.scale` / `.maxaccel` | **param** | hence `setp`, not `net` |
| `remora.input.NN` / `.NN.not` | out | **`%02d` — two digits** |
| `remora.output.NN` | in | **`%02d` — two digits** |
| `remora.SP.N` | in | setpoint channel — this is how spindle speed reaches the PWM module |
| `remora.PV.N` | out | process variable, used by the `Switch` module |

> 🐛 **Bug this caught.** `milo.hal` had `remora.input.0`. The real name is `remora.input.00`.
> A one-digit name does not error loudly — it simply never binds, and homing would never see a
> switch. Fixed 2026-09-04.

**There is no `remora.PWM.*` pin.** Spindle speed goes out on `remora.SP.<n>` and the firmware's
PWM module consumes that index. See the spindle block in `milo.hal` for the matching firmware
config.

## 🚨 SPI link is NOT currently up (2026-09-04)

`remora.SPI-status` reads **FALSE** with the servo thread running and `SPI-enable` set — so
rp1lib initialises and claims the pins, but no valid packets come back. **Not a clock problem:**
tested at 20 MHz, 10, 5, 2 and 1 MHz, false at every one.

Cause cannot be determined remotely. Candidates, all physical:
1. The SPI ribbon is not connected (the machine has been apart for months).
2. The Octopus's microSD is out — Remora halts without `config.txt`.
3. The Octopus is not adequately powered. It is fed from the Pi, which is browning out.
4. The firmware is not running for some other reason.

**Also learned:** `SPI_clk_div` is accepted but ignored — BAUDR stayed 20 MHz for 10/32/64/128.
`SPI_freq` is the parameter that works. `milo.hal` now uses `SPI_freq=2000000`.

### Retest after the power-supply swap — still FALSE, but the test proved nothing

Retested at 2 MHz once the Pi's rail was clean: `remora.SPI-status` still **FALSE**.

🚨 **Do not read anything into that result.** The Octopus was *not confirmed connected* when it
ran — only the Pi's supply had been changed. A FALSE reading with the ribbon possibly unplugged
is not a data point. **Before any future link test, confirm the ribbon is on and the Octopus is
powered**, or the result is unfalsifiable.

### 🚨 CORRECTION 2026-09-05: the MISO pull test below is only valid with CS ASSERTED

**The version of this test described below is wrong, and it cost a day.** It was run with chip
select idle-high — and a *healthy* SPI slave tri-states MISO whenever it is not selected. So a
floating MISO proved nothing, and the conclusions drawn from it ("nothing is driving MISO", "the
fault is physical", "the Octopus may be unpowered") were all unfounded. The board was alive the
whole time.

**Always assert CS before judging MISO:**

```sh
pinctrl set 8 op dl                      # assert CS (GPIO 8) low
pinctrl set 9 ip pu && pinctrl get 9     # MISO with pull-up
pinctrl set 9 ip pd && pinctrl get 9     # MISO with pull-down
pinctrl set 8 a0 && pinctrl set 9 a0     # RESTORE both to SPI0
```

| Reading | Meaning |
|---|---|
| CS low → MISO `lo` under a **pull-up**; CS high → follows the pull | ✅ **Slave is alive and correctly selected.** Only a live slave does this. |
| Follows the pull in **both** CS states | Nothing driving — then it really is power/ribbon/reset. |

Measured 2026-09-05 with the board powered: `lo` under pull-up with CS asserted, high-Z with CS
released. **The Octopus is alive, its SPI slave is configured, and CS is on the right pin.**

### 🔍 The original MISO pull test (kept for the reasoning — see the correction above)

Worth knowing because it separates "nothing is connected" from "connected but not talking",
which the `SPI-status` bit alone cannot:

```sh
# 1. Raw transfer, no LinuxCNC involved. All-zero rx = nothing came back.
python3 -c 'import spidev; s=spidev.SpiDev(); s.open(0,0); s.max_speed_hz=2000000; \
  print([hex(b) for b in s.xfer2([0xAA,0x55,0x00,0xFF])])'

# 2. Decide whether MISO is floating or actively driven.
pinctrl set 9 ip pu && pinctrl get 9     # pull-up
pinctrl set 9 ip pd && pinctrl get 9     # pull-down (control)
pinctrl set 9 a0                         # RESTORE to SPI0_MISO when done
```

Result on 2026-09-04: raw rx all `0x00`, and MISO followed the internal pull **both ways** —
`pu` → `hi`, `pd` → `lo`.

**Interpretation: nothing on the far end is driving MISO.** The Pi's internal pull is ~50 kΩ; a
powered STM32 holding that pin low would sink far more than the pull-up can source, so the line
could not have gone high. A line that simply follows whichever pull you apply is an unterminated
one. That points at the ribbon, the Octopus's power, or the STM32 being held in reset — **not**
at clock rate, protocol, or the `remora-spi` component.

> ⚠️ GPIO 25 idles as an **output driving low**, which is normal — the component pulses the PRU
> reset itself on SPI failure rather than holding it. Do not mistake the idle-low state for the
> board being held in reset.

### 🔌 Get a USB cable onto the Octopus

The single highest-value change to this setup. Remora prints its whole boot sequence over the
STM32's USB serial — `1. Reading json configuration file`, `3. Parsing json configuration file`,
then a `Creating ...` line per module. Those strings are in the flashed binary.

With no USB console we are blind: we cannot tell a dead board from an unwired ribbon from a
config the firmware rejected. With one, every question above is answered in five seconds, and it
is also how the new `config.txt` gets validated (a mistyped key shows up there and nowhere else).

## Pi &#8594; Octopus: use one connector, not six flying leads

Every signal the interface needs sits in a **contiguous block on the 40-pin header**:

| Pin | Signal | | Pin | Signal |
|---|---|---|---|---|
| 19 | MOSI | | 20 | GND |
| 21 | MISO | | 22 | **GPIO 25 — PRU reset** |
| 23 | SCLK | | 24 | CE0 |
| 25 | GND | | 26 | CE1 (unused) |

So a single **2×4 IDC socket over pins 19&#8211;26** carries the whole thing: both SPI, chip
select, the reset line, and **two** grounds — one of which (pin 25) sits directly beside SCLK in
the same row, giving the clock an adjacent return. A 2×3 over 19&#8211;24 also works and covers
every required signal, but only gets you one ground.

This is better than loose jumpers for three reasons beyond tidiness: it is keyed so it cannot be
plugged one pin over, it keeps the run short, and the ribbon's conductor order is fixed so the
ground stays next to the clock. Short and keyed is itself most of the EMI mitigation — see the
spindle-cable warning above.

### ✅ The Octopus side, resolved to the physical connector (2026-09-05)

Every SPI signal is on **EXP2**, one 2×5 header. This closes the gap where the repo knew the
STM32 pin names but not which connector they lived on.

| Signal | Pi GPIO | Pi pin | Octopus pin | STM32 | Wire |
|---|---|---|---|---|---|
| MOSI | GPIO 10 | 19 | **EXP2-6** | `PA_7` | red |
| MISO | GPIO 9 | 21 | **EXP2-1** | `PA_6` | orange |
| SCLK | GPIO 11 | 23 | **EXP2-2** | `PA_5` | green |
| CE0 | GPIO 8 | 24 | **EXP2-4** | `PA_4` | yellow |
| PRU reset | GPIO 25 | 22 | **EXP2-7** | `PC_15` | brown |
| GND | — | 25 | **EXP2-9** | GND | black |

Full EXP2, odd pins left: `1 PA6 · 2 PA5 · 3 PB1 · 4 PA4 · 5 PB2 · 6 PA7 · 7 PC15 · 8 RST ·
9 GND · 10 PC5`. Pins 3, 5, 8, 10 unused.

🚨 **EXP2-8 is `RST`, the STM32 hardware reset — NOT the PRU reset.** The PRU reset is EXP2-7
(`PC_15`), physically adjacent. Landing GPIO 25 one row over holds the MCU in reset, and the
symptom is **indistinguishable from a dead link**: rp1lib initialises, claims its pins, nothing
answers.

✅ **EXP2 carries no 5 V** — pin 10 is `PC5`, so the SPI harness cannot bridge the power domains.
⚠️ Several widely-copied third-party pin tables claim EXP2-10 is 5 V. BTT's own pinout says
`PC5`; it is **EXP1** that has 5 V on pin 10. Don't use pin 10 for anything either way.

**Why these pins were free:** BTT labels `PA_7`/`PA_6`/`PA_5` as **Motor-SPI**, the bus for
SPI-mode drivers (TMC2130/5160). This machine runs TMC2209s in **UART** mode, so the bus is idle
and Remora gets it. Moving to SPI-mode drivers later would collide with the Remora link.

### 🔌 Serial debug is on the TFT header, not EXP2

The Octopus narrates its whole startup over UART — including whether it accepted `config.txt`.
**This is the only thing that distinguishes "not powered" from "running but misconfigured",**
which the Pi side cannot tell apart.

TFT header: `RST · PA10 (RX) · PA9 (TX) · GND · 5V`

| Octopus TFT | Pi pin | Pi function |
|---|---|---|
| `PA_10` (RX) | 8 | TXD / GPIO 14 |
| GND | 9 | GND |
| `PA_9` (TX) | 10 | RXD / GPIO 15 |
| 5V | — | **do not connect** |

TX and RX cross. Pi pins 8/9/10 are contiguous — one 3-pin block just above the SPI block.

🚨 **The TFT 5 V pin is the one that can destroy hardware.** Unlike EXP2, this header carries
5 V, and a stock 4-wire TFT cable includes it. It must never land on the Pi header — the Pi has
its own supply and a second 5 V source fed into it can kill the board.
🚨 **And in the other direction:** if the Octopus was being back-fed 5 V through this pin,
removing the wire leaves it **unpowered**, and the link stays dead however correct the other
wires are. Power the Octopus from 24 V, or from USB during bench work. Never restore the
back-feed — that is the arrangement that browned out the Pi on 2026-09-04.

✅ **Pi 5 UART:** `/dev/serial0` → `ttyAMA10`, the dedicated 3-pin debug connector, **not**
GPIO 14/15. So the kernel console does *not* occupy the header pins and nothing needs freeing —
GPIO 14/15 just aren't enabled. Add `dtoverlay=uart0-pi5` to `config.txt`, reboot, and read it:
`stty -F /dev/ttyAMA0 115200 raw -echo && cat /dev/ttyAMA0`

⚠️ **Verify against BTT's pinout, not the silkscreen.** BIGTREETECH's wiki warns that *"the
silkscreen on the first production run of the octopus had incorrectly labeled pins."* Confirm
EXP2 pin 1 by the square pad / triangle marker. Source: `BIGTREETECH Octopus - PIN.jpg` in
`bigtreetech/BIGTREETECH-OCTOPUS-V1.0`, corroborated by the Remora Octopus SPI page.

## Current build state (2026-09-04)

**Pi:** `192.168.1.42`, hostname `milo`, user `cnc`, desktop key authorised.
Pi 5 Rev 1.0 · LinuxCNC 2.9.8 · Debian 13 Trixie · kernel `6.12.34+rpt-rpi-v8-rt`.
Booting from **SD**; the fitted NVMe holds another project's exfat partition.

✅ `remora-spi.so` built and installed (`sudo halcompile --install ./Remora-spi/remora-spi.c`).
rp1lib ships *inside* the component — nothing separate to build. It loads and initialises the
RP1 correctly: maps SPI0, finds the Synopsys DWC SSI, claims GPIO 10/9/11/8.

### 🚨 Open: LinuxCNC reports "Using POSIX non-realtime"

The kernel *is* PREEMPT_RT. LinuxCNC can't tell. Chain:
`makeApp()` → `if(euid != 0 || harden_rt() < 0)` → `harden_rt()` returns `-EINVAL` when
`!rtapi_is_realtime()` → which `stat()`s **`/sys/kernel/realtime`**, a file that mainline
PREEMPT_RT (6.12) no longer creates. The older out-of-tree RT patch did.

- `rtapi_app` **is** setuid root, so this is not a permissions problem.
- There is **no env override** — `FLAVOR=` and `RTAPI_FLAVOR=` are both ignored; the binary
  contains no such string.
- Upstream's fix is a **kernel patch** (add a `realtime_show` sysfs attribute, plus
  `ARCH_SUPPORTS_RT` → `def_bool y`), i.e. a kernel rebuild.
- ⚠️ **Irony worth recording: Flexi-Pi's older 6.6-rt kernel probably does not have this
  problem**, because that RT patch still creates the file. The image rejected on 2026-09-03 for
  being on an older base may be the one that just works.

**Do not act on this yet.** Idle `cyclictest`: `SCHED_OTHER` max **13 µs** vs `SCHED_FIFO` max
**9 µs**, against a 1000 µs servo period — negligible. If `SCHED_OTHER` also holds up *under
load*, the whole thing is cosmetic and both the kernel patch and the reflash are moot. Run the
loaded comparison first, **after** the power is sorted. Decide on data.

### 🚨 Do not run `stress-ng` on this Pi

It browned out and needed a power cycle on 2026-09-04. See the power section above: one
under-spec PD supply is currently carrying the Pi, its SD card and the Octopus's logic rail.

## Still open

| # | Item | State |
|---|---|---|
| 1 | Octopus SPI pins | ✅ Resolved to the connector: `PA_7`/`PA_6`/`PA_5`/`PA_4` = **EXP2-6/1/2/4** → Pi 19/21/23/24. |
| 2 | PRU reset wire | ✅ **EXP2-7** (`PC_15`) → Pi pin 22. 🚨 Not EXP2-8, which is the MCU `RST`. |
| 2b | Octopus power | ✅ **CLOSED 2026-09-05.** Board is powered and its SPI slave responds to CS. The "may be unpowered" theory came from a bad test — see the CS-asserted correction. |
| 2d | MOSI / SCLK wiring | 🚨 **The live suspect.** Slave is selected but returns only zeros in all 4 SPI modes, i.e. never sees a valid request. In EXP2's even column the order is **2 SCLK · 4 CS · 6 MOSI** — MOSI and SCLK **cross**, and wiring them in order swaps them while leaving CS correct. That reproduces this symptom exactly. |
| 2c | Serial debug | ⚠️ TFT header `PA_9`/`PA_10` → Pi pins 10/8, GND to 9. Needs `dtoverlay=uart0-pi5`. Highest-value diagnostic still not wired. |
| 3 | Endstop inputs | ⚠️ Assigned `PG_6`/`PG_9`/`PG_10` → `remora.input.00/01/02`. Verify pins against silkscreen and polarity in halshow. |
| 4 | Driver modules | ✅ TMC2209, now configured over UART in `octopus/config.txt`. |
| 5 | Motor directions | ⚠️ All three were reversed under RRF, but relative to CDYv3 wiring. Expect to negate one or more `SCALE`. Flip the sign in the INI, don't rewire. |
| 6 | TMC UART pins | ⚠️ `PC_4`/`PD_11`/`PC_6` from the standard Octopus v1.1 pinout, not Remora docs. **A wrong UART pin fails silently** — the driver keeps its defaults, i.e. StealthChop at the wrong current. Watch the boot output. |
| 7 | Spindle PWM + enable | ⚠️ Schema known (`SP` / `PWM Pin` / `PWM Max`). Nothing wired yet. |
| 8 | Spindle at-speed | 🚨 No signal. Without one, G-code plunges before the spindle is up to speed. Needs a VFD "up to frequency" output, or Modbus. |
| 9 | VFD make/model | 🚨 Still unknown. Decides analog+relay vs Modbus — a fork in the wiring, not a setting. |
| 10 | Probe / toolsetter | ⏸ Deliberately last. Both existed under RRF. |
| 11 | RT flavour | 🚨 See above. Blocked on the loaded latency test. |

## 💾 Storage: SD → NVMe, and keeping the card as a live fallback

The Pi has a 128 GB NVMe (YMTC, on the HAT). As found on 2026-09-04 it held a **Ventoy** layout —
119.2 G exfat `Flash128` plus a 1 M `UEFI_NTFS` stub — and was **effectively empty: 768 KB used,
one empty `System Volume Information` folder, no ISOs, no user files.** Nothing was lost by
reusing it.

**No EEPROM change is needed.** `BOOT_ORDER=0xf416` reads right-to-left as **NVMe → SD → USB →
retry**, so the Pi already tries the NVMe first and falls through to the SD only because an exfat
partition isn't bootable. Put a real OS on it and it boots. Bootloader was current (Dec 2025).

**PCIe runs at Gen 2 x1** (`LnkSta: 5GT/s, Width x1`) even though the SSD advertises 8GT/s x4 —
the Pi 5 only has one lane. `dtparam=pciex1_gen=3` would force Gen 3; **don't.** It is uncertified
and this box will run a mill. Gen 2 x1 is ~450 MB/s, still an order of magnitude over the card.

### The scripts

| Script | Runs on | Does |
|---|---|---|
| `nvme-clone.sh` | the Pi, `sudo` | clones the running SD onto the NVMe |
| `deploy.sh` | the desktop | pushes this repo's config to the Pi, verifies byte-for-byte |
| `sync-to-sd.sh` | the Pi, `sudo` | refreshes the SD fallback from the running NVMe |

🚨 **The clone gives the NVMe a different MBR disk ID (`0x1a2b3c4d`) than the SD (`0xb3a878db`).**
This is not cosmetic. PARTUUIDs are derived from the disk ID, so cloning the table verbatim would
put two partitions with identical PARTUUIDs in the same machine and `root=PARTUUID=` could resolve
to either one. `sync-to-sd.sh` therefore never touches the SD's `fstab` or `cmdline.txt` — the
card has to keep pointing at its own `b3a878db-*`, or it stops booting.

### The discipline that matters

**This repo is the source of truth; the Pi is a deploy target.** The reason the original
SPI/Remora build is stranded on one old SD card is precisely that it only ever existed on the
machine. Edit here → commit → `./deploy.sh`. After a config change, run `sudo ./sync-to-sd.sh`
so the fallback card isn't months behind the drive that's actually booting.

## Rebuild path (Pi side, from scratch)

The Pi's NVMe was pulled for another project, so the Pi side is a clean rebuild. The difference
from the last attempt is that the configuration now lives in this repo instead of only on that
drive.

### The two routes, and why we picked one

Both get you a Pi 5 running LinuxCNC with Remora over SPI. They differ in exactly one axis: how
current the OS is versus how much you have to build.

| | **Route A — LinuxCNC official image** | **Route B — Expatria Flexi-Pi** |
|---|---|---|
| OS base | Raspberry Pi OS **Trixie** (current) | Debian base unconfirmed; the Trixie migration was a Jan 2026 *pre-release*, so the stable build may still be Bookworm |
| LinuxCNC | 2.9.8 | **2.10** (newer) |
| Kernel | `6.12.34+rpt-rpi-v8-rt` — Pi Foundation's own PREEMPT_RT build | 6.6-rt |
| Pi 5 | Officially supported (Pi 3 and earlier not recommended) | Supported, "significantly better performance than Pi 4" |
| `remora-spi` | **You build it** — rp1lib + `halcompile` | **Pre-built and included** (stock `Remora-spi` and `Remora-eth-3.0`, as-is) |
| Default UI | XFCE desktop, AXIS available | QtDragon_hd |
| Size | 6.5 GB base, 16 GB minimum | — |

**Chosen 2026-09-03: Route A.** A current Debian base was the priority, and the decisive point is
that Route A does not make you pay for it with the risky part. The genuinely unbounded job in a
LinuxCNC Pi build is the **real-time kernel**, not LinuxCNC — rolling your own means `rpi-update`
into a bleeding-edge branch, plus the well-known trap where LinuxCNC reports *"Using POSIX
non-realtime"* on a kernel that is actually fine. Route A hands you Trixie *and* an RT kernel the
Pi Foundation built. What it costs is building `remora-spi`, which is a bounded, documented job
in Remora's own install docs.

Route B remains the better answer for anyone who wants zero build steps and doesn't care about
the Debian base. Note its LinuxCNC is *newer*, not older — the concern with it is the OS, not the
application.

**Route C — plain Pi OS Trixie, roll everything yourself — was rejected.** It buys nothing over
Route A and takes on the RT kernel as your problem. (A `2025-12-04-raspios-trixie-arm64-lite`
image already sits in `~/Downloads` from Feb 2026; it is *Lite*, so it has no desktop for AXIS to
draw on, and it is not a LinuxCNC image.)

### Route A, step by step

```
image_2026-01-21-raspios-lcnc-2.9.8-trixie-arm64.zip
https://www.linuxcnc.org/iso/image_2026-01-21-raspios-lcnc-2.9.8-trixie-arm64.zip
md5  705b7f3c2f7b385f6cb094d05e01070e
```

1. **Read the Octopus's microSD first** — copy `config.txt` into this repo *before* touching the
   Pi. See the section above.
2. Flash the image to the Pi 5's NVMe (Raspberry Pi Imager; set username/password in the imager's
   own settings, the image expects it).
3. Build and install the Remora component: rp1lib, then `halcompile` the stock
   `scottalford75/Remora` SPI component. Remora's install docs cover this.
4. Clone this repo, point LinuxCNC at `milo.ini`.
5. Reconcile `milo.hal` against `config.txt`: joint order, PWM channel, input numbers,
   `PRU_base_freq`.
6. Work through "First power-on order" below.

### ⚠️ Do not upgrade the kernel

The image ships `6.12.34+rpt-rpi-v8-rt`, which is the known-good one. **`6.12.47` was reported to
crash.** Do not reflexively `rpi-update` or accept a kernel bump after flashing — you are on the
good kernel out of the box. Pin it and leave it until something forces the issue.

These Trixie images were still described as experimental as recently as the 2.9.7 builds, with
the maintainer noting how little testing feedback he had. 2.9.8 is now *the* image on the official
downloads page, so it has graduated — but it is young. If something behaves strangely in the first
hours, suspect the image before suspecting your config.

## First power-on order

1. Motors unpowered. Start LinuxCNC, open halshow, press each endstop by hand and
   confirm the right pin changes state and in the right direction.
2. Still unpowered: jog each axis in the GUI and confirm commanded position moves
   the way you expect.
3. Power one axis. Jog 10 mm. Measure it with calipers. `SCALE` is wrong if it isn't
   10 mm — and it will be wrong by an exact ratio, which tells you the microstep
   mismatch immediately.
4. Only then home an axis, and keep a hand on the e-stop the first time.
