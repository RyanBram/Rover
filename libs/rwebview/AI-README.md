# AI README: rwebview

This document provides context and strategic guidelines for AI assistants and contributors about the **rwebview** project. `rwebview` is a custom, minimal browser engine that serves as a **backend implementation** for `src\webview.nim`, replacing the OS-native webview backend (`libs\webview\webview.cc`) while keeping the existing Nim wrapper (`src\webview.nim`) and all of Rover's logic (`src\rover.nim`) completely unchanged.

## 1. Project Goal & Scope

`rwebview` functions as **the 4th webview backend** alongside Edge WebView2 (Windows), WKWebView (macOS), and WebKitGTK (Linux). Unlike those OS-native backends, rwebview is a **self-contained custom engine** — it ships its own JS runtime, rendering pipeline, and audio mixer. This makes it fully portable with zero OS webview dependency.

### Current Status (Phase 10 — RPG Maker MV Testing)

All core subsystems are implemented (Phases 0–9 complete). The engine can:
- Parse and execute HTML + JavaScript via Lexbor + QuickJS
- Render via Canvas 2D (software rasterizer) and WebGL 1.0 (real OpenGL 3.3)
- Play audio via Web Audio API (software mixer + SDL3 audio stream)
- Persist data via localStorage (JSON file)
- Handle keyboard and mouse input
- Present with aspect-ratio-preserving letterbox viewport
- Show a native F2 debug overlay (FPS, resolution, GPU name)

Phase 10 is active: testing with a real RPG Maker MV game project in `rpg_maker/`. Known open issues are tracked in `ISSUES.md`.

### Design Philosophy

The primary goal is to implement **proper web standard features** that RPG Maker MV uses, rather than hacky RPG-Maker-specific patches. This means:
- Canvas 2D operations should follow the W3C Canvas 2D spec behavior
- WebGL bindings should match the WebGL 1.0 spec
- DOM stubs should mimic real browser behavior for the APIs they implement
- Audio should follow Web Audio API semantics

We avoid building a CSS layout engine or features not needed by the target application class (canvas-based HTML5 games). However, features that ARE implemented should work correctly for any web app that uses them — not just RPG Maker.

### C ABI Contract

The final product is a compiled library that `src\webview.nim` links against **instead of** `libs\webview\webview.cc`. It exports the **exact same C ABI** as `webview.h` (i.e., `webview_create`, `webview_navigate`, `webview_bind`, `webview_eval`, etc.) so that `src\webview.nim`'s `importc` declarations resolve transparently. No changes to `src\rover.nim` or `src\webview.nim` are needed when switching backends.

**Missing C ABI exports** (known gaps vs `webview.h`):
- `webview_version()` — not exported (may cause linker error)
- `webview_get_native_handle()` — not exported

## 2. Technology Stack & Language Constraints

To maintain a lightweight executable, ensure fast compilation, and guarantee seamless interoperability, the following strict language constraints apply to the `rwebview` project:

1.  **rwebview Core Implementation:** Must be written in **Nim**.
2.  **Third-Party Libraries (`libs\rwebview\libs`):** Must be written **EXCLUSIVELY in C, Nim, or JavaScript**.
3.  **STRICTLY BANNED:** Do **NOT** introduce any libraries or code written in **C++, Rust, Zig, Go, or any other languages**.

### Core Foundation (`libs\rwebview\libs`)

- **SDL3 (C):** Handles cross-platform window management, the main event loop (input devices), and provides abstractions for Audio and OpenGL/GPU contexts. Use SDL3's `SDL_GL_GetProcAddress` to load all OpenGL function pointers at runtime — do not link against a static GL library.
- **Lexbor (C):** A blazingly fast HTML parser. It is used strictly to parse `index.html`, walk the DOM tree, and collect `<script>` tags in order. We explicitly bypass its CSS/layout engine to save time and complexity.
- **QuickJS (C):** The ECMAScript runtime. It executes the JavaScript code and serves as the bridge where all native C bindings (SDL inputs, DOM objects, WebGL commands, Canvas text drawing) are exposed to JS. QuickJS includes built-in support for `TypedArray`, `Promise`, `JSON`, `Math`, `Date`, `URL`, and `URLSearchParams` — do not re-implement these.

### Additional Required Libraries (`libs\rwebview\libs`)

