# Contributing to CoolMac

Thanks for stopping by! 🎉

## Development setup

You only need the Xcode Command Line Tools (`xcode-select --install`) —
no full Xcode required.

```bash
git clone https://github.com/d4vz/coolmac.git
cd coolmac
swift build                 # builds app, helper, and probe
swift run coolmac-probe     # read-only dump of your machine's SMC keys
swift run coolmac --window  # run the UI in a window
```

## Most wanted contributions

1. **`coolmac-probe` output from untested machines.** Run the probe and
   paste the output into a new issue with your model/chip. That tells us
   which SMC keys your Mac exposes without anyone guessing.
2. **Bug reports** — please include macOS version, chip, and whether
   another fan-control app was running.
3. **Code** — curve editor, presets, per-fan control, packaging.

## Rules of the road

- Never write fan speeds outside a fan's `F*Mn`–`F*Mx` range, and always
  leave a path back to system Auto (mode `0`). The helper watchdog
  (15 s of silence → Auto) must keep working.
- Probe first, write second: any new SMC write path needs a read-only
  way to see what it did (`coolmac-probe`, helper `STATUS`).
- Keep it clean-room: CoolMac is built from publicly documented SMC
  interfaces. Don't contribute code copied from proprietary apps.

## Pull requests

Small, focused PRs with before/after proof (probe output, screenshots,
or fan RPM readings) are ideal.
