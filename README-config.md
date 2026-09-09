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

## ✅✅ FULL STACK WORKING (2026-09-05) — link + drivers, together

For the first time, everything below the machine layer is live at once:

| | Result |
|---|---|
| `remora.SPI-status` | **TRUE**, repeatable |
| Octopus state during test | `## Entering RUNNING state` |
| `SPI_freq` sweep 100 kHz → 2 MHz | **TRUE at every step** — good margin, no marginal-timing edge |
| TMC2209 ×3 over UART | `Testing connection to TMC driver...OK` |
| `config.txt` on the card | 1998 B, `Deserialization succeeded` |
| Modules loaded | 3 stepgens · 3 TMC2209 · 3 digital inputs · reset pin |

`milo.hal` runs `SPI_freq=2000000`. The sweep shows it works from 100 kHz to 2 MHz, so 2 MHz is a
conservative choice with headroom rather than a value found at the edge of working.

### 🚨 The MOSI incident — six flying leads is the real lesson
After the SD-card swap and two rounds of jumper changes, the link failed again. Diagnosis by
elimination, all from the Pi:

| Line | Verdict | How it proved itself |
|---|---|---|
| SCLK | ✅ | board clocked data in and reacted at all |
| CS | ✅ | MISO tri-stated / drove in step with it |
| MISO | ✅ | drove low under CS, high-Z when released |
| **MOSI** | ❌ | the only line that cannot verify itself indirectly |

Symptom was `Communication data error` at **every** clock from 2 MHz down to 100 kHz — which rules
out noise and loading, both of which are clock-dependent. The board was receiving transactions and
clocking in zeros. Reseating the MOSI lead (Pi 19 → EXP2-6) fixed it immediately.

📌 **This is the argument for the keyed 2×4 IDC connector over pins 19–26** documented above.
Six loose dupont leads beside a board you must keep handling is how an afternoon disappears into
one wire that backed out.

## ✅ SPI LINK IS UP (2026-09-05) — the "link is down" finding was a broken test

`remora.SPI-status` reads **TRUE**, repeatably, and the Octopus's own serial output confirms the
handshake from its side: `## Entering RESET state` → `Resetting rxBuffer` → `## Entering RUNNING
state`. **The hardware was never the problem.**

🚨 **The test was wrong.** `remora-spi.c` gates the transfer like this:

```c
if (*(data->SPIenable))
    if( (*(data->SPIreset) && !(data->SPIresetOld)) || *(data->SPIstatus) )
        spi_transfer();
```

`SPIstatus` starts FALSE, so **a rising edge on `SPI-reset` is the only thing that can trigger the
first transfer.** The old test set `SPI-enable` and nothing else — so `spi_transfer()` was called
**exactly zero times**, the component put nothing on the wire, and `SPI-status` read FALSE
regardless of the hardware. Verified directly: with the old test the Octopus's serial line is
*completely silent*; with a raw `spidev` write it logs `Communication data error`; with the reset
edge added it goes straight to `RUNNING`.

**Correct standalone test — the reset pulse is mandatory:**

```
setp remora.SPI-enable 1
setp remora.SPI-reset 0
start
loadusr -w sleep 1
setp remora.SPI-reset 1      # <-- rising edge. Without this, nothing happens, ever.
loadusr -w sleep 3
show pin remora.SPI-status
```

In `milo.hal` the edge comes from `iocontrol.0.user-request-enable`, i.e. it is generated when you
enable the machine in LinuxCNC. **Standalone tests must supply it by hand.**

📌 **Cost: two days.** This false negative sent us through ribbon cables, connector pinouts, board
power, USB, and the microSD — all of which were fine. **Lesson: before trusting a negative result
from a test, read the code path that produces the signal you are reading.** Everything below this
line was written while chasing the phantom; it is kept because the hardware findings are real and
independently useful, but the "link is down" premise behind it was false.

### The old (wrong) diagnosis, kept for the hardware findings
1. The SPI ribbon is not connected (the machine has been apart for months).
2. The Octopus's microSD is out — Remora halts without `config.txt`.
3. The Octopus is not adequately powered. It is fed from the Pi, which is browning out.
4. The firmware is not running for some other reason.

**All four were disproved.** The boot log shows `Mounting the filesystem... OK`, `Opening
"/fs/config.txt"... OK`, `Deserialization succeeded`, SPI1 slave + DMA initialised, all three
stepgens loaded, `## Entering IDLE state`.

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


## 🚨 Safety loop: LinuxCNC does not know the machine is dead (open, 2026-09-08)

`emc-enable-in` is driven by **`SPI-status` alone**. That covers "the link to the Octopus failed".
It does **not** cover the e-stop — and with the contactor topology that is a real behavioural gap,
not a theoretical one:

> E-stop drops the contactor → VFD mains and the Octopus **VM stepper rail** die. The Octopus
> **logic stays live** (deliberately — that is what preserves endstops and position). So SPI keeps
> working, `SPI-status` stays TRUE, and **LinuxCNC carries on executing the program into dead
> drivers.** The tool stops moving; the program does not stop. Commanded position walks away from
> actual position and you discover it at reset.

**The fix:** a **normally-open auxiliary contact** on the contactor, wired between an Octopus input
and **GND** — a dry contact. Do not put 24 V on a 3.3 V input.

| State | Contact | Input | `.not` | Meaning |
|---|---|---|---|---|
| Contactor energised | closed | LOW | TRUE | machine live |
| E-stop pressed | open | HIGH | FALSE | e-stopped |
| **Wire breaks** | open | HIGH | FALSE | **e-stopped — fail-safe** |

That polarity is chosen so a broken wire reads as *not safe*.

Wired in `octopus/config.txt` as `PG_12` → `remora.input.04`. The HAL side is written but
**deliberately left commented out**, because the contactor is not built yet — as of 2026-09-06 the
machine is still mains → e-stop switch → 24 V PSU with no contactor. Enabling it against an
unwired input would read "not live" forever and lock the machine in E-stop.

⚠️ When uncommenting, **delete the direct `net remora-status … => iocontrol.0.emc-enable-in`
line** — HAL will refuse two drivers on one signal.

### Does the physical e-stop replace pressing F1? No — and that is deliberate

Worth being precise, because the two are doing different jobs.

| Pin | What it is |
|---|---|
| `iocontrol.0.emc-enable-in` | the **external** e-stop input. FALSE forces LinuxCNC into e-stop and **holds it there** |
| `iocontrol.0.user-enable-out` | goes TRUE when the operator clears e-stop in the GUI (F1) |
| `iocontrol.0.user-request-enable` | pulses when the operator *requests* enable |

Wiring the contactor aux to `emc-enable-in` makes LinuxCNC **follow** the hardware: hit the
mushroom and it drops into e-stop instantly, and it will refuse to clear while the button is
latched. But **releasing the mushroom does not re-enable the machine.** You still perform a
deliberate clear.

