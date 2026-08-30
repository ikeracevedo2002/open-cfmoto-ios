# OpenCfMoto 2.0.18-pre (76)

Soak pre for the next Latest line. **2.0.13 stays Latest** until this soaks. X-Cape 1200 stills stay
on **2.0.14-pre** only — they are **not** in this build.

Clock lab defaults match Latest 2.0.13: empty `0x10451`, echo `0x10600`. Filled query is opt-in in
Setup, not the default.

## What’s in this cut

- **Mirror orientation** — Match dash (from 2.0.15-pre)
- **Clock lab** — one Setup card for every clock experiment: query / time-sync / Bluetooth listen (ZT + EC-BTP LE→AUTO) / stay-on-bike-Wi‑Fi. Defaults match Latest 2.0.13 (empty `0x10451`, echo `0x10600`, BLE off)
- **P2P keep-alive** (PR #21), **AA bind-defer**, **map lap timer** (2.0.17-pre)
- **Bluetooth remote pad** — pair a gamepad / ring / keypad; HID keys stand in for handlebar gestures
  (AVRCP remotes already work when Control AA is on)
- **Android Auto text size (DPI)** — Auto / 160 / 180 / 240 / 320
- **Connect when a Bluetooth device joins** — optional helmet remote / watch trigger
- **Bulgarian** strings (draft)
- Vehicle-telemetry field notes (`docs/RE-VEHICLE-TELEMETRY.md`)
- Telemetry no longer uploads the AA 17.4 “Start head unit server” banner as an error

Not in this cut: X-Cape 1200 stills, filled `{time,dateTime}` on every channel, Cockpit/Overtake,
speed-based volume.

## Thanks

- **Glifaus** — PR #21 Wi‑Fi Direct keep-alive
- **diesersinger** — lap timer idea
- **mgb1982** — clock lab / Zontes HCI
- **sashop2001** — DPI, Bluetooth trigger, Bulgarian (`APOpenCfMoto`)
- **sr.chacho** — remote pad idea (`#ideas`)
- **Authoritt** — PR #29 vehicle telemetry docs
- **Martin Escudero** — AA 17.4 head-unit server (already in 2.0.13)
- **joyfulyak** — bind-defer field log
- **ionutradu252** — original handlebar bridge
