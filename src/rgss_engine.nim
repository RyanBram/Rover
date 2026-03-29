# =============================================================================
# rgss_engine.nim
# Runtime loader for rgss.dll — dynamic dispatch to the rwebview backend
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
#   Thin runtime loader for rgss.dll using Nim's dynlib module (Windows
#   LoadLibrary / GetProcAddress). Resolves all webview_* function pointers
#   from the DLL and stores them in the global `rgss: RgssEngine` object.
#
#   Only activated when package.json specifies "engine": "rgss".
#   If the DLL is absent or a critical symbol is missing, loadRgssEngine()
#   returns false and rover.nim falls back to native WebView2 mode.
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - src/rover.nim        (via `import ./rgss_engine`)
#
# Used by:
#   - engineCreate, engineDestroy, engineRunStep, engineNavigate, et al.
#     in rover.nim when useRgss == true.
#
# =============================================================================

import std/dynlib

type
  WebviewBindFn* = proc(id: cstring; req: cstring; arg: pointer) {.cdecl.}

  RgssEngine* = object
    dll*: LibHandle
    # Core lifecycle
    webviewCreate*:     proc(debug: cint; window: pointer; w: cint; h: cint; initialState: cint): pointer {.cdecl.}
    webviewDestroy*:    proc(w: pointer): cint {.cdecl.}
    webviewRun*:        proc(w: pointer): cint {.cdecl.}
    webviewRunStep*:    proc(w: pointer): cint {.cdecl.}
    webviewTerminate*:  proc(w: pointer): cint {.cdecl.}
    # Navigation & content
    webviewNavigate*:   proc(w: pointer; url: cstring): cint {.cdecl.}
    webviewSetHtml*:    proc(w: pointer; html: cstring): cint {.cdecl.}
    webviewInit*:       proc(w: pointer; js: cstring): cint {.cdecl.}
    webviewEval*:       proc(w: pointer; js: cstring): cint {.cdecl.}
    # Window
    webviewSetTitle*:   proc(w: pointer; title: cstring): cint {.cdecl.}
    webviewSetSize*:    proc(w: pointer; w2: cint; h: cint; hints: cint): cint {.cdecl.}
    webviewGetWindow*:  proc(w: pointer): pointer {.cdecl.}
    webviewGetNativeHandle*: proc(w: pointer; kind: cint): pointer {.cdecl.}
    webviewGetSavedPlacement*: proc(w: pointer; placement: pointer) {.cdecl.}
    # Bindings
    webviewBind*:       proc(w: pointer; name: cstring; fn: WebviewBindFn; arg: pointer): cint {.cdecl.}
    webviewReturn*:     proc(w: pointer; id: cstring; status: cint; result: cstring): cint {.cdecl.}
    webviewUnbind*:     proc(w: pointer; name: cstring): cint {.cdecl.}
    # Virtual host mapping
    webviewSetVHMapping*: proc(w: pointer; hostName: cstring; folderPath: cstring; accessKind: cint) {.cdecl.}
    # Dev tools
    webviewOpenDevTools*: proc(w: pointer) {.cdecl.}

var rgss*: RgssEngine

proc loadRgssEngine*(dllPath: string): bool =
  ## Load rgss.dll and resolve all webview_* function pointers.
  ## Returns true on success.
  rgss.dll = loadLib(dllPath)
  if rgss.dll == nil:
    echo "[RGSS] ERROR: Failed to load " & dllPath
    return false

  template sym(name: string, T: typedesc): untyped =
    let p = rgss.dll.symAddr(name)
    if p == nil:
      echo "[RGSS] WARNING: Symbol not found: " & name
    cast[T](p)

  rgss.webviewCreate     = sym("webview_create", typeof(rgss.webviewCreate))
  rgss.webviewDestroy    = sym("webview_destroy", typeof(rgss.webviewDestroy))
  rgss.webviewRun        = sym("webview_run", typeof(rgss.webviewRun))
  rgss.webviewRunStep    = sym("webview_run_step", typeof(rgss.webviewRunStep))
  rgss.webviewTerminate  = sym("webview_terminate", typeof(rgss.webviewTerminate))
  rgss.webviewNavigate   = sym("webview_navigate", typeof(rgss.webviewNavigate))
  rgss.webviewSetHtml    = sym("webview_set_html", typeof(rgss.webviewSetHtml))
  rgss.webviewInit       = sym("webview_init", typeof(rgss.webviewInit))
  rgss.webviewEval       = sym("webview_eval", typeof(rgss.webviewEval))
  rgss.webviewSetTitle   = sym("webview_set_title", typeof(rgss.webviewSetTitle))
  rgss.webviewSetSize    = sym("webview_set_size", typeof(rgss.webviewSetSize))
  rgss.webviewGetWindow  = sym("webview_get_window", typeof(rgss.webviewGetWindow))
  rgss.webviewGetNativeHandle = sym("webview_get_native_handle", typeof(rgss.webviewGetNativeHandle))
  rgss.webviewGetSavedPlacement = sym("webview_get_saved_placement", typeof(rgss.webviewGetSavedPlacement))
  rgss.webviewBind       = sym("webview_bind", typeof(rgss.webviewBind))
  rgss.webviewReturn     = sym("webview_return", typeof(rgss.webviewReturn))
  rgss.webviewUnbind     = sym("webview_unbind", typeof(rgss.webviewUnbind))
  rgss.webviewSetVHMapping = sym("webview_set_virtual_host_name_to_folder_mapping", typeof(rgss.webviewSetVHMapping))
  rgss.webviewOpenDevTools = sym("webview_open_devtools", typeof(rgss.webviewOpenDevTools))

  # Critical functions must be present
  if rgss.webviewCreate == nil or rgss.webviewDestroy == nil or
     rgss.webviewRunStep == nil or rgss.webviewNavigate == nil:
    echo "[RGSS] ERROR: Missing critical symbols in " & dllPath
    unloadLib(rgss.dll)
    rgss.dll = nil
    return false

  echo "[RGSS] Engine loaded from " & dllPath
  true


