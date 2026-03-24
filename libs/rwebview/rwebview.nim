## rwebview.nim
##
## Backend implementation for ``webview.nim`` backed by SDL3 + QuickJS + Lexbor
## instead of OS-native webviews (Edge WebView2 / WKWebView / WebKitGTK).
##
## This module exports the **same C ABI** as ``libs/webview/webview.h``
## (``webview_create``, ``webview_navigate``, ``webview_bind``, etc.) so that
## ``src/webview.nim``'s ``importc`` declarations resolve here transparently.
## No changes are needed to ``src/rover.nim`` or ``src/webview.nim``.
## Compile with ``-d:rwebview`` to activate this backend.
##
## Phase 1: SDL3 window + QuickJS bootstrap.
##   - Opens an SDL3 window with an OpenGL 3.3 Core Profile context.
##   - Creates a QuickJS runtime and context.
##   - Binds console.log / console.warn / console.error -> stderr.
##   - Runs the main event loop (SDL_PollEvent + SDL_GL_SwapWindow).
##   - Exports webview_eval(), webview_init(), webview_set_title(),
##     webview_set_size(), webview_get_window().
##
## Phase 2: HTML Script Loader (Lexbor).
##   - webview_init() queues JS preamble strings.
##   - webview_navigate(url): resolves http://rover.assets/<path> → local path,
##     reads the HTML file, parses it via Lexbor, extracts <script> tags in DOM
##     order, injects all queued preamble JS first, then executes each script.
##   - webview_set_html(html): parses the supplied HTML string in-memory via
##     Lexbor and executes scripts the same way.
##   - Virtual URL resolution: http://rover.assets/<path> → baseDir/<path>
##     using the virtualHosts table populated by
##     webview_set_virtual_host_name_to_folder_mapping().

import std/[os, strutils, tables, math]

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
const qjsDir       = rwebviewRoot / "libs" / "quickjs"
const libDir       = rwebviewRoot / "bin" / "lib"
const binDir       = rwebviewRoot / "bin" / "bin"

# Include path for rwebview_qjs_wrap.c so it can find quickjs.h
{.passC: "-I" & qjsDir.}
# Include path for rwebview_lexbor_wrap.c so it can find lexbor/*.h
const lexborIncDir = rwebviewRoot / "bin" / "include"
{.passC: "-I" & lexborIncDir.}
# GCC extensions needed by quickjs.c (asm volatile spin-loop)
{.passC: "-std=gnu99".}
# Link against compiled static libraries
{.passL: "-L" & libDir.}
{.passL: "-lquickjs".}
{.passL: "-llexbor_static".}

# Compile the thin C wrappers.
{.compile: "c_src/rwebview_qjs_wrap.c".}
{.compile: "c_src/rwebview_lexbor_wrap.c".}

# SDL3 DLL -- loaded at runtime; absolute path for Phase 1 dev.
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
include "rwebview_ffi_quickjs"

# ===========================================================================
# Internal state types
# These are declared here (before html/dom/canvas2d/gl includes) so all
# feature modules can reference RWebviewState, RAfEntry, TimerEntry.
# NOTE: var gState is declared inside rwebview_dom (included below).
# ===========================================================================

type
  RAfEntry = object
    id: int
    fn: JSValue   ## DupValue'd JS function reference

  TimerEntry = object
    id:       int
    fn:       JSValue   ## DupValue'd JS function reference
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
  let ctx = state.jsCtx
  for e in state.rafPending:
    rw_JS_FreeValue(ctx, e.fn)
  for t in state.timers:
    if t.active:
      rw_JS_FreeValue(ctx, t.fn)
  state.rafPending = @[]
  state.timers = @[]
  state.nextTimerId = 1
  state.mouseButtons = 0

  # ── 1. Inject DOM preamble (window / document stubs) ─────────────────
  let domJs = domPreamble(state.width, state.height)
  let domRet = JS_Eval(ctx, cstring(domJs), csize_t(domJs.len),
                       "<dom-preamble>", JS_EVAL_TYPE_GLOBAL)
  if not jsCheck(ctx, domRet, "<dom-preamble>"):
    stderr.writeLine("[rwebview] DOM preamble failed — aborting navigate")
    return

  # ── 2. Bind native functions into the JS global ───────────────────────
  bindDom(state)
  bindWebGL(state)
  bindCanvas2D(state)
  bindXhr(state)
  bindAudio(state)
  bindStorage(state)
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

  # ── 5. Execute page scripts ───────────────────────────────────────────
  executeScripts(scripts, ctx, htmlPath)

  # ── 6. Fire window.onload if it was set ──────────────────────────────
  let global  = JS_GetGlobalObject(ctx)
  let winObj  = JS_GetPropertyStr(ctx, global, "window")
  rw_JS_FreeValue(ctx, global)
  let onload  = JS_GetPropertyStr(ctx, winObj, "onload")
  rw_JS_FreeValue(ctx, winObj)
  if JS_IsFunction(ctx, onload) != 0:
    let ret = JS_Call(ctx, onload, rw_JS_Undefined(), 0, nil)
    if not jsCheck(ctx, ret, "window.onload"):
      stderr.writeLine("[rwebview] window.onload threw an exception")
    # Flush microtasks so Promise.then callbacks (e.g. document.fonts.ready.then)
    # resolve now — before the first rAF tick checks them.
    while JS_ExecutePendingJob(state.rt, nil) > 0: discard
  rw_JS_FreeValue(ctx, onload)

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
# Lifecycle
# ===========================================================================