🔑 **That is a safety property, not an annoyance.** Machine power must never come back the instant
someone twists a mushroom out — re-enabling is an intentional act by someone who has looked at the
machine. It is also why "E-stop won't clear" is a *symptom to diagnose*, not something to defeat
(see the WDRESET section).

It can be made to auto-clear in HAL. Don't.

### Replacing F1 with a physical button — the right way to do it

The industrial pattern is **red latching mushroom to stop, green momentary button to reset**. That
is what the contactor topology was reworked for. With `halui` loaded (`[HAL] HALUI = halui` in
`milo.ini`):

```
# green reset button on a spare Octopus input
net estop-reset  remora.input.05 => halui.estop.reset
net machine-on   remora.input.05 => halui.machine.on
```

⚠️ Driving both from one input fires them simultaneously; if the machine does not come up in one
press, sequence them — reset first, then `machine.on` — with a `oneshot` or simply two presses.

✅ **This cannot defeat the hardware.** `halui.estop.reset` is a *software* reset; while the
mushroom is latched, `emc-enable-in` stays FALSE and LinuxCNC re-asserts e-stop immediately. The
button can only clear the software state once the hardware already permits it. Keyboard F1 remains
available either way.

## 🔗 The full safety chain — two chains, not one

The intended end state is several conditions all satisfied before the machine can be enabled.
Correct. But they belong in **two separate chains**, and conflating them is the classic error.

### Chain 1 — hardware, in copper. This is the safety function.
Normally-closed contacts **in series**, feeding the contactor coil. Break any one and the
contactor drops out. No software involved, nothing to crash or hang.

- E-stop mushroom (latching, NC)
- Any additional e-stop station / pendant, in series — **this is what the contactor rework was for**
- Guard or enclosure interlock, if the machine ever gets enclosed
- Thermal / overload contacts

🚨 **Nothing that is not an emergency stop belongs in this chain.** Power-good and spindle feedback
are not emergency stops.

### Chain 2 — software permissive, in HAL. This is awareness and interlock.
Conditions ANDed into `iocontrol.0.emc-enable-in`. Use the `logic` component rather than a stack
of `and2`s:

```
loadrt logic names=safety-chain personality=0x104   # AND, 4 inputs
addf safety-chain servo-thread

net link-ok       remora.SPI-status   => safety-chain.in-00
net contactor-ok  remora.input.04.not => safety-chain.in-01
net psu-ok        remora.input.05.not => safety-chain.in-02
net vfd-ok        remora.input.06.not => safety-chain.in-03
net machine-ok    safety-chain.and    => iocontrol.0.emc-enable-in
```

`.not` on the physical ones because dry contacts pull the input to GND. Check the pin names against
`man logic` before relying on them.

### 🚨 What NOT to put in Chain 2 — over-eager e-stop is its own hazard

**An e-stop mid-cut is not free.** It stops the axes *and* the spindle with the tool buried in the
work — that can weld the cutter in, break it, or move the part. A chain that trips on
not-really-emergencies trains you to ignore it, which is worse than not having it.

| Signal | Where it belongs |
|---|---|
| SPI link lost | **Chain 2** — no control at all |
| Contactor dropped / power gone | **Chain 2** — commanding dead drivers |
| 24 V PSU DC-OK (if the PSU has one) | **Chain 2** |
| VFD *fault* output | **Chain 2** — the spindle has failed |
| **Spindle at-speed** | ❌ **NOT the e-stop chain.** This is `spindle.0.at-speed`, which gates *feeding*. Motion waits for it after M3 natively |
| Coolant low / air pressure low | ❌ warning or program pause, not e-stop |

### 🔎 Add a first-out indicator, or you will regret the AND

With four inputs ANDed, "the machine won't enable" tells you nothing about **which** one is false.
This repo already documents that exact confusion once — "E-stop won't clear" turning out to mean
the SPI link was down. `halcmd show pin safety-chain` answers it, but a status readout in the GUI
is better. Wire the chain and the diagnosis together, not the chain alone.

### One more thing the e-stop should do
Killing VFD mains leaves a 24 000 rpm spindle coasting for a long time with the tool in the work.
The e-stop should **also** command the VFD to brake via its own safe-stop / external-fault input,
with the contactor as the backstop behind it. Decide that before the panel is built — it is a
wiring change, not a setting.

### H100 VFD — does it have the stop input? Yes, but it is not STO

