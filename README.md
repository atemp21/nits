# nits

A focused macOS menu-bar app for controlling external monitor brightness and volume,
and for making the Mac's own brightness/volume controls more precise.

Built because BetterDisplay Pro does far more than needed and MonitorControl has
degraded on recent macOS. *nit* is the unit of luminance.

## Status

**M0 complete** — core modules and the diagnostic CLI build and run. No app bundle
yet. See `docs/hardware.md` for what has been verified on real hardware.

## Why native Swift

External monitor brightness means DDC/CI over I2C, which has no public API on Apple
Silicon. It requires `IOAVServiceCreateWithService` / `IOAVServiceWriteI2C` from
IOKit, callable only in-process. Electron or Python would need a Swift helper doing
all the real work anyway, plus a runtime tax on what is a menu-bar slider. Global
media-key interception (`CGEventTap`) is likewise native-only.

## Layout

```
Sources/NitsCore/       logic, no UI, testable without hardware
  PrivateAPI.swift      the ONLY file touching undeclared symbols
  DDC.swift             VCP framing + I2C transactions
  DisplayRegistry.swift CGDisplay <-> IORegistry AV service matching
  Audio.swift           CoreAudio volume
Sources/nitsprobe/      diagnostics CLI
App/                    app bundle sources (from M3)
```

`PrivateAPI.swift` resolves every undeclared symbol with `dlsym` at runtime rather
than binding at link time, so a symbol disappearing in a future macOS degrades one
feature instead of preventing launch. That single choke point is the direct answer to
why comparable tools break across OS upgrades.

## Usage

```sh
make build   # build core + probe
make test    # unit tests, no hardware needed
make probe   # hardware diagnostics, read-only
make probe-write B=50   # writes brightness 50 over DDC
```

Run `make probe` with the monitor attached to find out whether DDC works on your
cable, and whether the monitor's speakers expose a settable CoreAudio volume.

## Roadmap

- [x] **M0** core modules, probe CLI, unit tests
- [ ] **M1** DDC brightness confirmed against the panel *(gate: proves the approach)*
- [ ] **M2** volume via CoreAudio, DDC fallback
- [ ] **M3** menu-bar UI with live sliders
- [ ] **M4** event tap, custom HUD, key routing, fine steps
- [ ] **M5** persistence, reconnect handling, launch at login

Deliberately out of scope for v1: sub-hardware-minimum software dimming,
input-source switching (VCP `0x60`), named presets. Seams are left for each.