proc webview_create*(debug: cint = 0; window: pointer = nil;
                     width: cint = 800; height: cint = 600;
                     initialState: cint = 0): Webview
    {.exportc, cdecl.} =
  ## Exported C ABI entry point.  Matched by ``webview_create`` in webview.h.
  if not SDL_Init(SDL_INIT_VIDEO or SDL_INIT_AUDIO):
    stderr.writeLine("[rwebview] SDL_Init failed: " & $SDL_GetError())
    return nil

  # Set Windows timer resolution to 1 ms for accurate SDL_Delay / Sleep timing.
  when defined(windows): discard timeBeginPeriod(1)

  # Allocate a debug console for GUI apps (--app:gui) so that console.log,
  # echo, and stderr output is visible during development.
  when defined(windows):
    if debug != 0:
      proc AllocConsole(): int32 {.importc, stdcall, dynlib: "kernel32".}
      proc c_freopen(path, mode: cstring; stream: File): pointer
          {.importc: "freopen", header: "<stdio.h>".}
      discard AllocConsole()
      discard c_freopen("CONOUT$", "w", stdout)
      discard c_freopen("CONOUT$", "w", stderr)

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
  state.running   = true
  state.width     = width
  state.height    = height
  state.preamble  = @[]

  cast[Webview](state)

proc webview_destroy*(w: Webview): cint {.exportc, cdecl, discardable.} =
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  # Free all Nim-held JS values so the GC list is empty before JS_FreeRuntime.
  # Unfired rAF callbacks
  for e in state.rafPending:
    rw_JS_FreeValue(state.jsCtx, e.fn)
  state.rafPending = @[]
  # Pending setTimeout / setInterval callbacks
  for t in state.timers:
    rw_JS_FreeValue(state.jsCtx, t.fn)
  state.timers = @[]
  # Canvas2D canvas element references (DupValue'd in jsCreateCanvas2D)
  for cs in canvas2dStates:
    rw_JS_FreeValue(state.jsCtx, cs.canvasJsVal)
  canvas2dStates = @[]
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
      if isDown and scanCode == 59:
        c2dShowOverlay = not c2dShowOverlay
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
      let js = "__rw_dispatchEvent(document,'wheel',{" &
               "deltaX:" & $wx & ",deltaY:" & $(-wy) & ",deltaZ:0," &
               "deltaMode:0,clientX:0,clientY:0,pageX:0,pageY:0});"
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

    of SDL_EVENT_WINDOW_FOCUS_GAINED:
      evalDisp("__rw_dispatchEvent(window,'focus',{});")

    of SDL_EVENT_WINDOW_FOCUS_LOST:
      evalDisp("__rw_dispatchEvent(window,'blur',{});__rw_dispatchEvent(document,'blur',{});")

    else: discard

  # Per-frame: update FPS display, fire timers, dispatch rAF, blit Canvas2D, swap GL buffer.
  inc rwFpsFrames
  let nowMs = SDL_GetTicks()
  if rwFpsLastMs == 0: rwFpsLastMs = nowMs
  if nowMs - rwFpsLastMs >= 1000:
    c2dFpsDisplay = rwFpsFrames
    rwFpsFrames   = 0
    rwFpsLastMs   = nowMs
  dispatchTimers(state)
  dispatchRaf(state)
  presentAllCanvas2D(state.width, state.height)
  mixAudioFrame()
  discard SDL_GL_SwapWindow(state.sdlWindow)

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

proc webview_open_devtools*(w: Webview) {.exportc, cdecl.} = discard

proc webview_get_saved_placement*(w: Webview; placement: pointer) {.exportc, cdecl.} = discard

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



when isMainModule:
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