Read out of the *H100 Series High Performance Vector Control Inverter* manual (the generic Chinese
H100, **not** LS Electric's LSLV-H100 — very different drives sharing a name).

**✅ Emergency stop input exists.** Six multi-function digital inputs — FOR(X1), REV(X2), RST(X3),
SPH(X4), SPM(X5), SPL(X6) — set by **F044–F049**. Assign **function `13` = Emergency stop** to a
spare one. (Defaults: F044=02 Forward, F045=03 Reverse, F046=14 Reset, F047/48/49 = High/Medium/Low
speed.) Function `14` = Reset is also available if a reset button is wanted.

**✅ And it can brake rather than coast** — which was the whole point. **`F022` = emergency stop
deceleration time**:

| F022 | Behaviour |
|---|---|
| `0.0` | emergency stop **coasts** — the 24 000 rpm spindle freewheels with the tool in the work |
| `0.1–6500.0 s` | controlled deceleration over that time |

⚠️ **Do not set it too short.** Decelerating a spinning spindle pushes energy back into the DC bus;
without a braking resistor an aggressive ramp trips on overvoltage. Start around 1–2 s and shorten
it only as far as it will reliably go.

**✅ A relay for the software chain.** `F053` drives the **FA / FB / FC** form-C relay and already
defaults to `3` = Fault indication. But for the permissive chain, **use `21` = "Ready for
operation" instead**, and wire the normally-open contact.

> 🔑 **Why "ready" beats "fault":** pick the function *and* the contact so that **de-energised means
> unsafe**. With "Ready" on the NO contact, a drive that loses power or hangs stops asserting ready
> and the chain opens. With "Fault" on the NC contact, a dead drive also stops asserting fault — so
> it reads healthy while being dead. Verify the relay's energisation direction with a meter before
> trusting either.

**❌ There is no Safe Torque Off.** Nothing in the manual — no STO, no safety-rated stop function.

So function 13 gives a **functional** stop that depends on the drive's firmware behaving. That is
genuinely useful — it is what makes the spindle brake instead of coast — but it is **not** a
substitute for breaking power. **The contactor remains the actual safety function**, exactly as in
Chain 1 above. Use both: function 13 for the fast controlled stop, the contactor as the backstop.

## ⚡ Choosing the contactor — and why it cannot be 24 V only

### 🚨 The contactor MUST break the VFD's mains. Here is why.

The proposal to switch only the 24 V bus fails on one point: **the spindle does not run on 24 V.**
It runs on the VFD, which runs on mains. Break only the 24 V rail and the steppers stop while the
**spindle keeps turning** — which is the opposite of what an e-stop is for.

That would only be acceptable if the VFD had a **safety-rated STO** to fall back on. The H100 does
not (see the H100 section above — function 13 is a *functional* stop dependent on firmware). So the
contactor breaking mains is the actual safety function, and there is no way around it.

**But the instinct is half right, and the design already does the other half.** The contactor
switches **both**: the VFD's mains *and* the Octopus's VM stepper rail. What stays live is the
Octopus's **logic and endstops** — deliberately, because that is what preserves machine position
and switch states across an e-stop. So it is already a mixed-voltage contactor, not an
all-or-nothing mains cut.

### What to buy

| Requirement | Why |
|---|---|
| **24 VDC coil** | the e-stop chain runs at 24 V — safe to run to a pendant, and no mains down a tether |
| **~20–25 A AC-1** | a VFD input is a rectifier/capacitive load, so **AC-1**, not AC-3. Size on the VFD's input current with headroom for **DC-bus inrush** at power-on |
| **3–4 poles** | VFD line + neutral, plus the 24 V VM rail |
| **Auxiliary NO contact** | feeds `remora.input.04` so LinuxCNC knows the machine is live — built in, or a clip-on block |

Concrete example: **Schneider TeSys `LC1D09BD`** (9 A AC-3 / **25 A AC-1**, `BD` = 24 VDC coil)
plus a **`LADN11`** aux block (1 NO + 1 NC). Eaton DILM, ABB AF and Siemens 3RT equivalents are all
fine. Confirm the coil-voltage suffix before ordering — it is the easiest thing to get wrong.

⚠️ **Check the DC rating for the 24 V poles.** DC arcs do not self-extinguish at a zero crossing,
so an AC contactor's DC rating is much lower and is published separately (**DC-1** / **DC-13**).
At 24 V and a few amps this is normally fine, but look rather than assume.

### 🔁 The seal-in circuit is what makes it behave

```
24V+ ──[E-stop NC]──[other NC contacts]──┬──[START NO]──┬── K1 coil ── 24V−
                                          │             │
                                          └──[K1 aux NO]┘
```

The K1 aux in parallel with START holds the coil in after you let go. Break the chain anywhere and
it drops **and stays dropped** until START is pressed again. That is what gives you "power does not
come back on its own" in hardware — the same property discussed for the software reset, but this
one does not depend on any firmware.

📌 Additional e-stop stations (a pendant) go in series in the NC run. That is the whole reason for
moving to a contactor.

### 🚫 Do NOT use a second contactor as the master off switch

A contactor is a **momentary-logic** device: it needs its coil held energised, so a "master"
contactor drops on any mains blip and needs someone to press START again. That is wrong for
end-of-day isolation.

**Use a lockable rotary disconnect switch** (or a plug you physically pull). Cheaper, simpler, and
— the part that matters here — **lockable**.

🔑 **The workshop is shared.** A lockable disconnect is how the machine is made safe to *leave*:
lock it off and nobody can energise it while you are under it or away from it. In a space other
people use, that is not a nicety, it is the point.

### ✅ Sized from the nameplate (2026-09-09) — and `LC1D09BD` is TOO SMALL

```
H100-1.5C2-1B
POWER : 1.5KW
INPUT : 1PH 110V 50/60HZ
OUTPUT: 3PH 0-110V 14A 0-1000HZ
```

🚨 **The 14 A is the OUTPUT current, not the input.** That is the trap. Input current on a
single-phase 110 V drive is *higher* than output, because the same power comes in at a lower
voltage through an uncorrected rectifier with a poor power factor:

> 1500 W ÷ (110 V × ~0.65 PF × ~0.95 η) ≈ **22 A** — call it **18–24 A** steady.

**So my earlier `LC1D09BD` recommendation was wrong.** At 25 A AC-1 it would sit at 80–90 % of
rating with nothing left for DC-bus inrush at power-on.

| Part | AC-1 rating | Verdict |
|---|---|---|
| `LC1D09BD` | 25 A | ❌ too tight — withdrawn |
| `LC1D18BD` | 32 A | ✅ minimum |
| **`LC1D25BD`** | **40 A** | ✅ **buy this** — the price difference is small and the margin is real |

Still with a `LADN11` aux block, still a 24 VDC coil.

### 🚨 This also sizes the circuit, which matters for the Church workshop
18–24 A at 110 V **will not run on a standard 15 A outlet.** It needs a **20 A circuit as an
absolute minimum, realistically a dedicated 30 A**. Worth settling before the workshop's electrical
is finalised, alongside whatever the compressor needs.

### ❓ One thing to confirm: is the spindle a 110 V spindle?
The drive outputs **0–110 V**. Many Chinese water-cooled spindles are **220 V**. Running a 220 V
spindle from a 110 V drive halves the V/f ratio — it makes rated torque only to about half its base
frequency and then runs in field weakening, so it feels gutless at speed. If the spindle and drive
came as a matched kit this is a non-issue; check the spindle's own plate to be sure.

### 🏅 The properly-engineered version, for reference
A **safety relay** (Pilz PNOZ, Schneider XPS, Omron G9S) sits between the e-stop and the contactor
and adds dual-channel monitoring — it detects a welded contact or a shorted wire, and enforces a
monitored reset. That is how a commercial machine does it. For a hobby mill a plain contactor with
the seal-in above is the normal pragmatic choice; the safety relay is worth knowing exists.

## 💧 Mist coolant + air blast (config written 2026-09-08, hardware not fitted)

G-code drives these directly: **M7 = mist, M8 = air blast, M9 = both off.** There is no flood
system, so `coolant-flood` is repurposed as the blast — which gives independent control of coolant
and chip clearing from the program.

| Function | Octopus pin | HAL |
|---|---|---|
| Mist solenoid | `PA_8` (FAN0 MOSFET) | `remora.output.00` ← `iocontrol.0.coolant-mist` |
| Air blast solenoid | `PE_5` (FAN1 MOSFET) | `remora.output.01` ← `iocontrol.0.coolant-flood` |

**Use the FAN/HEATER MOSFET outputs, not a bare GPIO.** They are low-side switches with
pulled-down gates, so they are off through boot and reset — the same reasoning that governs the
spindle enable relay. A bare 3.3 V pin cannot drive a 24 V solenoid at all.

🚨 **Flyback diode across each solenoid coil.** An inductive load on a bare MOSFET kills the FET on
the first switch-off.

**Why gating the air matters beyond tidiness:** the CAT 8010 is rated 70/30 duty with a stated
60-minute continuous ceiling. Running blast continuously through a long job exceeds the
compressor's own specification. On M8 it flows only during cuts, which is what brings a small
quiet compressor inside its rating — see the compressor sizing in [[plasma-table-plan]].

⚠️ Pin numbers are from the standard Octopus v1.1 pinout. Verify against the silkscreen, and
confirm the new modules parsed by reading the boot banner — a mistyped key shows up there and
nowhere else.


### Parts list — mist coolant + air blast

**1. The mist unit — get a non-atomizing one.** This is the decision that matters, and it matters
more given the machine is indoors — see the siting note below; the workshop is at the Church
with real ventilation, which relaxes this considerably.

| | Non-atomizing (Fog Buster / Tormach LUBE CUBE / HVLP MQL) | Venturi "mist" kits (cheap eBay/Amazon) |
|---|---|---|
| Output | fairly large droplets deposited **on the work** | finely atomized coolant **into the air** |
| Surroundings | "no film on anything surrounding" | film on everything |
| Breathing it | essentially none airborne | airborne aerosol you are standing in |
| Air | **10–20 psi** (Fog Buster) / **20–120 psi, 0.7–2.0 CFM** (LUBE CUBE) | much higher |

The cheap kits are the ones that put coolant fog in the room. Don't. ✅ Air consumption is still
tiny — the LUBE CUBE's stated **0.7–2.0 CFM** sits comfortably inside the CAT 8010's 3.10 CFM
@ 40 psi, so the compressor conclusion holds.
⚠️ **Correction:** an earlier version of this section said 5–10 psi. Fog Buster's own copy says
**10–20 psi**; the LUBE CUBE wants **20–120 psi**. Still low, but not as low as stated.
Coolant consumption is also negligible — an 8 oz reservoir is reported to need refilling about
once a year.

**2. Solenoid valve ×2** — one for mist (M7), one for air blast (M8).
- 2/2-way, **normally closed**, **24 VDC coil**, 1/4" ports, rated for air, ~5 W.
- 🔑 **Buy them with a DIN 43650 form B connector that has a built-in LED and flyback diode.**
  That satisfies the flyback-diode requirement neatly *and* gives you a per-valve indicator — much
  better than soldering a 1N4007 across each coil yourself.
- ~0.3 A at 24 V, well inside what the Octopus FAN MOSFET outputs will switch.

**3. Air preparation**
- Filter / water separator **plus regulator**. Not optional — otherwise you spray water onto the
  work and into the chips.
- ⚠️ **Get a low-pressure regulator (0–30 psi) for the mist leg.** A standard 0–125 psi regulator
  is far too coarse to set 5–10 psi accurately.
- ⚠️ **Mist and blast want very different pressures** — ~5–10 psi vs ~30–40 psi. Feed them from
  separate regulators off the same line rather than compromising on one.

**4. Plumbing** — 1/4" or 6 mm push-to-connect fittings, air hose from the compressor, PTFE tape.

**5. Coolant fluid** — water-soluble / semi-synthetic suitable for aluminium. Consumption is so low
that a small bottle lasts a very long time.

**6. Nozzle + mount** — Loc-Line style flexible hose and a magnetic base. Usually included with the
unit; a second one is needed for the blast nozzle.

**7. 🚨 The thing nobody budgets for: containment.** The Milo is an **open** machine. Even a
non-atomizing unit throws droplets and wet chips. You want a splash tray and guards — and
specifically, **keep it away from the electronics enclosure.** The Octopus and Pi are right there,
and coolant plus a live 24 V board is a bad afternoon.

⚠️ Prices not quoted here on purpose — check live listings rather than trusting a remembered
figure (see [[verify-prices-in-chrome]]).


### 🚨 Priced 2026-09-08 — and Fog Buster looks discontinued

Checked on live listings, not snippets.

| | Price | Availability |
|---|---|---|
| **Fog Buster 10100** (½ gal, single sprayer) | **$375.00** | ⚠️ **"Discontinued Item"** |
| **Tormach LUBE CUBE** (PN 55156) | **$395.00** | Out of stock — backorder |

**The $20 gap is not the story; availability is.** Three independent signals say Fog Buster is
winding down:
- `fogbuster.com` is a **parked GoDaddy domain, for sale**
- the 10100 listing is flagged **Discontinued Item**
- the dealer's whole Fog Buster category is now **one spare part** — a check valve at $25.71

So in practice this is not a choice between two products. **The LUBE CUBE is the one you can buy**,
even if it currently ships on backorder.

### What the LUBE CUBE actually includes — this shrinks the parts list

Reservoir · mounting bracket · precision spray nozzle · pneumatic lines · **pressure regulator** ·
**solenoid valve (pre-assembled)**.

So for the mist leg you do **not** separately need the regulator or the solenoid from the parts
list above. Those items still apply to the **air blast** leg.

### 🚨 But the included solenoid is 115 Vac — that breaks our wiring plan

That is what "115 Vac" in the product name refers to. It **cannot** be driven from an Octopus FAN
MOSFET output, which switches 24 V DC low-side. Two ways round it:

1. **Swap the solenoid for a 24 VDC one** — keeps `remora.output.00` driving it directly exactly as
   `milo.hal` is written, and keeps everything on one low voltage. Preferred.
2. **Drive the 115 Vac solenoid through an SSR or mains relay** from `remora.output.00`. Works, but
   puts mains switching in the coolant path for no benefit.

Either way `milo.hal` does not change — only what sits between the output and the valve.

Other requirements: **0.5 gal MQL-safe coolant**, and explicitly **not pure water, alcohols or
other solvents**.


### 🔧 DIY option — and what is actually hard about it

**How a Fog Buster works**, which is the whole design brief:

1. The reservoir is **pressurised with air at 10–20 psi**. That pressure — not suction — pushes
   coolant up the fluid tube.
2. A **separate, high-volume low-pressure air stream** runs to the nozzle.
3. They meet **at the nozzle exit**, not inside a venturi. The coolant is *carried* by the air as
   fairly large droplets rather than atomised into it.
4. Coolant flow and air flow are adjusted **independently**.

Everything except step 3 is generic plumbing. **The spray head is the hard part** — it is the
patented geometry, and it is the difference between a fogless sprayer and a fog machine.

#### 🚨 The failure mode to avoid
**Do not build a venturi / siphon nozzle.** If the air stream draws coolant through a restriction
— airbrush style — you get atomised fog, which is exactly the thing being avoided, and the reason
the non-atomising type was chosen in the first place given the machine is indoors.

#### Tier 1 — buy the head, build the rest (recommended)
CNC Rebuild sell a **"FogBuster DIY Coolant Sprayer Set"**: 1.5 L tank, **original FogBuster spray
head**, air tube, fluid tube, check valve. You add the regulator, solenoid and mounting.
⚠️ **No price quoted here — their price field literally renders `awefawfwaf`**, i.e. placeholder
text. It is also a European shop, so check shipping before assuming it beats $395.

#### Tier 2 — full DIY
| Part | What to use | Notes |
|---|---|---|
| Reservoir | **A water filter housing** — threaded sump + ported head | See the note below. Better than a garden sprayer in every way that matters. 🚨 **Do NOT 3D print a pressure vessel** — FDM layer adhesion, and a bad failure mode. |
| Regulator | **0–30 psi** | A 0–125 psi regulator cannot set 10–20 psi with any precision. |
| Coolant flow | small brass **needle valve** on the fluid line | This is the fine-adjustment that matters. |
| Air flow | needle or ball valve on the air line | Independent adjustment is the entire point. |
| Check valve | on the fluid line | Stops air backing into the reservoir and coolant into the air line. |
| Nozzle | **coaxial** — ~1–1.5 mm coolant tube inside/alongside a ~4–6 mm air tube, terminating together | Machine it on the Milo. Coolant must be introduced **at or just past the exit plane**. |

#### 🛢 The reservoir: use a water filter housing

The standard threaded-sump water filter housing — the kind used for whole-house filtration, RO
pre-filters and aquarium water prep. The screw-off bowl is the **sump**; the top with the ports is
the **cap** or **head**.

Why it beats a garden sprayer:

- **Rated around 125 psi** against a sprayer's ~40–60, and this needs only 10–20.
- **The head already has two threaded ports** — so there is *no drilling or tapping a pressure
  vessel*, which was the ugly part of the sprayer plan. And two is exactly the number needed:
  **air into the headspace through one, coolant out through the other via a dip tube.**
- **Clear sumps exist**, which gives you the level window the LUBE CUBE advertises as a feature.
- Screw-off sump for filling and cleaning; mounts on a standard bracket.

Standard sizes: **10″ or 20″ long**, in **2.5″ ("slim line")** or **4.5″ ("Big Blue")** diameter.

⚠️ **Two things to check before buying:**
1. **Sump material vs coolant.** Polypropylene is fine with water-soluble coolant. **Clear sumps
   are often SAN or styrene and can craze or embrittle with neat oils** — if running a neat
   lubricant rather than a water mix, take the opaque PP sump and give up the level window.
2. **Port size.** Prefer a **1/4″–1/2″ NPT** head; the 1″ ports on Big Blue housings are far more
   adapting than you want to reach 4 mm tube.

The **dip tube is the one part to fabricate** — a length of tube through the outlet port reaching
near the bottom of the sump, sealed at the port. Everything else threads together.

📌 Same form factor already exists in the air line: the bowl on a water separator is this idea at
small scale.

#### 🔑 The valve detail that makes it work with `milo.hal`
**Use a 3/2 (three-port, two-position) solenoid, not a 2/2.**

A 2/2 merely blocks flow — the reservoir stays pressurised and the nozzle dribbles after M9. A 3/2
**exhausts the downstream side when de-energised**, so the reservoir vents and flow stops the
instant the output drops. Same 24 VDC NC coil, same `remora.output.00`, same FAN MOSFET, same
flyback diode — just the right valve type.

#### What this leverages
The Milo can machine its own nozzle; the printer can make brackets, a housing
mount and a Loc-Line holder (but **not** the pressure vessel). The expensive part of the commercial unit is the
head; almost everything else is a fitting.

#### 💡 Better Tier-2 starting point: a cheap tank kit as the donor

Amazon prices, checked live 2026-09-08:

| Tier | Price | What you get |
|---|---|---|
| Bare mister | **$9.99 – $18.88** | venturi nozzle, Loc-Line, magnetic base, needle valve, tubing |
| Mid | **~$35.99** | as above, a bit more plumbing |
| **Tank unit** | **$96.99 – $109.98** | **3 L pressurised tank + solenoid valve + air filter/regulator + 2 nozzles + Loc-Line** |

They are all sold as "mist" / "oil mist" sprayers, so assume the **nozzle atomises** — that is the
thing we ruled out for an indoor machine.

**But look at the architecture of the $97–110 units.** A pressurised reservoir feeding a nozzle,
gated by a solenoid, with filtered/regulated air — that is *structurally the same* as a Fog Buster.
The reservoir is pressurised, not siphoned. **The only questionable part is the nozzle.**

So one of those is arguably the best possible starting point for Tier 2: it hands you the tank,
the solenoid, the air filter, the fittings and the Loc-Line in one box for around $100 — the whole
plumbing list — and leaves you exactly one part to evaluate and, if it fogs, replace with the
coaxial nozzle described above.

Even the $10 units are worth it purely as parts donors for the **air blast** leg: Loc-Line,
magnetic base and a needle valve for less than buying them individually.

⚠️ Check the solenoid's coil voltage before assuming it drops into `remora.output.00` — these kits
commonly ship 110 V or 220 V AC coils. Same issue as the LUBE CUBE. A 24 VDC replacement is cheap.

#### ⚖️ Honest calibration on the atomising point
The non-atomising preference is real and it is why the expensive units exist — but it **scales with
duty and ventilation**, and this file has been firm to the point of sounding absolute. Occasional
light use with airflow is not the same risk as hours a day in a room of the house. The reason it
⚠️ **Superseded 2026-09-08:** the workshop is at **the Church** — a dedicated space with powerful
ventilation and additional filtration, not a room of the house. That removes the premise the
non-atomising preference rested on. **The cheap atomising kits are a reasonable buy.**
Non-atomising is still nicer for coolant economy and for not coating the machine, but that is now
a preference, not a health call.

### 🧪 Coolant choice — decided 2026-09-08: neat MQL oil

Three families are used at hobby level:

| | Examples | For | Against |
|---|---|---|---|
| **Water-mix, general** | **Koolmist 77** | cheap, cools well, everywhere | *"doesn't do a ton for lubrication and surface finishes"*; reports of rust and tank-life trouble |
| **Water-mix, semi-synthetic** | **Trim MicroSol 585XT / 690XT** | high-lubricity microemulsion, long sump life, good foam control, ~1 gal at sane money | still water — still goes off, still conductive |
| **Neat MQL oil** | **Unist Coolube 2210** (**2210AL** aluminium / **2210EP** steel) | vegetable-based, no water, *"no cleanup except a light film that wipes off easily"* | dearer per litre; less outright cooling |

**Decision: Unist Coolube 2210AL.** Four things about *this* machine in *this* place decide it:

1. **Intermittent use in a shared workshop.** A water emulsion sitting unused in a reservoir goes
   rancid and smells. That is the practical killer of water-based fluid in a space that is not
   solely yours and is not used daily.
2. **Aluminium at 24 000 rpm on 1/8" cutters wants lubricity, not heat capacity.** Built-up edge
   and chip welding are the failure modes here, and they are lubrication problems. MQL is a
   lubrication strategy; that is the right lever for this work.
3. **🚨 Water-based emulsions are electrically conductive.** The Milo is an *open* machine with the
   electronics enclosure right beside it. A light oil film is far more benign next to a live 24 V
   board than a conductive water mix.
4. **MQL consumption is tiny**, so the higher price per litre is close to irrelevant per job —
   Fog Buster reckon an 8 oz reservoir lasts about a year.

**Honest counterpoint:** Koolmist 77 and Trim MicroSol are cheaper and perfectly usable, and for
deeper cuts — especially in steel — water genuinely wins on cooling, partly through evaporation.
If the work shifts that way, **2210EP** is the steel variant, or keep a water mix for those jobs.

#### 🔗 This decision is coupled to two others — order them together
- **Sump material.** Neat oil ⇒ **opaque polypropylene sump**. Clear SAN/styrene sumps can craze
  and embrittle with neat oils, so the level window is off the table. Do not buy the clear one and
  then choose the oil.
- **LUBE CUBE compatibility**, if that route is ever revisited: its spec explicitly requires
  *"MQL-safe coolant, not pure water, alcohols or other solvents"*. Coolube satisfies that; a water
  mix would not.


## Still open

| # | Item | State |
|---|---|---|
| 1 | Octopus SPI pins | ✅ Resolved **and proven live**: `PA_7`/`PA_6`/`PA_5`/`PA_4` = **EXP2-6/1/2/4** → Pi 19/21/23/24. |
| 2 | PRU reset wire | ✅ **EXP2-7** (`PC_15`) → Pi pin 22. 🚨 Not EXP2-8, which is the MCU `RST`. |
| 2b | Octopus power | ✅ **CLOSED 2026-09-05.** Board is powered and its SPI slave responds to CS. The "may be unpowered" theory came from a bad test — see the CS-asserted correction. |
| 2d | MOSI / SCLK wiring | ✅ **CLOSED 2026-09-05 — wiring was correct all along.** `SPI-status` TRUE and the Octopus reports `RUNNING`. The zeros came from a test that never triggered a transfer. |
| 2c | Serial debug | ✅ **WORKING 2026-09-05.** TFT `PA_9`/`PA_10` → Pi 10/8. Enable at runtime with `sudo dtoverlay uart0-pi5` (no reboot); persist via `config.txt`. Read: `stty -F /dev/ttyAMA0 115200 raw -echo && cat /dev/ttyAMA0`. **This is what finally broke the case open.** |
| 2e | Octopus config.txt | ✅ **DONE 2026-09-05.** Repo config written to the card and confirmed live: `Json config file lenght = 1998`, `Deserialization succeeded`, 3 stepgens + 3 digital inputs loaded, SPI link still TRUE. ⏸ A further revision (endstop `Pull Up`, 2076 B) is committed but **not yet on the card** — bundle it with the next swap. |
| 2g | 🚨 SPI-mode drivers are IMPOSSIBLE on this board | **Hard constraint.** `main.cpp` builds `RemoraComms(..., SPI1, PA_4)` for `TARGET_OCTOPUS_446`, and SPI1 on the F446 is `PA4/PA5/PA6/PA7` — which is precisely what BTT labels **Motor-SPI** (`MOSI PA7 · MISO PA6 · SCK PA5`). The stepper SPI bus and the Pi link are **the same peripheral on the same pins**. The STM32 cannot be an SPI slave to the Pi and an SPI master to the drivers at once. **Drivers must be UART or standalone — never SPI mode.** (Why the link still works with SPI jumpers fitted: the drivers only drive MISO when their own CS — `PC4`/`PD11`/`PC6` — is asserted, and Remora never asserts it, so they sit high-Z.) |
| 2f | TMC2209 UART | ✅ **CLOSED 2026-09-05.** All three report `Testing connection to TMC driver...OK` after the driver-slot jumpers were set to UART. **Confirms the parts really are TMC2209** and that current/microsteps now come from `config.txt`. Superseded note follows: | 🚨 **LIVE.** All three report `Testing connection to TMC driver...failed! Likely cause: no power`. 🚨 **That message is ambiguous by construction** — `test_connection()` returns 2 whenever `DRV_STATUS` reads `0`, which happens both when the driver is unpowered **and** when it never replies at all. So it does **not** distinguish a missing 24 V supply from driver-slot jumpers not set for UART mode. Check both. ✅ **24 V confirmed present 2026-09-05**, and the card's `.as-found` config had **no TMC modules at all** — i.e. the drivers were commissioned in **standalone/SPI jumper configuration**, which is why `PDN_UART` never reaches the MCU. **Rejumper the slots for UART.** ⚠️ A TMC2209 has *no SPI port* — it is UART-only — so if the slots really are set for SPI, that setting was never valid for these parts. Confirm the chip markings. |
| 3b | 🚨 Endstop connectors shorted the 5 V rail | **Found 2026-09-06.** A separate logic-power LED beside the MCU went out the instant an endstop was plugged in and stayed out until a power cycle — while the 24 V power LED stayed lit. The switches are wired **NC (closed at rest)**, so plugging one in immediately bridges whichever two pins it lands on. `STOP`/`DIAG` connectors are **5 V / GND / signal**, so it sat on **5 V + GND** = dead short. ✅ Fix: shift each connector **one pin toward the board edge** so it spans **GND + signal**. ✅ **No damage** — the regulator current-limited and latched off; that is protection working. |
| 3c | NC wiring is correct and needs no invert | At rest closed ⇒ LOW; triggered open ⇒ pull-up ⇒ HIGH; **broken wire ⇒ HIGH ⇒ reads triggered = fail-safe**. `home-sw-in` wants TRUE when active, so **no `Invert`, no `.not`**. 🚨 This makes `"Modifier": "Pull Up"` **mandatory** — without it a triggered NC switch floats. |
| 3a | ✅ Endstops VERIFIED LIVE | **2026-09-06.** All three triggered by hand with the link up: X, Y and Z each read **FALSE at rest, TRUE when pressed**, returning to FALSE on release. **No `Invert`, no `.not` pins needed** — `milo.hal`'s existing `remora.input.00/01/02 -> joint.N.home-sw-in` block is correct as written. Toolsetter (`input.03`) reads TRUE while disconnected, which is the fail-safe working. |
| 3 | Endstop inputs | ⏸ **Not wired to the mill yet** (2026-09-05), so `remora.input.00/01/02` will read noise until they are. Pins `PG_6`/`PG_9`/`PG_10` = BTT `DIAG0/1/2`. ✅ Config now sets `"Modifier": "Pull Up"` — RRF used `M574 ... S1`, i.e. **switch-type** endstops, which need a pull-up to work against. Without it the firmware logs `Setting pin as No Pull` and the inputs float. ⚠️ `Invert` still unset: determine NO-vs-NC empirically in halshow once wired. |
| 4 | Driver modules | ✅ **PROVEN LIVE 2026-09-05** — all three TMC2209s answer over UART (`test_connection()` OK), configured from `octopus/config.txt` at 8 microsteps, 1200/1200/900 mA. `SCALE` in `milo.ini` now agrees with the hardware by construction. |
| 5 | Motor directions | ✅ **CLOSED 2026-09-06.** All three ran backwards on first jog, exactly as `M569 P0/P1/P2 S0` predicted. Fixed by negating `SCALE` → **-200 / -200 / -400**. Re-jogged: all three now correct. |
| 6 | TMC UART pins | ✅ **VERIFIED 2026-09-05** against BTT's own pinout: MOTOR0/1/2 CS = `PC4`/`PD11`/`PC6`, matching the config exactly. 🚨 **Correction: it does NOT fail silently.** `TMC2209::configure()` calls `test_connection()` and prints `Testing connection to TMC driver...OK` or `failed! Likely cause: loose connection / no power`. With serial working you will see it. |
| 7 | Spindle PWM + enable | ⚠️ Schema known (`SP` / `PWM Pin` / `PWM Max`). Nothing wired yet. |
| 8 | Spindle at-speed | ✅ **Solved by the Modbus decision** — read actual output frequency from `0220H` and compare against commanded. Real feedback rather than a relay to trust. See [VFD-H100.md](VFD-H100.md). |
| 9 | VFD make/model | ✅ **IDENTIFIED 2026-09-05: Huanyang H100-1.5C2-1B**, 1.5 kW, 1PH 110 V in, 3PH 0-110 V 0-1000 Hz out. Has `485+`/`485-` ⇒ **Modbus RTU via `mb2hal`** (ships with LinuxCNC, no new deps). Full parameter and register map in **[VFD-H100.md](VFD-H100.md)**. 🚨 Not `hy_vfd` — that is the HY series. 🚨 `F165=3` is **8N1**, not the 8E1 the forums claim. 🚨 Never poll-write `F` parameters: EEPROM wear. ⚠️ Confirm the spindle is 110 V — this drive does not voltage-double. |
| 10 | Probe / toolsetter | ✅ **Toolsetter WIRED AND VERIFIED 2026-09-06** on `STOP3`/`PG_11` → `remora.input.03`: FALSE at rest, TRUE on contact, no invert. `net probe-in` now live in `milo.hal`. ⚠️ A touch probe added later must **share** `motion.probe-input` — OR'd in HAL or physically switched. |
| 11 | RT flavour | ✅ **CLOSED 2026-09-06 by measurement.** `cyclictest` 60 s, RT prio 80, all 4 cores: **max 11 µs**, avg 2 µs. Servo period is 1 ms and `BASE_PERIOD = 0`, so the margin is **~90×**. The "Using POSIX non-realtime" message is a *detection* artefact, not a performance problem. |

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

## ✅ MOTION VALIDATED (2026-09-06)

First real motion on the LinuxCNC/Remora stack.

| Check | Result |
|---|---|
| All three axes move | ✅ |
| Direction | ✅ correct after negating `SCALE` |
| Commanded 10 mm → measured | ✅ **≈10 mm** |

📌 **Why the 10 mm check settles the microstepping question.** A jumper/UART mismatch is never
subtle — 16 microsteps against a `SCALE` written for 8 gives a clean factor-of-two error (5 mm or
20 mm), not a near miss. Landing on ≈10 mm confirms the drivers are genuinely at the **8
microsteps** the TMC UART config set, and that `SCALE = 200/200/400` is correct.

That is now **three independent agreements**: RRF's `M92 X800 Y800 Z1600` at 32 microsteps
converts to exactly 200/200/400 at 8; the config says the same; and the machine measures it.

⏭ Next: homing. Note `HOME_SEQUENCE` puts **Z first** (Z=0, X=Y=1), which is the safe order —
Z retracts upward away from the table before X and Y move.
⚠️ **Until homing succeeds, JOGGING has no travel protection**: endstops are netted to
`joint.N.home-sw-in` only, not to limit pins, so they do **not** stop a jog; and soft limits do
not apply to an unhomed machine.
✅ **But LinuxCNC refuses MDI and AUTO on an unhomed machine** (`NO_FORCE_HOMING` deliberately not
set), so a *program* cannot be driven into a hard stop. **The exposure is manual jogging only** —
see the correction at the end of this file.

## ✅ HOMING WORKS — soft limits now active (2026-09-06)

All three axes home smoothly after the search-speed reduction.

| Joint | Landed at | `HOME` | Drift over 30 s |
|---|---|---|---|
| X | −0.01 | 0.0 | **0.000000 mm** |
| Y | 208.01 | 208.0 | **0.000000 mm** |
| Z | −0.01 | 0.0 | **0.000000 mm** |

The 0.01 mm is latch residual — two steps at 200 steps/mm, i.e. inside the machine's resolution.
Zero drift includes **Z under gravity**, which was the one worth checking: a vertical axis that
sags at standstill would show up here and does not.

🎉 **Soft limits are live from this point.** Before homing, *jogging* had no travel protection —
endstops are netted to `joint.N.home-sw-in` only, not limit pins, so they never stopped a jog, and
`[AXIS_*]` limits do not apply to an unhomed machine. ⚠️ **That returns every power-on until
homing completes** — but it only ever applied to jogging: LinuxCNC blocks MDI and AUTO entirely
until homed, so a program was never at risk. See the correction at the end of this file.

### What made homing work
1. **Search speeds cut to ~30% of each joint's `MAX_VELOCITY`** (was 30.0 across the board, an
   RRF `F1800` figure measured on the CDYv3 at 32 microsteps). Z was the worst case at 90% of its
   own ceiling and was the one that stalled.
