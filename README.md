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

## Privileged helper

Fan writes need root (verified: user-level `F*Tg` writes are denied).
`coolmac-helper` is a small root LaunchDaemon that owns all SMC writes
and talks to the app over `/var/run/coolmac.sock` (root:admin, 0660;
only root or the console user may connect).

```
scripts/install-helper.sh     # builds, prompts for admin password
scripts/uninstall-helper.sh   # reverts fans to Auto, removes helper
```

Protocol: `PING` · `AUTO` · `SET <0-100>` · `STATUS`.
**Watchdog:** if the app sends nothing for 15 s (crash/kill), the
helper reverts fans to system Auto — verified live.

Verified end-to-end on the M5 Pro: `SET 30` → fans tracked
2,549 rpm target at 2,553 rpm actual; curve mode drove fans
dynamically with temperature; quit/kill restored Auto.

## Known limits / next steps

1. **Quit Macs Fan Control first** if it's running — two controllers
   writing the same keys will fight.
2. No full Xcode on this machine (Command Line Tools only), so this is
   a SwiftPM executable for now; packaging as a signed `.app` with an
   `SMAppService` helper (no manual install script) needs Xcode.
3. Fan spin-up takes ~5–10 s; the curve polls every 2 s.
