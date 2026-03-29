# ROADMAP: rwebview

This document is the phased development plan for building **rwebview** — a minimal, self-contained browser engine written in Nim, targeting **RPG Maker MV** as the primary reference implementation. It is a companion to `AI-README.md`.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Complete Dependency Map](#2-complete-dependency-map)
3. [Missing Libraries (Action Required)](#3-missing-libraries-action-required)
4. ✅ [Phase 0 — Foundation & Build System](#phase-0--foundation--build-system)
5. ✅ [Phase 1 — Window + QuickJS Bootstrap](#phase-1--window--quickjs-bootstrap)
6. ✅ [Phase 2 — HTML Script Loader](#phase-2--html-script-loader)
7. ✅ [Phase 3 — Minimal DOM + Event System](#phase-3--minimal-dom--event-system)
8. ✅ [Phase 4 — WebGL Bindings (Critical Path)](#phase-4--webgl-bindings-critical-path)
9. ✅ [Phase 5 — Canvas 2D (Text Rendering)](#phase-5--canvas-2d-text-rendering)
10. ✅ [Phase 6 — Asset Loading (XHR / Fetch / Image)](#phase-6--asset-loading-xhr--fetch--image)
11. ✅ [Phase 7 — Web Audio API](#phase-7--web-audio-api)
12. ✅ [Phase 8 — Storage (localStorage)](#phase-8--storage-localstorage)
13. ✅ [Phase 9 — Rover Integration](#phase-9--rover-integration)
14. ✅ [Phase 10 — RPG Maker MV Testing](#phase-10--rpg-maker-mv-testing)
15. ✅ [Phase 11 — Unified Font Stack (Fonstash)](#phase-11--unified-font-stack-fonstash-for-canvas2d--ui)
16. [API Compatibility Checklist](#15-api-compatibility-checklist)

---

## 1. Architecture Overview

```
webview.nim  (Nim wrapper — importc of webview_* C ABI; backend-agnostic)
    │
    └── rwebview.nim  (C ABI backend — exports webview_create, webview_eval, etc.)
            │
            ├── SDL3           — Window creation, OpenGL context, event pump, audio device
            ├── SDL3_image     — PNG/JPEG/BMP/GIF decoder → feeds texImage2D / new Image()
            ├── SDL3_ttf       — TTF/OTF font rasterizer → feeds fillText / measureText
            ├── SDL_sound      — OGG/MP3/WAV/FLAC decoder → raw PCM for SDL3 audio stream
            ├── QuickJS        — ECMAScript engine; all browser APIs surface as JS bindings
            └── Lexbor         — HTML parser; reads index.html, extracts <script> load order
```

> **Key distinction:** `rwebview.nim` is a **backend replacement for `webview.cc`**, NOT a
> replacement for `webview.nim`. It exports the same `webview_*` C ABI that `webview.nim`
> already imports via `importc`. Activated via `-d:rwebview` at compile time. No changes
> to `src/rover.nim` or `src/webview.nim` are needed.

**Execution flow inside rwebview:**

```
rwebview_navigate(url)
  → Lexbor: parse index.html
    → collect <script src="..."> and inline <script> in DOM order
  → QuickJS: inject global preamble (window, document, navigator stubs)
    → execute scripts sequentially (blocking, just like a browser)
      → game calls canvas.getContext('webgl')         → SDL3 OpenGL context
      → game calls new Image(); img.src = "..."       → SDL3_image decode
      → game calls gl.texImage2D(...)                 → OpenGL call
      → game calls requestAnimationFrame(cb)          → SDL3 main loop tick
      → game calls new Audio(); audio.play()          → SDL_sound decode + SDL3 audio push
      → game calls ctx.fillText(...)                  → SDL3_ttf rasterize
      → game calls localStorage.setItem(...)          → JSON file on disk
```

---

## 2. Complete Dependency Map

| Library | Language | Role | Already in `libs/`? |
|---|---|---|---|
| SDL3 v3.5 | C | Window, OpenGL context, event loop, audio device | ✅ Yes |
| Lexbor | C | HTML parsing, DOM structure for script-tag ordering | ✅ Yes |
| QuickJS | C | ECMAScript runtime, all native bindings exposed here | ✅ Yes |
| **SDL3_image** | C | PNG/JPEG/BMP/GIF decode for `new Image()` and `texImage2D` | ❌ **Missing** |
| **SDL3_ttf** | C | TTF/OTF font rasterize for `fillText`, `measureText` | ❌ **Missing** |
| **SDL_sound** | C | OGG/MP3/WAV/FLAC decoder → raw PCM for SDL3 audio stream | ✅ Yes |

SDL3_image and SDL3_ttf are official SDL3 companion libraries (C, same license as SDL3)
available at https://github.com/libsdl-org/. SDL_sound is a standalone C decoder library
by Ryan C. Gordon from https://github.com/icculus/SDL_sound. All three must be cloned into
`libs/rwebview/libs/` alongside the existing SDL3 source tree.

---

## 3. Libraries Required

These libraries were cloned into `libs/rwebview/libs/`:

```bat
git clone --depth=1 https://github.com/libsdl-org/SDL_image  libs\rwebview\libs\SDL_image
git clone --depth=1 https://github.com/libsdl-org/SDL_ttf    libs\rwebview\libs\SDL_ttf
git clone --depth=1 https://github.com/icculus/SDL_sound      libs\rwebview\libs\SDL_sound
```

All three are official C libraries in the SDL3 ecosystem. They use CMake and are
built the same way as SDL3 itself. Building is covered in Phase 0.

### Why SDL ecosystem over stb single-headers?

| Concern | stb (rejected) | SDL companion (chosen) |
|---|---|---|
| Format support | PNG/JPEG only | PNG/JPEG/BMP/GIF/TGA/AVIF/WebP/etc. |
| Font hinting | None (raw rasterizer) | Full hinting via FreeType2 (bundled in SDL3_ttf) |
| Audio formats | OGG + MP3 separately | OGG/MP3/WAV/FLAC/OPUS in one lib |
| Maintenance | Mostly frozen | Actively maintained by SDL team |
| API surface | Raw C structs | Integrates natively with SDL_Surface/SDL_Texture |
| Dependencies | 4 separate files to track | 3 repos, same org, same versioning |

---

## Phase 0 — Foundation & Build System ✅ COMPLETE

**Goal:** Every library compiles cleanly and links into a `rwebview_test.exe` binary.

### Tasks

- [x] Confirm directory layout matches actual files (see layout below)
- [x] Clone SDL3_image, SDL3_ttf, SDL_sound into `libs/rwebview/libs/`
  (`SDL_sound`: https://github.com/icculus/SDL_sound)
- [x] Use CMake to build SDL3 → `SDL3.dll` + `libSDL3.dll.a`
- [x] Use CMake to build SDL3_image → `SDL3_image.dll` + `libSDL3_image.dll.a`
- [x] Use CMake to build SDL3_ttf → `SDL3_ttf.dll` + `libSDL3_ttf.dll.a`
- [x] Use CMake to build SDL_sound → `SDL3_sound.dll` + `libSDL3_sound.a`
- [x] Build QuickJS C sources → `libquickjs.a` (static, MinGW GCC)
- [x] Build Lexbor → `liblexbor_static.a` (static, CMake + Ninja)
- [x] Write `rwebview.nim` skeleton: export `webview_create`, `webview_destroy`, `webview_run`,
  `webview_eval`, `webview_init`, `webview_navigate`, `webview_set_html`, `webview_bind`,
  `webview_unbind`, `webview_return`, `webview_set_title`, `webview_set_size`,
  `webview_get_window`, `webview_set_virtual_host_name_to_folder_mapping`,
  `webview_open_devtools`, `webview_get_saved_placement`, `webview_terminate`,
  `webview_dispatch` — all with `{.exportc, cdecl.}` matching `webview.h` signatures
- [x] Verify `nim c rwebview.nim` compiles cleanly (no errors, no warnings)

### Build Output Layout

All built `.dll` and `.dll.a` import files go into `libs/rwebview/bin/`:

```
libs/rwebview/
├── AI-README.md
├── ROADMAP.md
├── rwebview.nim               # Orchestrator — includes all modules below
├── rwebview_ffi_sdl3.nim      # SDL3 core FFI bindings
├── rwebview_ffi_sdl3_media.nim# SDL3 media FFI (image, ttf, sound, audio)
├── rgss_quickjs_ffi.nim   # QuickJS FFI bindings
├── rwebview_html.nim          # Lexbor HTML parser + script extraction
├── rwebview_dom.nim           # Fake DOM, timers, rAF, event dispatch
├── rwebview_canvas2d.nim      # Canvas 2D CPU pixel ops + text rendering
├── rwebview_gl.nim            # WebGL bindings + Canvas2D→GL blit pipeline
├── rwebview_xhr.nim           # XHR, Fetch, Image decode
├── rwebview_audio.nim         # Web Audio API software mixer
├── testmedia.html             # RPG Maker title screen demo
├── build.bat                  # Phase 0 build runner
├── c_src/
│   ├── rwebview_rgss_wrap.c  # Thin C wrappers for RGSS inline functions
├── bin/                       # Built .dll + import .dll.a files go here
└── libs/
    ├── SDL/                   # SDL3 v3.5 source (already present)
    ├── lexbor/                # Lexbor source (already present)
    ├── quickjs/               # QuickJS source (already present)
    ├── SDL_image/             # SDL3_image source (clone from §3)
    ├── SDL_ttf/               # SDL3_ttf source (clone from §3)
    └── SDL_sound/             # SDL_sound source (clone from §3)
```

### WebGL C Library Research

The project `headless-gl` achieves its OpenGL context via **ANGLE** (C++ — banned
by `AI-README.md §2`). There is no pure-C library that provides a ready-made
WebGL API surface.

The equivalent approach for rwebview:
- SDL3 creates a real OpenGL 3.3 Core context (`SDL_GL_CreateContext`)
- All `gl.*` functions are loaded at runtime via `SDL_GL_GetProcAddress`
- The WebGL-to-OpenGL mapping is implemented as QuickJS C bindings written in this project

This is architecturally identical to how browser engines work internally — they
expose WebGL as a JS API layer on top of native GL. No external C library is
necessary or available for this specific task.

For reference, if **software-rendered offscreen** GL is ever needed (e.g., CI
testing without a GPU), **OSMesa** (part of Mesa3D, pure C) can replace the
SDL3 GL context. Since we have a real window, OSMesa is not needed now.

---

## Phase 1 — Window + QuickJS Bootstrap ✅ COMPLETE

**Goal:** Open a blank SDL3 window and execute a `console.log("Hello")` in QuickJS.

### Tasks

- [x] In `rwebview.nim`, write Nim FFI bindings for:
  - SDL3: `SDL_Init`, `SDL_CreateWindow`, `SDL_GL_CreateContext`, `SDL_GL_SwapWindow`, `SDL_PollEvent`, `SDL_Quit`
  - QuickJS: `JS_NewRuntime`, `JS_NewContext`, `JS_Eval`, `JS_FreeContext`, `JS_FreeRuntime`
- [x] Open SDL3 window with `SDL_WINDOW_OPENGL` flag
- [x] Create an OpenGL 3.3 Core Profile context via `SDL_GL_CreateContext`
  - Set `SDL_GL_CONTEXT_MAJOR_VERSION = 3`, `SDL_GL_CONTEXT_MINOR_VERSION = 3`
  - Set `SDL_GL_CONTEXT_PROFILE_MASK = SDL_GL_CONTEXT_PROFILE_CORE`
  - ⚠️ **Bug fixed (March 2026):** SDL3's `SDL_GLAttr` enum values are
    `MAJOR=17, MINOR=18, PROFILE_MASK=20` — NOT 18/19/21 as previously assumed.
    Using wrong values causes `SDL_GL_CreateContext` to fail silently.
    Always verify against `libs/rwebview/libs/SDL/include/SDL3/SDL_video.h`.
- [x] Create QuickJS runtime + context
- [x] Bind `console.log`, `console.warn`, `console.error` → `stderr` in Nim
  (uses `JS_CFUNC_generic_magic` to share one C proc with a `magic` discriminant)
- [x] Write the main event loop skeleton:
  ```
  while running:
    SDL_PollEvent(event)
    handle SDL_EVENT_QUIT / SDL_EVENT_WINDOW_CLOSE_REQUESTED → running = false
    SDL_GL_SwapWindow(window)
  ```
- [x] Test: `JS_Eval(ctx, "console.log('Hello from QuickJS')")` prints to console
- [x] Refactor: all public procs use `{.exportc, cdecl.}` with `webview_` prefix
  to satisfy `webview.nim`'s `importc` declarations
- [x] Add `-d:rwebview` switch in `src/webview.nim` (skips `webview.cc`, links rwebview instead)

### OpenGL Version Note

Target **OpenGL 3.3 Core Profile** on desktop. This maps to WebGL1 feature set
with a clean upgrade path to WebGL2-level features. Do **not** use OpenGL ES via
EGL on Windows — desktop GL 3.3 has identical API coverage and simpler driver support.

---

## Phase 2 — HTML Script Loader ✅ COMPLETE

**Goal:** Parse `index.html`, find all `<script>` tags in order, and execute them via QuickJS.

### Tasks

- [x] Write Nim FFI bindings for Lexbor:
  - `lxb_html_parser_create`, `lxb_html_parser_init`, `lxb_html_parse`, `lxb_html_parser_destroy`
  - `lxb_html_document_destroy`
  - `lxb_dom_collection_make_noi`, `lxb_dom_collection_destroy`,
    `lxb_dom_collection_length_noi`, `lxb_dom_collection_element_noi`
  - `lxb_dom_elements_by_tag_name` for querying `script` elements
  - `lxb_dom_element_get_attribute` to read `src` and `type` attributes
  - `lxb_dom_node_text_content` for inline script body text
  - `lxb_dom_document_element_noi` for the document root element
- [x] Thin C wrapper `c_src/rwebview_lexbor_wrap.c`:
  - `rw_lxb_html_doc_to_dom` casts `lxb_html_document_t*` → `lxb_dom_document_t*`
    without Nim needing the struct layout
- [x] Implement `parseScripts(htmlContent, baseDir): seq[ScriptEntry]`
  - `ScriptEntry = object; src: string; inline: string; isModule: bool`
  - Preserves DOM order (critical — Pixi.js must come before rpg_core scripts)
- [x] Implement `loadScriptFile(path)` — done inline inside `executeScripts` via
  Nim's standard `readFile`
- [x] Implement `executeScripts(scripts, ctx, label)`:
  1. For each entry: if `src` is set → read file → `JS_Eval`; else → `JS_Eval` inline code
  2. Halt (with logged error) on JS exception — never silently swallowed
- [x] Handle `<script type="module">` — logs a warning, treats as regular script
  (RPG Maker MV does not use ES modules)
- [x] Implement virtual URL resolution (`resolveUrl`):
  - `http://rover.assets/<path>` → `virtualHosts["rover.assets"] / <path>`
  - Relative paths → `baseDir / path`
  - `file:///abs/path` → absolute path pass-through
- [x] Implement `navigateImpl(state, htmlContent, htmlPath)`:
  - Injects all preamble JS registered via `webview_init()` before page scripts
  - Calls `parseScripts` then `executeScripts`
- [x] Implement `webview_navigate(url)`:
  - Resolves URL to local path, sets `state.baseDir`, reads file, calls `navigateImpl`
- [x] Implement `webview_set_html(html)`:
  - Calls `navigateImpl` with the supplied HTML string directly
- [x] `webview_set_virtual_host_name_to_folder_mapping` now also sets `state.baseDir`
  from the first registered mapping (so `webview_set_html` works even before navigate)

---

## Phase 3 — Minimal DOM + Event System ✅ COMPLETE

**Goal:** Enough DOM surface that RPG Maker MV's `main.js` does not throw during startup.

### Strategy

Do **not** build a fully spec-compliant DOM. RPG Maker MV's entire rendering
goes through a single `<canvas id="GameCanvas">`. The DOM is only used to:
1. Find that canvas element
2. Attach event listeners (keyboard, mouse, focus)
3. Set a few style properties

Implement a **fake DOM** — a small QuickJS object graph hardcoded to the RPG
Maker structure. Do not parse CSS, do not implement layout, do not compute `getBoundingClientRect` from layout.

### Tasks

- [x] Inject a JS preamble (via `JS_Eval` before scripts run) containing:
  - [x] `window.innerWidth`, `window.innerHeight` (from SDL3 window size)
  - [x] `window.devicePixelRatio = 1.0`
  - [x] `window.requestAnimationFrame(cb)` — store `cb`; call it once per SDL frame tick
  - [x] `window.cancelAnimationFrame(id)` — cancel stored callback
  - [x] `window.setTimeout(fn, ms)`, `window.clearTimeout(id)`
  - [x] `window.setInterval(fn, ms)`, `window.clearInterval(id)`
  - [x] `window.addEventListener`, `window.removeEventListener`
  - [x] `window.alert(msg)` → `echo msg` (stub)
  - [x] `window.confirm(msg)` → `return true` (stub — needed by some error dialogs)
  - [x] `window.location.href` (stub, read-only)
  - [x] `window.performance.now()` → SDL `SDL_GetTicks64()` in milliseconds
- [x] Implement `document` object:
  - [x] `document.createElement(tag)` — returns a stub element object
  - [x] `document.getElementById(id)` — returns pre-created elements by id
  - [x] `document.querySelector(sel)`, `document.querySelectorAll(sel)` — simple id/tag matching only
  - [x] `document.body`, `document.documentElement` — stub node objects
  - [x] `document.title` — getter/setter (sets SDL3 window title)
  - [x] `document.addEventListener`, `document.removeEventListener`
  - [x] `document.visibilityState = "visible"`, `document.hidden = false` (stubs)
  - [x] `document.fullscreenElement = null` (stub)
  - [x] `document.exitFullscreen()` (stub)
- [x] Implement `HTMLCanvasElement` behavior for `#GameCanvas`:
  - [x] `canvas.width`, `canvas.height` (match SDL window size)
  - [x] `canvas.getContext('2d')` → return Canvas 2D context object (Phase 5)
  - [x] `canvas.getContext('webgl')` or `canvas.getContext('webgl2')` → return WebGL context object (Phase 4)
  - [x] `canvas.style` — stub object with `width`, `height`, `left`, `top`, etc.
  - [x] `canvas.getBoundingClientRect()` → `{left:0, top:0, width, height}`
  - [x] `canvas.addEventListener`, `canvas.removeEventListener`
  - [x] `canvas.toDataURL()` → stub returning empty string (low priority)
- [x] Implement `navigator` stubs:
  - [x] `navigator.userAgent = "Mozilla/5.0 (rwebview)"` (mock)
  - [x] `navigator.platform = "Win32"` (mock)
  - [x] `navigator.maxTouchPoints = 0`
  - [x] `navigator.getGamepads = () => []` (stub)
- [x] Implement event dispatch from SDL3 events:
  - [x] SDL `SDL_EVENT_KEY_DOWN` / `SDL_EVENT_KEY_UP`
  - [x] SDL `SDL_EVENT_MOUSE_BUTTON_DOWN` / `_UP` / `SDL_EVENT_MOUSE_MOTION`
  - [x] SDL `SDL_EVENT_WINDOW_RESIZED`
  - [x] SDL `SDL_EVENT_WINDOW_FOCUS_GAINED` / `LOST`
- [x] Implement `HTMLImageElement` creation:
  - [x] `new Image()` → returns an image object
  - [x] Setting `img.src` triggers async decode via SDL3_image (Phase 6)
  - [x] `img.onload` / `img.onerror` callbacks fire when decode completes
- [x] Fix `clearInterval`/`clearTimeout` lifetime bug (Phase 3 real-world crash fix)

---

## Phase 4 — WebGL Bindings (Critical Path) ✅ COMPLETE

**Goal:** Pixi.js can create a WebGL context and render sprites to the SDL3 window.

This is the most complex phase and the **core rendering path**.

### Strategy

WebGL1 maps almost 1:1 to OpenGL 3.3 Core Profile. Write Nim FFI to OpenGL,
then expose each WebGL function as a QuickJS C function binding. Use
`JS_SetPropertyStr` to attach all `gl.*` methods to the context object.

### Tasks

#### 4.1 — OpenGL FFI in Nim
- [x] GL types + ~80 function pointer variables in `rwebview.nim`
- [x] `loadGLProcs()` loads all OpenGL function pointers via `SDL_GL_GetProcAddress` at runtime
- [x] Default VAO created and bound (Core Profile requirement)

#### 4.2 — WebGL Context Object in QuickJS
- [x] `bindWebGL(state)` creates a JS object with all `gl.*` methods bound via `JS_NewCFunction`
- [x] All WebGL constants installed via bulk JS eval (`glConstantsJS`)
- [x] GL handle types implemented as JS objects with `__id` property:
  - `WebGLBuffer`, `WebGLTexture`, `WebGLShader`, `WebGLProgram`
  - `WebGLFramebuffer`, `WebGLRenderbuffer` — wraps `GLuint`
  - `WebGLUniformLocation` — wraps `GLint`
- [x] `canvas.getContext('webgl')` returns the native GL context object (`__rw_glContext`)

#### 4.3 — Typed Array Support
- [x] QuickJS built-in `TypedArray` support verified (`Uint8Array`, `Float32Array`, etc.)
- [x] `jsGetBufferData(ctx, val)` helper extracts raw pointer + byte length from
  ArrayBuffer or TypedArray for `bufferData`, `texImage2D`, uniform*v, etc.

#### 4.4 — texImage2D from HTMLImageElement
- [x] 9-argument form: `texImage2D(target, level, ifmt, w, h, border, fmt, type, data)` — works with TypedArray or null
- [x] 6-argument form: `texImage2D(target, level, ifmt, fmt, type, source)` — reads `__pixelData` from image object (Phase 6 will populate this; falls back to 1×1 white pixel)

#### 4.5 — WebGL Extensions
- [x] `getExtension(name)` implemented:
  - `OES_element_index_uint`, `OES_texture_float`, `OES_texture_half_float` → stub objects
  - `OES_texture_float_linear`, `OES_texture_half_float_linear` → stub objects
  - `OES_standard_derivatives`, `EXT_shader_texture_lod`, `EXT_frag_depth` → stub objects
  - `EXT_blend_minmax`, `WEBGL_depth_texture` → stub objects
  - `OES_vertex_array_object`, `ANGLE_instanced_arrays`, `WEBGL_lose_context` → stub objects
  - All others → `null`
- [x] Instanced rendering procs loaded: `drawArraysInstanced`, `drawElementsInstanced`, `vertexAttribDivisor`

#### 4.6 — Swap and Present
- [x] `SDL_GL_SwapWindow` called at end of each frame in `webview_run` main loop (already present since Phase 1)

#### 4.7 — GLSL ES → Desktop GLSL 3.30 Preprocessing
- [x] `shaderSource` auto-converts WebGL GLSL ES to desktop GLSL 3.30 Core:
  - Strips `precision mediump/highp/lowp float/int;` lines
  - Adds `#version 330 core` header
  - Converts `attribute`→`in`, `varying`→`in`/`out`, `gl_FragColor`→output variable
  - Converts `texture2D()`→`texture()`, `textureCube()`→`texture()`

### WebGL API Methods Implemented (~70 functions)

| Category | Methods |
|---|---|
| State | viewport, clearColor, clear, enable, disable, blendFunc, blendFuncSeparate, blendEquation, blendEquationSeparate, blendColor, depthFunc, depthMask, depthRange, clearDepth, cullFace, frontFace, scissor, lineWidth, colorMask, stencilFunc, stencilFuncSeparate, stencilOp, stencilOpSeparate, stencilMask, stencilMaskSeparate, clearStencil, pixelStorei, flush, finish |
| Shaders | createShader, deleteShader, shaderSource, compileShader, getShaderParameter, getShaderInfoLog, createProgram, deleteProgram, attachShader, detachShader, linkProgram, getProgramParameter, getProgramInfoLog, useProgram, validateProgram |
| Attributes | getAttribLocation, bindAttribLocation, enableVertexAttribArray, disableVertexAttribArray, vertexAttribPointer, getActiveAttrib, getActiveUniform |
| Uniforms | getUniformLocation, uniform[1234][fi], uniform[1234][fi]v, uniformMatrix[234]fv |
| Buffers | createBuffer, deleteBuffer, bindBuffer, bufferData, bufferSubData |
| Textures | createTexture, deleteTexture, bindTexture, activeTexture, texImage2D, texSubImage2D, texParameteri, texParameterf, generateMipmap |
| Framebuffers | createFramebuffer, deleteFramebuffer, bindFramebuffer, framebufferTexture2D, framebufferRenderbuffer, checkFramebufferStatus |
| Renderbuffers | createRenderbuffer, deleteRenderbuffer, bindRenderbuffer, renderbufferStorage |
| Drawing | drawArrays, drawElements, drawArraysInstanced, drawElementsInstanced, vertexAttribDivisor |
| Reading | readPixels |
| Query | getError, isEnabled, getParameter, getExtension, getShaderPrecisionFormat, isContextLost |

---

## Phase 5 — Canvas 2D (Text Rendering) ✅ COMPLETE

**Goal:** `ctx.fillText()` and `ctx.measureText()` work correctly for RPG Maker MV's `Window_Base`.

RPG Maker MV uses Canvas 2D only for UI text overlaid on the WebGL canvas.
The game font is bundled as a TTF under `fonts/`.

### Strategy

Canvas 2D operations here go through SDL3_ttf for text and a CPU-side pixel
buffer for geometry. Workflow:
1. Create an OpenGL texture as the offscreen framebuffer for the 2D canvas
2. Use SDL3_ttf to render glyphs into an SDL_Surface, then upload to GL texture
3. Blit the result with `gl.texImage2D`

For `clearRect`, `fillRect`, and gradient operations, implement simple CPU-side
pixel operations on a `uint8` buffer, then upload to GL.

### Tasks

- [x] SDL3_ttf FFI bindings (inline in rwebview.nim):
  - `TTF_Init`, `TTF_Quit`
  - `TTF_OpenFont(path, ptsize)` → font handle
  - `TTF_CloseFont(font)`
  - `TTF_RenderText_Blended(font, text, fg)` → SDL_Surface with RGBA pixels
  - `TTF_GetStringSize(font, text, w, h)` → pixel dimensions (for `measureText`)
- [x] Font loading: `parseCssFont()` parses CSS font shorthand, `getOrLoadFont()`
  searches `fonts/` with case-insensitive matching, caches in `ttfFontCache`
- [x] `ctx.fillText(text, x, y)`: TTF_RenderText_Blended → SDL_ConvertSurface(RGBA32)
  → alpha-blended blit into CPU pixel buffer, with textAlign/textBaseline adjustment
  and transform matrix application
- [x] `ctx.measureText(text)`: TTF_GetStringSize → `{ width: <pixel_width> }`
- [x] CPU-side pixel buffer drawing ops:
  - `ctx.clearRect(x, y, w, h)` — zeroes RGBA pixels
  - `ctx.fillRect(x, y, w, h)` — fills with fillStyle + alpha blending
  - `ctx.drawImage(source, ...)` — 3/5/9-arg forms, nearest-neighbor scaling
  - `ctx.getImageData()` / `ctx.putImageData()` — pixel data access
  - `texImage2D` 6-arg path reads canvas pixels via `__ctxId`
- [x] `ctx.save()` / `ctx.restore()` via `Canvas2DSavedState` stack
  (font, fillStyle, globalAlpha, textAlign, textBaseline, transform matrix)
- [x] Transform: `translate`, `rotate`, `scale`, `setTransform`, `resetTransform`
  — 3x2 affine matrix applied to fillText positions
- [x] Stubs: `createLinearGradient`, `createRadialGradient`, `createPattern` (return
  objects with `addColorStop`), path ops (beginPath/closePath/moveTo/lineTo/arc/etc)
- [x] Property setters via Object.defineProperty: font, fillStyle, globalAlpha,
  textBaseline, textAlign, strokeStyle, lineWidth, etc.
- [x] `parseCssColor()`: handles #RGB, #RRGGBB, #RRGGBBAA, rgb(), rgba(), named colors

---

## Phase 6 — Asset Loading (XHR / Fetch / Image) ✅ COMPLETE

**Goal:** RPG Maker MV can load all its PNG, JSON, OGG, and data files.

### Strategy

All assets are local files. Implement a virtual URL scheme:
- `http://rover.assets/<path>` → `baseDir/<path>` (matches Rover's VirtualHost convention)

### Tasks

#### 6.1 — XMLHttpRequest
- [x] Implement `XMLHttpRequest` as a QuickJS class:
  - `xhr.open(method, url)` — store method and resolve url to local path
  - `xhr.send()` — read file synchronously in Nim, fire `onload` in next JS tick
  - `xhr.response`, `xhr.responseText` — string or ArrayBuffer based on `responseType`
  - `xhr.responseType` — `""` (text), `"arraybuffer"`, `"json"`
  - `xhr.status = 200` (always, for local files that exist; 404 otherwise)
  - `xhr.onload`, `xhr.onerror`, `xhr.onreadystatechange` callbacks
  - `xhr.overrideMimeType()` — no-op stub
  - `xhr.setRequestHeader()` / `xhr.getResponseHeader()` — no-op stubs

#### 6.2 — Fetch API
- [x] Implement `fetch(url)` as a QuickJS async function:
  - Resolve URL → local file path
  - Read file bytes in Nim
  - Return a `Response`-like object with:
    - `response.ok = true`, `response.status = 200`
    - `response.text()` → `Promise<string>`
    - `response.json()` → `Promise<any>` (via `JSON.parse`)
    - `response.arrayBuffer()` → `Promise<ArrayBuffer>`
    - `response.blob()` → stub returning a Blob-like object

#### 6.3 — Image Decoding
- [x] Write Nim FFI to SDL3_image:
  - `IMG_Load(filename)` → SDL_Surface (auto-detects PNG/JPEG/BMP/GIF)
  - `SDL_ConvertSurface(surface, SDL_PIXELFORMAT_RGBA32)` → normalise all formats to RGBA
  - `SDL_DestroySurface(surface)` → free after uploading to GL
- [x] On `img.src = url` assignment:
  1. Resolve URL → local path
  2. Decode via `IMG_Load` synchronously
  3. Store RGBA pixel data as `__pixelData` ArrayBuffer + width/height on JS image object
  4. Fire `img.onload` immediately
  5. If file not found or decode fails, fire `img.onerror`

#### 6.4 — Blob & URL.createObjectURL
- [x] `URL.createObjectURL(blob)` — return a dummy `blob:rwebview/<id>` string
- [x] `URL.revokeObjectURL(url)` — no-op stub
  (RPG Maker video playback uses this; stub is sufficient for non-video features)

---

## Phase 7 — Web Audio API ✅ COMPLETE

**Goal:** Background music and sound effects play correctly.

RPG Maker MV uses `AudioContext.decodeAudioData` for its audio engine.
Audio files are OGG (primary) and optionally M4A.

### Why SDL_sound instead of SDL_mixer

SDL_mixer provides a fixed-channel game audio model (music channel + N SFX
channels) that cannot implement the Web Audio API’s node-graph architecture.
The Web Audio API requires:
- Decoded raw PCM buffers (`AudioBuffer`) that flow through a programmable graph
- Arbitrary node chaining: `BufferSourceNode → GainNode → AnalyserNode → destination`
- Per-sample control for `AudioParam` automation (volume ramps, pitch shifts)

SDL_sound is **decode-only**: it converts audio files (OGG, MP3, WAV, FLAC, AU, AIFF)
into raw PCM float32 samples. Our code mixes those samples using a push-based
SDL3 audio stream — exactly how browser engines implement WebAudio internally.

### Audio Architecture

```
AudioContext.decodeAudioData(arrayBuffer)
  → SDL_sound: Sound_NewSampleFromMem + Sound_Decode_All
    → raw float32 PCM stored in AudioBuffer.channelData[n]
       ↓
AudioBufferSourceNode.start()  → pushed onto an active-node queue
     ↓ (per-frame, called from the main loop)
Nim software mixer: iterate active nodes, apply GainNode factor, sum samples
  → SDL3: SDL_PutAudioStreamData(stream, mixed_buf, len)
    → SDL3 audio device → speakers
```

### Tasks

#### 7.1 — SDL3 Audio Device Setup
- [x] Write Nim FFI for SDL3 audio:
  - `SDL_OpenAudioDevice(devid, spec)` → audio device handle
  - `SDL_CreateAudioStream(src_spec, dst_spec)` → resampling/format-conversion stream
  - `SDL_PutAudioStreamData(stream, buf, len)` → push PCM frames into the stream
  - `SDL_BindAudioStream(devid, stream)` → connect stream to the audio device
  - `SDL_CloseAudioDevice(devid)`

#### 7.2 — SDL_sound Integration
- [x] Write Nim FFI to SDL_sound (`bin/include/SDL3_sound/SDL_sound.h`):
  - `Sound_Init()` / `Sound_Quit()`
  - `Sound_NewSampleFromMem(buf, buflen, ext, desired)` → `Sound_Sample*` from ArrayBuffer bytes
  - `Sound_NewSampleFromFile(fname, desired, bufsize)` → `Sound_Sample*` from file path
  - `Sound_DecodeAll(sample)` → fully decode the source into `sample->buffer` (float32 PCM)
  - `Sound_FreeSample(sample)` / `Sound_GetDuration(sample)`
  - Set `desired.format = SDL_AUDIO_F32` — matches WebAudio’s `Float32Array` exactly

#### 7.3 — AudioContext.decodeAudioData Bridge
- [x] Implement `AudioContext.decodeAudioData(arrayBuffer, successCb, errorCb)`:
  1. Extract raw bytes from the QuickJS `ArrayBuffer` via `JS_GetArrayBuffer`
  2. Call `Sound_NewSampleFromMem` with `desired.format = SDL_AUDIO_F32`
  3. Call `Sound_Decode_All` to fully decode the audio into PCM
  4. Wrap result in an `AudioBuffer` QuickJS object:
     - `audioBuffer.sampleRate` → `sample->actual.rate`
     - `audioBuffer.numberOfChannels` → `sample->actual.channels`
     - `audioBuffer.length` → total sample frames decoded
     - `audioBuffer.getChannelData(n)` → `Float32Array` view into the decoded PCM
  5. Fire `successCb(audioBuffer)` in the next JS tick via a QuickJS promise resolve

#### 7.4 — Nim Software Mixer
- [x] Implement a per-frame audio push loop (`mixAudioFrame()` called each frame):
  - Maintain a list of active `AudioBufferSourceNode` handles
  - For each active node: read the next N frames from its `AudioBuffer` PCM data
  - Apply `GainNode.gain.value` as a scalar multiplier on each sample
  - Sum all active nodes’ samples into a single float32 mix buffer
  - Push the mix buffer to SDL3: `SDL_PutAudioStreamData(stream, mix_buf, len)`
  - Advance each node’s playback cursor; fire `source.onended` and remove on completion

#### 7.5 — Audio Graph Nodes
- [x] Implement `AudioBufferSourceNode`:
  - `source.buffer = audioBuffer` → stores the decoded AudioBuffer reference
  - `source.connect(gainNode)` → links to gain for mixer volume control
  - `source.start(when, offset)` → sets playback cursor to `offset * sampleRate`
  - `source.stop()` → stops playback in the mixer
  - `source.loop`, `source.loopStart`, `source.loopEnd` → cursor wraps at loop points
  - `source.onended` → fire JS callback when the cursor reaches the end of the buffer
  - `source.playbackRate` AudioParam
- [x] Implement `GainNode`:
  - `gainNode.gain.value` (0.0–1.0) → applied by the Nim mixer as a per-sample multiplier
  - `gainNode.connect(destination)` → chain the gain to another node or to the output
- [x] `AudioContext.createBufferSource()` → returns a new `AudioBufferSourceNode`
- [x] `AudioContext.createGain()` → returns a new `GainNode`
- [x] `AudioContext.destination` → represents the SDL3 audio stream sink
- [x] `AudioContext.currentTime` → tracked by mixer frame count / sampleRate
- [x] `AudioContext.resume()` / `suspend()` / `close()` lifecycle
- [x] Stubs: `createOscillator()`, `createDynamicsCompressor()`

---

## Phase 8 — Storage (localStorage) ✅ COMPLETE

**Goal:** `localStorage.setItem` / `getItem` persist game saves across sessions.

### Tasks

- [x] Choose a storage file path: `<baseDir>/rwebview_localStorage.json`
- [x] At startup, load the JSON file into an in-memory `OrderedTable[string, string]`
- [x] Implement the `localStorage` object in QuickJS:
  - `setItem(key, value)` → update in-memory table, write JSON file immediately
  - `getItem(key)` → return value or `null`
  - `removeItem(key)` → delete from table, write JSON file
  - `clear()` → empty table, write JSON file
  - `length` → table size
  - `key(index)` → return key at numeric index (iterates insertion order)
- [x] Write JSON file atomically: write to `.tmp` then `rename` (prevents corruption
  on power loss or crash)

---

## Phase 9 — Rover Integration ✅ COMPLETE

**Goal:** `rover.nim` uses `rwebview` in place of the OS-native webview backend.

### Architecture (already implemented as of March 2026)

The integration is **not** a switch in `rover.nim`. Instead:

- `rwebview.nim` exports the **same C ABI** as `webview.cc`:
  `webview_create`, `webview_destroy`, `webview_run`, `webview_eval`, `webview_init`,
  `webview_navigate`, `webview_set_html`, `webview_bind`, `webview_unbind`,
  `webview_return`, `webview_set_title`, `webview_set_size`, `webview_get_window`,
  `webview_set_virtual_host_name_to_folder_mapping`, `webview_open_devtools`,
  `webview_get_saved_placement`, `webview_terminate`, `webview_dispatch`
  — all marked `{.exportc, cdecl.}`.

- `src/webview.nim` already imports these via `importc`. The **only change** needed
  was adding a `when defined(rwebview):` guard at the top of `webview.nim` that
  replaces `{.compile: webview.cc.}` with `{.compile: rwebview.nim.}`.

- `src/rover.nim` is **unchanged**. No `import` changes, no proc name changes.

### Implementation (as of March 2026)

- [x] Implement `webview_navigate`: parse `http://rover.assets/<path>` →
  resolve to local filesystem path → Lexbor parse HTML → QuickJS execute scripts
- [x] Implement `webview_init`: queue JS for injection before first script run
- [x] Implement `webview_bind` / `webview_return`: full QuickJS Promise channel
  wiring Rover's 33 native bindings (`fs_read_file`, `exit_app`, etc.) to JS
- [x] `w.init(preamble + polyfill)` works: queued strings injected before page scripts
- [x] Virtual host mapping: `webview_set_virtual_host_name_to_folder_mapping`
  resolves `http://rover.assets/<path>` → `baseDir/<path>` in XHR/fetch layer

### webview_bind / webview_return Architecture

```
Nim: webview_bind(w, "funcName", cb, arg)
  → stores BindingEntry{fn=cb, arg} in state.bindings["funcName"]
  → evals JS: window.funcName = function(...){return new Promise(...)}

JS: window.funcName(args...)  →  Promise<result>
  → JS glue creates UUID id, stores {resolve,reject} in __rw_calls[id]
  → calls native __rw_native_call("funcName", id, JSON.stringify(args))

Nim: rwNativeCallImpl dispatches to cb(id, req, arg)
  → cb does work, calls webview_return(w, id, 0, resultJson)

webview_return  →  evals __rw_resolve(id, 0, resultJson)
  → looks up __rw_calls[id], calls resolve(JSON.parse(resultJson))
  → JS Promise resolves with the result
```

**rebindBindings** is called at the start of every `navigateImpl` to re-inject
`__rw_calls`, `__rw_resolve`, and all `window.funcName` glue, because
`dom_preamble.js` rebuilds the `window` object on each page load.

---

## Phase 10 — RPG Maker MV Testing ✅ COMPLETE

**Goal:** The sample game in `rpg_maker/` loads and is interactive end-to-end.

### Test Checkpoints

- [x] **T1** — Splash screen renders: Pixi.js initializes without JS exceptions
- [x] **T2** — Title screen renders: game font loads, menu text is visible
- [x] **T3** — Input works: arrow keys navigate the title menu
- [x] **T4** — New game starts: map loads, character sprite visible
- [x] **T5** — Walking works: character moves on map with correct tile rendering
- [ ] **T6** — Battle works: encounter screen, sprites, and attack animations render
- [x] **T7** — Save works: `localStorage.setItem` writes data; data survives restart
- [x] **T8** — BGM plays: background music starts on title screen
- [x] **T9** — SE plays: menu cursor sound effects play at correct pitch
- [ ] **T10** — No console errors: `console.error` / `console.warn` output from game scripts is zero

### Bugs Found & Fixed During Testing

| Bug | Root Cause | Fix |
|---|---|---|
| Stack overflow crash | `patchMouseCoords` IIFE called `setTimeout` → wrapped `window.setTimeout` → infinite recursion | Removed JS patch; handle coords natively in Nim |
| Canvas full-stretch (no letterbox) | `glViewport(0,0,winW,winH)` filled entire window | Computed `scale=min(winW/gameW, winH/gameH)`, centered viewport, clear black borders |
| Mouse not clicking | `canvas.offsetLeft` was `undefined` → `pageX - undefined = NaN` → `isInsideCanvas(NaN,NaN) = false` | Added `offsetLeft/offsetTop` to elements; smart `style.marginLeft` setter |
| Parallax scroll wrong | Pattern tiling ignored canvas CTM | Applied inverse CTM to pattern source coordinates |
| Stroke outline invisible | `strokeText` ignored `strokeA` alpha | Applied `strokeA` to outline blending |
| copCopy drawImage slow | Per-pixel copy loop | Replaced with `copyMem` fast path |
| copDestinationIn transparency | Transparent source pixels left dest unchanged | Zero alpha on dest where source is transparent |
| PannerNode crash | Missing PannerNode stub | Added passthrough stub with connect/disconnect |
| Alpha blending artifacts | Incorrect alpha composition formula | Fixed to standard Porter-Duff source-over |
| Audio OGG detection | File extension detection failed | Improved format sniffing logic |
| Rain/snow particles too large | `drawImage` AABB used as rendered dimensions for rotated sprites | Added affine-sampled drawImage path with inverse CTM mapping |
| Mouse coordinate offset | `canvas.offsetLeft/Top` not synced with letterbox viewport origin | Added `style.margin/width/height` interceptors with `_recalcOffset()` |
| Windowskin too transparent | Canvas2D compositing path corrupted PIXI's cached blend state before `gWebGLActive` was set | Set `gWebGLActive = true` in `initDrawingBuffer()` after FBO creation, eliminating the canvas2D fallback path |
| SE pitch shift | `jsAudioDecode` stored `sample.actual.freq` (raw codec rate) but `sample.buffer` contains data at `desired.freq` (44100 Hz) after SDL_sound conversion | Use desired spec values (`AUDIO_SAMPLE_RATE`, `AUDIO_CHANNELS`) for deinterleaving and mixing |
| Viewport clipped at non-default window size | FBO created at window size, not game canvas size; letterbox used FBO dimensions | Added `__rw_resizeDrawingBuffer` native function; canvas width/height setters resize FBO to match game resolution |

### Debugging Approach

- `console.log` → `stdout` (active since Phase 1)
- `JS_IsException` check on every `JS_Eval` — errors printed, never silently swallowed
- Native F2 overlay: press F2 in-game for FPS + resolution + GPU name display
- SDL3 debug: compile with `SDL_HINT_LOGGING = "all"` for verbose output

---

## Phase 11 — Unified Font Stack (Fonstash for Canvas2D + UI) ✅ COMPLETE

**Goal:** Eliminate dual FreeType2 backends; use fonstash as the **unified font rendering engine** for both Canvas 2D text and NanoVG UI text.

### Problem Statement

**Current Architecture (Fragmented):**
```
Canvas2D fillText()    →  SDL3_ttf.dll  →  FreeType2 instance #1
NanoVG nvgText()       →  fonstash      →  FreeType2 instance #2
                                             ^^^ MEMORY DUPLICATION
                                                 MAINTENANCE BURDEN
```

**Issues:**
- Two separate FreeType2 runtime instances (memory overhead)
- Two independent font managers (complexity, potential bugs)
- SDL_ttf API for Canvas2D (`TTF_RenderText_Blended`, `TTF_GetStringSize`)
- fonstash API for UI (glyph iteration, atlas management)
- Synchronization challenges if fonts need to be shared or preloaded
- Both libraries call FreeType2 `FT_Load_Glyph` independently (cache miss overhead)

**Why this matters:**
- **Memory:** Each FreeType2 instance allocates face caches, glyph slot buffers, and hinting structures. Duplication wastes ~500 KB for a game using 2-3 fonts.
- **Performance:** No shared glyph cache — same glyph may be rasterized twice at different sizes.
- **Maintainability:** Canvas2D refactors must coordinate with NanoVG/UI changes to avoid font inconsistencies.

### Solution: Unified Fonstash Backend

**New Architecture (Unified):**
```
Shared Layer: c_src/rwebview_fonstash_core.c
    ▲
    │
    ├─ Canvas2D fillText()   → fonsRenderText()
    ├─ Canvas2D measureText() → fonsTextBounds()
    └─ NanoVG nvgText()      → fonsTextIter() + nvgRenderQuad()
    
Single FreeType2 instance
Unified glyph atlas
Unified font cache
```

**Benefits:**
- ✅ Single FreeType2 instance (unified caching, better performance)
- ✅ Single glyph atlas (reuse glyph positions across Canvas2D + UI)
- ✅ Unified font loading (consistent behavior, preload once)
- ✅ Simpler maintenance (one rendering pipeline, not two)
- ✅ Smaller binary (potential DLL savings if fonstash replaces SDL_ttf for Canvas2D role)

### SDL_ttf Features Canvas2D Currently Uses

Canvas2D (`rwebview_canvas2d.nim`) currently calls:

| SDL3_ttf Function | Purpose | Fonstash Equivalent |
|---|---|---|
| `TTF_Init()` | Initialize TTF subsystem | `fonsCreateInternal()` in core (single call, not per-font) |
| `TTF_Quit()` | Cleanup TTF subsystem | `fonsDeleteInternal()` in core (shutdown) |
| `TTF_OpenFont(path, size)` | Load font file at given size, return handle | `fonsAddFont(fontCtx, name, path, 0)` → font ID |
| `TTF_CloseFont(font)` | Free font handle | *(implicit; fonstash manages lifetime internally)* |
| `TTF_RenderText_Blended(font, text, fg_color)` | Render glyph string to RGBA SDL_Surface | `fonsTextIterInit()` + `fonsTextIterNext()` → iterate quads, then custom CPU rasterizer to Canvas2D pixel buffer |
| `TTF_GetStringSize(font, text, &w, &h)` | Measure text dimensions in pixels | `fonsTextBounds(fontCtx, 0, 0, text, NULL, bounds)` → bounds[2]-bounds[0] = width, bounds[3]-bounds[1] = height |
| `TTF_SetFontSize()` | Dynamic font size (per-render) | `fonsSetSize(fontCtx, size)` (state, not per-font) |

### Fonstash API Contract for Canvas2D

For Canvas2D to adopt fonstash, **rwebview_fonstash_core.c** must export these functions:

```c
// Initialization (called once at startup)
FONScontext* rw_fons_create(int atlasWidth, int atlasHeight, int flags);
void rw_fons_destroy(FONScontext* ctx);

// Font management (called during canvas init or @font-face parsing)
int rw_fons_add_font(FONScontext* ctx, const char* name, const char* path);
int rw_fons_get_font(FONScontext* ctx, const char* name);

// Rendering state (Canvas2D must set these before each text op)
void rw_fons_set_size(FONScontext* ctx, float size);
void rw_fons_set_font(FONScontext* ctx, int fontId);
void rw_fons_set_align(FONScontext* ctx, int align);  // FONS_ALIGN_LEFT|CENTER|RIGHT | TOP|BASELINE|BOTTOM
void rw_fons_set_color(FONScontext* ctx, unsigned int rgba);  // 0xRRGGBBAA

// Text metrics (for Canvas2D measureText)
float rw_fons_text_bounds(FONScontext* ctx, float x, float y, const char* string, const char* end, float* bounds);
    // bounds[4] = {xmin, ymin, xmax, ymax}
    // width = bounds[2] - bounds[0]
    // height = bounds[3] - bounds[1]

// Glyph iteration (for Canvas2D fillText with custom CPU pixel rendering)
int rw_fons_text_iter_init(FONScontext* ctx, FONStextIter* iter, float x, float y, const char* str, const char* end);
int rw_fons_text_iter_next(FONScontext* ctx, FONStextIter* iter, FONSquad* quad);
    // quad.x0, quad.y0, quad.x1, quad.y1 = glyph screen coords
    // quad.s0, quad.t0, quad.s1, quad.t1 = atlas UV coords
    // Caller blits glyph from atlas texture to Canvas2D pixel buffer using UV coords

// Atlas access (for Canvas2D to fetch glyph pixels when needed)
const unsigned char* rw_fons_get_atlas_data(FONScontext* ctx, int* width, int* height);
    // Returns RGBA pixel buffer of current glyph atlas
    // Canvas2D can read from this to implement fillText alpha blending
```

### Canvas2D Refactoring Plan

| Module | Change | Effort | Risk |
|---|---|---|---|
| `getOrLoadFont()` | Replace `TTF_OpenFont()` → `fonsGetFont()` | Low (1 call site) | Low (same return type handling) |
| `fillText()` | Replace `TTF_RenderText_Blended()` → iterate `fonsTextIterNext()` quads, blit from atlas to Canvas2D buffer | Medium (custom glyph fetch logic) | Medium (atlas UV mapping) |
| `measureText()` | Replace `TTF_GetStringSize()` → `fonsTextBounds()` | Low (1 call, similar API) | Low (bounds array indexing) |
| `ttfFontCache` | Unified with fonstash internal cache | Low (remove table) | Low (lookup via `fonsGetFont` ID) |
| `ttfInitialized` | Removed (fonstash context lifetime managed by core) | Low (simplify startup) | Low |

**Total effort:** ~200-250 lines refactored, ~3-5 days including testing.

### UI (rwebview_ui.nim) — No Changes

NanoVG's fonstash integration (already proven working) requires zero changes. The shared fonstash context created in `rwebview_fonstash_core.c` will be transparently used by both:
1. Canvas2D (via `rw_fons_*` wrappers)
2. NanoVG (via direct fonstash API, as today)

### Implementation Checklist

- [ ] Create `c_src/rwebview_fonstash_core.c`
  - [ ] Wrap `fonsCreateInternal()` with NanoVG rendering callbacks
  - [ ] Export `rw_fons_*` functions listed above
  - [ ] Manage singleton FONScontext lifetime (init at startup, cleanup at exit)
  - [ ] Add error logging for atlas full / scratch buffer full

- [ ] Create Nim bindings in `rwebview_canvas2d.nim`
  - [ ] Import `rw_fons_*` C functions via `importc`
  - [ ] Refactor `getOrLoadFont()` to call `rw_fons_add_font()` and cache font IDs
  - [ ] Refactor `fillText()` to use `rw_fons_text_iter_init()` + `rw_fons_text_iter_next()`
  - [ ] Implement custom glyph blitting from atlas UV coords to Canvas2D pixel buffer (respecting alpha, composition ops, transforms)
  - [ ] Refactor `measureText()` to use `rw_fons_text_bounds()`

- [ ] Test integration
  - [ ] Verify RPG Maker MV text rendering unchanged (visual regression test)
  - [ ] Verify rwebview_ui.nim NanoVG text unchanged
  - [ ] Memory profiler: confirm single FreeType2 instance
  - [ ] Performance profiler: measure glyph cache hit rate improvement

- [ ] Update AI-README.md §7.4
  - [ ] Change "nanovg.c (font rendering): stb_truetype" → "**shared fonstash layer**"
  - [ ] Remove stb_truetype from dependency table
  - [ ] Document unified architecture

### Why NOT Use SDL_ttf Adapter Instead?

This was initially considered but rejected:

**Adapter approach (avoid):**
```
Canvas2D fillText() →  SDL_ttf adapter  →  fonstash  →  FreeType2
                         (extra layer,     (still 1     (shared)
                          overhead)         instance)
```

**Problems with adapter:**
- Adds wrapper function call overhead per glyph (extra stack frame, indirection)
- No architectural benefit — two layers instead of one, solving same problem
- Increases maintenance burden (three function-call boundaries: Canvas2D → adapter → fonstash)
- NanoVG still uses fonstash directly; adapter doesn't unify anything

**Direct refactor (chosen):**
```
Canvas2D fillText() →  fonstash API directly  →  FreeType2 (shared)
NanoVG nvgText()   →  fonstash API directly  →
```

No wrappers, same code path, simpler, faster, clearer intent.

---

## 15. API Compatibility Checklist

Cross-reference this with `AI-README.md §5` to track coverage.
All specs are anchored to versions **ratified or widely adopted by 2020** (living standards
frozen at that snapshot). Newer additions (e.g. CSS Container Queries, WebGPU) are out of scope
for this checklist.

### 15.1 — Core Browser APIs

| Feature Group | W3C/WHATWG Spec | Phase | Status |
|---|---|---|---|
| `window.*` timers, rAF, events | HTML LS | 3 | ✅ Done (setTimeout, setInterval, rAF, onload, resize, keydown/keyup/mousedown/mouseup/mousemove/wheel/click) |
| `document.*` DOM | DOM LS | 3 | ✅ Done (getElementById, createElement, querySelector, body, head, documentElement, addEventListener, createTextNode) |
| `navigator.*` stubs | HTML LS | 3 | ✅ Done (userAgent, platform, language, maxTouchPoints, getGamepads stub) |
| `console.*` | Console Standard | 1 | ✅ Done (log/warn/error → stdout; info/debug → stdout) |
| `console.time/timeEnd/assert/trace` | Console Standard | — | ⬜ Not verified (mentioned in AI-README §5.1 but not in dom_preamble.js) |
| `HTMLCanvasElement` | HTML LS | 3+5 | ✅ Done (getContext '2d'/'webgl', width/height, toDataURL stub, offsetLeft/Top) |
| `HTMLImageElement` | HTML LS | 6 | ✅ Done (src=url → SDL_image decode → `__pixelData` + onload/onerror, naturalWidth/Height) |
| `HTMLAudioElement` | HTML LS | 7 | ⚠️ Stub only (`new Audio()` returns a no-op; Web Audio API is the primary path) |
| `HTMLVideoElement` | HTML LS | — | ⬜ Stub only — `play()`/`pause()` return resolved Promise, no decode |
| `HTMLInputElement` | HTML LS | — | ⬜ Stub only (value, type, onchange, onkeydown) |
| `HTMLMediaElement.canPlayType` | HTML LS | 7 | ✅ Done (OGG→"probably", M4A→"") |
| Canvas 2D API | HTML LS §4.12.5 | 5+10 | ✅ Done (clearRect, fillRect, drawImage, fillText, strokeText, measureText, save/restore, transforms, globalAlpha, globalCompositeOperation ×7, getImageData/putImageData, createLinearGradient, createPattern, arc+fill) |
| Canvas 2D path rasterizer | HTML LS §4.12.5 | — | ⬜ Path ops (beginPath/moveTo/lineTo/bezierCurveTo/quadraticCurveTo/arc) are stubs — `stroke()` and `fill()` do nothing. Needs a pure-C Bézier/fill library (e.g. **stb_truetype** scanline fill, or **nanosvg** rasterizer). |
| Canvas 2D: `clip()` | HTML LS | — | ⬜ Not implemented |
| Canvas 2D: `createImageBitmap` | HTML LS | — | ⬜ Not implemented (`createImageBitmap` → would reuse SDL_image decode) |
| Canvas 2D: `OffscreenCanvas` | HTML LS (2018) | — | ⬜ Not implemented |
| WebGL1 API | Khronos WebGL 1.0 | 4 | ✅ Done (~70 functions, 200+ constants, extensions, GLSL ES→Core preprocessing) |
| WebGL2 API | Khronos WebGL 2.0 (2017) | — | ⬜ Not implemented — `getContext('webgl2')` returns `null` intentionally; would require OpenGL 4.x proc loading and new binding surface |
| XMLHttpRequest | XHR LS | 6 | ✅ Done (open, send, responseType: text/arraybuffer/json, status, onload/onerror) |
| Fetch API | Fetch LS | 6 | ✅ Done (fetch → Response with text/json/arrayBuffer/blob methods) |
| Web Audio API | W3C WAA CR (2018) | 7 | ✅ Done (AudioContext, decodeAudioData, BufferSourceNode, GainNode, PannerNode stub, software mixer) |
| Web Audio: AnalyserNode | W3C WAA CR | — | ⬜ Not implemented (used by some visualisers; stub needed) |
| Web Audio: AudioWorklet | W3C WAA CR (2018) | — | ⬜ Not implemented (advanced; not required by RPG Maker) |
| localStorage | Web Storage LS | 8 | ✅ Done (setItem/getItem/removeItem/clear/length/key, atomic JSON file write) |
| sessionStorage | Web Storage LS | — | ⬜ Not implemented — in-memory table only, discarded on restart; easy to add as a `table` that is never persisted to disk |
| IndexedDB | W3C IDB 2.0 (2018) | — | ⬜ Not implemented. Required by PGlite and some Unity apps. Potential libraries: **idbfs** is JS-only; native side would need a key-value store such as **LMDB** (C, MDB backend) or **SQLite** (C). |
| KeyboardEvent, MouseEvent | UI Events W3C (2019) | 3+10 | ✅ Done (keydown/keyup with key/code/keyCode/which, mousedown/mouseup/mousemove/wheel/click with clientX/clientY/pageX/pageY/button/buttons/altKey/ctrlKey/shiftKey) |
| WheelEvent | UI Events W3C (2019) | 10 | ✅ Done (dispatched from `SDL_EVENT_MOUSE_WHEEL`) |
| TouchEvent | Touch Events W3C (2013) | — | ⬜ Not started. SDL3 finger events (`SDL_EVENT_FINGER_DOWN/UP/MOTION`) are available; need to map to `touches` / `changedTouches` arrays and dispatch `touchstart`/`touchend`/`touchmove`/`touchcancel` |
| Pointer Events | PE Level 2 W3C (2019) | — | ⬜ Stub only — `PointerEvent` constructor exists in `dom_preamble.js` but no SDL events are translated to `pointerdown`/`pointermove`/`pointerup`/`pointercancel`. SDL3 has no separate pointer-ID concept; mapping mouse→pointerId=1 is sufficient for most games |
| FocusEvent | UI Events W3C (2019) | 3 | ✅ Done (`SDL_EVENT_WINDOW_FOCUS_GAINED/LOST` → `focus`/`blur` on window) |
| CustomEvent | DOM LS | 10 | ✅ Done (`CustomEvent` constructor in `dom_preamble.js`) |
| Fullscreen API | Fullscreen LS (2018) | 10 | ⬜ Stubs only — `requestFullscreen()`, `exitFullscreen()`, `fullscreenElement`, `fullscreenchange` event not wired to SDL3 `SDL_SetWindowFullscreen` |
| Page Visibility API | W3C PR (2013) | 3 | ⚠️ Partial — `document.visibilityState='visible'` and `document.hidden=false` are hard-coded; not updated on SDL window focus/blur events |
| Screen Orientation API | W3C CR (2016) | 3 | ⚠️ Partial — `screen.orientation.type`/`angle` present; `lock()` is a no-op Promise stub |
| Pointer Lock API | W3C REC (2016) | — | ⬜ Not implemented. `element.requestPointerLock()` / `document.exitPointerLock()` absent. SDL3 provides `SDL_SetRelativeMouseMode()` — straightforward to wire up |
| History API | WHATWG HTML LS | 3 | ⚠️ Stub — `pushState`/`replaceState` are no-ops; `popstate` event never fired |
| MutationObserver | DOM LS | 3 | ⚠️ Stub — constructor + `observe`/`disconnect`/`takeRecords` present but callback never invoked |
| ResizeObserver | ResizeObserver W3C (2019) | 3 | ⚠️ Stub — `observe`/`unobserve`/`disconnect` present but callback never invoked |
| IntersectionObserver | IntersectionObserver W3C (2019) | — | ⬜ Not implemented (no stub). Many modern frameworks politely guard this with feature detection |
| Web Cryptography API | W3C REC (2017) | 3 | ⚠️ Partial — `crypto.getRandomValues` uses `Math.random` (insecure). `crypto.subtle` (SubtleCrypto: digest/sign/encrypt/generateKey etc.) not implemented. For a secure `getRandomValues`, call `SDL_rand_bits()` or `BCryptGenRandom` (Windows) |
| TextDecoder / TextEncoder | Encoding LS (WHATWG 2014) | — | ⬜ Not implemented. QuickJS does not expose these globally. Needed by some Emscripten outputs and Unity WebGL. Pure-JS polyfill available as a fallback |
| AbortController / AbortSignal | DOM LS (2018) | — | ⬜ Not implemented. Required by modern `fetch()` usage patterns. Can be pure-JS stub |
| `queueMicrotask` | HTML LS (widely adopted 2018–19) | — | ⬜ Not implemented. QuickJS microtask queue is internal; `queueMicrotask(fn)` can be exposed via `JS_EnqueueJob` or shim as `Promise.resolve().then(fn)` |
| `requestIdleCallback` | HTML LS (Chrome-origin, 2016) | — | ⬜ Not implemented. Shim as `setTimeout(fn, 0)` is sufficient for most use cases |
| Blob / File API | W3C WD (2019) | 6 | ⚠️ Partial — `Blob` constructor is a no-op stub; `FileReader` not implemented. `URL.createObjectURL(blob)` returns a dummy string |
| FileReader | W3C WD (2019) | — | ⬜ Not implemented. Required for apps that read user-selected files |
| Streams API | WHATWG Streams LS (stable 2019) | — | ⬜ Not implemented (`ReadableStream`, `WritableStream`, `TransformStream`). Some Emscripten / modern fetch users expect these |
| Clipboard API | W3C WD (2019) | — | ⬜ Not implemented. `navigator.clipboard.writeText()`/`readText()` absent. SDL3 provides `SDL_SetClipboardText()` / `SDL_GetClipboardText()` — straightforward to wire up |
| Gamepad API | W3C WD (2020) | — | ⬜ Stub only (`navigator.getGamepads()` returns empty array). SDL3 has `SDL_EVENT_GAMEPAD_*` events and `SDL_GetGamepads()`. Mapping to `Gamepad` objects (id/index/buttons/axes) is well-defined |
| `btoa` / `atob` | HTML LS | — | ⬜ Not verified present in QuickJS global scope. Must add to window if absent |
| performance.now | HR Time L2 W3C (2019) | 3 | ✅ Done → `SDL_GetTicks64()` milliseconds |
| performance.mark/measure | User Timing L2 W3C (2019) | — | ⬜ Not implemented. Stubs sufficient for most apps |
| `EventSource` (SSE) | HTML LS | — | ⬜ Not implemented. Not relevant for local-file apps |
| `WebSocket` | WHATWG Fetch LS + RFC 6455 | — | ⬜ Not implemented. Out of scope for offline apps |
| `Worker` (Web Worker) | HTML LS | — | ⬜ Stub only — constructor returns a fake object with `postMessage`/`terminate`. Actual threading would require a second QuickJS runtime in a background thread or use of SDL3 thread API |
| `SharedArrayBuffer` | TC39 / HTML LS | — | ⬜ Not implemented |
| `DOMParser` | DOMParser W3C | — | ⬜ Not implemented. `new DOMParser().parseFromString(html,'text/html')` is used by jQuery and some plugins. Could delegate to Lexbor. |
| `XMLSerializer` | DOM LS | — | ⬜ Not implemented |
| CSS Variables (custom properties) | CSS Custom Props W3C (2015) | 11 | ⬜ Future (Phase 11) |
| CSS Box Model / Display | CSS2.1 + CSS3 | 11 | ⬜ Future (Phase 11) |
| `<link rel="stylesheet">` | HTML LS | 11 | ⬜ Future (Phase 11) |
| `<style>` tag parsing | HTML LS + CSS LS | 11 | ⬜ Future (Phase 11) |
| Typed Arrays (BufferView) | Khronos + TC39 | 4 | ✅ (QuickJS built-in + `jsGetBufferData` helper for GL calls) |
| Promise / async-await | TC39 ES2017 | — | ✅ (QuickJS built-in) |
| JSON, Math, Date, Array, String | TC39 ES2019 | — | ✅ (QuickJS built-in) |
| `Symbol`, `WeakMap`, `WeakSet`, `Map`, `Set` | TC39 ES2015 | — | ✅ (QuickJS built-in) |
| `Proxy`, `Reflect` | TC39 ES2015 | — | ✅ (QuickJS built-in) |
| ES modules (`import`/`export`) | TC39 ES2015 | — | ⚠️ Treated as regular script (warning logged); async dynamic `import()` is not wired up |
| `for…of`, generators, iterators | TC39 ES2015 | — | ✅ (QuickJS built-in) |
| BigInt | TC39 ES2020 | — | ✅ (QuickJS built-in) |
| ImageData | HTML LS | 5 | ✅ Done (getImageData/putImageData, `new ImageData(w,h)`) |
| URL / URLSearchParams | URL LS | — | ✅ (QuickJS built-in; custom `_URL` in `dom_preamble.js` fills gaps) |
| WebAssembly (`WebAssembly.*` JS API) | W3C WebAssembly Core 1.0 (2019) | 12 | ⬜ Future (Phase 12) |

### 15.2 — Canvas 2D Path Rasterizer Gap (detail)

`beginPath`, `moveTo`, `lineTo`, `arc`, `bezierCurveTo`, `quadraticCurveTo`, `closePath`,
`stroke`, `fill`, `clip` — **all currently stubs** in `rwebview_canvas2d.nim`.
For RPG Maker MV and GDevelop these APIs are used for:
- Circle/arc drawing (health-bar borders, button outlines)
- Gradient-filled shapes overlaid on the WebGL canvas

Candidate C libraries for polygon/path rasterization:
| Library | Language | License | Notes |
|---|---|---|---|
| **nanosvg** (`nanosvgrast.h`) | C (single header) | zlib | Bezier + arc fill via scanline; already handles SVG paths |
| **stb_truetype** scanline fill | C (single header) | public domain | Rasterizes outlines from glyph contours; same algorithm usable for path fill |
| **sokol_shape** | C (single header) | zlib | Geometry primitives only — circles, boxes, no arbitrary paths |
| **Blend2D** | C++ | zlib | Banned (C++ — see `AI-README.md §2`) |
| **cairo** | C | LGPL | Large, but pure C; mature path rasterizer with Porter-Duff ops |

**Recommended:** `nanosvg` rasterizer — 2 single-header files, public domain, can rasterize
any SVG path → RGBA pixel buffer → upload to the existing Canvas 2D GL texture.

### 15.3 — Performance Fixes Applied

| Fix | Description |
|---|---|
| VSync FFI | `SDL_GL_SetSwapInterval` corrected to `(interval: cint)` — no window parameter (SDL3 API) |
| Frame limiter | `SDL_Delay`-based 60fps cap as fallback when VSync is unavailable |
| Audio queue-first | `mixAudioFrame()` checks `SDL_GetAudioStreamQueued` BEFORE mixing to prevent source position racing |
| Audio multi-chunk | `mixAudioFrame()` pushes up to 3 chunks per call to absorb frame-rate jitter and prevent underruns |
| Audio queue depth | `MIX_QUEUE_MAX_BYTES` increased to 4× chunk (~93ms) to eliminate crackling during frame drops |
| Discrete GPU | `NvOptimusEnablement` + `AmdPowerXpressRequestHighPerformance` exports force discrete GPU on hybrid laptops |
| GL attributes | `SDL_GL_DOUBLEBUFFER=1`, `SDL_GL_DEPTH_SIZE=24`, `SDL_GL_ACCELERATED_VISUAL=1` for hardware-accelerated rendering |
| Internal resolution | Canvas stays at fixed base resolution (e.g., 816×624); GL blit pipeline upscales with LINEAR filtering |
| Resizable window | `SDL_WINDOW_RESIZABLE` flag; `window.resize` event dispatched |
| Letterbox viewport | Aspect-ratio-preserving blit: `scale=min(winW/gameW, winH/gameH)`, centered, black bars |
| drawImage fast path | 1:1 blit (no scaling) with `copyMem` instead of per-pixel loop for `copy` composite mode |
| FPS tracking | Per-second frame counter exposed to native F2 overlay |
| GPU detection | `glGetString(GL_RENDERER/GL_VENDOR)` cached once for debug overlay |

---

## Phase 11 — HTML Element & CSS Layout Integration

**Goal:** rwebview can render a basic HTML UI page — `<div>`, `<p>`, `<span>`, `<button>`,
`<input>`, `<select>` — with CSS box-model layout and styled text. This phase focuses first
on **stub infrastructure** (elements render as visible placeholders) and then progressively
replaces stubs with real layout and paint.

This is not required for RPG Maker MV (which renders entirely on `<canvas>`), but is needed
for apps that mix DOM UI with canvas rendering — e.g. GDevelop's splash screen, Construct 3's
debug overlay, Unity WebGL's progress bar, or custom HTML5 apps run via Rover.

### Design Principles

1. **Lexbor parses; Clay lays out; SDL3 + existing Canvas 2D paints.**
   Do not build a full browser rendering engine. Map a useful subset of CSS
   (block / flex / absolute positioning) to Clay layout primitives, then
   paint each box using the CPU pixel buffer already present in `rwebview_canvas2d.nim`.
2. **CSS is best-effort.** Properties not understood by the layout engine are silently
   ignored. The goal is visual correctness for common patterns, not spec compliance.
3. **Lexbor CSS module replaces ad-hoc parsing.** Do not write a hand-rolled CSS parser —
   Lexbor already contains a production-grade CSS tokenizer and property set parser
   (`libs/lexbor/source/lexbor/css/`). The CSS module is compiled as part of the existing
   Lexbor static library build; no additional dependency is needed.
4. **All new rendering goes through the existing Canvas 2D GL blit pipeline** —
   the DOM paint buffer is just another CPU texture uploaded each frame over the WebGL
   back-buffer, identical to how Canvas 2D currently works.

### Library Map

| Role | Library | Language | License | Notes |
|---|---|---|---|---|
| HTML parsing | **Lexbor** (already present) | C | Apache-2.0 | Full DOM tree, not just script-tag extraction. Use `lxb_dom_*` APIs already wired in `rwebview_html.nim` |
| CSS parsing | **Lexbor CSS module** (already present) | C | Apache-2.0 | `lexbor/css/` tokenizer + property parser. Parse `<style>` tag content and inline `style=` attributes into `lxb_css_*` value objects |
| Layout engine | **Clay** (single-header C) | C | zlib | Flexbox-like layout. Maps to `display:flex`, `display:block`, `margin`, `padding`, `width`, `height`. Source: https://github.com/nicbarker/clay — **must be C only** per `AI-README.md §2` |
| Path rasterizer | **nanosvg** (single-header C) | C | zlib | `nanosvgrast.h` — fills Bézier/arc paths into RGBA buffer; replaces stubs for `beginPath/fill/stroke/clip` |
| Text rendering | **SDL3_ttf** (already present) | C | zlib | Already used for Canvas 2D `fillText`; reuse for HTML text nodes |
| Image rendering | **SDL3_image** (already present) | C | zlib | Already used; decode `<img src>` into `SDL_Surface` |
| GPU blit | **existing Canvas 2D GL pipeline** | Nim | — | CPU pixel buffer → OpenGL texture → fullscreen quad; no new GL code needed |

### Phase 11.1 — Lexbor Full DOM Walk (Stub Render)

- [ ] Extend `rwebview_html.nim` (`parseScripts`) so that the full Lexbor DOM tree is
  retained after script extraction instead of being immediately destroyed
- [ ] Walk the retained DOM tree and build a Nim `DomNode` tree mirroring:
  `tagName`, `id`, `className`, `style` attribute string, `textContent`, `children`
- [ ] Map each `DomNode` to a stub JS element object in QuickJS via `_makeElement(tag)`
  (already exists in `dom_preamble.js`) so runtime JS can call `getElementById` etc.
- [ ] For CSS `<style>` blocks: call Lexbor CSS parser (`lxb_css_parser_*`) and attach
  computed property structs to each matching DOM node
- [ ] For inline `style="..."`: parse via Lexbor CSS inline-style parser, attach to node
- [ ] Render loop stubs: draw each DomNode as a coloured `fillRect` using its
  `background-color` value; text nodes as `fillText` at computed position (block layout only)

### Phase 11.2 — Clay Flexbox Layout

> **Clay** (C, single-header) is a game-oriented **UI layout library** that computes
> element bounding boxes using a flexbox-style algorithm. It does not render; it outputs
> `Clay_RenderCommand` structs that tell the caller exactly what rectangle to draw where.
> This maps cleanly onto the existing Canvas 2D `fillRect` / `fillText` paint functions.

- [ ] Add Clay single-header (`clay.h`) to `libs/rwebview/libs/clay/`
  (https://github.com/nicbarker/clay — MIT/zlib licensed, pure C, single file)
- [ ] Write Nim FFI bindings for Clay:
  - `Clay_Initialize(memory, capacity)` — one-time setup with a fixed memory arena
  - `Clay_BeginLayout()` / `Clay_EndLayout()` → `Clay_RenderCommandArray`
  - `CLAY_CONTAINER`, `CLAY_TEXT`, `CLAY_RECTANGLE` macros (or equivalent Nim wrappers)
  - `Clay_Sizing`, `Clay_Padding`, `Clay_ChildAlignment` config structs
- [ ] CSS-to-Clay mapping:
  - `display:block` → `CLAY_CONTAINER` with `CLAY_LAYOUT(.sizing={GROW,FIT})`
  - `display:flex` → `CLAY_CONTAINER` with `layoutDirection=LEFT_TO_RIGHT/TOP_TO_BOTTOM`
  - `flex-direction`, `justify-content`, `align-items` → `Clay_ChildAlignment`
  - `width`/`height` in px → `CLAY_SIZING_FIXED`, in % → `CLAY_SIZING_PERCENT`
  - `min-width`/`max-width` → `Clay_Sizing.min`/`.max`
  - `margin`, `padding` in px → `Clay_Padding`
  - `position:absolute`/`fixed` → `CLAY_FLOATING` extension
- [ ] For each `Clay_RenderCommand`:
  - `CLAY_RENDER_COMMAND_TYPE_RECTANGLE` → `fillRect` / `strokeRect` on the CPU pixel buffer
  - `CLAY_RENDER_COMMAND_TYPE_TEXT` → `fillText` via SDL3_ttf (already implemented)
  - `CLAY_RENDER_COMMAND_TYPE_IMAGE` → `drawImage` (already implemented)
  - `CLAY_RENDER_COMMAND_TYPE_SCISSOR_START/END` → push/pop scissor region
  - `CLAY_RENDER_COMMAND_TYPE_BORDER` → `strokeRect`-style CPU pixel ops
- [ ] Upload the completed CPU pixel buffer to the existing Canvas 2D GL texture once per frame

### Phase 11.3 — Canvas Path Rasterizer (nanosvg)

- [ ] Add `nanosvg.h` + `nanosvgrast.h` to `libs/rwebview/libs/nanosvg/`
  (https://github.com/memononen/nanosvg — zlib/MIT, single-header, pure C)
- [ ] Write Nim wrapper for `NSVGrasterizer`:
  - `nsvgCreateRasterizer()` → rasterizer handle
  - `nsvgRasterize(rast, image, tx, ty, scale, dst, w, h, stride)` → rasterizes into RGBA buffer
- [ ] Replace Canvas 2D path stubs in `rwebview_canvas2d.nim`:
  - On each `moveTo`/`lineTo`/`bezierCurveTo`/`quadraticCurveTo`/`arc`/`closePath`:
    accumulate path data into an in-memory `NSVGpath`-compatible structure
  - On `fill()`: call `nsvgRasterize` into the CPU pixel buffer with current `fillStyle`
  - On `stroke()`: same with `strokeStyle` and `lineWidth`
  - On `clip()`: rasterize path to a 1-bit mask; alpha-multiply subsequent draws by mask
- [ ] `createImageBitmap(image)` → return a new offscreen Canvas2D buffer pre-filled with
  the image's `__pixelData`
- [ ] `OffscreenCanvas(w,h)` constructor → allocate a new CPU pixel buffer; `getContext('2d')`
  returns a Canvas 2D context backed by that buffer; `transferToImageBitmap()` snapshots it

### Phase 11.4 — Input Element Rendering

- [ ] `<input type="text">`:
  - Rendered as a white fillRect with a text cursor drawn via SDL3_ttf
  - Capture SDL keyboard events when element has focus (SDL window stays focused)
  - Expose `value` property; fire `input`, `change`, `keydown`/`keyup` events
- [ ] `<input type="checkbox">` / `<input type="radio">`:
  - Simple box/circle drawn with `fillRect`/`arc`; `checked` state toggled on click
- [ ] `<select>` / `<option>`:
  - Draw dropdown as fillRect; expand on click; dispatch `change` event

### Phase 11.5 — CSS Baseline Properties

Properties to implement via Lexbor CSS parser output (not a full cascade engine):

| CSS Property | Implementation |
|---|---|
| `color` | → `fillStyle` for text nodes |
| `background-color` | → `fillRect` on node bounding box |
| `background-image: url(...)` | → `drawImage` from SDL_image |
| `font`, `font-size`, `font-family`, `font-weight` | → `parseCssFont()` (already exists) |
| `border`, `border-radius` | → `strokeRect`; radius via `nanosvg` arc corners |
| `opacity` | → `globalAlpha` multiplier |
| `display` (`none`/`block`/`inline`/`flex`) | → layout skip / Clay CONTAINER |
| `position` (`static`/`relative`/`absolute`/`fixed`) | → Clay FLOATING or offset |
| `z-index` | → paint order sort before drawing |
| `overflow: hidden` | → scissor rect |
| `visibility: hidden` | → skip paint, keep layout space |
| `cursor` | → SDL3 `SDL_SetCursor` call |
| Custom properties `--name: value` | → Lexbor CSS variable resolution |

### Phase 11.6 — `querySelector` / `querySelectorAll` with CSS Selectors

Currently `querySelector` only matches `#id` and tag names. Extend to:
- [ ] Class selector `.className` → check `element.className.split(' ')`
- [ ] Attribute selector `[attr]`, `[attr=val]` → check element property
- [ ] Descendant combinator `a b` → recursive child walk
- [ ] Child combinator `a > b`
- [ ] Multiple selectors `a, b`
- Use Lexbor's CSS selector API (`lxb_css_selector_*`) for parsing; match against
  the JS DOM node graph

---

## Phase 12 — WebAssembly Runtime

**Goal:** rwebview can load and execute `.wasm` binaries via the standard `WebAssembly` JS API
(W3C WebAssembly Core 1.0, 2019). This unlocks Unity WebGL apps, Emscripten-compiled C/C++,
and any tool that targets WASM.

### Why WASM Matters for Rover

Rover's primary use cases beyond RPG Maker MV include:
- **Unity WebGL** — outputs a `.wasm` file + JS glue + compressed assets
- **Emscripten apps** — any C/C++ desktop app ported to browser-compatible WASM
- **PGlite** — PostgreSQL compiled to WASM; used for in-browser database persistence
- **GDevelop compiled games** — newer GDevelop versions can export to WASM

All of these use the standard `WebAssembly.instantiate` / `WebAssembly.instantiateStreaming`
JS API surface.

### Library Options (pure C, compatible with `AI-README.md §2`)

| Library | Language | License | Binary Size | Speed | Notes |
|---|---|---|---|---|---|
| **wasm3** | C | MIT | ~50 KB | Interpreted (~20–500× slower than native) | Simplest to embed. Single `wasm3.h` + a few `.c` files. Source: https://github.com/wasm3/wasm3 |
| **WAMR** (iwasm) | C | Apache-2.0 | ~200 KB (interp) | Interp + Fast JIT (x86-64) | Bytecode Alliance project. Supports interpreter, "Fast JIT" (C-compiled), and AOT. Full WASI support. Source: https://github.com/bytecodealliance/wasm-micro-runtime |
| **toywasm** | C | MIT | ~100 KB | Interpreted | Spec-complete, heavily tested, designed for embedding. Source: https://github.com/yamt/toywasm |
| **wac** | C | MPL-2.0 | ~4 KB (core) | Interpreted | Extremely minimal (~4K lines). Suitable as a reference, not production. Source: https://github.com/kanaka/wac |
| **wabt `wasm-interp`** | C + C++ | Apache-2.0 | — | Interpreted | Reference implementation; **uses C++** — **banned** by `AI-README.md §2` |
| **wasmer / wasmtime** | Rust | Apache-2.0 | — | JIT/AOT | **Banned** (Rust — see `AI-README.md §2`) |

**Recommended primary:** **WAMR (iwasm)** — most complete, active maintenance, fast-JIT
option for x86-64, full WASI, official WASM proposals support (MVP + threads + SIMD).

**Recommended fallback/CI:** **wasm3** — trivial to embed, zero build complexity, good
enough for simple Emscripten apps without multi-threading.

### 12.1 — WAMR Build Integration

- [ ] Clone WAMR into `libs/rwebview/libs/wamr/`
  (`git clone https://github.com/bytecodealliance/wasm-micro-runtime`)
- [ ] CMake build: configure with `WAMR_BUILD_INTERP=1`, `WAMR_BUILD_FAST_JIT=1` (x86-64),
  `WAMR_BUILD_LIBC_BUILTIN=1`, `WAMR_BUILD_LIBC_WASI=0` (we provide our own WASI shim)
- [ ] Output: `libiwasm.a` static library into `libs/rwebview/bin/`
- [ ] Write Nim FFI bindings for WAMR's C API (`wasm_export.h`):
  - `wasm_runtime_init()` / `wasm_runtime_destroy()`
  - `wasm_runtime_load(buf, size, error_buf)` → `WASMModuleCommon*`
  - `wasm_runtime_instantiate(module, stack_size, heap_size, error_buf)` → `WASMModuleInstanceCommon*`
  - `wasm_runtime_lookup_function(inst, name)` → `WASMFunctionInstanceCommon*`
  - `wasm_runtime_call_wasm(exec_env, func, argc, argv)` → bool
  - `wasm_runtime_get_exception(inst)` → cstring
  - `wasm_runtime_deinstantiate(inst)`
  - `wasm_runtime_unload(module)`
  - `wasm_runtime_module_malloc(inst, size, native_addr)` → WASM linear memory offset
  - `wasm_runtime_module_free(inst, ptr)`
  - `wasm_runtime_get_wasi_ctx(inst)` (for WASI integration)

### 12.2 — WebAssembly JS API Surface

Expose the standard `WebAssembly` global object in QuickJS:

- [ ] `WebAssembly.validate(bufferSource)` → `bool` — validate a WASM binary (calls `wasm_runtime_load` then frees immediately)
- [ ] `WebAssembly.compile(bufferSource)` → `Promise<WebAssembly.Module>` — load module from ArrayBuffer
- [ ] `WebAssembly.instantiate(bufferOrModule, importObject)` → `Promise<{module, instance}>` — load + instantiate
- [ ] `WebAssembly.instantiateStreaming(fetchResponse, importObject)` → `Promise<{module, instance}>` — accepts a Fetch `Response` object, extracts ArrayBuffer, delegates to `instantiate`
- [ ] `WebAssembly.Module` object:
  - `module.exports` → array of `{name, kind}` export descriptors
  - `module.imports` → array of import descriptors
  - `WebAssembly.Module.customSections(module, name)` → array of `ArrayBuffer`
- [ ] `WebAssembly.Instance` object:
  - `instance.exports` → JS object where each export is accessible by name
  - Functions → JS functions that call `wasm_runtime_call_wasm`
  - Memory → `WebAssembly.Memory` object (see below)
  - Table → `WebAssembly.Table` object (stub initially)
  - Globals → `WebAssembly.Global` objects (stub initially)
- [ ] `WebAssembly.Memory`:
  - `new WebAssembly.Memory({initial, maximum})` → creates WASM linear memory
  - `memory.buffer` → `ArrayBuffer` view into the WASM linear memory region
  - `memory.grow(delta)` → extend linear memory by `delta` pages (64 KB each)
- [ ] `WebAssembly.Table`:
  - `new WebAssembly.Table({element:'anyfunc', initial, maximum})` → function reference table
  - `table.get(index)`, `table.set(index, fn)`, `table.grow(delta)` — stub initially
- [ ] `WebAssembly.Global`:
  - `new WebAssembly.Global({value, mutable}, initVal)`
  - `global.value` getter/setter
- [ ] `WebAssembly.CompileError`, `WebAssembly.LinkError`, `WebAssembly.RuntimeError` — error constructors

### 12.3 — Import Object Wiring

Emscripten and Unity WebGL supply an `importObject` to `instantiate()` containing:

- [ ] `importObject.env.*` — JS functions that the WASM module calls as imports.
  These include the GL bindings, audio, filesystem, etc.
  WAMR's import registration: `wasm_runtime_register_natives("env", NativeSymbol*, count)`.
  Map each `importObject.env.funcName` to a native trampoline that calls back into QuickJS.
- [ ] `importObject.wasi_snapshot_preview1.*` — partial WASI implementation:
  - `fd_write`, `fd_read`, `fd_seek`, `fd_close` → route to Nim file I/O
  - `proc_exit(code)` → call `webview_terminate`
  - `environ_get`, `environ_sizes_get` → return empty
  - `clock_time_get` → `SDL_GetTicks64` nanoseconds
  - `random_get` → `SDL_rand_bits` (fill buffer with random bytes)
- [ ] Memory access bridge: when a WASM import function receives a pointer (WASM linear memory
  offset), `wasm_runtime_module_malloc` / address math converts to a native pointer for Nim use

### 12.4 — Emscripten Compatibility Shims

Emscripten-compiled apps expect a specific set of JavaScript globals in addition to the WASM
imports. Add these to `dom_preamble.js` or a new `emscripten_compat.js` preamble:

- [ ] `Module` global object with callbacks: `Module.onRuntimeInitialized`, `Module.print`, `Module.printErr`, `Module.locateFile`, `Module.canvas`, `Module.arguments`
- [ ] `Module.HEAPU8`, `Module.HEAP32`, `Module.HEAPF32`, etc. — TypedArray views into WASM memory (filled after instantiation)
- [ ] `Module._malloc(size)` / `Module._free(ptr)` → forward to WASM `malloc`/`free` exports
- [ ] `Module.ccall(name, returnType, argTypes, args)` / `Module.cwrap(name, returnType, argTypes)` — call WASM C functions with type conversion
- [ ] `Module.writeArrayToMemory(arr, ptr)` / `Module.UTF8ToString(ptr)` / `Module.stringToUTF8(str, ptr, maxLen)` — memory utility helpers
- [ ] `Module.FS.*` — Emscripten virtual filesystem:
  - `FS.mkdir`, `FS.writeFile`, `FS.readFile`, `FS.unlink`, `FS.stat` — backed by Nim file I/O at `baseDir`
  - `FS.createDataFile`, `FS.mount(IDBFS/NODEFS/MEMFS, ...)` — MEMFS is in-memory; NODEFS routes to Nim file I/O; IDBFS is a stub (data not persisted unless IndexedDB is implemented in Phase 11)
- [ ] `GL` namespace expected by Emscripten GL layer: `GL.textures`, `GL.programs`, `GL.shaders`, `GL.buffers`, `GL.framebuffers`, `GL.renderbuffers` — integer id→WebGL handle maps used by Emscripten's GL emulation layer

### 12.5 — Unity WebGL Specifics

Unity WebGL uses a slightly different WASM loading path than raw Emscripten:

- [ ] `.wasm.br` (Brotli) / `.wasm.gz` (gzip) compressed WASM bundles:
  need decompression before `WebAssembly.instantiate`. Use **brotli** (C, Google,
  https://github.com/google/brotli) or **zlib** (already available on Windows) for
  decompression. Note: `Content-Encoding` response headers from Rover's HTTP server
  already handle this for the OS webview backend; for rwebview the decompression
  must happen Nim-side before passing the ArrayBuffer to WAMR.
- [ ] `UnityLoader.js` / Unity's JS runtime glue — inject as a script tag like any other;
  will call `WebAssembly.instantiateStreaming` or `WebAssembly.instantiate`
- [ ] Progress bar UI — Unity WebGL renders a DOM progress bar before the WASM is ready.
  Phase 11 HTML/CSS rendering handles this if basic `<div>` + `<progress>` stubs are present.
- [ ] Compressed texture formats (DXT/ETC) — Unity WebGL uses `WEBGL_compressed_texture_s3tc`
  extension for DXT textures. This requires `GL_EXT_texture_compression_s3tc` on the OpenGL
  side; verify driver support and add to `getExtension()` response if available.

### 12.6 — Testing Checkpoints

- [ ] **W1** — `WebAssembly.validate(buf)` returns `true` for a minimal hand-crafted WASM binary
- [ ] **W2** — `WebAssembly.instantiate` can call a simple WASM function that adds two integers
- [ ] **W3** — An Emscripten-compiled "hello world" C program runs and prints via `Module.print`
- [ ] **W4** — An Emscripten-compiled OpenGL app (`gears.wasm`) renders to the SDL3 window
- [ ] **W5** — A Unity WebGL minimal project loads to its splash screen
- [ ] **W6** — A GDevelop WASM-exported game starts

---

*Last updated: March 2026. Phases 0–10 complete. Phases 11–12 planned. See ISSUES.md for remaining work beyond Phase 10.*
