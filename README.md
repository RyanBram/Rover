<p align="center">
  <img src="./assets/icons/rover.svg" width="200" alt="Rover Logo">
</p>

<h1 align="center">Rover</h1>
<p align="center">Universal HTML5 launcher for Windows, macOS, and Linux — a modern alternative to Electron and NW.js</p>

---

## Features

- ✨ **No Server Required** - Direct HTML loading via native WebView
- 🪶 **Ultra Lightweight** - Single ~200KB executable with minimal dependencies
- ⚡ **Instant Startup** - Launch in milliseconds, not seconds
- 🔧 **NW.js Compatible** - Drop-in replacement using `package.json` configuration
- 🌐 **Cross-Platform** - Works on Windows (WebView2), macOS (WKWebView), and Linux (WebKitGTK)
- 🎯 **Modern Engine** - Powered by platform-native web rendering

## Quick Start

### Minimal Setup

1. Create a `package.json` in your project directory:

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

2. Create your `index.html` file

3. Place `rover.exe` in the same directory

4. Run the application:

```powershell
.\rover.exe
```

That's it! Rover will load your HTML5 application directly in a native WebView window.

## Configuration

Rover uses the same `package.json` format as NW.js for easy migration:

| Field           | Type   | Default        | Description            |
| --------------- | ------ | -------------- | ---------------------- |
| `name`          | string | `"rover-app"`  | Application name       |
| `main`          | string | `"index.html"` | Entry HTML file        |
| `window.title`  | string | `"Rover App"`  | Window title           |
| `window.width`  | int    | `960`          | Window width (pixels)  |
| `window.height` | int    | `720`          | Window height (pixels) |

### Example Configuration

```json
{
  "name": "my-game",
  "main": "index.html",
  "window": {
    "title": "My Awesome Game",
    "width": 1920,
    "height": 1080
  }
}
```

## Build from Source

### Prerequisites

- **Nim >= 2.0.0** - Install from [nim-lang.org](https://nim-lang.org/)
- **Git** - For cloning the repository

Verify Nim installation:

```powershell
nim --version
```

### Compilation

Click build.bat on Windows

**Output:** `rover.exe` (~200 KB)

### Build Options

For maximum size optimization:

```powershell
nim c -d:release --opt:size --passL:-s src/rover.nim
```

Flags explained:

- `-d:release` - Enable release mode optimizations
- `--opt:size` - Optimize for smaller binary size
- `--passL:-s` - Strip debug symbols

## Supported Engines

Rover works seamlessly with popular HTML5 game engines and web frameworks:

<p align="center">
  <img src="./assets/icons/construct3.png" height="48" alt="Construct 3" title="Construct 3">
  <br>
  <img src="./assets/icons/gdevelop.png" height="48" alt="GDevelop" title="GDevelop">
  <br>
  <img src="./assets/icons/rpgmakermv.png" height="48" alt="RPG Maker MV/MZ" title="RPG Maker MV/MZ">
</p>

<p align="center"><sub>...and many more HTML5 frameworks!</sub></p>

## Use Cases

- 🎮 **HTML5 Game Distribution** - Package Construct 3, GDevelop, or RPG Maker games as desktop apps
- 📦 **Electron Alternative** - Lightweight replacement for simple web applications
- 🌐 **Offline Web Apps** - Run web applications without internet connectivity
- 🎨 **Interactive Presentations** - Create engaging HTML-based presentations
- 🔧 **Kiosk Applications** - Build fullscreen interactive displays

## Comparison with Alternatives

| Feature        | Rover          | Valet       | Electron/NW.js   |
| -------------- | -------------- | ----------- | ---------------- |
| Size           | ~200 KB        | ~1 MB       | ~200 MB          |
| Startup Time   | Instant        | 1-2 seconds | 3-5 seconds      |
| Memory Usage   | ~30 MB         | ~50 MB      | ~150 MB          |
| Server         | No server      | HTTP server | No server        |
| Node.js APIs   | ❌ No          | ❌ No       | ✅ Yes           |
| Window Control | Full control   | Limited     | Full control     |
| Rendering      | Native WebView | OS Browser  | Bundled Chromium |

### When to Use Rover

✅ Your app is pure HTML5/JavaScript/CSS  
✅ You want the smallest possible package size  
✅ You need instant startup times  
✅ You don't require Node.js APIs

### When to Use Valet

✅ You need HTTP server functionality  
✅ You want to use the OS's default browser engine  
✅ Your app requires specific browser features

### When to Use Electron/NW.js

✅ You need Node.js APIs (fs, child_process, etc.)  
✅ You require consistent rendering across all platforms  
✅ You need advanced desktop integration features

## Troubleshooting

### WebView2 Not Found (Windows)

**Error:** `WebView2 runtime not found`

**Solution:**

- Download and install [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
- WebView2 is pre-installed on Windows 11 and recent Windows 10 updates
- Alternatively, bundle the WebView2 runtime with your application

### Application Won't Start

**Error:** `Failed to load package.json`

**Solution:**

- Ensure `package.json` exists in the same directory as `rover.exe`
- Verify JSON syntax is valid (use a JSON validator)
- Check that the `main` field points to an existing HTML file

### Window Appears Blank

**Error:** White/blank window appears

**Solution:**

- Check browser console for JavaScript errors (if available)
- Verify the HTML file path in `package.json` is correct
- Ensure all referenced assets (CSS, JS, images) use relative paths
- Check that your HTML file is valid and complete

### Cross-Origin Issues

**Error:** `CORS policy` errors in console

**Solution:**

- Use relative paths for all local resources
- Avoid `file://` protocol references
- If loading external resources, ensure proper CORS headers

## Project Structure

```
my-app/
├── rover.exe           # Rover executable
├── package.json        # Configuration file
├── index.html          # Entry point
├── js/                 # JavaScript files
├── css/                # Stylesheets
├── assets/             # Images, fonts, audio
│   ├── images/
│   ├── fonts/
│   └── audio/
└── libs/               # Third-party libraries
```

## License

MIT License - Feel free to use in your projects!

---

<p align="center">
  <sub>Built with <img src="./assets/icons/nim-lang.svg" height="14" alt="Nim"></sub>
</p>
