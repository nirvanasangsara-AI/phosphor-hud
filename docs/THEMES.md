# Themes

Every Phosphor theme — including the five built-ins — is a JSON file with the schema below.
Drop yours in `~/.config/phosphor/themes/*.json`. They show up in the **Theme** menu the next time
you open it; no restart needed. Problems (bad JSON, unknown values) are listed at the bottom of that
menu with the file and the field.

To start from a built-in:

```bash
dist/Phosphor.app/Contents/MacOS/Phosphor --export-themes ~/.config/phosphor/themes/built-in
cp ~/.config/phosphor/themes/built-in/retro.json ~/.config/phosphor/themes/my-retro.json
```

Only top-level files in `themes/` are loaded, so the exported `built-in/` folder is just reference.
Or skip copying entirely and inherit: a theme only has to list what it changes.

```json
{
  "id": "synthwave",
  "name": "Synthwave",
  "extends": "retro",
  "font": "rounded",
  "bar": "capsule",
  "colors": { "fg": "#FF5CF0", "dim": "#7FE7FFB3", "track": "#FF5CF026", "danger": "#FFE45C" },
  "backdrop": { "type": "solid", "color": "#1A0B2E" },
  "effects": { "scanlines": false, "cursor": false }
}
```

(Full file: [`examples/themes/synthwave.json`](../examples/themes/synthwave.json).)

## Resolution

1. Start from **Clean** (it defines every key).
2. Merge the theme named in `extends`, if any.
3. Merge this file.

Merging is per key, and nested objects (`colors`, `effects`, `backdrop`) merge key by key too, so
`"effects": { "rain": true }` turns rain on without touching the other effects. A user file with the
same `id` as a built-in replaces it.

## Fields

| Key | Type | Values / meaning |
|---|---|---|
| `id` | string | Unique id, stored in preferences. Defaults to the file name. |
| `name` | string | Shown in the Theme menu. Defaults to `id`. |
| `extends` | string | Id of a theme to inherit from (built-in or yours). |
| `layout` | string | `list` (one row per window) or `raid` (MMO party frames). |
| `font` | string | `default`, `rounded`, `monospaced`, `serif` (system font designs). |
| `bar` | string | `capsule`, `blocks` (`████░░░`), `segments`, `hairline`, `health`. |
| `monochrome` | bool | `true` paints every provider in `colors.fg` instead of its brand colour. |
| `uppercase` | bool | Upper-case names, labels and status text. |
| `corner` | number | Panel corner radius, pt. |
| `borderWidth` | number | Panel border width, pt (border colour is `colors.border`). |
| `width` | number | Panel width in list layout, pt. |
| `compactWidth` | number | Panel width in compact mode, pt. |
| `header` | string | Header text. `{online}` → number of providers shown, `{version}` → app version. |
| `prompt` | string / null | Prefix before provider names, e.g. `"C:\\>"` or `">"`. |

### `colors`

Hex `#RRGGBB` or `#RRGGBBAA`.

| Key | Used for |
|---|---|
| `fg` | Main text; every bar when `monochrome`. |
| `dim` | Labels, countdowns, secondary text. |
| `track` | Empty part of bars. |
| `danger` | Windows at 90 %+. |
| `warn` | Forecast says you'll hit the limit before the reset. Defaults to `danger`. |
| `border` | Panel outline; `null` for none. |
| `hpHigh`, `hpMid`, `hpLow` | Raid Frames HP bar at >50 %, >20 %, ≤20 % left. |
| `mana` | Raid Frames second bar (the provider's second window). |

### `backdrop`

| Key | Meaning |
|---|---|
| `type` | `material` (macOS HUD blur), `solid`, or `clear` (black at `opacity`). |
| `color` | For `solid`. |
| `opacity` | For `clear`: black at this opacity. For `material`: a dark shade over the blur, so text stays readable over bright windows (Clean uses 0.65). 0–1. |

### `effects`

| Key | Type | Meaning |
|---|---|---|
| `glow` | bool | Soft phosphor glow around text and bars, in `fg`. |
| `glowRadius` | number | Glow blur radius, pt. |
| `scanlines` | bool | CRT scanlines. |
| `vignette` | bool | Darkened edges. |
| `rain` | bool | Katakana rain behind the content. |
| `cursor` | bool | Blinking block cursor after the header. |
