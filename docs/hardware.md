# Hardware findings

Record what the probe actually reports, per cable. This file is the source of truth
for what works, and exists because Apple Silicon DDC support varies by port.

## Machine

- MacBook Pro (MacBookPro18,1), Apple M1 Pro
- macOS 26.6.2 (Darwin 25.6.0), arm64

## Display

Samsung C34J79x (CJ79 34" ultrawide), with built-in speakers.

| Property | Value |
| --- | --- |
| EDID product id | `0x0f1e` (3870) |
| EDID serial | 809056048 |
| Product name | `C34J79x` |
| Identity key | `19501-3870-809056048-External` |
| DCP path | `dcpext0@89C00000` → `dispext0:dcpav-service-epic:0/DCPAVServiceProxy` |

## Private API availability

Verified present on macOS 26.6.2:

| Symbol | Framework | Used for |
| --- | --- | --- |
| `IOAVServiceCreateWithService` | IOKit | obtaining the I2C transport |
| `IOAVServiceWriteI2C` / `IOAVServiceReadI2C` | IOKit | DDC/CI transactions |
| `DisplayServicesGetBrightness` / `SetBrightness` | DisplayServices | built-in panel |
| `DisplayServicesCanChangeBrightness` | DisplayServices | capability check |

Note: the *internal* panel's `DisplayAttributes.ProductAttributes.ProductID` is a
fourcc (`0x30313441`, `"A410"`), not an EDID product code. External displays report a
real EDID product id, so product-id matching works for the displays that need DDC.

## Cable matrix

| Connection | External AV service | VCP 0x10 read | 0x10 write | 0x62 volume | CoreAudio volume settable |
| --- | --- | --- | --- | --- | --- |
| USB-C / DisplayPort | yes | yes (100/100) | yes | yes (max 100) | **no** |
| HDMI | untested | untested | untested | untested | untested |

USB-C works fully. HDMI remains untested; there is no need to use it, and it is the
least reliable DDC path on Apple Silicon.

## Supported VCP codes

All confirmed by read on the C34J79x:

| Code | Feature | Current | Max |
| --- | --- | --- | --- |
| `0x10` | brightness | 100 | 100 |
| `0x12` | contrast | 75 | 100 |
| `0x62` | audio volume | 19 | 100 |
| `0x8D` | audio mute | 2 (unmuted) | 2 |

Reply frames arrive with a leading source-address byte, e.g.
`6e 88 02 00 10 00 00 64 00 64 a4 6e`. The parser locates the `0x88` length marker
rather than assuming an offset, so this needs no special-casing.

## Volume path: DDC, not CoreAudio

**The monitor's CoreAudio device reports `settableVolume=false` and `hasMute=false`,
and its volume is unreadable.** It enumerates as a DisplayPort output device and
audio plays through it, but the panel owns the level entirely.

So volume must go over DDC VCP `0x62`, with mute on `0x8D`. This is the opposite of
the original plan's preferred path, and it raises the value of the app: with this
monitor as the default output, the Mac's own volume keys have nothing to control, so
translating them to DDC is the whole point rather than a nicety.

## Timing

Measured over USB-C. The I2C call itself is only ~3.6ms; the inter-message delay
dominates, so it is configurable on `DDCChannel`.

| Added delay | 60 writes | per write | All landed | Panel responsive after |
| --- | --- | --- | --- | --- |
| 0ms | 215ms | 3.6ms | yes, 0 errors | yes |
| 4ms | 508ms | 8.5ms | yes, 0 errors | yes |
| 40ms (VESA spec) | ~2.8s | 46.6ms | yes | yes |

A single read costs ~110ms at the spec delay, which is why reads happen once on
connect and never in a loop.

This panel tolerates zero added delay under a sustained 60-write burst. The default
is nevertheless **8ms**, for margin on less robust panels while staying inside one
frame. Write coalescing stays in the design regardless, to bound queue growth.

## Permissions

Two permissions matter, and **neither can be granted programmatically** — they live in
the SIP-protected TCC database, and `tccutil` can only reset, never grant.

| Permission | Needed for | Without it |
| --- | --- | --- |
| Accessibility | the media-key event tap | sliders still work; keys are not intercepted |
| Screen Recording | `screencapture` of the real UI | offscreen renders still work (`make shots`) |

Accessibility is granted to **nits.app**; Screen Recording, for development
screenshots, is granted to the terminal (Warp) rather than to nits.

The app prompts for Accessibility on first launch and then polls, so the tap starts
the moment it is granted without needing a relaunch.

## Offscreen rendering

`make shots` renders the UI without any permission. `ImageRenderer` cannot draw
AppKit-backed controls, so SwiftUI's `Slider` appears as a placeholder in the panel
shot; layout, text, symbols and state are faithful. Two alternatives were tried and
are worse: `cacheDisplay` draws the controls but loses the SwiftUI text layers, and
`CALayer.render(in:)` comes out blank because SwiftUI has no layer contents until it
draws on screen.

Practical consequence: **design new UI in pure SwiftUI shapes and it renders in full.**
The HUD does, and is fully reviewable offscreen.