2. **`remora.joint.N.deadband` set to 1.5 steps**, stopping the stepgen hunting that had all
   three motors dithering ±1 step at standstill.

## ⚠️ CORRECTION — the unhomed hazard is narrower than stated above (2026-09-06)

Earlier passages in this file say an unhomed machine has "no travel protection at all". **That
overstates it**, and the overstatement is mine. `NO_FORCE_HOMING` is deliberately **not** set, so
LinuxCNC refuses MDI and AUTO until every joint is homed — discovered when `M3 S6000` was rejected
until homing was done.

So the accurate picture:

| Unhomed | |
|---|---|
| **Jogging** | ⚠️ **no protection** — endstops are `home-sw-in` only, never limit pins, so they do not stop a jog; soft limits need a homed machine |
| **MDI / AUTO** | ✅ **blocked entirely by LinuxCNC** — a program cannot be run, so it cannot be driven into a hard stop |

⇒ **The real exposure is manual jogging on a freshly powered machine, and nothing else.**

🚨 **Do NOT set `NO_FORCE_HOMING = 1`.** It would remove the one interlock that makes the above
true, in exchange for convenience that is worth nothing here. Leaving it unset is what confines
the hazard to jogging.

## 🌡 Cooling — the Pi needs a fan (2026-09-06)

