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

## ⚠️ Microstepping: drop 32 → 16

RRF ran `M350 X32 Y32 Z32` with `M92 X800 Y800 Z1600`. Carried over literally, the
required step rate at full rapid is:

```
X: 66.667 mm/s × 800 steps/mm = 53,333 steps/s
Z: 33.333 mm/s × 1600 steps/mm = 53,333 steps/s
```

**~53 kHz on two axes simultaneously.** Remora's stepgen runs at a configurable base
frequency on the STM32, and the step rate cannot exceed it. A default in the 40 kHz
region — common for Remora — would silently cap rapids at roughly 50 mm/s on X/Y and
25 mm/s on Z, i.e. below the machine's real capability, and the symptom is "it just
won't go as fast as it used to" rather than an error.

Dropping to 16 microsteps halves it:

```
X: 66.667 mm/s × 400 steps/mm = 26,667 steps/s
Z: 33.333 mm/s × 800 steps/mm = 26,667 steps/s
```

Comfortable, with headroom. 32 microsteps buys nothing real on a mill — the TMC's
interpolation smooths the motor regardless of the step input rate, and resolution is
already 0.0025 mm/step at 16. **`milo.ini` is written for 16 microsteps** (`SCALE`
400/400/800); the 32-microstep values are in a comment beside them.

Two things must agree with whatever is chosen:
1. `SCALE` in `milo.ini`
2. the microstep setting in the Octopus's Remora `config.json` (or the driver jumpers,
   if the modules are running standalone)

Before trusting either, check Remora's actual base frequency in its config and confirm
it clears the number above.

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
