# ISSUES: rwebview — Known Issues & Future Work

This document tracks known bugs, open issues, and engineering recommendations for the rwebview custom browser engine. Issues are organized by priority and category.

*Last updated: March 2026, Phase 10.*

---

## Table of Contents

1. [User-Reported Issues (Phase 10)](#1-user-reported-issues-phase-10)
2. [API Completeness Gaps](#2-api-completeness-gaps)
3. [Architectural Concerns](#3-architectural-concerns)
4. [Performance Recommendations](#4-performance-recommendations)
5. [Long-Term Roadmap](#5-long-term-roadmap)
6. [Resolved Issues Log](#6-resolved-issues-log)

---

## 1. User-Reported Issues (Phase 10)

### ISSUE-001: Rain/Snow Particles Render Too Large

**Status:** Open
**Priority:** High
**Reported:** Phase 10 testing

**Symptom:** Rain and snow particle effects (RPG Maker MV weather system) appear as large blotches instead of fine droplets/flakes. The particles are visually much larger than they should be.

**Analysis:**
RPG Maker MV's weather system uses `Sprite_Weather` which draws small particle images onto the screen via `drawImage`. The particle sprites are typically very small (a few pixels). Possible causes:

1. **GL texture filtering:** The Canvas2D→GL blit pipeline uses `GL_LINEAR` filtering. When small particles (2-4px) are drawn onto the CPU canvas buffer and then upscaled by the GL blit to fill the window, LINEAR interpolation blurs them into larger splotches. Switching to `GL_NEAREST` for the final blit would preserve pixel sharpness but may cause aliasing on text and sprites.

2. **Canvas2D drawImage scaling:** If the source sprite is being drawn with `drawImage(img, dx, dy, dw, dh)` where `dw/dh` are larger than the source dimensions, the nearest-neighbor scaling in the software rasterizer produces blocky large particles instead of crisp small ones.

3. **Possible missing NEAREST filter option:** Browsers respect `imageSmoothingEnabled = false` on the Canvas2D context to use nearest-neighbor. RPG Maker may set this for weather particles. If the flag is not honored in the software rasterizer, this could cause incorrect rendering.

**Recommended investigation:**
- Log `drawImage` calls from `Sprite_Weather` to check actual source/dest dimensions
- Check whether `ctx.imageSmoothingEnabled` is being set and honored
- Consider offering per-canvas GL_NEAREST vs GL_LINEAR filter mode

---

### ISSUE-002: Sound Effect Pitch Shift

**Status:** Open
**Priority:** Medium
**Reported:** Phase 10 testing

**Symptom:** Some sound effects (SE) play at altered pitch. Needs investigation whether this affects specific SE types (decision, cancel, cursor) or specific audio files.

**Analysis:**
RPG Maker MV plays SE via `AudioManager.playSe()` which creates an `AudioBufferSourceNode` and sets `source.playbackRate.value` based on the SE's `pitch` parameter (default 100 = 1.0x). Potential causes:

1. **playbackRate mapping:** RPG Maker uses `pitch / 100` as the playbackRate value. If the native Nim mixer's `src.position += float64(src.playbackRate)` computation doesn't correctly account for the sample rate ratio between the decoded audio and the output device (both should be 44100 Hz), this could cause pitch errors.

2. **Sample rate mismatch:** If SDL_sound decodes some OGG files at a sample rate different from 44100 Hz (e.g., 22050 Hz or 48000 Hz) but the mixer assumes 44100 Hz uniform, playback speed (and thus pitch) will be wrong. The mixer should resample to the output device rate.

3. **SE-specific pitch defaults:** RPG Maker's `System.json` defines default pitch values for cursor (100), ok (100), cancel (100), buzzer (100), equip (100), save (100), load (100), battleStart (100), escape (100), etc. If any of these are non-100 and the `playbackRate` AudioParam setter has a bug, it could manifest as pitch shift.

4. **Integer vs float precision:** The `playbackRate` is stored as `float32` in the mixer. If there's a rounding error when the JS value (e.g., 1.0) passes through the QuickJS float64 → Nim float32 conversion, small pitch errors could accumulate over short sound effects.

**Recommended investigation:**
- Add logging to `__rw_audio_sourceSetProp` for `playbackRate` to verify values RPG Maker sends
- Check decoded audio sample rates via `Sound_Sample.actual.rate` — are they all 44100?
- Verify the mixer's `position += playbackRate` logic handles non-44100 sources

---

### ISSUE-003: Mouse Coordinate Offset

**Status:** Open (partially fixed)
**Priority:** High
**Reported:** Phase 10 testing

**Symptom:** Mouse clicks register several pixels to the bottom-right of the actual touch/click point. The user must aim slightly above-left to hit the intended target.

**Previous fixes applied:**
- Added `offsetLeft`/`offsetTop` properties to DOM stub elements (was `undefined` → `NaN`)
- Made `style.marginLeft`/`marginTop` setters auto-update `offsetLeft`/`offsetTop` (for RPG Maker's `Graphics._centerElement`)
- Letterbox viewport computation: `scale = min(winW/gameW, winH/gameH)`, centered
- Reverted mouse to raw SDL coords (RPG Maker's `pageToCanvasX/Y` handles conversion)

**Analysis:**
The coordinate pipeline in RPG Maker MV is:
```
SDL mouseX/mouseY (raw window pixels, float32)
  → dispatched as event.pageX/pageY to JS
  → Graphics.pageToCanvasX(pageX) = (pageX - canvas.offsetLeft) / _realScale
  → Graphics._isInsideCanvas(x, y) gates all clicks
```

Remaining possible causes:

1. **SDL mouse position reference point:** SDL3 reports mouse position relative to the window's client area. If the SDL window has a title bar or border, and `pageX/pageY` should be relative to the content area, there may be a built-in offset from window decoration.

2. **Letterbox offset mismatch:** The GL letterbox viewport starts at `(c2dBlitVpX, c2dBlitVpY)` in GL coordinates (bottom-left origin). RPG Maker's `canvas.offsetLeft` is computed from `Graphics._centerElement` which sets `style.marginLeft = (windowWidth - boxWidth * realScale) / 2`. If these two margins don't match exactly, the coordinate conversion will be off.

3. **DPI scaling:** If Windows display scaling is not 100%, SDL mouse coordinates may already be in physical pixels while RPG Maker assumes logical pixels (or vice versa). `window.devicePixelRatio` is hardcoded to 1.0 in the DOM preamble.

4. **Float→int truncation:** SDL reports mouse coords as `float32`. When cast to `int` for dispatch, truncation (vs rounding) could cause a systematic 0-1 pixel offset.

**Recommended investigation:**
- Add debug logging to compare: raw SDL coords, dispatched pageX/pageY, computed canvas coords after `pageToCanvasX/Y`, and `_realScale`/`offsetLeft` values
- Verify that `offsetLeft/offsetTop` matches the letterbox `c2dBlitVpX/Y` when converted to CSS pixels
- Test with 100% Windows display scaling to rule out DPI issues

---

## 2. API Completeness Gaps

### 2.1. webview.h C ABI Conformance

rwebview aims to be a drop-in backend replacement for `webview.cc`. The following `webview.h` functions are **not yet exported**:

| Function | Impact | Recommendation |
|---|---|---|
| `webview_version()` | Returns `webview_version_info_t*`. `src/webview.nim` imports it via `importc`. If Rover code calls it, this will be a **linker error**. | Export a static version struct. Low effort. |
| `webview_get_native_handle()` | Returns a platform window handle of a specific kind. Used by some rover.nim features. | Export implementation returning SDL window handle for `UiWindow` kind, NULL for others. |

### 2.2. DOM API Gaps

The fake DOM is functional for RPG Maker MV but has notable gaps that could affect other HTML5 game engines:

| API | Status | Impact |
|---|---|---|
| `canvas.toDataURL()` | Stub (returns `""`) | Screenshot/save features broken |
| `getBoundingClientRect()` | Hardcoded `{left:0,top:0,width,height}` | Input positioning for non-fullscreen canvases wrong |
| `document.querySelectorAll()` | Returns `[]` | CSS selector-based code silent-fails |
| `element.innerHTML` setter | No parsing | Dynamic HTML injection doesn't work |
| `classList.toggle()` | No-op | CSS class toggling doesn't work |
| `MutationObserver` | Stub | Framework lifecycle hooks may not fire |

### 2.3. Canvas 2D Gaps

| API | Status | Impact |
|---|---|---|
| `strokeRect` | Stub | Box outlines don't render |
| `stroke()` (path) | Stub | All path-based stroked shapes missing |
| `clip()` | Stub | Clipping regions don't work (RPG Maker uses `destination-in` composite instead) |
| `bezierCurveTo` / `quadraticCurveTo` | Stub | Curved paths don't render |
| `createRadialGradient` | Treated as linear | Radial gradients display incorrectly |
| `arc()` partial angles | Only full circles | Pie charts, arc segments don't render |
| `isPointInPath` | Always returns false | Hit testing via path geometry broken |
| `shadowColor`/`shadowBlur` | Properties exist but no rendering | Drop shadows missing |

### 2.4. Audio Gaps

| API | Status | Impact |
|---|---|---|
| `AudioParam` ramping | `linearRampToValueAtTime` etc. apply immediately | Volume fades are instant jumps |
| `PannerNode` | Passthrough stub | 3D spatial audio doesn't work |
| `AnalyserNode` | Not implemented | Audio visualization features broken |
| `BiquadFilterNode` | Not implemented | Audio effects missing |
| `ConvolverNode` | Not implemented | Reverb/impulse response missing |
| `OscillatorNode` | Stub | Synthesized sounds don't play |

---

## 3. Architectural Concerns

### 3.1. Hacky vs Proper Web Implementation

Several current implementations lean toward RPG-Maker-specific patches rather than proper web standards. These should be refactored to be more general:

| Area | Current (Hacky) | Proper Alternative |
|---|---|---|
| `canvas.style.marginLeft` → `offsetLeft` | Direct setter synchronization specific to RPG Maker's `_centerElement` | Implement basic CSS box model: parse `style` values → compute `offsetLeft/Top/Width/Height` from layout rules. Even a simplified model (no flow layout, just margin/padding/border) would be more general. |
| `document.fonts.ready.then().check()` | Always returns `true` immediately | Track actually loaded fonts via `@font-face` declarations. Fire `ready` when all referenced fonts are loaded. Still simple — just check if TTF files exist on disk. |
| Image loading in `rwebview_dom.nim` | `jsLoadImage` is a stub that doesn't actually load image data (sets width=1, height=1) | Full image loading is handled by `rwebview_xhr.nim` via `img.src` setter. The dom stub should be removed or unified. |
| `Audio.canPlayType('ogg')` | Hardcoded `'probably'` | Check whether SDL_sound can actually decode the format at runtime. |
| `window.innerWidth/Height` | Set once at init, updated on resize | Correct. But `outerWidth/Height` is set to the same value, which is not technically correct (should include window chrome). Low impact. |

### 3.2. Event Dispatch Architecture

The current event system dispatches SDL events to JS via `__rw_dispatchEvent(target, type, props)`. This is functional but has limitations:

- **No event bubbling:** Events fire on the specific target only. Real browsers bubble events from target → parent → document → window. RPG Maker relies on window-level listeners so this works, but other apps may expect bubbling.
- **No `Event.preventDefault()` feedback:** JS can call `preventDefault()` but the native side never checks whether it was called. This means keyboard shortcuts (e.g., Tab, Backspace, F5) cannot be blocked by JS.
- **No `stopPropagation()` effect:** Since there's no bubbling, `stopPropagation` is a no-op.

### 3.3. Timer Precision

`setTimeout(fn, 0)` defers to the next SDL frame (16ms at 60fps), not the next microtask. In real browsers, `setTimeout(fn, 0)` fires within ~1-4ms. This can cause timing-sensitive code to behave differently.

---

## 4. Performance Recommendations

### 4.1. QuickJS Performance (No JIT)

QuickJS is an interpreter-only ECMAScript engine. It is ~30-100x slower than V8's JIT-compiled code for CPU-intensive JavaScript. Strategies to mitigate:

#### Short-term: Offload Hot Paths to Nim

Identify JavaScript code that runs per-frame and is CPU-bound, then rewrite in Nim:

| Hot Path | Current | Recommendation |
|---|---|---|
| Canvas2D pixel blending | Already in Nim | ✅ Done |
| Audio software mixing | Already in Nim | ✅ Done |
| Image decode | Already in Nim (SDL_image) | ✅ Done |
| `Graphics.pageToCanvasX/Y` | JS per-mouse-event | Could be native, but very lightweight (~3 ops). Not worth moving. |
| `Bitmap.blt` (RPG Maker) | JS calls `drawImage` (already native) | ✅ Already native |
| `Array.sort` in battle logic | QuickJS built-in (C) | ✅ Already native |

**Verdict:** Most hot paths are already in Nim/C. The main remaining JS bottleneck is RPG Maker's update/render loop logic — which is too application-specific to rewrite natively.

#### Medium-term: QuickJS Compilation Optimization

- Compile QuickJS with `-O2` or `-O3` (currently may be using default optimization)
- Enable QuickJS's `CONFIG_BIGNUM` only if needed (it adds overhead)
- Consider building QuickJS with `CONFIG_STACK_CHECK` disabled for release builds (reduces function call overhead)

#### Long-term: QuickJS-NG or Alternative Engine

[QuickJS-NG](https://github.com/nicedayzhu/quickjs-ng) is an actively maintained fork of QuickJS with:
- Better ES2023+ support
- Performance improvements (tail call optimization, faster property access)
- Bug fixes

Even longer term, if performance becomes a serious issue, consider engines with JIT support that still meet the C-only language constraint:
- **Hermes** (Meta) — bytecode-precompiled JS engine, faster interpretation. C++ though (banned).
- No pure-C JS engine with JIT exists currently.

**Realistic assessment:** For RPG Maker MV (a 2015-era engine), QuickJS interpreter speed is sufficient. The game logic is not CPU-intensive — most frame time is spent in native Canvas2D/WebGL/Audio code. JIT would matter more for modern frameworks (React, Vue) or heavy computation.

### 4.2. Canvas2D Rasterizer Optimization

The software rasterizer is the primary bottleneck for 2D rendering:

| Optimization | Status | Potential Gain |
|---|---|---|
| `copyMem` fast path for `copy` composite | ✅ Done | ~5x for opaque full-row blits |
| Row-based clipping in `fillText` | ✅ Done | Avoids per-pixel bounds checks |
| Inverse CTM pattern tiling | ✅ Done | Correct parallax with one pass |
| SIMD (SSE2/AVX) alpha blending | Not done | Could 4x pixel blending throughput |
| Multi-threaded row rendering | Not done | Could parallelize large fills over CPU cores |
| Dirty rectangle tracking | Not done | Skip unchanged canvas regions on upload |

**Highest-impact next optimization:** SIMD alpha blending. The `blendPixel` proc's source-over path is called millions of times per frame. SSE2 can process 4 pixels in parallel.

### 4.3. GL Blit Pipeline

| Optimization | Status |
|---|---|
| `glTexSubImage2D` for dirty rect | Uses full texture reupload every frame |
| PBO (pixel buffer object) for async upload | Not implemented |
| Multi-canvas batching | Single draw call per canvas (correct) |

**Recommendation:** Implement dirty rectangle tracking — only reupload changed canvas regions via `glTexSubImage2D`. For RPG Maker, the tilemap layer changes rarely (only on scroll), while the sprite/UI layers change frequently. This could halve the per-frame upload bandwidth.

### 4.4. Multithreading for QuickJS

QuickJS is **not thread-safe**. A single `JSContext` must only be accessed from one thread. However, potential parallel architectures:

1. **Audio mixing on a separate thread:** Move `mixAudioFrame()` to a dedicated audio thread with a lock-free ring buffer between the JS/render thread and the mixer. SDL3's audio callback already runs on a separate thread.

2. **Canvas2D row parallelism:** Split large `fillRect`/`drawImage` operations into row ranges and process on multiple threads. Requires per-canvas write locking.

3. **Multiple JSContexts:** QuickJS supports multiple contexts in separate threads (each with its own `JSRuntime`). Could run Web Workers this way.

**Assessment:** For RPG Maker MV, single-threaded is fine. The audio mixer is already effectively async (SDL3 pulls from the audio stream on its own thread). Multi-threading complexity is not justified until profiling shows a clear thread-bound bottleneck.

---

## 5. Long-Term Roadmap

### 5.1. Proper HTML/CSS Engine (Lexbor Integration)

Lexbor includes a CSS parser and selector engine that we currently bypass. The long-term plan:

**Phase A — CSS Selector matching** (medium effort):
- Use Lexbor's CSS selector engine for `querySelector`/`querySelectorAll`
- Parse `<style>` tags and `style` attributes
- This alone would make the fake DOM much more capable

**Phase B — Basic CSS box model** (high effort):
- Implement `display: block/inline/none`, `position: absolute/relative/fixed`
- Compute `offsetLeft/Top/Width/Height`, `clientWidth/Height` from CSS properties
- Handle `margin`, `padding`, `border` for layout
- This replaces all the hacky `offsetLeft` synchronization

**Phase C — Text layout** (very high effort):
- Line wrapping, `text-align`, `vertical-align`
- `innerHTML` parsing via Lexbor
- This would enable non-canvas UI rendering

**Timeline:** Phase A could be done in the short term and would immediately improve generality. Phases B and C are major undertakings that should only be pursued if rwebview needs to support applications beyond canvas-based games.

**Lexbor status:** Lexbor's CSS engine is still maturing. Monitor their releases and roadmap before committing to deep integration. The HTML parser is stable and production-ready; the CSS/layout engine is experimental.

### 5.2. Video Playback

`HTMLVideoElement` is currently a stub. RPG Maker MV uses it for movie scenes. Options:
- **SDL3_image** supports animated GIF (not video)
- **FFmpeg** (C) via `libavcodec`/`libavformat` — full format support but adds ~20MB of DLLs
- **pl_mpeg** (C, single-header) — MPEG1 video decoder, tiny, but limited format support
- **dav1d** (C) — AV1 decoder, modern and efficient

**Recommendation:** Start with `pl_mpeg` for basic MPEG1 support (covers simple cutscenes), consider FFmpeg only if WEBM/MP4 is required.

### 5.3. WebGL2 / OpenGL ES 3.0

The current WebGL1 implementation covers RPG Maker MV's Pixi.js needs. WebGL2 adds:
- 3D texture support
- Transform feedback
- Multiple render targets
- Integer textures

**Not needed** for RPG Maker MV. Implement only if targeting modern engines (PixiJS v7+, Three.js, Babylon.js).

### 5.4. Cross-Platform

rwebview's foundation (SDL3 + QuickJS + Lexbor) is fully cross-platform. The blockers for Linux/macOS are in `rover.nim` (Win32 APIs), not in rwebview. rwebview itself should work on any platform with SDL3 and OpenGL 3.3 support.

---

## 6. Resolved Issues Log

Issues that were found and fixed during development.

| Issue | Phase | Root Cause | Fix |
|---|---|---|---|
| Stack overflow on startup | 10 | `patchMouseCoords` IIFE called `setTimeout` which was a wrapper for `window.setTimeout` → infinite recursion | Removed JS mouse coord patch; handle in Nim |
| Canvas stretched instead of letterboxed | 10 | `glViewport(0,0,winW,winH)` ignored aspect ratio | `scale = min(winW/gameW, winH/gameH)`, centered viewport, black bars |
| Mouse clicks silently rejected | 10 | `canvas.offsetLeft = undefined` → `NaN` in `pageToCanvasX` → `isInsideCanvas(NaN,NaN) = false` | Added `offsetLeft/offsetTop` to DOM elements; smart style setters |
| Parallax background wrong | 10 | Pattern tiling ignored CTM (current transform matrix) | Applied inverse CTM to pattern source coordinates |
| Stroke text outlines invisible | 10 | `strokeText` didn't apply `strokeA` alpha channel | Applied `strokeA` to outline blending |
| drawImage `copy` mode slow | 10 | Per-pixel copy loop instead of bulk memory copy | Replaced with `copyMem` row-based fast path |
| `destination-in` composite wrong | 10 | Transparent source pixels left destination unchanged | Zero alpha on dest where source alpha is 0 |
| PannerNode crash | 9 | Missing `PannerNode` constructor in audio module | Added passthrough stub |
| Alpha blending artifacts | 9 | Incorrect Porter-Duff formula | Fixed to standard source-over compositing |
| Audio OGG not detected | 9 | File extension detection logic missed .ogg | Improved format sniffing |
| Every-other-frame rAF bug | 3 | Double-buffer `rafStaging` swapped incorrectly | Switched to single-buffer `rafPending` |
| setTimeout 0ms infinite loop | 3 | `clearInterval` didn't free JS function refs | Added sweep of inactive timers in `dispatchTimers` |
| GLSL ES → GLSL 3.30 failures | 4 | Missing `texture2D` → `texture` rewrite | Added full GLSL ES preprocessing in `shaderSource` |
| SDL GL attribute wrong values | 1 | Used assumed enum values instead of actual SDL3 header | Verified `SDL_GL_CONTEXT_MAJOR_VERSION=17, MINOR=18, PROFILE_MASK=20` |
