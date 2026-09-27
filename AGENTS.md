# Working on nits

## Build and verify

```sh
make build && make test   # must both pass before any commit
make probe                # read-only hardware diagnostics
```

`make test` needs no monitor, no private API and no permissions — the DDC framing is
deliberately split into a pure `DDCCodec` so it stays testable. Keep it that way: any
new wire-format logic goes in the codec with tests, not inline in `DDCChannel`.

## Hard rules

1. **All undeclared Apple symbols go in `Sources/NitsCore/PrivateAPI.swift`.** Nowhere
   else. Resolve them with `dlsym` behind `PrivateDisplayAPI`, never by declaring an
   `@_silgen_name` or linking directly. Every caller must handle the unavailable case.
   This is why the app survives macOS upgrades.
2. **Never poll DDC.** Reads are slow and unreliable; read once on connect and keep
   optimistic local state. Writes are coalesced on a ~25ms debounce. Samsung panels
   stall when I2C is hammered, and that is most of why competing apps feel laggy.
3. **Choose the volume path per device, by capability.** Use CoreAudio when
   `AudioDevice.hasSettableVolume` is true, otherwise DDC VCP `0x62` and mute `0x8D`.
   Never hardcode one path: the C34J79x reports `settableVolume=false`, so it is
   DDC-only, while the built-in speakers are CoreAudio. See `docs/hardware.md`.
4. **Never key preferences on `CGDirectDisplayID`.** It is not stable across reconnect.
   Use `DisplayIdentity.key`.
5. **The app must launch without Accessibility permission**, degrading to sliders only.

## Hardware caveats

- HDMI is the least reliable DDC path on Apple Silicon. Record per-cable results in
  `docs/hardware.md` rather than assuming.
- Some Samsung EDIDs omit a usable serial number, so display identity must tolerate a
  missing serial.
- The app cannot be sandboxed (private APIs + IORegistry), which rules out the Mac App
  Store permanently.

## Style

Match the existing files: doc comments explain *why* a non-obvious choice was made,
not what the line does. No comment where the code is already clear.
