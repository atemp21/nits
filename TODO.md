# TODO

Open items for nits. Things that are done live in the README roadmap; this file is
only what is still outstanding.

## Blocked on a permission grant

Neither of these can be scripted — both live in the SIP-protected TCC database, and
`tccutil` can only reset permissions, never grant them.

- [ ] **Grant nits Accessibility permission**, then verify the media keys end to end.
      System Settings › Privacy & Security › Accessibility. The app prompts on launch
      and polls afterwards, so the tap starts without a relaunch.

      This is the last unverified piece of v1. The routing and HUD logic are tested,
      but no real keypress has ever been through them. Worth checking specifically:
      - F1/F2 change the Samsung's brightness when its window has focus
      - volume keys hit the Samsung, not the laptop speakers, while it is the
        default output
      - Shift+Option gives quarter steps
      - macOS does not also act on the key (no double HUD)
      - the HUD appears on the display being adjusted

- [ ] **Grant Warp Screen Recording** if real screenshots are ever wanted.
      Only needed for capturing the live UI; `make shots` renders offscreen without it.

## Hardware coverage

- [ ] **Test DDC over HDMI** and fill in the cable matrix in `docs/hardware.md`.
      USB-C works fully, so this is curiosity rather than need. HDMI is the least
      reliable DDC path on Apple Silicon.
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
- [ ] **Contrast control.** Already read and written by the core (VCP `0x12`, currently
      75 on the C34J79x); simply not surfaced in the UI.

## Release readiness

The repo is structured for release but is not releasable yet.

- [ ] **Choose a licence** and add `LICENSE`. Deliberately left as your call.
- [ ] **Developer ID signing and notarisation** for distribution outside your own Mac.
      Requires enabling hardened runtime in `project.yml`, which is currently off, and
      swapping ad-hoc signing for a real identity.
- [ ] **App icon.** Menu-bar only today, so it has never needed one.
- [ ] Decide whether to make the GitHub repo public (`gh repo edit --visibility public`).

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