Found running at **73–74 °C** with **no cooling device present** (`/sys/class/thermal/` listed a
single zone and nothing else). All four sticky throttle flags were set — `0xf0000` = under-voltage,
frequency capping, throttling **and** the soft temperature limit had each occurred during a 4½-hour
uptime.

**This matters more here than on a desktop.** Thermal throttling varies the CPU clock, and a
varying clock is exactly what destroys realtime determinism on a machine servicing a 1 kHz servo
thread while cutting.

A fan was fitted, powered from one of the Octopus's always-on fan ports:

| | Before | After |
|---|---|---|
| Temperature | 73–74 °C | **42–44 °C** |
| Headroom to the 80 °C soft limit | 6 °C | **37 °C** |

⚠️ **The fan runs only while the Octopus is powered.** The Pi routinely runs with the Octopus off —
config work, LinuxCNC before the machine is energised, everything done over ssh. In that window
there is no cooling. The Pi 5 has its own 4-pin fan header (`cooling_fan` **is** present in the
device tree, nothing attached), which is firmware-managed by temperature and gives tacho feedback;
moving the fan there later removes the coupling entirely.

🚨 **Run the loaded latency test only after a reboot with the fan running.** The sticky throttle
flags clear only on reboot, and a latency test taken while thermally throttling measures the
cooling rather than the kernel — which would send the still-open RT-flavour question down a false
trail.

