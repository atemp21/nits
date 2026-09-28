# TODO

Open items for nits. Things that are done live in the README roadmap; this file is
only what is still outstanding.

## Hardware coverage

- [ ] **Test DDC over HDMI** and fill in the cable matrix in `docs/hardware.md`.
      HDMI is the least reliable DDC path on Apple Silicon.
- [ ] **Test other monitors.** Everything so far is verified on one Samsung C34J79x.
- [ ] **Test with the monitor as the only display** (laptop lid closed). Routing falls
      back to the single candidate, but it has never been exercised.
- [ ] **Test a real sleep/wake and replug cycle.** The code paths exist and are
      delayed appropriately, but have only been reasoned about, not observed.

## Deferred features

Left out of v1 deliberately, with seams already in place.

- [ ] **Sub-hardware-minimum software dimming.** A gamma or overlay dimming layer that
      continues below the panel's own minimum, and smooths DDC's coarse integer steps.
      This was the single largest precision win over MonitorControl and is the answer
      if brightness 0 still is not dark enough at night.
- [ ] **Input source switching** (VCP `0x60`). Confirmed readable on the C34J79x.
      Useful for flipping the monitor between the Mac and another machine.
- [ ] **Named presets** per display, optionally auto-applied on connect.

## Binary releases

Source builds work today. Shipping a downloadable app needs:

- [ ] **Developer ID signing and notarisation**, so Gatekeeper accepts it.
      Requires enabling hardened runtime in `project.yml`, which is currently off, and
      swapping ad-hoc signing for a real identity.
- [ ] **App icon.** Menu-bar only today, so it has never needed one.
- [ ] A release workflow that builds, signs and attaches the app to a GitHub release.

Note: the Mac App Store is permanently out of reach. DDC needs private IOKit calls
and IORegistry access, so the app cannot be sandboxed.

## Smaller things

- [ ] The panel's sliders cannot be captured offscreen (`ImageRenderer` will not draw
      AppKit-backed controls). Only matters if UI review becomes frequent enough to be
      worth building a pure-SwiftUI slider.
- [ ] No preference for which display a key targets when the heuristic guesses wrong.
      Worth adding only if the routing actually misbehaves in daily use.
- [ ] `DisplayRegistry` falls back to match-by-elimination when a panel's EDID product
      id does not match. Fine with one external display; revisit with two.
