# Rover

### WebView-based HTML launcher for Windows, MacOS, and Linux - a lightweight alternative to Electron/NW.js.

## Features

- **No Server Required** - Direct HTML loading via WebView2
- **NW.js Compatible** - Uses `package.json` for configuration
- **Lightweight** - Single executable, minimal dependencies
- **Modern Engine** - Uses platform webview

## Requirements

- **Nim >= 2.0.0** - For compilation

## Installation

```powershell
# Build
nimble build
```

## Usage

1. Create a `package.json` in your project:

```json
{
  "name": "my-app",
  "main": "index.html",
  "window": {
    "title": "My Application",
    "width": 1280,
    "height": 720
  }
}
```

2. Create your `index.html`

3. Place `rover.exe` in the same directory

4. Run `rover.exe`

## Configuration

### package.json

| Field           | Type   | Default      | Description      |
| --------------- | ------ | ------------ | ---------------- |
| `name`          | string | "rover-app"  | Application name |
| `main`          | string | "index.html" | Entry HTML file  |
| `window.title`  | string | "Rover App"  | Window title     |
| `window.width`  | int    | 960          | Window width     |
| `window.height` | int    | 720          | Window height    |

## Comparison with Valet

| Aspect         | Valet                    | Rover             |
| -------------- | ------------------------ | ----------------- |
| Rendering      | OS Browser               | OS WebView        |
| Server         | HTTP server required     | No server         |
| Startup        | ~2-3 seconds             | Instant           |
| Resources      | Separate browser process | Single executable |
| Window Control | Limited                  | Full control      |

## License

MIT