⚠️ Also noticed: a **web browser was running on the controller** (`x-www-browser` plus an isolated
content process). That is the largest avoidable background load on a machine that should be doing
one job — and the same failure class as the Chromium leak that wedged the dashboard panel.

## ✅ RT LATENCY — measured, and the question is closed (2026-09-06)

`cyclictest -m -S -p 80 -i 1000 -D 60` on the RT kernel, fan fitted, after a reboot:

| Core | Min | Avg | **Max** |
|---|---|---|---|
| 0 | 1 µs | 2 µs | **11 µs** |
| 1 | 1 µs | 2 µs | 10 µs |
| 2 | 1 µs | 2 µs | 8 µs |
| 3 | 1 µs | 2 µs | 10 µs |

**Conditions were verified either side and did not move** — `throttled` identical before and
after, temp steady at 40 °C, rail 5.14 V. That check is not optional: under-voltage and thermal
throttling both work by varying the CPU clock, which is exactly what this test measures. A run
where the flags change measures the power supply or the cooling, not the kernel.

### Why 11 µs is comfortable here

`SERVO_PERIOD = 1000000` (1 ms), and **`BASE_PERIOD = 0`** — Remora generates steps on the STM32,
so **the Pi has no base thread at all**. Worst-case latency is therefore **1.1 % of the only
realtime period this machine has. Margin ≈ 90×.**

