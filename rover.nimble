# Package

version       = "1.0.0"
author        = "Rover"
description   = "WebView2-based HTML launcher for Windows (Tauri-like)"
license       = "MIT"
srcDir        = "src"
bin           = @["rover"]

# Dependencies

requires "nim >= 2.0.0"
requires "https://github.com/neroist/webview"
