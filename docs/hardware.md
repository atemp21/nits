# Hardware findings

Record what the probe actually reports, per cable. This file is the source of truth
for what works, and exists because Apple Silicon DDC support varies by port.

## Machine

- MacBook Pro (MacBookPro18,1), Apple M1 Pro
- macOS 26.6.2 (Darwin 25.6.0), arm64

## Private API availability

Verified present on macOS 26.6.2:

| Symbol | Framework | Used for |
| --- | --- | --- |
| `IOAVServiceCreateWithService` | IOKit | obtaining the I2C transport |
| `IOAVServiceWriteI2C` / `IOAVServiceReadI2C` | IOKit | DDC/CI transactions |
| `DisplayServicesGetBrightness` / `SetBrightness` | DisplayServices | built-in panel |
| `DisplayServicesCanChangeBrightness` | DisplayServices | capability check |

With no external display attached, the IORegistry shows 2 `DCPAVServiceProxy` nodes,
the internal panel's being tagged `Location = "Embedded"`.

## Cable matrix

Fill in by running `make probe` with the monitor on each port. HDMI is the least
reliable DDC path on Apple Silicon; if only USB-C works, that is a documented
requirement rather than a bug.

| Connection | External AV service? | VCP 0x10 read | 0x10 write | 0x62 volume | Audio device settable |
| --- | --- | --- | --- | --- | --- |
| USB-C / DisplayPort | ? | ? | ? | ? | ? |
| HDMI | ? | ? | ? | ? | ? |

## Volume path

Decided by `make probe`:

- Monitor speakers listed with `settableVolume=true` → use CoreAudio (preferred:
  public API, instant, accurate state).
- Listed with `settableVolume=false`, or absent → the panel owns the level, so drive
  DDC VCP `0x62` instead.
