# Handbook canvas — source

Working files for the ModelBar Handbook, published as a Claude Design canvas:
https://claude.ai/code/artifact/fce4b490-5c42-4d38-ba09-9dd1df7ed71c

Each `.dc.html` is one artboard; `canvas.json` places them and sets the
launch view. These are the *source* — the published page is generated from
them, not the other way round.

## Re-publishing after editing these files

    node "<design skill dir>/seed-canvas.mjs" \
      --template "<design skill dir>/payload.template.html" \
      --out modelbar-handbook.html --title "ModelBar Handbook" \
      --artboard Main.dc.html --artboard Proxy.dc.html --artboard Memory.dc.html \
      --artboard Manifest.dc.html --artboard CLI.dc.html --artboard Harnesses.dc.html \
      --artboard Gotchas.dc.html \
      --canvas canvas.json

Then publish `modelbar-handbook.html` to the same artifact URL.

## If the canvas is edited in the browser instead

Saving from the canvas publishes a new version, and these files go stale —
the published page becomes the newer copy. To get back in sync, read the
artifact and extract it (`seed-canvas.mjs --extract <saved page> --to <empty dir>`),
then copy the artboards back over these.

## Design vocabulary

Lifted from the app itself so the docs read as part of the product, not about it:

| Token | Value | Source |
| --- | --- | --- |
| Section header | 10px / 800 / 0.9px tracking, uppercase | `SectionHeader` (9pt heavy, 0.8 tracking) |
| Hairline rule | `rgba(0,0,0,0.08)` | `Rectangle().fill(Color.primary.opacity(0.08))` |
| Meter | 6px capsule on `rgba(0,0,0,0.13)` | `Meter` |
| Green / orange / red | `#34c759` / `#ff9500` / `#ff3b30` | `Level.color` — <70%, 70–90%, 90%+ |
| Blue (unmanaged) | `#007aff` | `StatusDot.Kind.unmanaged` |
| Numbers | tabular-nums | `.monospacedDigit()` |

Keep these in step with `Sources/ModelBar/MonitorViews.swift` if the app's
own tokens change.
