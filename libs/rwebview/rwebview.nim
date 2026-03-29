# =============================================================================
# rwebview.nim
# Backend implementation for webview.nim backed by SDL3 + QuickJS + Lexbor
# =============================================================================
#
# Author    : Ryan Bramantya
# Copyright : Copyright (c) 2026 Ryan Bramantya
# License   : Apache License 2.0
# Website   : https://github.com/RyanBram/Rover
#
# -----------------------------------------------------------------------------
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.
#
# -----------------------------------------------------------------------------
#
# Description:
#   Backend implementation for Rover's `webview.nim` instead of OS-native
#   webviews (Edge WebView2 / WKWebView / WebKitGTK).
#
#   This module exports the same C ABI as `libs/webview/webview.h`
#   (`webview_create`, `webview_navigate`, `webview_bind`, etc.) so that
#   `src/webview.nim`'s `importc` declarations resolve here transparently.
#   No changes are needed to `src/rover.nim` or `src/webview.nim`.
#   Compile with `-d:rwebview` to activate this backend.
#
#   SDL3 window + QuickJS bootstrap:
#   - Opens an SDL3 window with an OpenGL 3.3 Core Profile context.
#   - Creates a QuickJS runtime and context.
#   - Binds console.log / console.warn / console.error -> stderr.
#   - Runs the main event loop (SDL_PollEvent + SDL_GL_SwapWindow).
#   - Exports webview_eval(), webview_init(), webview_set_title(),
#     webview_set_size(), webview_get_window().
#
#   HTML Script Loader (Lexbor):
#   - webview_init() queues JS preamble strings.
#   - webview_navigate(url): resolves http://rover.assets/<path> -> local path,
#     reads the HTML file, parses it via Lexbor, extracts <script> tags in DOM
#     order, injects all queued preamble JS first, then executes each script.
#   - webview_set_html(html): parses the supplied HTML string in-memory via
#     Lexbor and executes scripts the same way.
#   - Virtual URL resolution: http://rover.assets/<path> -> baseDir/<path>
#     using the virtualHosts table populated by
#     webview_set_virtual_host_name_to_folder_mapping().
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rover.nim                # via d:rwebview compile flag
#   - webview.nim              # fallback substitute
#
# Used by:
#   - End-user application using Rover Framework
#
# =============================================================================

import std/[os, strutils, tables, math, base64, locks, algorithm]

# -- Force discrete GPU on hybrid-graphics laptops (Intel + NVIDIA / AMD) ----
# The GPU driver checks for these exported symbols in the .exe's PE table.
# Without them, the OS defaults to the integrated GPU → slow OpenGL.
{.emit: """
#ifdef _WIN32
__declspec(dllexport) unsigned long NvOptimusEnablement = 0x00000001;
__declspec(dllexport) unsigned long AmdPowerXpressRequestHighPerformance = 0x00000001;
#endif
""".}

# -- compile-time paths ------------------------------------------------------
const rwebviewRoot = currentSourcePath().parentDir()
const libDir       = rwebviewRoot / "bin" / "lib"
const binDir       = rwebviewRoot / "bin" / "bin"

# QuickJS is the sole JS engine. The static library (libqjs.a) and header
# (quickjs.h) are installed to bin/lib and bin/include by CMake in buildrwebview.bat.
# Header: bin/include/quickjs.h  (QuickJS, has QUICKJS_NG=1 define)
# Library: bin/lib/libqjs.a      (built from libs/quickjs via CMake)
const qjsLibPath = libDir / "libqjs.a"
{.passL: qjsLibPath.}

# Include path for installed headers (quickjs.h, lexbor/*.h)
const includeDir = rwebviewRoot / "bin" / "include"
{.passC: "-I" & includeDir.}
# SDL3 static include path (when using -d:sdlStatic flag)
when defined(sdlStatic):
  const sdl3StaticIncDir = rwebviewRoot / "bin" / "staticlib" / "include"
  {.passC: "-I" & sdl3StaticIncDir.}
# GCC extensions needed by quickjs.c (asm volatile spin-loop)
{.passC: "-std=gnu99".}
# Link against compiled static libraries (use full paths for DLL compatibility)
const lexborLibPath = libDir / "liblexbor_static.a"
{.passL: lexborLibPath.}

# Compile the thin C wrappers.
{.compile: "c_src/rwebview_quickjs_wrap.c".}
{.compile: "c_src/rwebview_lexbor_wrap.c".}
{.compile: "c_src/rwebview_lexbor_css_wrap.c".}

# -- Native UI C libraries (nanovg, flex, microui) --
# Include path for c_src/ headers (nanovg.h, flex.h, microui.h, fontstash.h)
const cSrcDir = rwebviewRoot / "c_src"
{.passC: "-I" & cSrcDir.}
# Include path for nanovg_gl.h (from nanovg upstream) used by the GL3 backend
const nanovgSrcDir = rwebviewRoot / "libs" / "nanovg" / "src"
{.passC: "-I" & nanovgSrcDir.}
# FreeType2 (standalone static build installed by buildrwebview.bat to bin/freetype/)
const ftIncDir = rwebviewRoot / "bin" / "freetype" / "include" / "freetype2"
{.passC: "-I" & ftIncDir.}
const ftLibPath = rwebviewRoot / "bin" / "freetype" / "lib" / "libfreetype.a"
{.passL: ftLibPath.}
# NanoVG core (paths, shapes, text via fontstash + FreeType2)
const nanovgCPath = rwebviewRoot / "libs" / "nanovg" / "src" / "nanovg.c"
{.compile(nanovgCPath, "-DFONS_USE_FREETYPE -I" & ftIncDir).}
# NanoVG GL3 backend (loads GL functions via SDL_GL_GetProcAddress)
{.compile: "c_src/rwebview_nanovg_gl3.c".}
# Fonstash CPU wrapper for Canvas2D text rendering (replaces SDL_ttf)
{.compile: "c_src/rwebview_fonstash_core.c".}
# CSS Flexbox layout engine
{.compile: "c_src/flex.c".}
# microui immediate-mode widget toolkit
{.compile: "c_src/microui.c".}
# microui helper (callback setters for Nim FFI)
{.compile: "c_src/rwebview_microui_helper.c".}
# Link opengl32 for base GL types used by nanovg_gl backend
{.passL: "-lopengl32".}

# SDL3 DLL -- only needed when NOT using static linking
when not defined(sdlStatic):
  const sdl3Dll = binDir / "SDL3.dll"

# ===========================================================================
# C ABI types  (must match webview.h exactly)
# ===========================================================================
# These are the raw C-level types.  The friendly Nim aliases (WebviewHint,
# WebviewError, etc.) live in src/webview.nim and are NOT repeated here.

type
  Webview = pointer   # opaque; matches webview_t in webview.h

# C integer constants for hints and errors — used only inside this file.
# src/webview.nim defines the Nim enum wrappers that map to these values.
const
  WEBVIEW_HINT_NONE  = 0.cint

  WEBVIEW_ERROR_OK               =  0.cint
  WEBVIEW_ERROR_UNSPECIFIED      = -1.cint
  WEBVIEW_ERROR_INVALID_ARGUMENT = -2.cint

# ===========================================================================
# SDL3 types and constants

# ===========================================================================
# Split modules (include = textual insertion, shares parent scope)
# Include order matters: each file sees symbols declared by prior includes.
# ===========================================================================
include "rwebview_ffi_sdl3"
include "rwebview_ffi_sdl3_media"
include "rgss/rgss_quickjs_ffi"
include "rgss/rgss_quickjs"

# MicroQuickJS adaptor (opt-in via -d:withMQuickJS)
when defined(withMQuickJS):
  include "rgss/rgss_mquickjs_ffi"
  include "rgss/rgss_mquickjs"

