# Changelog

All notable changes to CoolMac are documented here.

## [Unreleased]

### Added
- Editable curve points: drag the chart dots or use per-point
  temperature/percent steppers; persisted in UserDefaults
  (`curvePoints`), live-applied, with a "Reset curve" action.
- Presets: Silent and Balanced apply persisted curves in Curve mode,
  Full blast switches to Manual 100%; the active preset is highlighted
  and persisted (`activePreset`) until the curve/sliders are edited.
- Per-fan control: "Link fans" toggle (default on). Unlinked Manual
  mode shows independent Fan 1 / Fan 2 sliders (persisted as
  `manualFanPercents`); Curve mode shares one curve across both fans.
- Helper protocol: new `SET2 <p1> [<p2> …]` per-fan command with
  per-fan dedupe. `SET`/`AUTO` unchanged; the app falls back to `SET`
  (max percent) when an old helper returns `ERR` for `SET2`.
- Launch at login via a per-user LaunchAgent
  (`com.github.d4vz.coolmac`), toggled from the popover footer and
  only enabled when running from the app bundle.

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
