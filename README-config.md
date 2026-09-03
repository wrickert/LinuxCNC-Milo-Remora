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
| Accelerations, max feeds | Driver current settings (`M906`) — depends on Octopus driver modules |
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

**The alternative, if you want 16:** recompile the Remora firmware with a higher `PRU_BASEFREQ`
in `configuration.h` (the STM32F4 has headroom above 40 kHz), and pass the matching
`PRU_base_freq` to `loadrt remora-spi`. **Both must agree** — the HAL parameter only tells the
component what the firmware is doing; it does not configure the firmware. Not worth it unless
something else forces 16.

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

## Still open

- **`TODO(pins)`** throughout `milo.hal` — endstops, spindle PWM + enable, probe,
  toolsetter. These must be read off the real Octopus wiring.
- **Which driver modules are in the Octopus**, and standalone vs UART. RRF asked for
  1800 mA on X/Y (`M906 X1800 Y1800 Z1200`), which is at the top of a TMC2209's usable
  range. If the Octopus has TMC2209s, verify that current is actually being set and
  that the drivers aren't thermally throttling; if it has TMC5160s, it's a non-issue.
- **Motor directions.** All three were reversed under RRF, but relative to CDYv3
  wiring. Expect to negate one or more `SCALE` values. Flip the sign in the INI —
  don't rewire.
- **Whether the Octopus is even flashed with Remora yet.** Unknown as of 2026-09-03.

## First power-on order

1. Motors unpowered. Start LinuxCNC, open halshow, press each endstop by hand and
   confirm the right pin changes state and in the right direction.
2. Still unpowered: jog each axis in the GUI and confirm commanded position moves
   the way you expect.
3. Power one axis. Jog 10 mm. Measure it with calipers. `SCALE` is wrong if it isn't
   10 mm — and it will be wrong by an exact ratio, which tells you the microstep
   mismatch immediately.
4. Only then home an axis, and keep a hand on the e-stop the first time.
