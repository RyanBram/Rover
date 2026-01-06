Rover - Universal HTML5 App Launcher
Copyright (c) 2026 Ryan Bramantya

OVERVIEW
================================================================================
Rover is a lightweight, high-performance launcher for HTML5 applications and games.
It allows you to run web-based projects as native desktop applications without
the overhead of a full browser or heavy frameworks like Electron/NW.js.

FEATURES
================================================================================
* Fast & Lightweight: Minimal resource usage (under 5MB executable).
* Native Performance: Uses Microsoft Edge WebView2 for high performance.
* Engine Support: Optimized for Construct 3, GDevelop, RPG Maker MZ/MV.
* Customization: Change window title, size, and icon via configuration.
* Developer Tools: Built-in debugging tools (F12).

HOW TO USE
================================================================================
1. Place "rover.exe" in the root folder of your HTML5 game/app.
2. Ensure the folder contains an "index.html" file.
3. (Optional) Create a "package.json" file to customize settings:

   {
     "name": "My Game",
     "main": "index.html",
     "window": {
       "title": "My Awesome Game",
       "icon": "icon/game.ico",
       "width": 1280,
       "height": 720
     }
   }

4. Run "rover.exe" to launch your application.

Useful Hotkeys:
*  F4: Fullscreen
* F12: Open Developer Tools

LINKS
================================================================================
Download Page: https://ryanbram.itch.io/rover-universal-html5-app-launcher
Source Code  : https://github.com/RyanBram/Rover

LICENSE
================================================================================
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