The following SDL3 companion libraries are required by the implementation. Clone them into `libs/rwebview/libs/` if not already present:

- **SDL3_image (C):** PNG/JPEG/BMP/GIF/TGA/WebP decoder. Required for `new Image()` and feeding pixel data to `gl.texImage2D`. Without this, not a single sprite renders. Provides `IMG_Load` / `IMG_Load_IO` returning an `SDL_Surface`.
- **SDL3_ttf (C):** TTF/OTF font renderer backed by FreeType2 (bundled). Required for `ctx.fillText()` and `ctx.measureText()`. Provides `TTF_OpenFont`, `TTF_RenderText_Blended`, `TTF_SizeText`.
- **SDL_sound (C):** Decoder-only audio library by Ryan Gordon (icculus). Decodes OGG/MP3/WAV/FLAC/AU/AIFF into raw PCM float32 samples via bundled `stb_vorbis` and `dr_mp3`. Required for `AudioContext.decodeAudioData()`. Exposes `Sound_NewSampleFromMem` and `Sound_Decode_All`, allowing our Nim code to implement a custom WebAudio node graph on top of SDL3's `SDL_PutAudioStreamData` API. RPG Maker MV uses OGG as its primary audio format. Source: https://github.com/icculus/SDL_sound

### OpenGL Version Target

Target **OpenGL 3.3 Core Profile** on Windows desktop. This covers the full WebGL1 API surface and maps cleanly to WebGL2 extensions. Do **not** use OpenGL ES via EGL on Windows — desktop GL 3.3 has identical coverage and significantly simpler driver support on Windows.

## 3. Directory Structure

```text
libs\rwebview\
├── AI-README.md               # This file (Rules and Guidelines)
├── ROADMAP.md                 # Phased implementation plan
├── build.bat                  # Phase 0 build runner (CMake + Ninja)
├── testmedia.html             # RPG Maker title screen demo (Canvas2D + Audio)
├── rwebview.nim               # Orchestrator — includes all modules below
├── rwebview_ffi_sdl3.nim      # SDL3 core FFI (window, GL context, events, timer)
├── rwebview_ffi_sdl3_media.nim# SDL3 media FFI (SDL_image, SDL_ttf, SDL_sound, Audio)
├── rwebview_ffi_quickjs.nim   # QuickJS FFI (runtime, context, value helpers)
├── rwebview_html.nim          # Lexbor HTML parser, script-tag extraction
├── rwebview_dom.nim           # Fake DOM preamble, timers, rAF, event dispatch
├── rwebview_canvas2d.nim      # Canvas 2D CPU pixel ops (clearRect, fillRect, drawImage, fillText)
├── rwebview_gl.nim            # WebGL bindings (~70 GL functions) + Canvas2D→GL blit pipeline
├── rwebview_xhr.nim           # XMLHttpRequest, Fetch API, Image decode (SDL_image)
├── rwebview_audio.nim         # Web Audio API software mixer (SDL_sound decode, SDL3 audio stream)
├── rwebview_storage.nim       # localStorage (JSON file-backed persistent key/value storage)
├── c_src\
│   └── rwebview_qjs_wrap.c    # Thin C wrappers for QuickJS / Lexbor struct access
├── bin\                       # Built .dll + import .dll.a files
└── libs\                      # Third-party dependencies (C/Nim/JS ONLY)
    ├── SDL\                   # SDL3 v3.5 (Windowing, Input, OpenGL context)
    ├── SDL_image\             # SDL3_image (PNG/JPEG/BMP/GIF decode)
    ├── SDL_ttf\               # SDL3_ttf (TTF/OTF font rendering via FreeType2)
    ├── SDL_sound\             # SDL_sound (OGG/MP3/WAV/FLAC decode → raw float32 PCM)
    ├── lexbor\                # Lexbor (HTML parsing, script-tag extraction)
    └── quickjs\               # QuickJS (JS execution and all native bindings)
```

> **Architecture:** `rwebview.nim` is a monolithic orchestrator that `include`s the 9
> module files in dependency order. All modules share the parent scope — types, procs,
> and global state defined in earlier includes are visible to later ones. The include
> order is: `rwebview_ffi_sdl3` → `rwebview_ffi_sdl3_media` → `rwebview_ffi_quickjs` →
> [state types in rwebview.nim] → `rwebview_html` → `rwebview_dom` → `rwebview_canvas2d`
> → `rwebview_gl` → `rwebview_xhr` → `rwebview_audio` → `rwebview_storage`.

