# Glass (khwan.glass)

Milky-glass control panel for the omarchy bar: frosted window opacity, compositor
blur, rounding, and dim — sliders in the bar, live-apply while dragging.

## What it does

- **Presets — 10 styles** (see `PRESETS.md` in the project mirror for the design
  reasoning): Milky · Cloud · Frosted (light) · Smoke · Ink (dark, via blur
  brightness < 1) · Crystal (sheer) · Veil · Gauze (sheer-readable: the
  wallpaper stays clearly visible, text keeps its contrast) · Crisp (reading) ·
  Stock (removes the managed block; omarchy defaults return). The panel shows
  which preset the current look matches, or **Custom**.
- **⇅ Sync all** — one click removes every per-app rule so all windows follow
  "All apps". Undoable.
- **FROST** — global + per-app window opacity (release-apply: rewrites the
  managed block in `~/.config/hypr/looknfeel.lua` + `hyprctl reload`, which
  re-frosts open windows), add/remove per-app rows, `S` = keep-solid opt-out.
- **BLUR** — on/off, size, passes, brightness, contrast, noise (live while
  dragging via `hyprctl eval hl.config(...)`; persisted + block rewrite on
  release, no reload).
- **SHAPES** — rounded-corners switch (off = square windows, on = restore the
  last radius), rounding slider, dim-inactive + strength (live).
- **BAR** — transparent bar toggle.
- **Undo stack (session)** — every change is one Undo away; **Revert** restores
  the newest `looknfeel.lua.bak.*`.
- **Style tour** — right-click the icon applies the next favorite (Cloud →
  Smoke → Ink → Crystal → Milky) with a 10s keep-or-revert trial.
- **User presets** — "+ Save as…" snapshots the current look; saved ones appear
  as chips (✕ to delete).

## Bar icon gestures

click = panel · wheel = frost ±0.05 · right-click = style tour (10s trial) ·
middle-click = blur on/off

Panel keys: `1-9` + `0` presets (0 = Stock) · `u` undo · `r` revert

## Files

- `Glass.qml` — bar widget + panel UI
- `GlassIcon.qml` — canvas-drawn frosted-square glyph
- `Service.qml` — startup init; IPC target `khwan.glass.service`
  (get/set/preset/sync/round/savepreset/delpreset/revert)
- `WheelSafeSlider.qml` — wheel-safe slider (copied from im0001gt.screens)
- `scripts/glass-ctl` — state, Lua block generation, hyprctl apply paths, presets
- `tests/test_blockgen.py` — golden tests (run: `python3 tests/test_blockgen.py`)

## State

`~/.local/state/omarchy/glass.json` mirrors the managed block between
`-- BEGIN/END khwan.glass` markers in `~/.config/hypr/looknfeel.lua`. The Lua file
wins on panel open (hand-edits are adopted); user presets live in the state file.

## CLI

```
scripts/glass-ctl get | readback | set '<json>' | live '<json>' | frost '<json>'
                 | persist '<json>' | preset milky|cloud|frosted|smoke|ink|crystal|veil|gauze|crisp|stock|<user>
                 | savepreset '<name>' | delpreset '<name>' | sync
                 | round true|false|toggle
                 | revert | classes | bar true|false|toggle | init
```

All responses carry `state`, `active` (matched preset or null = Custom),
`user` (user preset names), and `tour`. Widget IPC:
`quickshell -p /usr/share/omarchy/shell ipc call khwan.glass open|close|toggle`
