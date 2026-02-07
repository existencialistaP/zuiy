# zuiy

## Dependencies
- `zig` (build)
- `raylib` (runtime, system package)
- `swww` (wallpaper)
- `dunst` + `dunstctl` (notify)
- `systemctl`/`loginctl` (power)

Optional:
- `JetBrainsMonoNerdFont` (or any font via `ZUIY_FONT`)

## Build
```bash
zig build
zig build install
```

## Usage
```bash
zuiy launcher
zuiy power
zuiy wallpaper
zuiy notify
```

## Shortcuts
### launcher
- arrows/Tab: navigate
- Enter: open
- Esc: quit

### power
- arrows/Tab: navigate
- hold Enter: confirm (configurable)
- Esc/Q: quit

### wallpaper
- arrows/Tab/J/K: navigate
- Enter: apply and exit
- Space: live apply (toggle)
- `/`: filter
- Esc/Q: quit

### notify
- arrows/Tab: navigate
- Enter: select
- `/`: filter
- `1..5`: quick action (if available)
- `X`: clear history
- D: do not disturb
- Esc/Q: quit

## Config
File: `~/.config/zuiy/config` (or `ZUIY_CONFIG`)

Keys:
```
power_hold_ms=500
wallpaper_preview_max_dim=720
wallpaper_cache_size=6
wallpaper_live_apply=false
```

## Environment
- `ZUIY_FONT` path to `.ttf` font
- `ZUIY_WALLPAPER_DIR` extra wallpapers folder
- `ZUIY_WALLPAPER_CMD` custom command to apply wallpaper