### Standalone rwebview Test Workflow (Build & Test Without Rover)

`rwebview.nim` contains a `when isMainModule:` block that acts as a standalone test
harness — no Rover integration needed. This is the **correct workflow for iterating
on rwebview phases** (rendering, audio, localStorage, bindings, etc.):

**Step 1 — Build all libraries and the standalone binary:**
```bat
cd libs\rwebview
build.bat
```
This CMake-builds SDL3 → SDL3_image → SDL3_ttf → SDL_sound → QuickJS → Lexbor (steps
1–6), then compiles `rwebview.nim` → `bin\rwebview.exe` (step 7). Only step 7 needs to
re-run after code changes; skip the library builds once they succeed:
```bat
nim c --hints:off --warnings:off "--outdir:bin" rwebview.nim
```

**Step 2 — Run the standalone binary:**
```bat
bin\rwebview.exe                      # Opens testmedia.html (default)
bin\rwebview.exe testmedia.html       # Same, explicit path
bin\rwebview.exe path\to\custom.html  # Any HTML file (drag-and-drop also works)
```
`isMainModule` sets `baseDir` to the HTML file's directory so relative asset paths
(`img/Test.png`, `audio/Test.ogg`, etc.) resolve correctly.

**Step 3 — Only after rwebview tests pass, compile the full Rover binary:**
```bat
cd ..\..
nim c -f -d:rwebview --threads:on --opt:size --app:gui "src\rover.nim"
```
Output: `src\rover.exe` (≈3.4 MB, links rwebview + SDL3 + QuickJS + Lexbor etc.).

> **Why not always compile Rover first?** The full Rover build takes ~40s and links
> all modules. The rwebview standalone build (step 7 only) takes ~8s and links only
> rwebview. Use the fast cycle for iterating; use the full build for final integration.

### Performance Architecture (Phase 8+)

Canvas 2D operations (clearRect, fillRect, drawImage, fillText) are CPU-side pixel
loops operating on a fixed internal resolution buffer (e.g., 816×624 for RPG Maker).
The GL blit pipeline uploads this buffer to a texture and draws it as a fullscreen
quad with `GL_LINEAR` filtering, letting the GPU handle bilinear upscaling to any
window size. This means:
- CPU work is constant regardless of window size (~2MB at 816×624 vs ~8MB at 1080p)
- `SDL_GL_SetSwapInterval(1)` enables VSync; an `SDL_Delay`-based frame limiter
  caps at ~60fps as a fallback when VSync is unavailable
- The audio mixer checks queue level BEFORE mixing to prevent source positions from
  advancing faster than real-time playback

## 4. Development Guidelines for AI

1.  **Proper web features over app-specific hacks:** When implementing a browser API, follow the W3C/WHATWG spec behavior — not just what RPG Maker happens to need. This prevents fragile patches that break when the app uses the feature differently. If a feature is too complex to implement fully, stub it with correct return types and document the limitation.
2.  **Canvas is King:** The entire game renders on a single `<canvas>` element. The Canvas 2D software rasterizer and WebGL 1.0 bindings are the critical rendering paths.
3.  **Never silently swallow JS exceptions:** After every `JS_Eval` call, check `JS_IsException(result)` and print the exception message to stdout via `JS_ToCString`. Silent failures are the hardest bugs to trace in a custom JS engine.
4.  **Rover polyfill.js reuse:** The existing `src\polyfill.js` in Rover already emulates `nw.*`, `process.*`, `require()`, and `module.exports` that RPG Maker MZ and some MV plugins expect. Inject it via `rwebview`'s `init()` after the global preamble, just as the current `webview.nim` path does. Do not duplicate this work.
5.  **C ABI contract — replace the backend, not the wrapper:** `rwebview.nim` exports C functions with `{.exportc, cdecl.}` and the `webview_` prefix matching `libs\webview\webview.h`. The high-level Nim wrapper (`src\webview.nim`) imports these via `importc`. **Do NOT re-implement** `CallBackContext`, `bindCallback`, `bind`, `newWebview`, `title=`, `size=`, `html=`, or any other high-level Nim sugar in `src\webview.nim` — that code already lives there.
6.  **Fake DOM, real rendering:** Do not build a CSS layout engine. The DOM is a minimal stub graph. But WebGL, Canvas2D, and Audio implementations should be spec-accurate for the features they support.
7.  **Performance-aware design:** QuickJS has no JIT. For CPU-hot loops (pixel blending, audio mixing, coordinate transforms), implement in Nim rather than JS. Use `copyMem` for bulk pixel ops. The Canvas2D software rasterizer is the primary bottleneck — profile and optimize there first.