var gScriptEngine: ScriptEngine  ## RGSS engine vtable (shared)

# ===========================================================================
# Internal state types
# These are declared here (before html/dom/canvas2d/gl includes) so all
# feature modules can reference RWebviewState, RAfEntry, TimerEntry.
# NOTE: var gState is declared inside rwebview_dom (included below).
# ===========================================================================

type
  RAfEntry = object
    id: int
    fn: ScriptValue   ## DupValue'd scripting function reference

  TimerEntry = object
    id:       int
    fn:       ScriptValue   ## DupValue'd scripting function reference
    fireAt:   uint64    ## SDL_GetTicks() target (ms)
    interval: uint64    ## 0 = setTimeout; >0 = setInterval repeat ms
    active:   bool

  ## Phase 9: entry for a webview_bind'd callback
  BindingEntry = object
    fn:  proc(id: cstring; req: cstring; arg: pointer) {.cdecl.}
    arg: pointer

type RWebviewState = object
  sdlWindow:    ptr SDL_Window
  glCtx:        SDL_GLContext
  rt:           ptr JSRuntime
  jsCtx:        ptr JSContext
  scriptCtx:    ptr ScriptCtx  ## RGSS wrapper around jsCtx (Phase SL-2+)
  running:      bool
  width:        cint
  height:       cint
  preamble:     seq[string]
  virtualHosts: Table[string, string]
  baseDir:      string   ## directory of the last navigated HTML file
  nextTimerId:  int
  rafPending:   seq[RAfEntry]   ## rAF callbacks to fire next frame
  timers:       seq[TimerEntry]
  mouseButtons: uint32   ## bitmask of currently-pressed JS mouse buttons
  bindings:     Table[string, BindingEntry]  ## Phase 9: webview_bind registry
  navigateUrl:  string   ## original URL passed to webview_navigate (used for window.location)
  savedPlacement: array[44, byte]  ## WINDOWPLACEMENT bytes — saved before fullscreen (initialState=2)
  screenW: cint   ## actual monitor width in pixels (for screen.width)
  screenH: cint   ## actual monitor height in pixels (for screen.height)


# ===========================================================================
# Feature modules — include order:
#   html     (Lexbor + script loader, needs SDL + QJS types)
#   dom      (gState decl + timer/rAF bindings, needs RWebviewState)
#   canvas2d (Canvas2D state + bindings, needs gState + RWebviewState)
#   gl       (OpenGL types + WebGL bindings, needs canvas2dStates)
# ===========================================================================
include "rwebview_html"
include "rwebview_dom"
include "rwebview_canvas2d"
include "rwebview_gl"
include "rwebview_xhr"
include "rwebview_audio"
include "rwebview_storage"
include "rwebview_ui"

# ===========================================================================
# Phase 9 — webview_bind / webview_return channel
# ===========================================================================
# Architecture:
#   webview_bind("name", cb, arg)
#     → stores BindingEntry in gState.bindings["name"]
#     → evals JS glue: window.name = function(...args){return new Promise(...)}
#   JS calls window.name(args)
#     → JS glue creates a UUID, stores resolve/reject in __rw_calls[id]
#     → calls native __rw_native_call("name", id, JSON.stringify(args))
#   __rw_native_call dispatches to BindingEntry.fn(id, req, arg)
#   Nim calls webview_return(w, id, 0, resultJson)
#     → evals __rw_resolve(id, 0, resultJson) in JS
#     → Promise resolves / rejects