📌 **That margin is architectural, not luck.** A conventional LinuxCNC PC runs a base thread at
25–50 kHz — a 20–40 µs period, where 11 µs of jitter would be marginal to bad. Offloading stepgen
to Remora removes that thread entirely, which is what makes a Pi viable as a controller.

🚨 **So "Using POSIX non-realtime" can be ignored.** It is the `/sys/kernel/realtime` detection gap
described above — the kernel *is* PREEMPT_RT and performs like it. Do not go patching or
rebuilding kernels over that message.

⚠️ **Caveat: this run was unloaded** — no cutting, no heavy GUI. Worth re-running during real
machining. Given ~90× margin, even an order-of-magnitude degradation stays comfortable, but the
number to watch is `max`, not `avg`.
🚨 **`stress-ng` was NOT used** and remains prohibited on this Pi — an earlier session crashed the
machine with it (all four cores loaded, dropped off the network). That was during the brownout era
and cooling is now fixed, but retesting it should be a deliberate decision, not a side effect.

## 🚨 E-stop won't clear = the Octopus is wedged in WDRESET (2026-09-06)

**Symptom.** LinuxCNC refuses to come out of E-stop. Pressing F1 or clicking the button does
nothing — it flips and immediately flips back.

**That is correct behaviour, not a bug.** `milo.hal:59` wires