# =============================================================================
# [Documentation]
# =============================================================================
#
# Overview
# --------
#   rgss_engine.nim is a pure Nim shim between rover.nim and rgss.dll.
#   It contains no rendering or JS logic — only dynamic symbol resolution.
#   The actual SDL3 + OpenGL + QuickJS + Lexbor engine lives in:
#       libs/rwebview/rwebview.nim  →  compiled to  src/rgss.dll
#
# RgssEngine Object  (proc pointer table)
# ----------------------------------------
#   Field                    C symbol exported by rgss.dll
#   ─────────────────────── ──────────────────────────────────────────────
#   webviewCreate            webview_create(debug,window,w,h,state)→ptr
#   webviewDestroy           webview_destroy(w)→cint
#   webviewRun               webview_run(w)→cint          (blocking loop)
#   webviewRunStep           webview_run_step(w)→cint     (single frame)
#   webviewTerminate         webview_terminate(w)→cint
#   webviewNavigate          webview_navigate(w,url)→cint
#   webviewSetHtml           webview_set_html(w,html)→cint
#   webviewInit              webview_init(w,js)→cint
#   webviewEval              webview_eval(w,js)→cint
#   webviewSetTitle          webview_set_title(w,title)→cint
#   webviewSetSize           webview_set_size(w,w,h,hints)→cint
#   webviewGetWindow         webview_get_window(w)→ptr    (returns HWND)
#   webviewGetNativeHandle   webview_get_native_handle(w,kind)→ptr  [OPTIONAL]
#   webviewGetSavedPlacement webview_get_saved_placement(w,placement)
#   webviewBind              webview_bind(w,name,fn,arg)→cint
#   webviewReturn            webview_return(w,id,status,result)→cint
#   webviewUnbind            webview_unbind(w,name)→cint
#   webviewSetVHMapping      webview_set_virtual_host_name_to_folder_mapping(...)
#   webviewOpenDevTools      webview_open_devtools(w)
#
# Optional Symbols
# ----------------
#   webview_get_native_handle is currently NOT exported by rwebview.nim
#   (the SDL3/OpenGL backend has no WebView2 controller pointer to expose).
#   loadRgssEngine() prints a WARNING but continues — the field is left nil
#   and rover.nim never calls engineGetNativeHandle.
#
# Critical Symbols  (loadRgssEngine fails if any are missing)
# ------------------------------------------------------------
#   webview_create, webview_destroy, webview_run_step, webview_navigate.
#   Missing any of these causes loadRgssEngine() to return false,
#   unload the DLL, and rover.nim falls back to native WebView2 mode.
#
# Loading Sequence  (called from rover.nim main())
# -------------------------------------------------
#   1. Check fileExists(getCurrentDir() / "rgss.dll").
#   2. loadLib(dllPath)  →  Windows LoadLibraryW.
#   3. For each field: symAddr(name) → GetProcAddress; nil fields print WARN.
#   4. Validate critical symbols; unloadLib + return false on failure.
#   5. Set global useRgss = true in rover.nim.
#
# Distribution
# ------------
#   rgss.dll statically embeds: SDL3, SDL3_image, SDL3_sound,
#   QuickJS (libqjs.a), Lexbor (liblexbor_static.a),
#   NanoVG, FreeType2, HarfBuzz, microui, flex layout engine.
#   Final size: ~10 MB.  No additional DLLs required at runtime.
#   Build flag: -d:sdlStatic  (activates libSDL3.a etc. linkage in rwebview).
#
# =============================================================================