## 5. RPG Maker MV Browser API Surface Map

This section details the specific browser APIs, objects, methods, and properties that RPG Maker MV (and its underlying Pixi.js library) are known to use. This list is derived from analyzing RPG Maker MV's core scripts and is crucial for guiding implementation efforts.

### 5.1. Global Objects & Properties

- **`window`**:
  - `window.innerWidth`, `window.innerHeight`
  - `window.devicePixelRatio`
  - `window.requestAnimationFrame`, `window.cancelAnimationFrame`
  - `window.setTimeout`, `window.clearTimeout`
  - `window.setInterval`, `window.clearInterval`
  - `window.addEventListener`, `window.removeEventListener` (for 'load', 'resize', 'keydown', 'keyup', 'mousedown', 'mouseup', 'mousemove', 'touchstart', 'touchend', 'touchmove', 'contextmenu', 'blur', 'focus')
  - `window.onload` (event handler)
  - `window.onresize` (event handler)
  - `window.onbeforeunload` (event handler, for saving)
  - `window.alert`, `window.confirm` (for debugging/dialogs)
- **`document`**:
  - `document.body`
  - `document.documentElement`
  - `document.createElement` (for 'canvas', 'div', 'img', 'audio', 'video', 'input')
  - `document.getElementById`
  - `document.querySelector`, `document.querySelectorAll`
  - `document.addEventListener`, `document.removeEventListener` (similar events to window)
  - `document.title`
  - `document.visibilityState`, `document.hidden` (for game pausing)
  - `document.fullscreenElement` (for fullscreen detection)
  - `document.exitFullscreen()`
- **`navigator`**:
  - `navigator.userAgent` (for browser/OS detection, can be mocked)
  - `navigator.platform` (can be mocked)
  - `navigator.maxTouchPoints` (for touch detection)
  - `navigator.getGamepads()` (for gamepad support, if implemented)
- **`console`**:
  - `console.log`, `console.warn`, `console.error`, `console.info`, `console.debug`
  - `console.trace`, `console.assert`
  - `console.time`, `console.timeEnd`

### 5.2. DOM Element Properties & Methods

- **`HTMLElement` (general)**:
  - `element.style` (basic properties: `width`, `height`, `position`, `left`, `top`, `zIndex`, `backgroundColor`, `display`, `opacity`, `transform`, `transformOrigin`, `pointerEvents`, `cursor`)
  - `element.classList` (`add`, `remove`, `contains`, `toggle`)
  - `element.id`, `element.className`
  - `element.appendChild`, `element.removeChild`, `element.insertBefore`
  - `element.children`, `element.parentNode`
  - `element.getBoundingClientRect()` (for input positioning)
  - `element.focus()`, `element.blur()`
  - `element.addEventListener`, `element.removeEventListener`
  - `element.innerHTML`, `element.textContent`
  - `element.dataset` (for custom data attributes)
- **`HTMLCanvasElement`**:
  - `canvas.getContext('2d')`
  - `canvas.getContext('webgl')`, `canvas.getContext('webgl2')`
  - `canvas.width`, `canvas.height`
  - `canvas.toDataURL()`
- **`HTMLImageElement`**:
  - `new Image()` constructor
  - `image.src`
  - `image.onload`, `image.onerror`
  - `image.width`, `image.height`, `image.naturalWidth`, `image.naturalHeight`
- **`HTMLAudioElement`**:
  - `new Audio()` constructor
  - `audio.src`
  - `audio.play()`, `audio.pause()`
  - `audio.volume`, `audio.loop`, `audio.currentTime`, `audio.duration`, `audio.ended`
  - `audio.oncanplaythrough`, `audio.onerror`
  - `audio.load()`
- **`HTMLVideoElement`**: (Less critical, but used for movie playback)
  - `new Video()` constructor
  - `video.src`
  - `video.play()`, `video.pause()`
  - `video.volume`, `video.loop`, `video.currentTime`, `video.duration`, `video.ended`
  - `video.oncanplay`, `video.onended`, `video.onerror`
  - `video.load()`
  - `video.width`, `video.height`