```
net remora-status  remora.SPI-status => iocontrol.0.emc-enable-in
```

so if Remora cannot talk to the Octopus, LinuxCNC re-asserts E-stop the instant you clear it.
It will not enable a machine it has no control over. Treat "E-stop won't clear" as
**"the SPI link is down"** and go diagnose the link, not the GUI.

### Diagnosing it

The single most useful check costs nothing:

```
halcmd show pin remora | grep SPI-
```

`SPI-enable TRUE`, `SPI-reset FALSE`, `SPI-status FALSE` is the signature.

Then, with LinuxCNC **stopped**, look at whether anything holds the SPI device:

```
sudo ls -l /proc/*/fd 2>/dev/null | grep spidev
```

⚠️ **Nothing holding `/dev/spidev0.0` is NOT proof of a fault.** `remora-spi` does not open the
device until it sees a **rising edge on `remora.SPI-reset`**, which only arrives when you clear
E-stop. Before that first pulse the fd legitimately does not exist. This is the same trap that
made the original "link is down" test wrong (see the 2026-09-05 section above).

### Telling a wedged board apart from a loose wire

Watch the Octopus's own serial console on `/dev/ttyAMA0` while running `spi-link-test.sh`. A
board in WDRESET says:

```
Reset SPI now
Communication data error
```

That is the board **acknowledging the reset command but rejecting the data packet after it** —
so the link is half-alive, which looks alarmingly like a marginal wire. It is not.

**The discriminator is a clock sweep.** Run `spi-freq-sweep.sh`:

| Result | Meaning |
|---|---|
| Fails identically at 500 kHz **and** 4 MHz | Protocol/state problem — the board is wedged |
| Works at 500 kHz, fails at 2–4 MHz | Signal integrity — loose wire, poor ground, long runs |

On 2026-09-06 it failed identically across the whole sweep, which ruled out the wiring
immediately — worth having, given three physical wire faults in the preceding two days.

### The fix

Hardware-reset the board (**Pi GPIO25 → Octopus PC_15**, active low) with `octopus-reset.sh`,
which pulses the line and then prints and grades the boot banner. A healthy board reports:

```
Json config file lenght = 2264
Config deserialisation - Deserialization succeeded
Testing connection to TMC driver...OK     (×3)
## Entering START state
```

Then restart LinuxCNC and clear E-stop normally.

### This is not a recurring tax

Verified the same day: after a **clean** LinuxCNC exit the board sits in `IDLE`, and the next
SPI reset pulse walks it `IDLE → RESET → RUNNING` with no hardware reset needed. Two
consecutive link tests passed back-to-back. Only an **abnormal** stop — LinuxCNC killed, a
crash, control-box power pulled — leaves it in WDRESET. The 2026-09-06 wedge followed an
earlier power interruption.

**So if you find yourself running `octopus-reset.sh` regularly, do not treat it as routine —
suspect power.**

### 🚫 Do not "fix" this by netting PRU-reset to the E-stop chain

`remora.PRU-reset` is an **IN** pin on the component and `milo.hal` deliberately leaves it
unnetted, which is why LinuxCNC has no software path to reset the board. The obvious repair —

```
net pru-reset iocontrol.0.user-request-enable => remora.PRU-reset   # DON'T
```

— makes things worse. The board takes **~3 seconds** to boot and re-initialise the three
TMC2209 drivers (the boot banner shows each one being probed), which is far longer than
LinuxCNC waits for `emc-enable-in` after clearing E-stop. Every single E-stop clear would then
fail once and need a second press. Keep the reset manual and out of the safety chain.
