# App icon

`icon.png` and `AppIcon.icns` are generated, not hand-drawn. To
regenerate after changing the mark:

```
tools/make-icon.sh [preview-dir]
```

It compiles `Menfez/Sources/MenfezCore/LogoMark.swift` together with
`tools/icon/main.swift`, renders every iconset slice at its exact size (16 px to
512 px @2x, no downsampling), and runs `iconutil`. Pass a directory to keep the
iconset and the menu-bar previews. Output is deterministic; commit both files.

`build-app.sh` copies `AppIcon.icns` into the bundle (falling back to `sips` on
`icon.png` only if the `.icns` is missing).

## The mark

Tunnel path. Three nested graphite arch rings recede into depth around a
glowing teal doorway; a teal path runs out of the doorway, widening in
perspective to the foot of the tile, and a small teal light sits above the
arches. A way through, which is what the app opens. Pure CoreGraphics vectors
in `LogoMark.appIcon`. The 16 and 32 px slices use a simpler figure on a
16-unit grid: one light arch ring, a bold teal doorway and a short path, no
light above (it would touch the ring).

The menu bar draws its own template image on a 22-unit grid (`LogoMark.draw`).
Every mode shares the same arch (x 5–17, top 7, legs to 17). It has no colour,
so it shows the mode by figure:

| Mode | Figure |
|---|---|
| Doğrudan / Direct | the doorway closed: a solid arch, no path |
| DPI | the doorway open (hollow arch) and a short perspective path into it |
| Tünel / Tunnel | the same, plus a solid dot above the arch, 2 units clear |

## Palette

No blue.

| Role | Value |
|---|---|
| Tile | `#262A2E` to `#1E2124` |
| Outer ring | `#36393F` to `#2C2F35` |
| Middle ring | `#21292C` |
| Inner ring | `#1A2327`, lit faintly teal from the door |
| Floor | `#262D31` |
| Doorway | `#5DD3BC` to `#55CDB6`, soft glow |
| Path | `#4CBBA6` at the door, darkening to `#2A6D66` |
| Light above | `#52C2AC` |
| Rim | white at 8 % |

## Silhouette

824 px body on a 1024 canvas with a 22.5 % corner radius and a soft drop shadow,
the macOS app-icon grid.