- **`HTMLInputElement`**: (Used for text input in some plugins or debug)
  - `input.value`
  - `input.type` (e.g., 'text')
  - `input.onchange`, `input.onkeydown`, `input.onkeyup`

### 5.3. Canvas 2D API (`CanvasRenderingContext2D`)

- `ctx.canvas`
- `ctx.clearRect`, `ctx.fillRect`, `ctx.strokeRect`
- `ctx.fillText`, `ctx.measureText`
- `ctx.font`, `ctx.textAlign`, `ctx.textBaseline`
- `ctx.fillStyle`, `ctx.strokeStyle`, `ctx.lineWidth`
- `ctx.beginPath`, `ctx.moveTo`, `ctx.lineTo`, `ctx.arc`, `ctx.bezierCurveTo`, `ctx.quadraticCurveTo`
- `ctx.stroke`, `ctx.fill`, `ctx.closePath`
- `ctx.save()`, `ctx.restore()`
- `ctx.translate()`, `ctx.rotate()`, `ctx.scale()`
- `ctx.globalAlpha`, `ctx.globalCompositeOperation`
- `ctx.drawImage()` (with various overloads)
- `ctx.createLinearGradient()`, `ctx.createRadialGradient()`, `ctx.addColorStop()`
- `ctx.setTransform()`, `ctx.resetTransform()`
- `ctx.clip()`

### 5.4. WebGL API (`WebGLRenderingContext` / `WebGL2RenderingContext`)

Pixi.js uses a wide range of WebGL functions. This list is extensive but not exhaustive; focus on common rendering operations.

- **Context & State**:
  - `gl.viewport()`
  - `gl.clearColor()`, `gl.clear()` (with `COLOR_BUFFER_BIT`, `DEPTH_BUFFER_BIT`, `STENCIL_BUFFER_BIT`)
  - `gl.enable()`, `gl.disable()` (e.g., `BLEND`, `DEPTH_TEST`, `SCISSOR_TEST`, `CULL_FACE`)
  - `gl.blendFunc()`, `gl.blendFuncSeparate()`
  - `gl.depthFunc()`, `gl.depthMask()`
  - `gl.cullFace()`, `gl.frontFace()`
  - `gl.scissor()`
  - `gl.pixelStorei()` (e.g., `UNPACK_FLIP_Y_WEBGL`, `UNPACK_PREMULTIPLY_ALPHA_WEBGL`)
  - `gl.getError()`
  - `gl.getParameter()` (e.g., `MAX_TEXTURE_SIZE`, `VERSION`, `VENDOR`, `RENDERER`)
  - `gl.getExtension()` (e.g., `OES_texture_float`, `WEBGL_lose_context`)
- **Shaders & Programs**:
  - `gl.createShader()`, `gl.shaderSource()`, `gl.compileShader()`, `gl.getShaderParameter()`, `gl.getShaderInfoLog()`, `gl.deleteShader()`
  - `gl.createProgram()`, `gl.attachShader()`, `gl.linkProgram()`, `gl.getProgramParameter()`, `gl.getProgramInfoLog()`, `gl.useProgram()`, `gl.deleteProgram()`
  - `gl.getAttribLocation()`, `gl.getUniformLocation()`
  - `gl.bindAttribLocation()`
- **Buffers**:
  - `gl.createBuffer()`, `gl.bindBuffer()`, `gl.bufferData()`, `gl.bufferSubData()`, `gl.deleteBuffer()`
  - `gl.vertexAttribPointer()`, `gl.enableVertexAttribArray()`, `gl.disableVertexAttribArray()`
- **Textures**:
  - `gl.createTexture()`, `gl.deleteTexture()`, `gl.bindTexture()`
  - `gl.activeTexture()`
  - `gl.texImage2D()`, `gl.texSubImage2D()` (from `HTMLImageElement`, `HTMLCanvasElement`, `ImageData`, `ArrayBufferView`)
  - `gl.texParameteri()`, `gl.texParameterf()` (e.g., `TEXTURE_MAG_FILTER`, `TEXTURE_MIN_FILTER`, `TEXTURE_WRAP_S`, `TEXTURE_WRAP_T`)
  - `gl.generateMipmap()`
