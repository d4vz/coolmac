# Changelog

All notable changes to CoolMac are documented here.

## [0.1.0] — 2026-10-17

First public release.

### Added
- SwiftUI menu-bar app: CPU temperature ring, per-fan RPM gauges,
  Auto / Curve / Manual modes, 0–100% slider with RPM equivalent,
  live dynamic-curve chart.
- Dynamic fan curve: fan % interpolated from hottest P-core temperature
  (40 °C → 0%, 55 °C → 25%, 70 °C → 50%, 85 °C → 75%, 95 °C → 100%).
- `coolmac-helper`: privileged root daemon (LaunchDaemon) that owns all
  SMC fan writes over a Unix socket, restricted to root + the console
  user, with a 15-second watchdog that reverts fans to system Auto.
- `coolmac-probe`: read-only CLI enumerating AppleSMC fan/temperature keys.
- `scripts/build-app.sh`: builds `dist/CoolMac.app` (ad-hoc signed,
  generated icon) with the SwiftPM toolchain only — no Xcode required.
- Verified end-to-end on MacBook Pro with Apple M5 Pro (2 fans).
