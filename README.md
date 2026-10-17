# coolmac

Your own clean-room fan control for Apple Silicon Macs — built from the
publicly documented AppleSMC interface, not from any proprietary app.

**Your machine (probed 2026-10-17):** MacBook Pro, Apple M5 Pro, 2 fans.

## What the probe found

```
swift run coolmac-probe   # read-only, never writes to the SMC
```

- Fans: `FNum=2`, `F0/F1`: min 1,350 rpm, max ~5,349 / 5,777 rpm
  (`F*Ac` actual, `F*Tg` target, `F*md` mode: 0 = auto, 1 = manual)
- CPU temperature: `Tp*` keys (P-cores, hottest ≈ 44 °C at probe time)
- 3,626 SMC keys total

## Run

```
swift run coolmac          # menu-bar app: "44°C  5361 rpm"
swift run coolmac-probe    # dump fan + temperature keys
```

Modes: **Automatic (system)**, **Dynamic curve** (default — fan % is
interpolated from CPU temp: 40 °C→0 %, 55 °C→25 %, 70 °C→50 %,
85 °C→75 %, 95 °C→100 %), **Manual** (fixed %).

## Known limits / next steps

1. **Fan writes need root.** Reading works as a normal user; writing
   `F*Tg`/`F*md` requires a privileged helper (like every fan app).
   Until that helper exists, coolmac reports "writes denied" in its
   menu instead of pretending. Next: an `SMAppService` helper.
2. **Quit Macs Fan Control first** if it's running — two controllers
   writing the same keys will fight (at probe time it was holding
   both fans near max).
3. No full Xcode on this machine (Command Line Tools only), so this is
   a SwiftPM executable for now; packaging as a signed `.app` needs Xcode.
