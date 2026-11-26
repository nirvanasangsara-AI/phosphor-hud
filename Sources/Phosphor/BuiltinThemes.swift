// The built-in themes, in exactly the JSON a user theme uses (docs/THEMES.md).
// `Phosphor --export-themes <dir>` writes them out as starting points.
// Clean comes first and must be complete: every other theme inherits missing keys from it.

enum BuiltinThemes {
    static let all = [clean, retro, matrix, glasses, raid]

    static let clean = #"""
    {
      "id": "clean",
      "name": "Clean",
      "layout": "list",
      "font": "rounded",
      "bar": "capsule",
      "colors": {
        "fg": "#FFFFFF", "dim": "#FFFFFFC7", "track": "#FFFFFF26",
        "danger": "#FF453A", "warn": "#FF9F0A", "border": "#FFFFFF1F",
        "hpHigh": "#1EBE3C", "hpMid": "#E0B000", "hpLow": "#C41E3A", "mana": "#2F6FEB"
      },
      "backdrop": { "type": "material", "opacity": 0.65 },
      "effects": { "glow": false, "glowRadius": 3, "scanlines": false, "vignette": false, "rain": false, "cursor": false },
      "monochrome": false,
      "uppercase": false,
      "corner": 16,
      "borderWidth": 1,
      "width": 330,
      "compactWidth": 250,
      "header": "Usage",
      "prompt": null
    }
    """#

    static let retro = #"""
    {
      "id": "retro",
      "name": "Retro CRT · Amber",
      "font": "monospaced",
      "bar": "blocks",
      "colors": {
        "fg": "#FFB000", "dim": "#FFB0008C", "track": "#FFB00026",
        "danger": "#FF5F1F", "warn": "#FF5F1F", "border": "#FFB00059"
      },
      "backdrop": { "type": "solid", "color": "#140B00" },
      "effects": { "glow": true, "scanlines": true, "vignette": true, "cursor": true },
      "monochrome": true,
      "uppercase": true,
      "corner": 6,
      "header": "PHOSPHOR v{version}  QUOTA MONITOR",
      "prompt": "C:\\>"
    }
    """#

    static let matrix = #"""
    {
      "id": "matrix",
      "name": "Matrix",
      "font": "monospaced",
      "bar": "segments",
      "colors": {
        "fg": "#00FF41", "dim": "#00FF4180", "track": "#00FF411F",
        "danger": "#E6FFE6", "warn": "#E6FFE6", "border": "#00FF4140"
      },
      "backdrop": { "type": "solid", "color": "#000000" },
      "effects": { "glow": true, "rain": true, "cursor": true },
      "monochrome": true,
      "uppercase": true,
      "corner": 4,
      "header": "> tail -f /dev/quota",
      "prompt": ">"
    }
    """#

    static let glasses = #"""
    {
      "id": "glasses",
      "name": "Glasses HUD · Green Mono",
      "font": "monospaced",
      "bar": "hairline",
      "colors": {
        "fg": "#3CFF7A", "dim": "#3CFF7A8C", "track": "#3CFF7A2E",
        "danger": "#3CFF7A", "warn": "#B6FFCC", "border": null
      },
      "backdrop": { "type": "clear", "opacity": 0.45 },
      "effects": { "glow": true, "glowRadius": 2.5 },
      "monochrome": true,
      "uppercase": true,
      "corner": 10,
      "header": "◢ QUOTA",
      "prompt": null
    }
    """#

    static let raid = #"""
    {
      "id": "raid",
      "name": "Raid Frames",
      "layout": "raid",
      "font": "serif",
      "bar": "health",
      "colors": {
        "fg": "#F5E6C8", "dim": "#B8A67E", "track": "#0000008C",
        "danger": "#E0303F", "warn": "#FF8C1A", "border": "#C8A24A",
        "hpHigh": "#1EBE3C", "hpMid": "#E0B000", "hpLow": "#C41E3A", "mana": "#2F6FEB"
      },
      "backdrop": { "type": "solid", "color": "#15110C" },
      "monochrome": false,
      "corner": 4,
      "borderWidth": 1.5,
      "header": "Raid  ·  {online} online"
    }
    """#
}
