# colourMatik brand assets

The mascot: a chameleon (the animal that *takes* colour from its surroundings)
walking across a 35 mm film strip and *giving* it colour — the black-and-white
frame turns colour under its feet. Engraved illustration on a dark rounded tile.

Source art: `../chameleon-icon-source.png` (1792×1792, transparent).

## App icons
| File | Use |
|------|-----|
| `icons/AppIcon.icns` | macOS app icon (16→1024, retina). Embedded in the installer app. |
| `icons/colourMatik.ico` | Windows icon (16, 32, 48, 64, 128, 256). |
| `icons/colourMatik-{16,32,48,64,128,256,512,1024}.png` | Square PNGs (dark rounded tile). |
| `icons/chameleon-filmstrip-transparent.png` | Full artwork, transparent (sticker / hero use). |

Small sizes (≤64px) zoom to the head + eye so the favicon stays legible; larger
sizes show the full chameleon-on-film composition.

## Web / favicons (`web/`)
`favicon.ico`, `favicon-16.png`, `favicon-32.png`, `apple-touch-icon.png` (180),
`icon-192.png`, `icon-512.png`, `og-image.png` (1200×630 social card).

### Drop-in `<head>` for catheadai.com
```html
<link rel="icon" href="/colourmatik/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/colourmatik/favicon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/colourmatik/favicon-16.png">
<link rel="apple-touch-icon" sizes="180x180" href="/colourmatik/apple-touch-icon.png">
<meta property="og:title" content="colourMatik — Match any look. One click.">
<meta property="og:description" content="Copy the color grade of one clip onto another, inside Premiere Pro — fully on your machine.">
<meta property="og:image" content="https://catheadai.com/colourmatik/og-image.png">
<meta property="og:url" content="https://catheadai.com/colourmatik">
<meta name="twitter:card" content="summary_large_image">
```

## Brand tokens
- background `#0d0d0f` · film cream `#efe6d2` · accent blue `#1473e6`
- logo bars `#4ea1f7` / `#33ab5f` / `#e2a33e` · art teal `#2e8b7a` · art orange `#e0862e`
