# Tools

## icon-tuner.html

Interactive HTML tool for tuning the app icon's sine-wave panel boundaries. Open in a browser — no build step needed.

### What it controls

The app icon (`Sources/TBDApp/AppIcon.swift`) draws three colored panels separated by sine-wave curves. Each boundary follows:

```
x(t) = cx + slant*(0.5 - t) + amplitude * sin(2π * frequency * t + phase)
```

The tuner provides real-time sliders for amplitude, frequency, phase, slant, panel positions, color palette, and independent offsets for the right boundary.

### Workflow

1. Open `tools/icon-tuner.html` in a browser
2. Adjust sliders until the icon looks right
3. Copy the "Swift Values" block (click to copy)
4. Update the `SineBoundary` values in `Sources/TBDApp/AppIcon.swift`
5. The Swift code uses raw tuner values directly — `SineBoundary.x()` handles the canvas→CoreGraphics y-axis flip internally via `(1-t)`

### Bookmarking

All slider values persist in query params. Bookmark a URL to save a configuration. Only non-default values are included to keep URLs short.

### Area display

The percentage chips at the top show each panel's area share, computed by pixel-counting on an offscreen canvas. Use this to keep panels roughly balanced.