proc rwNativeCallImpl(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## C callback registered as global __rw_native_call(name, id, req).
  ## Called by JS binding glue; dispatches to the Nim callback.
  if argc < 3 or gState == nil: return rw_JS_Undefined()
  let args  = cast[ptr UncheckedArray[JSValue]](argv)
  let nameC = jsToCString(ctx, args[0])
  let idC   = jsToCString(ctx, args[1])
  let reqC  = jsToCString(ctx, args[2])
  let name  = $nameC; let id = $idC; let req = $reqC
  JS_FreeCString(ctx, nameC)
  JS_FreeCString(ctx, idC)
  JS_FreeCString(ctx, reqC)
  if name in gState.bindings:
    let entry = gState.bindings[name]
    entry.fn(cstring(id), cstring(req), entry.arg)
  rw_JS_Undefined()

proc bindNativeCallChannel(ctx: ptr JSContext) =
  ## Registers __rw_native_call on the QuickJS global object (once, at create time).
  let global = JS_GetGlobalObject(ctx)
  let fn     = JS_NewCFunction(ctx, rwNativeCallImpl, "__rw_native_call", 3)
  discard JS_SetPropertyStr(ctx, global, "__rw_native_call", fn)
  rw_JS_FreeValue(ctx, global)

proc injectBindingGlue(state: ptr RWebviewState; name: string) =
  ## Evals the JS Promise-wrapper for one bound name into the current context.
  ## Called both from webview_bind (immediate) and rebindBindings (per navigate).
  let js = """
(function(){
  if (typeof __rw_calls === 'undefined') { __rw_calls = {}; }
  window['""" & name & """'] = function() {
    var args = Array.prototype.slice.call(arguments);
    return new Promise(function(resolve, reject) {
      var id = String(Date.now()) + '_' + String(Math.random()).slice(2);
      __rw_calls[id] = { resolve: resolve, reject: reject };
      __rw_native_call('""" & name & """', id, JSON.stringify(args));
    });
  };
})();
"""
  let label = "<bind:" & name & ">"
  let ret = JS_Eval(state.jsCtx, cstring(js), csize_t(js.len),
                    cstring(label), JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(state.jsCtx, ret, label)

proc rebindBindings(state: ptr RWebviewState) =
  ## Re-injects __rw_calls, __rw_resolve, and all binding glue each navigate.
  ## Required because dom_preamble.js rebuilds the `window` object, erasing
  ## any previous window.funcName properties.
  let bootstrap = """
var __rw_calls = {};
function __rw_resolve(id, status, result) {
  var p = __rw_calls[id];
  if (!p) return;
  delete __rw_calls[id];
  var val;
  try { val = (result !== null && result !== undefined && result !== '') ? JSON.parse(result) : undefined; }
  catch(e) { val = result; }
  if (status === 0) p.resolve(val);
  else p.reject(new Error(typeof val === 'string' ? val : JSON.stringify(val)));
}
"""
  let ret = JS_Eval(state.jsCtx, cstring(bootstrap), csize_t(bootstrap.len),
                    "<rw-bind-bootstrap>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(state.jsCtx, ret, "<rw-bind-bootstrap>")
  for name in state.bindings.keys:
    injectBindingGlue(state, name)

proc navigateImpl(state: ptr RWebviewState; htmlContent: string;
                  htmlPath: string) =
  ## Core implementation shared by webview_navigate and webview_set_html.
  ## Injects DOM preamble, user preamble JS, parses HTML, executes scripts,
  ## then fires window.onload.

  # ── 0. Reset per-page timer / rAF state ──────────────────────────────
  # Free any JS function references from RPG Maker scripts that ran before.
  gWebGLActive = false  # reset WebGL-mode flag; set again in initDrawingBuffer
  glJSBoundFBO = 0      # reset JS framebuffer binding tracker
  clearAssetCaches()    # OPT-4/5: clear file + image caches on new page load
  let ctx = state.jsCtx
  for e in state.rafPending:
    state.scriptCtx.freeValue(e.fn)
  for t in state.timers:
    if t.active:
      state.scriptCtx.freeValue(t.fn)
  state.rafPending = @[]
  state.timers = @[]
  state.nextTimerId = 1
  state.mouseButtons = 0

  # ── 1. Inject DOM preamble (window / document stubs) ─────────────────
  let domJs = domPreamble(state.width, state.height, state.navigateUrl,
                          state.screenW, state.screenH)
  let domRet = JS_Eval(ctx, cstring(domJs), csize_t(domJs.len),
                       "<dom-preamble>", JS_EVAL_TYPE_GLOBAL)
  if not jsCheck(ctx, domRet, "<dom-preamble>"):
    stderr.writeLine("[rwebview] DOM preamble failed — aborting navigate")
    return

  # ── 2. Bind native functions into the JS global ───────────────────────
  bindDom(state)
  bindWebGL(state.scriptCtx, state.width, state.height)
  bindCanvas2D(state.scriptCtx)
  bindXhr(state)
  bindAudio(state.scriptCtx)
  bindStorage(state.scriptCtx)
  rebindBindings(state)   # Phase 9: re-inject __rw_calls + all webview_bind glue

  # ── 3. Inject all preamble JS registered via webview_init() ──────────
  for js in state.preamble:
    let ret = JS_Eval(ctx, cstring(js), csize_t(js.len),
                      "<preamble>", JS_EVAL_TYPE_GLOBAL)
    if not jsCheck(ctx, ret, "<preamble>"):
      stderr.writeLine("[rwebview] preamble JS injection failed — aborting navigate")
      return

  # ── 4. Parse HTML and collect script entries ──────────────────────────
  let scripts = parseScripts(htmlContent, state.baseDir)
  stderr.writeLine("[rwebview] navigate: found " & $scripts.len &
                   " script(s) in " & htmlPath)
  # Parse <link rel="stylesheet"> font-face rules before running scripts
  # so that canvas2d.getFont() can resolve custom font families.
  parseStylesheetFonts(htmlContent, state.baseDir)

  # Inject virtual DOM elements from HTML body (canvas, div, input, etc.)
  # so that document.getElementById() resolves HTML-declared elements.
  let elemsJs = buildHtmlElemsJs(htmlContent)
  if elemsJs.len > 0:
    let elemsRet = JS_Eval(state.jsCtx, cstring(elemsJs),
                           csize_t(elemsJs.len), "<html-elems>",
                           JS_EVAL_TYPE_GLOBAL)
    discard jsCheck(state.jsCtx, elemsRet, "<html-elems>")

  # ── 4b. Speculative preload scanner ────────────────────────────────────
  # OPT-2: Scan HTML for <img>, <script>, <link> resource URLs and pre-cache
  # their file contents before JS execution. This mirrors browser preload
  # scanners that fetch resources ahead of the HTML parser.
  preloadScanHtml(htmlContent, state.baseDir)

  # ── 5. Execute page scripts ───────────────────────────────────────────
  executeScripts(scripts, ctx, htmlPath)

  # ── 6. Fire DOMContentLoaded, then window load event ─────────────────
  # DOMContentLoaded fires before 'load' — some games (jQuery, GDevelop)
  # use it instead of window.onload to start initialization.
  let dclJs = "__rw_dispatchEvent(document,'DOMContentLoaded',{bubbles:true,cancelable:false});"
  let dclRet = JS_Eval(ctx, cstring(dclJs), csize_t(dclJs.len),
                       "<DOMContentLoaded>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, dclRet, "<DOMContentLoaded>")
  flushJobs(state.rt)

  # window 'load' event — dispatched through __rw_dispatchEvent so ALL
  # window.addEventListener('load',...) handlers fire, not just window.onload.
  let loadJs = "__rw_dispatchEvent(window,'load',{bubbles:false,cancelable:false});"
  let loadRet = JS_Eval(ctx, cstring(loadJs), csize_t(loadJs.len),
                        "<window-load>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, loadRet, "<window-load>")
  # Flush microtasks so Promise.then callbacks (e.g. document.fonts.ready.then)
  # resolve now — before the first rAF tick checks them.
  flushJobs(state.rt)

# ===========================================================================

# ===========================================================================
# console.log / console.warn / console.error
# ===========================================================================
#
# JS_NewCFunction2 with cproto=JS_CFUNC_generic_magic (=1) passes a 'magic'
# int to the callback.  We encode the prefix index in magic:
#   0 = log, 1 = warn, 2 = error
#
# {.cdecl.} is required -- these are raw C callbacks.

const consolePrefixes = ["[LOG]", "[WARN]", "[ERR]"]

proc consoleImpl(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue; magic: cint): JSValue {.cdecl.} =
  var parts: seq[string]
  for i in 0..<int(argc):
    # argv is a C array of JSValue structs (each 16 bytes).
    let arg = cast[ptr JSValue](
                cast[uint](argv) + uint(i) * uint(sizeof(JSValue)))[]
    parts.add(jsValToStr(ctx, arg))
  let prefix =
    if magic >= 0 and magic < consolePrefixes.len: consolePrefixes[magic]
    else: "[LOG]"
  stderr.writeLine(prefix & " " & parts.join(" "))
  rw_JS_Undefined()

proc bindConsole(ctx: ptr JSContext) =
  let global  = JS_GetGlobalObject(ctx)
  let console = JS_NewObject(ctx)
  # JS_NewCFunction2 with cproto=JS_CFUNC_generic_magic links consoleImpl.
  let logFn  = JS_NewCFunction2(ctx, cast[JSCFunction](consoleImpl),
                                "log",   1, JS_CFUNC_generic_magic, 0)
  let warnFn = JS_NewCFunction2(ctx, cast[JSCFunction](consoleImpl),
                                "warn",  1, JS_CFUNC_generic_magic, 1)
  let errFn  = JS_NewCFunction2(ctx, cast[JSCFunction](consoleImpl),
                                "error", 1, JS_CFUNC_generic_magic, 2)
  # SetPropertyStr steals the value ref -- do NOT free logFn/warnFn/errFn.
  discard JS_SetPropertyStr(ctx, console, "log",   logFn)
  discard JS_SetPropertyStr(ctx, console, "warn",  warnFn)
  discard JS_SetPropertyStr(ctx, console, "error", errFn)
  discard JS_SetPropertyStr(ctx, global,  "console", console)  # steals console
  rw_JS_FreeValue(ctx, global)

# ===========================================================================

# ===========================================================================
# Win32 helpers for fullscreen / DPI (Windows only)
# ===========================================================================
when defined(windows):
  type
    RwPoint {.pure, bycopy.} = object
      x, y: int32
    RwRect {.pure, bycopy.} = object
      left, top, right, bottom: int32
    RwWindowPlacement {.pure, bycopy.} = object
      length:           uint32
      flags:            uint32
      showCmd:          uint32
      ptMinPosition:    RwPoint
      ptMaxPosition:    RwPoint
      rcNormalPosition: RwRect
    RwMonitorInfo {.pure, bycopy.} = object
      cbSize:    uint32
      rcMonitor: RwRect
      rcWork:    RwRect
      dwFlags:   uint32
  static:
    assert sizeof(RwWindowPlacement) == 44, "WINDOWPLACEMENT size mismatch"
    assert sizeof(RwMonitorInfo) == 40, "MONITORINFO size mismatch"
  const
    RW_GWL_STYLE          = (-16).cint
    RW_WS_OVERLAPPEDWINDOW = 0x00CF0000'i32
    RW_SWP_NOOWNERZORDER  = 0x0200'u32
    RW_SWP_FRAMECHANGED   = 0x0020'u32
    RW_SWP_NOMOVE         = 0x0002'u32
    RW_SWP_NOSIZE         = 0x0001'u32
    RW_SWP_NOZORDER       = 0x0004'u32
    RW_MONITOR_DEFAULT_PRIMARY = 1'u32
    RW_SW_SHOWMAXIMIZED   = 3.cint
  proc rwGetWindowLong(hwnd: pointer; nIndex: cint): int32
      {.importc: "GetWindowLongA", stdcall, dynlib: "user32.dll".}
  proc rwSetWindowLong(hwnd: pointer; nIndex: cint; newLong: int32): int32
      {.importc: "SetWindowLongA", stdcall, dynlib: "user32.dll".}
  proc rwGetWindowPlacement(hwnd: pointer; lpwndpl: pointer): bool
      {.importc: "GetWindowPlacement", stdcall, dynlib: "user32.dll".}
  proc rwSetWindowPos(hwnd: pointer; hwndAfter: pointer;
                      x, y, cx, cy: cint; flags: uint32): bool
      {.importc: "SetWindowPos", stdcall, dynlib: "user32.dll".}
  proc rwMonitorFromWindow(hwnd: pointer; dwFlags: uint32): pointer
      {.importc: "MonitorFromWindow", stdcall, dynlib: "user32.dll".}
  proc rwGetMonitorInfo(hmon: pointer; mi: pointer): bool
      {.importc: "GetMonitorInfoA", stdcall, dynlib: "user32.dll".}
  proc rwShowWindow(hwnd: pointer; nCmdShow: cint): bool
      {.importc: "ShowWindow", stdcall, dynlib: "user32.dll".}
  proc rwGetSystemMetrics(nIndex: cint): cint
      {.importc: "GetSystemMetrics", stdcall, dynlib: "user32.dll".}
  const
    RW_SM_CXSCREEN = 0.cint
    RW_SM_CYSCREEN = 1.cint

# Console window handle for F12 toggle
var rwConsoleHwnd: pointer = nil
var rwConsoleVisible: bool = false

# ── Win32 helpers to disable the console window's X (close) button ──────────
# SetWindowLongPtrW(GWLP_WNDPROC) cannot subclass a console window because the
# window lives in conhost.exe (a separate process).  Instead we remove the
# close entry from the system menu; the button goes grey and clicking it has no
# effect, so closing the console no longer terminates the process.
when defined(windows):
  proc rwGetSystemMenu(hwnd: pointer; bRevert: bool): pointer
      {.importc: "GetSystemMenu", stdcall, dynlib: "user32.dll".}
  proc rwDeleteMenu(hMenu: pointer; nPos: uint32; wFlags: uint32): bool
      {.importc: "DeleteMenu", stdcall, dynlib: "user32.dll".}
  proc rwDrawMenuBar(hwnd: pointer): bool
      {.importc: "DrawMenuBar", stdcall, dynlib: "user32.dll".}

# ===========================================================================
# Lifecycle
# ===========================================================================

proc webview_create*(debug: cint = 0; window: pointer = nil;
                     width: cint = 800; height: cint = 600;
                     initialState: cint = 0): Webview
    {.exportc, cdecl.} =
  ## Exported C ABI entry point.  Matched by ``webview_create`` in webview.h.
  # DPI-unaware mode: Windows virtualises the window so it appears at the OS
  # display-scale size (e.g. 150% → window renders at 1.5× its logical size).
  # Must be set before SDL_Init.
  when defined(windows):
    discard SDL_SetHint("SDL_WINDOWS_DPI_AWARENESS", "unaware")
  if not SDL_Init(SDL_INIT_VIDEO or SDL_INIT_AUDIO):
    stderr.writeLine("[rwebview] SDL_Init failed: " & $SDL_GetError())
    return nil

  # Set Windows timer resolution to 1 ms for accurate SDL_Delay / Sleep timing.
  when defined(windows): discard timeBeginPeriod(1)

  # Allocate a debug console for GUI apps (--app:gui) so that console.log,
  # echo, and stderr output is visible during development.
  # The console starts hidden; press F12 to toggle it.
  # The close button is disabled (greyed out) so that accidentally closing the
  # console window does NOT terminate the game process.
  when defined(windows):
    if debug != 0:
      proc AllocConsole(): int32 {.importc, stdcall, dynlib: "kernel32".}
      proc GetConsoleWindow(): pointer {.importc, stdcall, dynlib: "kernel32".}
      proc c_freopen(path, mode: cstring; stream: File): pointer
          {.importc: "freopen", header: "<stdio.h>".}
      discard AllocConsole()
      discard c_freopen("CONOUT$", "w", stdout)
      discard c_freopen("CONOUT$", "w", stderr)
      rwConsoleHwnd = GetConsoleWindow()
      if rwConsoleHwnd != nil:
        discard rwShowWindow(rwConsoleHwnd, 0)  # SW_HIDE = 0
        rwConsoleVisible = false
        # Grey out / disable the X button so closing the console does not kill
        # the game.  DeleteMenu on SC_CLOSE removes the entry from the system
        # menu; the title-bar button renders as greyed-out automatically.
        let sysMenu = rwGetSystemMenu(rwConsoleHwnd, false)
        if sysMenu != nil:
          discard rwDeleteMenu(sysMenu, 0xF060'u32, 0)  # SC_CLOSE, MF_BYCOMMAND
          discard rwDrawMenuBar(rwConsoleHwnd)

  # Request hardware-accelerated double-buffered OpenGL 3.3 Core context
  discard SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)
  discard SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24)
  discard SDL_GL_SetAttribute(SDL_GL_ACCELERATED_VISUAL, 1)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE)

  let sdlWin = SDL_CreateWindow("rwebview", width, height,
                                SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE)
  if sdlWin == nil:
    stderr.writeLine("[rwebview] SDL_CreateWindow failed: " & $SDL_GetError())
    SDL_Quit()
    return nil
  # NOTE: With SDL_WINDOWS_DPI_AWARENESS=permonitorv2, SDL3 already handles DPI
  # transparently at the OS level.  A logical 816×624 window is automatically
  # displayed as 1224×936 physical pixels at 150% DPI — no manual scaling needed.
  # We only query the DPI scale to compute screen.width/height in logical pixels
  # so that polyfill.js's checkFullScreen() comparison works correctly.

  let glCtx = SDL_GL_CreateContext(sdlWin)
  if glCtx == nil:
    stderr.writeLine("[rwebview] SDL_GL_CreateContext failed: " & $SDL_GetError())
    SDL_DestroyWindow(sdlWin)
    SDL_Quit()
    return nil

  # Enable vsync to prevent screen tearing/flickering (Phase 4 bug fix).
  # SDL3's SetSwapInterval takes only the interval — no window parameter.
  discard SDL_GL_SetSwapInterval(1)

  let rt = JS_NewRuntime()
  if rt == nil:
    stderr.writeLine("[rwebview] JS_NewRuntime failed")
    discard SDL_GL_DestroyContext(glCtx)
    SDL_DestroyWindow(sdlWin)
    SDL_Quit()
    return nil

  let ctx = JS_NewContext(rt)
  if ctx == nil:
    stderr.writeLine("[rwebview] JS_NewContext failed")
    JS_FreeRuntime(rt)
    discard SDL_GL_DestroyContext(glCtx)
    SDL_DestroyWindow(sdlWin)
    SDL_Quit()
    return nil

  bindConsole(ctx)
  bindNativeCallChannel(ctx)   # Phase 9: register __rw_native_call C function
  loadGLProcs()

  let state = cast[ptr RWebviewState](alloc0(sizeof(RWebviewState)))
  state.sdlWindow = sdlWin
  state.glCtx     = glCtx
  state.rt        = rt
  state.jsCtx     = ctx
  # RGSS: wrap existing JSContext in a ScriptCtx for migrated modules.
  if gScriptEngine.newCtx == nil:
    gScriptEngine = newQuickJSEngine()
  gQJSState.rt = state.rt
  state.scriptCtx = qjs_wrapExistingCtx(addr gScriptEngine, ctx)
  stderr.writeLine("[rwebview] Script interpreter: " & $gScriptEngine.name &
                   " v" & $gScriptEngine.version)
  state.running   = true
  state.width     = width
  state.height    = height
  state.preamble  = @[]
  # Use GetSystemMetrics for screen.width/height in JS (returns logical pixels).
  when defined(windows):
    state.screenW = rwGetSystemMetrics(RW_SM_CXSCREEN)
    state.screenH = rwGetSystemMetrics(RW_SM_CYSCREEN)
  when not defined(windows):
    state.screenW = width
    state.screenH = height

  # Apply initial window state — must be done after state allocation so that
  # savedPlacement can be stored directly in the state struct.
  when defined(windows):
    let initProps = SDL_GetWindowProperties(sdlWin)
    let initHwnd  = SDL_GetPointerProperty(initProps, "SDL.window.win32.hwnd", nil)
    if initHwnd != nil:
      if initialState == 1:   # maximize
        discard rwShowWindow(initHwnd, RW_SW_SHOWMAXIMIZED)
      elif initialState == 2: # fullscreen — save normal placement then cover monitor
        var wndpl: RwWindowPlacement
        wndpl.length = uint32(sizeof(RwWindowPlacement))
        discard rwGetWindowPlacement(initHwnd, addr wndpl)
        copyMem(addr state.savedPlacement[0], addr wndpl, sizeof(RwWindowPlacement))
        let style = rwGetWindowLong(initHwnd, RW_GWL_STYLE)
        var mi: RwMonitorInfo
        mi.cbSize = uint32(sizeof(RwMonitorInfo))
        let hmon = rwMonitorFromWindow(initHwnd, RW_MONITOR_DEFAULT_PRIMARY)
        discard rwGetMonitorInfo(hmon, addr mi)
        discard rwSetWindowLong(initHwnd, RW_GWL_STYLE,
                                style and not RW_WS_OVERLAPPEDWINDOW)
        discard rwSetWindowPos(initHwnd, nil,
                               mi.rcMonitor.left, mi.rcMonitor.top,
                               mi.rcMonitor.right - mi.rcMonitor.left,
                               mi.rcMonitor.bottom - mi.rcMonitor.top,
                               RW_SWP_NOOWNERZORDER or RW_SWP_FRAMECHANGED)

  cast[Webview](state)

proc webview_destroy*(w: Webview): cint {.exportc, cdecl, discardable.} =
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  # Stop background threads before freeing JS state
  stopMixerThread()
  stopAudioDecodeThread()
  # Free all Nim-held JS values so the GC list is empty before JS_FreeRuntime.
  # Pending deferred image loads
  for req in pendingImageLoads:
    state.scriptCtx.freeValue(req.imgObj)
  pendingImageLoads = @[]
  # Pending deferred XHR requests
  for req in pendingXhrRequests:
    state.scriptCtx.freeValue(req.xhrObj)
  pendingXhrRequests = @[]
  # Pending deferred fetch requests
  for req in pendingFetchRequests:
    state.scriptCtx.freeValue(req.resolveFn)
    state.scriptCtx.freeValue(req.rejectFn)
  pendingFetchRequests = @[]
  # Unfired rAF callbacks
  for e in state.rafPending:
    state.scriptCtx.freeValue(e.fn)
  state.rafPending = @[]
  # Pending setTimeout / setInterval callbacks
  for t in state.timers:
    state.scriptCtx.freeValue(t.fn)
  state.timers = @[]
  # Canvas2D canvas element references (DupValue'd in jsCreateCanvas2D)
  for cs in canvas2dStates:
    state.scriptCtx.freeValue(cs.canvasJsVal)
  canvas2dStates = @[]
  # Audio source onended callbacks (DupValue'd in jsAudioSourceSetOnended)
  for src in audioMixer.sources:
    state.scriptCtx.freeValue(src.onendedCb)
    state.scriptCtx.freeValue(src.onendedThis)
  audioMixer.sources = @[]
  # Free any pending input data for unprocessed decode requests.
  # adLock is already deinitialized by stopAudioDecodeThread, so access directly
  # (the worker thread is joined — no race condition).
  for req in sdRequests:
    if req.data != nil: dealloc(req.data)
  sdRequests = @[]
  if state.scriptCtx != nil: dealloc(state.scriptCtx)
  JS_FreeContext(state.jsCtx)
  JS_RunGC(state.rt)   # collect any JS objects with circular refs
  JS_FreeRuntime(state.rt)
  discard SDL_GL_DestroyContext(state.glCtx)
  SDL_DestroyWindow(state.sdlWindow)
  SDL_Quit()
  when defined(windows): discard timeEndPeriod(1)
  `=destroy`(state[])
  dealloc(state)
  WEBVIEW_ERROR_OK

# ===========================================================================
# SDL Keycode → HTML KeyboardEvent mapping
# ===========================================================================
# SDL3 keycodes for non-printable keys = 0x40000000 | scancode.
# We need to convert these to standard HTML keyCode values, key names, and
# code strings that match the W3C UIEvents spec.

const SDLK_SCANCODE_MASK = 0x40000000'u32

proc sdlToHtmlKey(sdlKey: uint32; scancode: uint32; shifted: bool): tuple[keyCode: int; key: string; code: string] =
  # For printable ASCII keys (letters, digits, symbols) SDL keycode = Unicode codepoint.
  # For non-printable keys (arrows, F-keys, modifiers, etc.) SDL keycode = 0x40000000 | scancode.

  if (sdlKey and SDLK_SCANCODE_MASK) != 0:
    # Non-printable key — map by scancode
    case scancode
    of 40: return (13, "Enter", "Enter")
    of 41: return (27, "Escape", "Escape")
    of 42: return (8,  "Backspace", "Backspace")
    of 43: return (9,  "Tab", "Tab")
    of 57: return (20, "CapsLock", "CapsLock")
    of 58: return (112, "F1", "F1")
    of 59: return (113, "F2", "F2")
    of 60: return (114, "F3", "F3")
    of 61: return (115, "F4", "F4")
    of 62: return (116, "F5", "F5")
    of 63: return (117, "F6", "F6")
    of 64: return (118, "F7", "F7")
    of 65: return (119, "F8", "F8")
    of 66: return (120, "F9", "F9")
    of 67: return (121, "F10", "F10")
    of 68: return (122, "F11", "F11")
    of 69: return (123, "F12", "F12")
    of 70: return (44, "PrintScreen", "PrintScreen")
    of 71: return (145, "ScrollLock", "ScrollLock")
    of 72: return (19, "Pause", "Pause")
    of 73: return (45, "Insert", "Insert")
    of 74: return (36, "Home", "Home")
    of 75: return (33, "PageUp", "PageUp")
    of 76: return (46, "Delete", "Delete")
    of 77: return (35, "End", "End")
    of 78: return (34, "PageDown", "PageDown")
    of 79: return (39, "ArrowRight", "ArrowRight")
    of 80: return (37, "ArrowLeft", "ArrowLeft")
    of 81: return (40, "ArrowDown", "ArrowDown")
    of 82: return (38, "ArrowUp", "ArrowUp")
    of 83: return (144, "NumLock", "NumLock")
    # Numpad
    of 84: return (111, "/", "NumpadDivide")
    of 85: return (106, "*", "NumpadMultiply")
    of 86: return (109, "-", "NumpadSubtract")
    of 87: return (107, "+", "NumpadAdd")
    of 88: return (13, "Enter", "NumpadEnter")
    of 89: return (97,  "1", "Numpad1")
    of 90: return (98,  "2", "Numpad2")
    of 91: return (99,  "3", "Numpad3")
    of 92: return (100, "4", "Numpad4")
    of 93: return (101, "5", "Numpad5")
    of 94: return (102, "6", "Numpad6")
    of 95: return (103, "7", "Numpad7")
    of 96: return (104, "8", "Numpad8")
    of 97: return (105, "9", "Numpad9")
    of 98: return (96,  "0", "Numpad0")
    of 99: return (110, ".", "NumpadDecimal")
    # Modifiers
    of 224: return (17, "Control", "ControlLeft")
    of 225: return (16, "Shift", "ShiftLeft")
    of 226: return (18, "Alt", "AltLeft")
    of 227: return (91, "Meta", "MetaLeft")
    of 228: return (17, "Control", "ControlRight")
    of 229: return (16, "Shift", "ShiftRight")
    of 230: return (18, "Alt", "AltRight")
    of 231: return (91, "Meta", "MetaRight")
    else:
      return (0, "Unidentified", "Unidentified")
  else:
    # Printable key — SDL keycode is the Unicode codepoint (lowercase)
    let ch = sdlKey
    case ch
    of 8:  return (8,  "Backspace", "Backspace")
    of 9:  return (9,  "Tab", "Tab")
    of 13: return (13, "Enter", "Enter")
    of 27: return (27, "Escape", "Escape")
    of 32: return (32, " ", "Space")
    of 39: return (222, "'", "Quote")
    of 44: return (188, ",", "Comma")
    of 45: return (189, "-", "Minus")
    of 46: return (190, ".", "Period")
    of 47: return (191, "/", "Slash")
    of 48..57:  # 0-9
      let digit = char(ch)
      return (int(ch), $digit, "Digit" & $digit)
    of 59: return (186, ";", "Semicolon")
    of 61: return (187, "=", "Equal")
    of 91: return (219, "[", "BracketLeft")
    of 92: return (220, "\\", "Backslash")
    of 93: return (221, "]", "BracketRight")
    of 96: return (192, "`", "Backquote")
    of 97..122:  # a-z
      let upper = char(ch.int - 32)
      let keyStr = if shifted: $upper else: $char(ch)
      return (int(upper), keyStr, "Key" & $upper)
    else:
      return (int(ch), $char(ch), "Unidentified")

# FPS tracking for the native F2 overlay
var rwFpsFrames:  int    = 0
var rwFpsLastMs:  uint64 = 0

proc webview_run_step*(w: Webview): cint {.exportc, cdecl, discardable.} =
  ## Process one SDL event frame and render one frame.
  ## Returns 0 while running, 1 when a window-close or quit event is received.
  ## Intended for hosts (e.g. rover.nim) that have their own message loop and
  ## call this instead of webview_run().
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  if not state.running: return 1

  template evalDisp(js: string) =
    let r = JS_Eval(state.jsCtx, cstring(js), csize_t(js.len),
                    "<event>", JS_EVAL_TYPE_GLOBAL)
    discard jsCheck(state.jsCtx, r, "<event>")

  var event: SDL_Event
  while SDL_PollEvent(addr event):
    case event.typ

    of SDL_EVENT_QUIT, SDL_EVENT_WINDOW_CLOSE_REQUESTED:
      state.running = false
      # Forward the close to the host's Win32 message pump so rover.nim's
      # WM_CLOSE handler triggers the flush-and-destroy sequence.
      when defined(windows):
        let props = SDL_GetWindowProperties(state.sdlWindow)
        let hwnd  = SDL_GetPointerProperty(props, "SDL.window.win32.hwnd", nil)
        if hwnd != nil: PostMessageA(hwnd, WM_CLOSE_MSG, 0, 0)
      return 1

    of SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_UP:
      let evType    = if event.typ == SDL_EVENT_KEY_DOWN: "keydown" else: "keyup"
      let sdlKey    = sdlEvKeyCode(event)
      let scanCode  = sdlEvKeyScancode(event)
      let modFlags  = sdlEvKeyMod(event)   # uint16
      let isDown    = event.typ == SDL_EVENT_KEY_DOWN
      let altKey    = (modFlags and SDL_KMOD_ALT)   != 0
      let ctrlKey   = (modFlags and SDL_KMOD_CTRL)  != 0
      let shiftKey  = (modFlags and SDL_KMOD_SHIFT) != 0
      let (htmlKeyCode, htmlKey, htmlCode) = sdlToHtmlKey(sdlKey, scanCode, shiftKey)
      # F2 (scancode 59) toggles the native debug overlay — do not propagate to JS
      # F12 (scancode 69) toggles the console window — do not propagate to JS
      if isDown and scanCode == 59:
        c2dShowOverlay = not c2dShowOverlay
      elif isDown and scanCode == 69:
        if rwConsoleHwnd != nil:
          rwConsoleVisible = not rwConsoleVisible
          discard rwShowWindow(rwConsoleHwnd, if rwConsoleVisible: 5 else: 0)
      else:
        let js = "__rw_dispatchEvent(document,'" & evType & "',{" &
                 "keyCode:" & $htmlKeyCode & "," &
                 "which:" & $htmlKeyCode & "," &
                 "code:'" & htmlCode & "'," &
                 "key:'" & htmlKey & "'," &
                 "altKey:" & (if altKey: "true" else: "false") & "," &
                 "ctrlKey:" & (if ctrlKey: "true" else: "false") & "," &
                 "shiftKey:" & (if shiftKey: "true" else: "false") & "," &
                 "repeat:" & (if isDown and sdlEvKeyRepeat(event): "true" else: "false") &
                 "});";
        evalDisp(js)

    of SDL_EVENT_MOUSE_MOTION:
      let mx = int(sdlEvMouseX(event))
      let my = int(sdlEvMouseY(event))
      # Send raw SDL window coords; RPG Maker's Graphics.pageToCanvasX/Y
      # converts them to game-canvas space using canvas.offsetLeft and _realScale.
      let js = "__rw_dispatchEvent(document,'mousemove',{" &
               "clientX:" & $mx & ",clientY:" & $my & "," &
               "pageX:" & $mx & ",pageY:" & $my & "," &
               "screenX:" & $mx & ",screenY:" & $my & "," &
               "movementX:0,movementY:0,button:0,buttons:" &
               $state.mouseButtons & "});"
      evalDisp(js)

    of SDL_EVENT_MOUSE_BUTTON_DOWN, SDL_EVENT_MOUSE_BUTTON_UP:
      let isPress = event.typ == SDL_EVENT_MOUSE_BUTTON_DOWN
      let btnSDL  = int(sdlEvMouseButton(event))
      let btnJS   =
        if btnSDL == 1: 0
        elif btnSDL == 2: 1
        elif btnSDL == 3: 2
        else: btnSDL - 1
      let mask = uint32(1 shl btnJS)
      if isPress: state.mouseButtons = state.mouseButtons or mask
      else:       state.mouseButtons = state.mouseButtons and not mask
      let evType = if isPress: "mousedown" else: "mouseup"
      let mx = int(sdlEvMouseX(event))
      let my = int(sdlEvMouseY(event))
      # Send raw SDL coords; RPG Maker converts via pageToCanvasX/Y
      let js = "__rw_dispatchEvent(document,'" & evType & "',{" &
               "button:" & $btnJS & ",buttons:" & $state.mouseButtons & "," &
               "clientX:" & $mx & ",clientY:" & $my & "," &
               "pageX:" & $mx & ",pageY:" & $my & "," &
               "screenX:" & $mx & ",screenY:" & $my & "});"
      evalDisp(js)
      if not isPress:
        let js2 = "__rw_dispatchEvent(document,'click',{" &
                  "button:" & $btnJS & ",buttons:" & $state.mouseButtons & "," &
                  "clientX:" & $mx & ",clientY:" & $my & "," &
                  "pageX:" & $mx & ",pageY:" & $my & "," &
                  "screenX:" & $mx & ",screenY:" & $my & "});"
        evalDisp(js2)

    of SDL_EVENT_MOUSE_WHEEL:
      let wx = sdlEvWheelX(event)
      let wy = sdlEvWheelY(event)
      # wheelDelta: positive = scroll-up (×120/notch); detail: negative = scroll-up
      let wheelDelta   = int(wy * 120.0)
      let wheelDetail  = int(-wy * 3.0)
      let js = "__rw_dispatchEvent(document,'wheel',{" &
               "deltaX:" & $wx & ",deltaY:" & $(-wy) & ",deltaZ:0," &
               "deltaMode:0,clientX:0,clientY:0,pageX:0,pageY:0});" &
               # Legacy mousewheel (Chrome/IE style)
               "__rw_dispatchEvent(document,'mousewheel',{" &
               "wheelDelta:" & $wheelDelta & ",wheelDeltaX:0,wheelDeltaY:" & $wheelDelta & "," &
               "deltaX:" & $wx & ",deltaY:" & $(-wy) & ",deltaZ:0," &
               "deltaMode:0,clientX:0,clientY:0,pageX:0,pageY:0});" &
               # Legacy DOMMouseScroll (Firefox style)
               "__rw_dispatchEvent(document,'DOMMouseScroll',{" &
               "detail:" & $wheelDetail & ",axis:2,VERTICAL_AXIS:2," &
               "clientX:0,clientY:0,pageX:0,pageY:0});"
      evalDisp(js)

    of SDL_EVENT_WINDOW_RESIZED:
      let nw = sdlEvData1(event)
      let nh = sdlEvData2(event)
      state.width  = nw
      state.height = nh
      let js = "window.innerWidth=" & $nw & ";window.innerHeight=" & $nh & ";" &
               "window.outerWidth=" & $nw & ";window.outerHeight=" & $nh & ";" &
               "__rw_dispatchEvent(window,'resize',{});"
      evalDisp(js)

    of SDL_EVENT_FINGER_DOWN, SDL_EVENT_FINGER_MOTION, SDL_EVENT_FINGER_UP:
      # Map SDL3 touch finger events to Touch + Pointer events.
      # SDL finger coordinates are normalized 0..1; scale to window pixels.
      let fx    = sdlEvFingerX(event)
      let fy    = sdlEvFingerY(event)
      let fid   = sdlEvFingerID(event)
      let fpres = sdlEvFingerPressure(event)
      let cx    = int(fx * float32(state.width))
      let cy    = int(fy * float32(state.height))
      let isDown = event.typ == SDL_EVENT_FINGER_DOWN
      let isUp   = event.typ == SDL_EVENT_FINGER_UP
      let touchType  = if isDown: "touchstart" elif isUp: "touchend" else: "touchmove"
      let ptrType    = if isDown: "pointerdown" elif isUp: "pointerup" else: "pointermove"
      # Build a minimal Touch object and dispatch touch + pointer events.
      # The touch object fields are what C2 actually reads (clientX/Y, identifier).
      let touchObj = "{identifier:" & $fid &
                     ",clientX:" & $cx & ",clientY:" & $cy &
                     ",pageX:" & $cx & ",pageY:" & $cy &
                     ",screenX:" & $cx & ",screenY:" & $cy &
                     ",force:" & $fpres & "}"
      let js = "(function(){" &
               "var t=" & touchObj & ";" &
               # Touch events (used by C2's legacy input path)
               "__rw_dispatchEvent(document,'" & touchType & "',{" &
               "touches:[t],changedTouches:[t],targetTouches:[t]," &
               "clientX:" & $cx & ",clientY:" & $cy & "});" &
               # Pointer events (used by C2's primary input path)
               "__rw_dispatchEvent(document,'" & ptrType & "',{" &
               "pointerId:" & $fid & ",pointerType:'touch'," &
               "clientX:" & $cx & ",clientY:" & $cy & "," &
               "pageX:" & $cx & ",pageY:" & $cy & "," &
               "screenX:" & $cx & ",screenY:" & $cy & "," &
               "pressure:" & $fpres & ",isPrimary:true,buttons:1});" &
               "})();"
      evalDisp(js)

    of SDL_EVENT_WINDOW_FOCUS_GAINED:
      evalDisp("__rw_dispatchEvent(window,'focus',{});" &
               "document.hidden=false;document.visibilityState='visible';" &
               "__rw_dispatchEvent(document,'visibilitychange',{});")

    of SDL_EVENT_WINDOW_FOCUS_LOST:
      evalDisp("__rw_dispatchEvent(window,'blur',{});__rw_dispatchEvent(document,'blur',{});" &
               "document.hidden=true;document.visibilityState='hidden';" &
               "__rw_dispatchEvent(document,'visibilitychange',{});")

    else: discard

  # Per-frame: update FPS display, fire timers, dispatch rAF, blit Canvas2D, swap GL buffer.
  inc rwFpsFrames
  let nowMs = SDL_GetTicks()
  if rwFpsLastMs == 0: rwFpsLastMs = nowMs
  if nowMs - rwFpsLastMs >= 1000:
    c2dFpsDisplay = rwFpsFrames
    rwFpsFrames   = 0
    rwFpsLastMs   = nowMs
  let frameT0 = SDL_GetTicks()
  dispatchTimers(state)
  processXhrQueue(state)        # OPT-3: fire deferred XHR callbacks (before rAF, like browser)
  processFetchQueue(state)      # OPT-4: fire deferred fetch callbacks
  let tRaf0 = SDL_GetTicks()
  dispatchRaf(state)
  let dtRaf = SDL_GetTicks() - tRaf0
  processImageQueue(state)      # OPT-1+3: batch image decode (time-budgeted)
  processStreamDecodeResults(state.scriptCtx)  # stbvorbis streaming chunks
  processStreamBufferResults(state.scriptCtx)  # progressive decode: growing-buffer streaming
  # Get actual pixel dimensions for the GL viewport (handles display scaling).
  var physW = state.width
  var physH = state.height
  discard SDL_GetWindowSizeInPixels(state.sdlWindow, addr physW, addr physH)
  presentAllCanvas2D(int(physW), int(physH))
  processAudioOnended(state.scriptCtx)  # Fire onended JS callbacks (mixer thread queues them)
  discard SDL_GL_SwapWindow(state.sdlWindow)
  let dtFrame = SDL_GetTicks() - frameT0
  if dtFrame > 20 or dtRaf > 10:
    stderr.writeLine("[perf] frame: " & $dtFrame & "ms (rAF=" & $dtRaf & "ms)")

  0  # still running

proc webview_run*(w: Webview): cint {.exportc, cdecl, discardable.} =
  ## Block on the SDL event loop until the window is closed.
  ## Frame pacing is handled entirely by SDL_GL_SetSwapInterval(1) (vsync).
  ## No manual SDL_Delay — it fights with vsync and causes frame-doubling,
  ## reducing 60fps to 40fps on systems with accurate timers.
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  while state.running:
    if webview_run_step(w) != 0: break
  WEBVIEW_ERROR_OK

proc webview_terminate*(w: Webview): cint {.exportc, cdecl, discardable.} =
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  cast[ptr RWebviewState](w).running = false
  WEBVIEW_ERROR_OK

proc webview_dispatch*(w: Webview;
                       fn: proc(w: Webview; arg: pointer) {.cdecl.};
                       arg: pointer = nil): cint {.exportc, cdecl, discardable.} =
  ## Phase 1: call fn synchronously on this thread.
  ## Phase 3: enqueue as SDL user-event for main-loop dispatch.
  if w == nil or fn == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  fn(w, arg)
  WEBVIEW_ERROR_OK

# ===========================================================================
# Window management
# ===========================================================================

proc webview_get_window*(w: Webview): pointer {.exportc, cdecl.} =
  if w == nil: return nil
  let state = cast[ptr RWebviewState](w)
  if state.sdlWindow == nil: return nil
  let props = SDL_GetWindowProperties(state.sdlWindow)
  SDL_GetPointerProperty(props, "SDL.window.win32.hwnd", nil)

proc webview_set_title*(w: Webview; title: cstring): cint {.exportc, cdecl, discardable.} =
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  discard SDL_SetWindowTitle(cast[ptr RWebviewState](w).sdlWindow, title)
  WEBVIEW_ERROR_OK

proc webview_set_size*(w: Webview; width: cint; height: cint;
                       hints: cint = WEBVIEW_HINT_NONE): cint
    {.exportc, cdecl, discardable.} =
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  discard SDL_SetWindowSize(state.sdlWindow, width, height)
  state.width  = width
  state.height = height
  WEBVIEW_ERROR_OK

proc webview_open_devtools*(w: Webview) {.exportc, cdecl.} =
  ## Toggle the debug console window visibility (F12).
  when defined(windows):
    if rwConsoleHwnd != nil:
      rwConsoleVisible = not rwConsoleVisible
      discard rwShowWindow(rwConsoleHwnd, if rwConsoleVisible: 5 else: 0)

proc webview_get_saved_placement*(w: Webview; placement: pointer) {.exportc, cdecl.} =
  if w == nil or placement == nil: return
  let state = cast[ptr RWebviewState](w)
  copyMem(placement, addr state.savedPlacement[0], state.savedPlacement.len)

proc webview_set_virtual_host_name_to_folder_mapping*(w: Webview;
    hostName: cstring; folderPath: cstring; accessKind: cint)
    {.exportc, cdecl.} =
  if w == nil: return
  let state = cast[ptr RWebviewState](w)
  let host   = ($hostName).toLowerAscii()
  let folder = $folderPath
  state.virtualHosts[host] = folder
  # Use the first registered mapping as the default baseDir so that
  # webview_set_html() can resolve scripts even before navigate is called.
  if state.baseDir.len == 0:
    state.baseDir = folder

# ===========================================================================
# JS execution
# ===========================================================================

proc webview_eval*(w: Webview; js: cstring): cint {.exportc, cdecl, discardable.} =
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  let src = $js
  let ret = JS_Eval(state.jsCtx, cstring(src), csize_t(src.len),
                    "<eval>", JS_EVAL_TYPE_GLOBAL)
  if not jsCheck(state.jsCtx, ret, "<eval>"):
    return WEBVIEW_ERROR_UNSPECIFIED
  WEBVIEW_ERROR_OK

proc webview_init*(w: Webview; js: cstring): cint {.exportc, cdecl, discardable.} =
  ## Register JS to inject before every page load (Phase 2+).
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  cast[ptr RWebviewState](w).preamble.add($js)
  WEBVIEW_ERROR_OK

proc webview_navigate*(w: Webview; url: cstring): cint {.exportc, cdecl, discardable.} =
  ## Phase 2: resolve URL → local HTML file, parse scripts, execute them.
  ##
  ## Supported URL forms:
  ##   http://rover.assets/<path>  →  virtualHosts["rover.assets"] / <path>
  ##   file:///abs/path            →  /abs/path
  ##   (any other)                 →  treated as a local file path directly
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  let urlStr = $url

  let filePath = resolveUrl(urlStr, state)
  if not fileExists(filePath):
    stderr.writeLine("[rwebview] webview_navigate: file not found: " & filePath &
                     "  (url: " & urlStr & ")")
    return WEBVIEW_ERROR_UNSPECIFIED

  # Set baseDir to the directory containing the HTML file.
  state.baseDir = filePath.parentDir()
  state.navigateUrl = urlStr   # used by domPreamble to set window.location

  let htmlContent = readFile(filePath)
  navigateImpl(state, htmlContent, filePath)
  WEBVIEW_ERROR_OK

proc webview_set_html*(w: Webview; html: cstring): cint {.exportc, cdecl, discardable.} =
  ## Phase 2: parse the supplied HTML string, execute its scripts.
  ## baseDir must already be set (e.g. via a prior webview_navigate call or
  ## webview_set_virtual_host_name_to_folder_mapping).
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  let htmlContent = $html
  navigateImpl(state, htmlContent, "<set_html>")
  WEBVIEW_ERROR_OK

# ===========================================================================
# JS <-> Nim bindings  (Phase 3 implementation; stubs for now)
# ===========================================================================
# NOTE: The high-level Nim wrappers (bindCallback, bind, CallBackContext, etc.)
# are intentionally NOT implemented here — they already live in src/webview.nim.
# This layer only needs to satisfy the low-level C ABI.

proc webview_bind*(w: Webview; name: cstring;
                   fn: proc(id: cstring; req: cstring; arg: pointer) {.cdecl.};
                   arg: pointer = nil): cint {.exportc, cdecl, discardable.} =
  ## Phase 9: register a named JS↔Nim binding backed by QuickJS.
  ## Injects a Promise-returning function into the JS global scope immediately.
  if w == nil or name == nil or fn == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  let nameStr = $name
  if nameStr in state.bindings: return -3  # WEBVIEW_ERROR_DUPLICATE
  state.bindings[nameStr] = BindingEntry(fn: fn, arg: arg)
  # Inject JS glue immediately (for binds registered after navigate).
  # Also injected in rebindBindings() on each navigate for binds registered before.
  injectBindingGlue(state, nameStr)
  WEBVIEW_ERROR_OK

proc webview_unbind*(w: Webview; name: cstring): cint {.exportc, cdecl, discardable.} =
  if w == nil or name == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state   = cast[ptr RWebviewState](w)
  let nameStr = $name
  if nameStr notin state.bindings: return -4  # WEBVIEW_ERROR_NOT_FOUND
  state.bindings.del(nameStr)
  # Remove from JS: delete window[name]
  let js  = "delete window['" & nameStr & "'];"
  let ret = JS_Eval(state.jsCtx, cstring(js), csize_t(js.len),
                    "<unbind>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(state.jsCtx, ret, "<unbind>")
  WEBVIEW_ERROR_OK

proc webview_return*(w: Webview; id: cstring; status: cint;
                     retval: cstring): cint {.exportc, cdecl, discardable.} =
  ## Phase 9: resolve or reject a pending JS Promise created by a binding call.
  if w == nil or id == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  # Escape single-quotes in id (should be UUID-like, but be safe)
  let safeId = ($id).replace("'", "\\'")
  let safeVal = if retval == nil: "null" else: $retval
  let js = "__rw_resolve('" & safeId & "'," & $status & "," & safeVal & ");"
  let ret = JS_Eval(state.jsCtx, cstring(js), csize_t(js.len),
                    "<return>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(state.jsCtx, ret, "<return>")
  WEBVIEW_ERROR_OK



when isMainModule and not defined(rwebviewLib):
  # Usage: rwebview.exe [path-to-html]
  # Default: testmedia.html next to this source file.
  # Supports drag-and-drop (Windows sends the dropped file as argv[1]).

  let testHtml =
    if paramCount() >= 1:
      let p = paramStr(1)
      if p.isAbsolute: p
      else: getCurrentDir() / p
    else:
      rwebviewRoot / "testmedia.html"

  echo "rwebview — loading: ", testHtml

  let w = webview_create(width = 800, height = 600)
  if w == nil:
    stderr.writeLine("FAIL: webview_create returned nil")
    quit(1)

  # Point baseDir at the HTML file's directory so relative asset paths resolve.
  let htmlDir = testHtml.parentDir()
  webview_set_virtual_host_name_to_folder_mapping(
    w, "rover.assets", cstring(htmlDir), 0)

  let testUrl = "file:///" & testHtml.replace('\\', '/')
  discard webview_navigate(w, cstring(testUrl))

  echo "Close window to finish."
  discard webview_run(w)
  discard webview_destroy(w)
  echo "COMPLETE"