- **Framebuffers & Renderbuffers**:
  - `gl.createFramebuffer()`, `gl.deleteFramebuffer()`, `gl.bindFramebuffer()`
  - `gl.framebufferTexture2D()`
  - `gl.createRenderbuffer()`, `gl.deleteRenderbuffer()`, `gl.bindRenderbuffer()`
  - `gl.renderbufferStorage()`
  - `gl.framebufferRenderbuffer()`
  - `gl.checkFramebufferStatus()`
- **Drawing**:
  - `gl.drawArrays()` (e.g., `TRIANGLES`, `TRIANGLE_STRIP`, `POINTS`)
  - `gl.drawElements()`
- **Uniforms**:
  - `gl.uniform1f`, `gl.uniform2f`, `gl.uniform3f`, `gl.uniform4f`
  - `gl.uniform1i`, `gl.uniform2i`, `gl.uniform3i`, `gl.uniform4i`
  - `gl.uniform1fv`, `gl.uniform2fv`, `gl.uniform3fv`, `gl.uniform4fv`
  - `gl.uniform1iv`, `gl.uniform2iv`, `gl.uniform3iv`, `gl.uniform4iv`
  - `gl.uniformMatrix2fv`, `gl.uniformMatrix3fv`, `gl.uniformMatrix4fv`
- **Reading Pixels**:
  - `gl.readPixels()`

### 5.5. Asset Loading

- **`XMLHttpRequest`**:
  - `new XMLHttpRequest()` constructor
  - `xhr.open()`, `xhr.send()`
  - `xhr.response`, `xhr.responseText`, `xhr.responseType`
  - `xhr.status`, `xhr.statusText`
  - `xhr.onload`, `xhr.onerror`, `xhr.onprogress`, `xhr.onreadystatechange`
  - `xhr.overrideMimeType()`
  - `xhr.setRequestHeader()`, `xhr.getResponseHeader()`
- **`fetch` API**:
  - `fetch(url, options)` (global function)
  - `Response` object: `response.json()`, `response.text()`, `response.blob()`, `response.arrayBuffer()`
  - `response.ok`, `response.status`, `response.statusText`
  - `response.headers` (basic access)
  - `Request` object (less common, but good to support basic usage)
  - `Promise` support for `fetch` and `Response` methods.

### 5.6. Web Audio API

- **`AudioContext`**:
  - `new AudioContext()` constructor
  - `context.createBufferSource()`
  - `context.decodeAudioData()` (Promise-based)
  - `context.createGain()`
  - `context.destination`
  - `context.currentTime`
  - `context.resume()`, `context.suspend()`
- **`AudioBufferSourceNode`**:
  - `source.buffer`
  - `source.connect()`
  - `source.start()`, `source.stop()`
  - `source.loop`, `source.loopStart`, `source.loopEnd`
  - `source.onended`
- **`GainNode`**:
  - `gainNode.gain.value`
  - `gainNode.connect()`
- **`AudioBuffer`**:
  - `buffer.duration`
  - `buffer.sampleRate`

### 5.7. Storage

- **`localStorage`**:
  - `localStorage.getItem(key)`
  - `localStorage.setItem(key, value)`
  - `localStorage.removeItem(key)`
  - `localStorage.clear()`
  - `localStorage.length`
  - `localStorage.key(index)`

### 5.8. Event Objects

- **`Event`**: `event.type`, `event.preventDefault()`, `event.stopPropagation()`
- **`KeyboardEvent`**: `event.key`, `event.code`, `event.keyCode` (deprecated but used), `event.which` (deprecated but used), `event.altKey`, `event.ctrlKey`, `event.shiftKey`, `event.metaKey`
- **`MouseEvent`**: `event.clientX`, `event.clientY`, `event.pageX`, `event.pageY`, `event.button`, `event.buttons`, `event.altKey`, `event.ctrlKey`, `event.shiftKey`, `event.metaKey`
- **`TouchEvent`**: `event.touches`, `event.changedTouches`, `event.targetTouches`
  - `Touch` object: `touch.identifier`, `touch.clientX`, `touch.clientY`, `touch.pageX`, `touch.pageY`, `touch.target`
- **`GamepadEvent`**: `event.gamepad` (if gamepad support is added)
  - `Gamepad` object: `gamepad.id`, `gamepad.index`, `gamepad.buttons`, `gamepad.axes`

### 5.9. Utility Objects & Functions

- **`Math`**: `Math.PI`, `Math.abs`, `Math.acos`, `Math.asin`, `Math.atan`, `Math.atan2`, `Math.ceil`, `Math.cos`, `Math.exp`, `Math.floor`, `Math.log`, `Math.max`, `Math.min`, `Math.pow`, `Math.random`, `Math.round`, `Math.sin`, `Math.sqrt`, `Math.tan`, `Math.sign`
- **`JSON`**: `JSON.parse()`, `JSON.stringify()`
- **`Date`**: `new Date()`, `Date.now()`, `date.getTime()`, `date.getFullYear()`, `date.getMonth()`, `date.getDate()`, `date.getHours()`, `date.getMinutes()`, `date.getSeconds()`, `date.getMilliseconds()`
- **`Array`**: All standard array methods (`push`, `pop`, `shift`, `unshift`, `splice`, `slice`, `concat`, `indexOf`, `lastIndexOf`, `forEach`, `map`, `filter`, `reduce`, `some`, `every`, `find`, `findIndex`, `sort`, `reverse`, `join`, `includes`)
- **`String`**: All standard string methods (`length`, `charAt`, `charCodeAt`, `indexOf`, `lastIndexOf`, `substring`, `slice`, `substr`, `toUpperCase`, `toLowerCase`, `trim`, `startsWith`, `endsWith`, `includes`, `replace`, `split`)
- **`Number`**: `Number.isFinite`, `Number.isNaN`, `Number.parseInt`, `Number.parseFloat`
- **`Boolean`**: Standard boolean operations
- **`RegExp`**: `new RegExp()`, `regexp.test()`, `regexp.exec()`
- **`Promise`**: Core Promise functionality (`new Promise`, `Promise.resolve`, `Promise.reject`, `Promise.all`, `Promise.race`, `.then()`, `.catch()`, `.finally()`)
- **`URL`**: `new URL()`, `URLSearchParams` (basic usage)
- **`encodeURIComponent()`, `decodeURIComponent()`**
- **`btoa()`, `atob()`** (for base64 encoding/decoding)
- **`ImageData`**: `new ImageData()`, `imageData.width`, `imageData.height`, `imageData.data`
- **`ArrayBuffer`, `Uint8Array`, `Float32Array`, `Int32Array`, etc.**: Typed Arrays are heavily used by WebGL and for binary data handling.

---

## 6. Implementation Status (as of Phase 10)

### Subsystem Completion

| Subsystem | File | Status | Notes |
|---|---|---|---|
| SDL3 FFI | `rwebview_ffi_sdl3.nim` | ✅ Complete | Window, GL context, events, timer |
| SDL3 Media FFI | `rwebview_ffi_sdl3_media.nim` | ✅ Complete | SDL_image, SDL_ttf, SDL_sound, Audio |
| QuickJS FFI | `rwebview_ffi_quickjs.nim` | ✅ Complete | Runtime, context, value helpers |
| HTML Parser | `rwebview_html.nim` | ✅ Complete | Lexbor-based script extraction |
| DOM + Events | `rwebview_dom.nim` + `dom_preamble.js` | ✅ Complete | Fake DOM, timers, rAF, event dispatch |
| Canvas 2D | `rwebview_canvas2d.nim` | ✅ Complete | Software rasterizer, ~20 operations |
| WebGL 1.0 | `rwebview_gl.nim` | ✅ Complete | ~70 GL functions, GLSL ES→3.30 translation |
| XHR / Fetch / Image | `rwebview_xhr.nim` | ✅ Complete | Local file loading, Image decode |
| Web Audio | `rwebview_audio.nim` | ✅ Complete | Software mixer, OGG/MP3/WAV decode |
| localStorage | `rwebview_storage.nim` | ✅ Complete | JSON file-backed, atomic writes |
| GL Blit Pipeline | `rwebview_gl.nim` | ✅ Complete | Letterbox viewport, F2 overlay |
| Rover Integration | `rwebview.nim` | ✅ Complete | Full C ABI, 33 bindings functional |

### Canvas 2D Operations

| Operation | Status | Notes |
|---|---|---|
| `clearRect` | ✅ | Fast-path for full-width rows |
| `fillRect` | ✅ | Solid color, gradient, pattern fill; CTM-aware |
| `strokeRect` | ⬜ Stub | |
| `fillText` | ✅ | SDL_ttf, textBaseline/textAlign, alpha blending |
| `strokeText` | ✅ | 8-offset outline blit using strokeStyle |
| `measureText` | ✅ | Via TTF_GetStringSize |
| `drawImage` | ✅ | 3/5/9-arg, CTM, canvas-to-canvas, fast 1:1 path |
| `getImageData` | ✅ | Returns Uint8ClampedArray |
| `putImageData` | ✅ | Direct pixel copy |
| `save`/`restore` | ✅ | Full state stack with transforms |
| `translate`/`rotate`/`scale` | ✅ | Affine CTM |
| `setTransform`/`resetTransform` | ✅ | 6-arg form |
| `createLinearGradient` | ✅ | 2-stop interpolation with addColorStop |
| `createRadialGradient` | ⚠️ Partial | Treated as linear (rare usage) |
| `createPattern` | ✅ | Tiles via inverse CTM (parallax scroll) |
| `arc` + `fill` | ✅ | Full circles only |
| `beginPath`/`closePath`/`moveTo`/`lineTo` | ⬜ Stub | |
| `bezierCurveTo`/`quadraticCurveTo` | ⬜ Stub | |
| `stroke`/`clip` | ⬜ Stub | |

### Composite Operations (globalCompositeOperation)

7 modes implemented via `blendPixel`: `source-over` (default, fast opaque path), `copy`, `lighter`, `difference`, `source-atop`, `destination-in`, `saturation`.

### WebGL 1.0 Coverage

~70 functions implemented covering: state management, shaders (with automatic GLSL ES→GL 3.30 Core translation), programs, buffers, textures (including `texImage2D` from Image/Canvas sources), framebuffers, renderbuffers, drawing, uniforms (all variants including matrix), reading pixels, parameter queries, extensions (OES_element_index_uint, OES_texture_float, ANGLE_instanced_arrays, etc.).

### Audio Nodes

| Node | Status |
|---|---|
| `AudioContext` | ✅ Full lifecycle, decodeAudioData, createBufferSource/Gain/Panner |
| `AudioBuffer` | ✅ Multi-channel float32, getChannelData, copyFromChannel |
| `AudioBufferSourceNode` | ✅ Playback, loop, playbackRate (AudioParam), onended |
| `GainNode` | ✅ Per-sample gain multiplication |
| `PannerNode` | ⚠️ Passthrough stub (connect/disconnect work, positioning no-op) |
| `AudioParam` | ⚠️ value get/set works; ramp methods apply immediately (no interpolation) |

### C ABI Compatibility with webview.h

| Function | rwebview Status |
|---|---|
| `webview_create` | ✅ Implemented |
| `webview_destroy` | ✅ Implemented |
| `webview_run` | ✅ Implemented |
| `webview_run_step` | ✅ Implemented (extra, not in webview.h) |
| `webview_terminate` | ✅ Implemented |
| `webview_dispatch` | ✅ Implemented (synchronous) |
| `webview_get_window` | ✅ Returns HWND via SDL |
| `webview_set_title` | ✅ Implemented |
| `webview_set_size` | ✅ Implemented (hint param ignored) |
| `webview_navigate` | ✅ URL resolution + HTML parse + JS execution |
| `webview_set_html` | ✅ In-memory HTML parse |
| `webview_init` | ✅ Queues JS preamble |
| `webview_eval` | ✅ JS_Eval |
| `webview_bind` | ✅ Promise-based binding channel |
| `webview_unbind` | ✅ Implemented |
| `webview_return` | ✅ Resolves/rejects Promise |
| `webview_set_virtual_host_name_to_folder_mapping` | ✅ Implemented |
| `webview_open_devtools` | ⬜ No-op stub |
| `webview_get_saved_placement` | ⬜ No-op stub |
| `webview_version` | ❌ **Not exported** (potential linker error) |
| `webview_get_native_handle` | ❌ **Not exported** |

### Known Open Issues

See `ISSUES.md` for the full tracker. Key items:
- Particle rendering (rain/snow) too large
- Some SE audio pitch shift
- Mouse coordinate offset (few pixels toward bottom-right)
- `webview_version` / `webview_get_native_handle` not exported

---

*Last updated: March 2026, Phase 10 active.*
