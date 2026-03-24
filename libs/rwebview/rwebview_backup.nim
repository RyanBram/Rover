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

type
  SDL_Window   = object   # opaque -- always ptr SDL_Window
  SDL_GLContext = pointer # typedef void* in SDL3

  SDL_Event* {.bycopy.} = object
    ## SDL3 event union — 128 bytes.
    ## All sub-event structs share this layout prefix:
    ##   [0..3]  type     uint32
    ##   [4..7]  reserved uint32
    ##   [8..15] timestamp uint64
    ## Window event fields (SDL_WindowEvent):
    ##   [16..19] windowID uint32
    ##   [20..23] data1    int32
    ##   [24..27] data2    int32
    ## Key event fields (SDL_KeyboardEvent):
    ##   [16..19] windowID  uint32
    ##   [20..23] which     uint32   (keyboard id)
    ##   [24..27] scancode  uint32
    ##   [28..31] key       uint32   (SDL_Keycode)
    ##   [32..33] mod       uint16
    ##   [34..35] raw       uint16
    ##   [36]    down       bool
    ##   [37]    repeat     bool
    ## Mouse motion fields (SDL_MouseMotionEvent):
    ##   [16..19] windowID  uint32
    ##   [20..23] which     uint32
    ##   [24..27] state     uint32
    ##   [28..31] x         float32
    ##   [32..35] y         float32
    ## Mouse button fields (SDL_MouseButtonEvent):
    ##   [16..19] windowID  uint32
    ##   [20..23] which     uint32
    ##   [24]    button     uint8
    ##   [25]    down       bool
    ##   [26]    clicks     uint8
    ##   [27]    padding    uint8
    ##   [28..31] x         float32
    ##   [32..35] y         float32
    ## Mouse wheel fields (SDL_MouseWheelEvent):
    ##   [16..19] windowID  uint32
    ##   [20..23] which     uint32
    ##   [24..27] x         float32  (scroll horiz)
    ##   [28..31] y         float32  (scroll vert)
    typ*:     uint32              # [0..3]
    reserved: uint32              # [4..7]
    timestamp: uint64             # [8..15]
    padding2: array[112, byte]    # [16..127]

# Typed-overlay helpers — interpret bytes 16..35 of an SDL_Event.
# We use cast rather than a union because SDL3's event union is too wide
# to represent safely in Nim without triggering GC-unsafe copy issues.

proc sdlEvWindowID(e: var SDL_Event): uint32 {.inline.} =
  cast[ptr uint32](cast[uint](addr e) + 16)[]
proc sdlEvData1(e: var SDL_Event): int32 {.inline.} =
  cast[ptr int32](cast[uint](addr e) + 20)[]
proc sdlEvData2(e: var SDL_Event): int32 {.inline.} =
  cast[ptr int32](cast[uint](addr e) + 24)[]

proc sdlEvKeyScancode(e: var SDL_Event): uint32 {.inline.} =
  cast[ptr uint32](cast[uint](addr e) + 24)[]
proc sdlEvKeyCode(e: var SDL_Event): uint32 {.inline.} =
  cast[ptr uint32](cast[uint](addr e) + 28)[]
proc sdlEvKeyMod(e: var SDL_Event): uint16 {.inline.} =
  cast[ptr uint16](cast[uint](addr e) + 32)[]
proc sdlEvKeyDown(e: var SDL_Event): bool {.inline.} =
  cast[ptr bool](cast[uint](addr e) + 36)[]
proc sdlEvKeyRepeat(e: var SDL_Event): bool {.inline.} =
  cast[ptr bool](cast[uint](addr e) + 37)[]

proc sdlEvMouseX(e: var SDL_Event): float32 {.inline.} =
  cast[ptr float32](cast[uint](addr e) + 28)[]
proc sdlEvMouseY(e: var SDL_Event): float32 {.inline.} =
  cast[ptr float32](cast[uint](addr e) + 32)[]
proc sdlEvMouseButton(e: var SDL_Event): uint8 {.inline.} =
  cast[ptr uint8](cast[uint](addr e) + 24)[]
proc sdlEvMouseButtonDown(e: var SDL_Event): bool {.inline.} =
  cast[ptr bool](cast[uint](addr e) + 25)[]
proc sdlEvMouseState(e: var SDL_Event): uint32 {.inline.} =
  cast[ptr uint32](cast[uint](addr e) + 24)[]
proc sdlEvWheelX(e: var SDL_Event): float32 {.inline.} =
  cast[ptr float32](cast[uint](addr e) + 24)[]
proc sdlEvWheelY(e: var SDL_Event): float32 {.inline.} =
  cast[ptr float32](cast[uint](addr e) + 28)[]

# SDL_GLAttr ordinal values — counted from SDL3's SDL_video.h SDL_GLAttr enum:
# 0=RED_SIZE, 1=GREEN_SIZE, 2=BLUE_SIZE, 3=ALPHA_SIZE, 4=BUFFER_SIZE,
# 5=DOUBLEBUFFER, 6=DEPTH_SIZE, 7=STENCIL_SIZE, 8=ACCUM_RED_SIZE,
# 9=ACCUM_GREEN_SIZE, 10=ACCUM_BLUE_SIZE, 11=ACCUM_ALPHA_SIZE,
# 12=STEREO, 13=MULTISAMPLEBUFFERS, 14=MULTISAMPLESAMPLES,
# 15=ACCELERATED_VISUAL, 16=RETAINED_BACKING (deprecated),
# 17=CONTEXT_MAJOR_VERSION, 18=CONTEXT_MINOR_VERSION,
# 19=CONTEXT_FLAGS, 20=CONTEXT_PROFILE_MASK, ...
const
  SDL_GL_CONTEXT_MAJOR_VERSION* = 17.cint
  SDL_GL_CONTEXT_MINOR_VERSION* = 18.cint
  SDL_GL_CONTEXT_PROFILE_MASK*  = 20.cint
  SDL_GL_CONTEXT_PROFILE_CORE*  = 0x0001.cint

const
  SDL_INIT_AUDIO* = 0x00000010'u32
  SDL_INIT_VIDEO* = 0x00000020'u32

const
  SDL_WINDOW_OPENGL* = 0x0000000000000002'u64

const
  SDL_EVENT_QUIT*                   = 0x100'u32
  # Window events (0x202..0x21F range)
  SDL_EVENT_WINDOW_SHOWN*           = 0x202'u32
  SDL_EVENT_WINDOW_RESIZED*         = 0x206'u32
  SDL_EVENT_WINDOW_FOCUS_GAINED*    = 0x20E'u32
  SDL_EVENT_WINDOW_FOCUS_LOST*      = 0x20F'u32
  SDL_EVENT_WINDOW_CLOSE_REQUESTED* = 0x210'u32
  # Keyboard events
  SDL_EVENT_KEY_DOWN*               = 0x300'u32
  SDL_EVENT_KEY_UP*                 = 0x301'u32
  # Mouse events
  SDL_EVENT_MOUSE_MOTION*           = 0x400'u32
  SDL_EVENT_MOUSE_BUTTON_DOWN*      = 0x401'u32
  SDL_EVENT_MOUSE_BUTTON_UP*        = 0x402'u32
  SDL_EVENT_MOUSE_WHEEL*            = 0x403'u32

# SDL key modifier bit flags (SDL_Keymod values from SDL_keycode.h)
const
  SDL_KMOD_LSHIFT* = 0x0001'u16
  SDL_KMOD_RSHIFT* = 0x0002'u16
  SDL_KMOD_LCTRL*  = 0x0040'u16
  SDL_KMOD_RCTRL*  = 0x0080'u16
  SDL_KMOD_LALT*   = 0x0100'u16
  SDL_KMOD_RALT*   = 0x0200'u16
  SDL_KMOD_SHIFT*  = SDL_KMOD_LSHIFT or SDL_KMOD_RSHIFT
  SDL_KMOD_CTRL*   = SDL_KMOD_LCTRL  or SDL_KMOD_RCTRL
  SDL_KMOD_ALT*    = SDL_KMOD_LALT   or SDL_KMOD_RALT

# ===========================================================================
# SDL3 FFI  (runtime DLL)
# ===========================================================================

proc SDL_Init(flags: uint32): bool
    {.importc: "SDL_Init", dynlib: sdl3Dll.}
proc SDL_Quit()
    {.importc: "SDL_Quit", dynlib: sdl3Dll.}
proc SDL_CreateWindow(title: cstring; w: cint; h: cint; flags: uint64): ptr SDL_Window
    {.importc: "SDL_CreateWindow", dynlib: sdl3Dll.}
proc SDL_DestroyWindow(window: ptr SDL_Window)
    {.importc: "SDL_DestroyWindow", dynlib: sdl3Dll.}
proc SDL_SetWindowTitle(window: ptr SDL_Window; title: cstring): bool
    {.importc: "SDL_SetWindowTitle", dynlib: sdl3Dll.}
proc SDL_SetWindowSize(window: ptr SDL_Window; w: cint; h: cint): bool
    {.importc: "SDL_SetWindowSize", dynlib: sdl3Dll.}
proc SDL_GL_SetAttribute(attr: cint; value: cint): bool
    {.importc: "SDL_GL_SetAttribute", dynlib: sdl3Dll.}
proc SDL_GL_CreateContext(window: ptr SDL_Window): SDL_GLContext
    {.importc: "SDL_GL_CreateContext", dynlib: sdl3Dll.}
proc SDL_GL_DestroyContext(ctx: SDL_GLContext): bool
    {.importc: "SDL_GL_DestroyContext", dynlib: sdl3Dll.}
proc SDL_GL_SwapWindow(window: ptr SDL_Window): bool
    {.importc: "SDL_GL_SwapWindow", dynlib: sdl3Dll.}
proc SDL_PollEvent(event: ptr SDL_Event): bool
    {.importc: "SDL_PollEvent", dynlib: sdl3Dll.}
proc SDL_GetWindowProperties(window: ptr SDL_Window): uint32
    {.importc: "SDL_GetWindowProperties", dynlib: sdl3Dll.}
proc SDL_GetPointerProperty(props: uint32; name: cstring; default: pointer): pointer
    {.importc: "SDL_GetPointerProperty", dynlib: sdl3Dll.}
proc SDL_GetError(): cstring
    {.importc: "SDL_GetError", dynlib: sdl3Dll.}
proc SDL_GetTicks(): uint64
    {.importc: "SDL_GetTicks", dynlib: sdl3Dll.}
proc SDL_GetKeyName(key: uint32): cstring
    {.importc: "SDL_GetKeyName", dynlib: sdl3Dll.}
proc SDL_GL_GetProcAddress(name: cstring): pointer
    {.importc: "SDL_GL_GetProcAddress", dynlib: sdl3Dll.}
proc SDL_DestroySurface(surface: pointer)
    {.importc: "SDL_DestroySurface", dynlib: sdl3Dll.}
proc SDL_ConvertSurface(surface: pointer; format: uint32): pointer
    {.importc: "SDL_ConvertSurface", dynlib: sdl3Dll.}

# SDL_Surface struct — layout from SDL3/SDL_surface.h
# We only read the first few fields; match the C layout exactly.
type
  SDL_Surface {.bycopy.} = object
    flags:    uint32          # SDL_SurfaceFlags
    format:   uint32          # SDL_PixelFormat (enum = uint32)
    w:        cint            # width
    h:        cint            # height
    pitch:    cint            # bytes per row
    pixels:   pointer         # raw pixel data

const
  # SDL_PIXELFORMAT_ABGR8888 = 0x16762004 → RGBA byte order on little-endian
  SDL_PIXELFORMAT_RGBA32 = 0x16762004'u32

# ===========================================================================
# SDL3_ttf FFI  (runtime DLL)
# ===========================================================================

const sdl3TtfDll = binDir / "SDL3_ttf.dll"

type
  TTF_Font = object  # opaque

  SDL_Color {.bycopy.} = object
    r, g, b, a: uint8

proc TTF_Init(): bool
    {.importc: "TTF_Init", dynlib: sdl3TtfDll.}
proc TTF_Quit()
    {.importc: "TTF_Quit", dynlib: sdl3TtfDll.}
proc TTF_OpenFont(file: cstring; ptsize: cfloat): ptr TTF_Font
    {.importc: "TTF_OpenFont", dynlib: sdl3TtfDll.}
proc TTF_CloseFont(font: ptr TTF_Font)
    {.importc: "TTF_CloseFont", dynlib: sdl3TtfDll.}
proc TTF_SetFontSize(font: ptr TTF_Font; ptsize: cfloat): bool
    {.importc: "TTF_SetFontSize", dynlib: sdl3TtfDll.}
proc TTF_RenderText_Blended(font: ptr TTF_Font; text: cstring;
                            length: csize_t; fg: SDL_Color): ptr SDL_Surface
    {.importc: "TTF_RenderText_Blended", dynlib: sdl3TtfDll.}
proc TTF_GetStringSize(font: ptr TTF_Font; text: cstring;
                       length: csize_t; w: ptr cint; h: ptr cint): bool
    {.importc: "TTF_GetStringSize", dynlib: sdl3TtfDll.}

# ===========================================================================
# QuickJS types
# ===========================================================================
#
# JSValue in the non-NaN-boxing struct build:
#   typedef struct JSValue { JSValueUnion u; int64_t tag; } JSValue;   -- 16 bytes
# Nim {.bycopy.} ensures the struct is passed by value matching C ABI.

type
  JSRuntime = object   # opaque
  JSContext = object   # opaque

  JSValueUnion {.union.} = object
    int32Val: int32
    float64:  float64
    ptrVal:   pointer

  JSValue* {.bycopy.} = object
    u:   JSValueUnion  # 8 bytes
    tag: int64         # 8 bytes

  JSCFunction* =
    proc(ctx: ptr JSContext; thisVal: JSValue;
         argc: cint; argv: ptr JSValue): JSValue {.cdecl.}

  JSCFunctionMagic* =
    proc(ctx: ptr JSContext; thisVal: JSValue;
         argc: cint; argv: ptr JSValue; magic: cint): JSValue {.cdecl.}

const
  JS_EVAL_TYPE_GLOBAL*    = 0.cint
  JS_CFUNC_generic*       = 0.cint
  JS_CFUNC_generic_magic* = 1.cint

# ===========================================================================
# QuickJS exported functions (non-inline) -- linked via -lquickjs
# ===========================================================================

proc JS_NewRuntime(): ptr JSRuntime         {.importc: "JS_NewRuntime".}
proc JS_FreeRuntime(rt: ptr JSRuntime)      {.importc: "JS_FreeRuntime".}
proc JS_NewContext(rt: ptr JSRuntime): ptr JSContext
                                            {.importc: "JS_NewContext".}
proc JS_FreeContext(ctx: ptr JSContext)     {.importc: "JS_FreeContext".}
proc JS_Eval(ctx: ptr JSContext; input: cstring; inputLen: csize_t;
             filename: cstring; evalFlags: cint): JSValue
                                            {.importc: "JS_Eval".}
proc JS_GetException(ctx: ptr JSContext): JSValue
                                            {.importc: "JS_GetException".}
proc JS_GetGlobalObject(ctx: ptr JSContext): JSValue
                                            {.importc: "JS_GetGlobalObject".}
proc JS_NewObject(ctx: ptr JSContext): JSValue
                                            {.importc: "JS_NewObject".}
## JS_SetPropertyStr steals ownership of 'val'.
proc JS_SetPropertyStr(ctx: ptr JSContext; thisObj: JSValue;
                       prop: cstring; val: JSValue): cint
                                            {.importc: "JS_SetPropertyStr".}
proc JS_FreeCString(ctx: ptr JSContext; str: cstring)
                                            {.importc: "JS_FreeCString".}
## JS_NewCFunction2 is the non-inline core used by JS_NewCFunction / JS_NewCFunctionMagic.
proc JS_NewCFunction2(ctx: ptr JSContext; fn: JSCFunction; name: cstring;
                      length: cint; cproto: cint; magic: cint): JSValue
                                            {.importc: "JS_NewCFunction2".}
proc JS_NewStringLen(ctx: ptr JSContext; str: cstring; len: csize_t): JSValue
                                            {.importc: "JS_NewStringLen".}
proc JS_ToCStringLen2(ctx: ptr JSContext; plen: ptr csize_t;
                      val: JSValue; cesu8: cint): cstring
                                            {.importc: "JS_ToCStringLen2".}

# ===========================================================================
# QuickJS inline-function wrappers (from c_src/rwebview_qjs_wrap.c)
# ===========================================================================

proc rw_JS_IsException(v: JSValue): cint   {.importc: "rw_JS_IsException".}
proc rw_JS_FreeValue(ctx: ptr JSContext; v: JSValue)
                                           {.importc: "rw_JS_FreeValue".}
proc rw_JS_DupValue(ctx: ptr JSContext; v: JSValue): JSValue
                                           {.importc: "rw_JS_DupValue".}
proc rw_JS_Undefined(): JSValue            {.importc: "rw_JS_Undefined".}
proc rw_JS_Null(): JSValue                 {.importc: "rw_JS_Null".}
proc rw_JS_True(): JSValue                 {.importc: "rw_JS_True".}
proc rw_JS_False(): JSValue                {.importc: "rw_JS_False".}
proc rw_JS_NewString(ctx: ptr JSContext; s: cstring): JSValue
                                           {.importc: "rw_JS_NewString".}

# ===========================================================================
# QuickJS additional non-inline API
# ===========================================================================

proc rw_JS_NewInt32(ctx: ptr JSContext; v: int32): JSValue
    {.importc: "rw_JS_NewInt32".}
proc rw_JS_NewFloat64(ctx: ptr JSContext; v: float64): JSValue
    {.importc: "rw_JS_NewFloat64".}
proc rw_JS_NewBool(ctx: ptr JSContext; v: cint): JSValue
    {.importc: "rw_JS_NewBool".}

proc JS_GetPropertyStr(ctx: ptr JSContext; thisObj: JSValue;
                       prop: cstring): JSValue
    {.importc: "JS_GetPropertyStr".}
proc JS_SetPropertyUint32(ctx: ptr JSContext; thisObj: JSValue;
                           idx: uint32; val: JSValue): cint
    {.importc: "JS_SetPropertyUint32".}
proc JS_NewArray(ctx: ptr JSContext): JSValue
    {.importc: "JS_NewArray".}
proc JS_Call(ctx: ptr JSContext; funcObj: JSValue; thisObj: JSValue;
             argc: cint; argv: ptr JSValue): JSValue
    {.importc: "JS_Call".}
proc JS_IsFunction(ctx: ptr JSContext; v: JSValue): cint
    {.importc: "JS_IsFunction".}
proc JS_ToInt32(ctx: ptr JSContext; pres: ptr int32; v: JSValue): cint
    {.importc: "JS_ToInt32".}
proc JS_NewCFunction(ctx: ptr JSContext; fn: JSCFunction; name: cstring;
                     length: cint): JSValue
    {.importc: "rw_JS_NewCFunction".}
proc JS_ExecutePendingJob(rt: ptr JSRuntime; pctx: ptr ptr JSContext): cint
    {.importc: "JS_ExecutePendingJob".}

# Phase 4 additions — numeric conversion + typed array access
proc JS_ToFloat64(ctx: ptr JSContext; pres: ptr float64; v: JSValue): cint
    {.importc: "JS_ToFloat64".}
proc rw_JS_ToUint32(ctx: ptr JSContext; pres: ptr uint32; v: JSValue): cint
    {.importc: "rw_JS_ToUint32".}
proc JS_GetArrayBuffer(ctx: ptr JSContext; psize: ptr csize_t; obj: JSValue): ptr uint8
    {.importc: "JS_GetArrayBuffer".}
proc JS_GetTypedArrayBuffer(ctx: ptr JSContext; obj: JSValue;
                             pbyteOffset: ptr csize_t;
                             pbyteLength: ptr csize_t;
                             pbytesPerElement: ptr csize_t): JSValue
    {.importc: "JS_GetTypedArrayBuffer".}
proc rw_JS_VALUE_GET_TAG(v: JSValue): cint
    {.importc: "rw_JS_VALUE_GET_TAG".}

# ===========================================================================
# Nim helpers
# ===========================================================================

proc jsToCString(ctx: ptr JSContext; v: JSValue): cstring {.inline.} =
  JS_ToCStringLen2(ctx, nil, v, 0)

proc jsValToStr(ctx: ptr JSContext; v: JSValue): string =
  let s = jsToCString(ctx, v)
  if s == nil: return "undefined"
  result = $s
  JS_FreeCString(ctx, s)

proc jsCheck(ctx: ptr JSContext; v: JSValue; label: string): bool =
  ## Consume v; return false and print if it is an exception.
  if rw_JS_IsException(v) != 0:
    let exc = JS_GetException(ctx)
    let msg = jsToCString(ctx, exc)
    if msg != nil:
      stderr.writeLine("[rwebview] JS exception in '" & label & "': " & $msg)
      JS_FreeCString(ctx, msg)
    rw_JS_FreeValue(ctx, exc)
    rw_JS_FreeValue(ctx, v)
    return false
  rw_JS_FreeValue(ctx, v)
  true

# ===========================================================================
# Phase 4 — OpenGL types, function pointers, and loader
# ===========================================================================

type
  GLenum     = uint32
  GLuint     = uint32
  GLint      = int32
  GLsizei    = int32
  GLfloat    = float32
  GLboolean  = uint8
  GLbitfield = uint32
  GLclampf   = float32
  GLubyte    = uint8

# -- OpenGL function pointer variables (loaded via SDL_GL_GetProcAddress) ----

var
  # State
  glViewport:        proc(x, y: GLint; w, h: GLsizei) {.cdecl.}
  glClearColor:      proc(r, g, b, a: GLclampf) {.cdecl.}
  glClear:           proc(mask: GLbitfield) {.cdecl.}
  glEnable:          proc(cap: GLenum) {.cdecl.}
  glDisable:         proc(cap: GLenum) {.cdecl.}
  glBlendFunc:       proc(sfactor, dfactor: GLenum) {.cdecl.}
  glBlendFuncSeparate: proc(srcRGB, dstRGB, srcAlpha, dstAlpha: GLenum) {.cdecl.}
  glBlendEquation:   proc(mode: GLenum) {.cdecl.}
  glBlendEquationSeparate: proc(modeRGB, modeAlpha: GLenum) {.cdecl.}
  glBlendColor:      proc(r, g, b, a: GLclampf) {.cdecl.}
  glDepthFunc:       proc(fn: GLenum) {.cdecl.}
  glDepthMask:       proc(flag: GLboolean) {.cdecl.}
  glDepthRange:      proc(n, f: float64) {.cdecl.}
  glClearDepth:      proc(d: float64) {.cdecl.}
  glCullFace:        proc(mode: GLenum) {.cdecl.}
  glFrontFace:       proc(mode: GLenum) {.cdecl.}
  glScissor:         proc(x, y: GLint; w, h: GLsizei) {.cdecl.}
  glLineWidth:       proc(width: GLfloat) {.cdecl.}
  glColorMask:       proc(r, g, b, a: GLboolean) {.cdecl.}
  glStencilFunc:     proc(fn: GLenum; refVal: GLint; mask: GLuint) {.cdecl.}
  glStencilFuncSeparate: proc(face, fn: GLenum; refVal: GLint; mask: GLuint) {.cdecl.}
  glStencilOp:       proc(fail, zfail, zpass: GLenum) {.cdecl.}
  glStencilOpSeparate: proc(face, fail, zfail, zpass: GLenum) {.cdecl.}
  glStencilMask:     proc(mask: GLuint) {.cdecl.}
  glStencilMaskSeparate: proc(face: GLenum; mask: GLuint) {.cdecl.}
  glClearStencil:    proc(s: GLint) {.cdecl.}
  glPixelStorei:     proc(pname: GLenum; param: GLint) {.cdecl.}
  glFlush:           proc() {.cdecl.}
  glFinish:          proc() {.cdecl.}
  glGetError:        proc(): GLenum {.cdecl.}
  glGetIntegerv:     proc(pname: GLenum; params: ptr GLint) {.cdecl.}
  glGetFloatv:       proc(pname: GLenum; params: ptr GLfloat) {.cdecl.}
  glGetBooleanv:     proc(pname: GLenum; params: ptr GLboolean) {.cdecl.}
  glGetString:       proc(name: GLenum): ptr GLubyte {.cdecl.}
  glIsEnabled:       proc(cap: GLenum): GLboolean {.cdecl.}
  # Shaders
  glCreateShader:    proc(typ: GLenum): GLuint {.cdecl.}
  glDeleteShader:    proc(shader: GLuint) {.cdecl.}
  glShaderSource:    proc(shader: GLuint; count: GLsizei; strings: ptr cstring; lengths: ptr GLint) {.cdecl.}
  glCompileShader:   proc(shader: GLuint) {.cdecl.}
  glGetShaderiv:     proc(shader: GLuint; pname: GLenum; params: ptr GLint) {.cdecl.}
  glGetShaderInfoLog: proc(shader: GLuint; maxLen: GLsizei; length: ptr GLsizei; log: cstring) {.cdecl.}
  glCreateProgram:   proc(): GLuint {.cdecl.}
  glDeleteProgram:   proc(program: GLuint) {.cdecl.}
  glAttachShader:    proc(program, shader: GLuint) {.cdecl.}
  glDetachShader:    proc(program, shader: GLuint) {.cdecl.}
  glLinkProgram:     proc(program: GLuint) {.cdecl.}
  glGetProgramiv:    proc(program: GLuint; pname: GLenum; params: ptr GLint) {.cdecl.}
  glGetProgramInfoLog: proc(program: GLuint; maxLen: GLsizei; length: ptr GLsizei; log: cstring) {.cdecl.}
  glUseProgram:      proc(program: GLuint) {.cdecl.}
  glValidateProgram: proc(program: GLuint) {.cdecl.}
  glGetAttribLocation: proc(program: GLuint; name: cstring): GLint {.cdecl.}
  glGetUniformLocation: proc(program: GLuint; name: cstring): GLint {.cdecl.}
  glBindAttribLocation: proc(program: GLuint; index: GLuint; name: cstring) {.cdecl.}
  glGetActiveAttrib: proc(program: GLuint; index: GLuint; bufSize: GLsizei;
                          length: ptr GLsizei; size: ptr GLint; typ: ptr GLenum; name: cstring) {.cdecl.}
  glGetActiveUniform: proc(program: GLuint; index: GLuint; bufSize: GLsizei;
                           length: ptr GLsizei; size: ptr GLint; typ: ptr GLenum; name: cstring) {.cdecl.}
  # Buffers
  glGenBuffers:      proc(n: GLsizei; buffers: ptr GLuint) {.cdecl.}
  glDeleteBuffers:   proc(n: GLsizei; buffers: ptr GLuint) {.cdecl.}
  glBindBuffer:      proc(target: GLenum; buffer: GLuint) {.cdecl.}
  glBufferData:      proc(target: GLenum; size: int; data: pointer; usage: GLenum) {.cdecl.}
  glBufferSubData:   proc(target: GLenum; offset: int; size: int; data: pointer) {.cdecl.}
  glVertexAttribPointer: proc(index: GLuint; size: GLint; typ: GLenum;
                              normalized: GLboolean; stride: GLsizei; offset: pointer) {.cdecl.}
  glEnableVertexAttribArray:  proc(index: GLuint) {.cdecl.}
  glDisableVertexAttribArray: proc(index: GLuint) {.cdecl.}
  # Textures
  glGenTextures:     proc(n: GLsizei; textures: ptr GLuint) {.cdecl.}
  glDeleteTextures:  proc(n: GLsizei; textures: ptr GLuint) {.cdecl.}
  glBindTexture:     proc(target: GLenum; texture: GLuint) {.cdecl.}
  glActiveTexture:   proc(texture: GLenum) {.cdecl.}
  glTexImage2D:      proc(target: GLenum; level: GLint; internalformat: GLint;
                          width, height: GLsizei; border: GLint;
                          format: GLenum; typ: GLenum; pixels: pointer) {.cdecl.}
  glTexSubImage2D:   proc(target: GLenum; level: GLint; xoffset, yoffset: GLint;
                          width, height: GLsizei; format: GLenum; typ: GLenum; pixels: pointer) {.cdecl.}
  glTexParameteri:   proc(target, pname: GLenum; param: GLint) {.cdecl.}
  glTexParameterf:   proc(target, pname: GLenum; param: GLfloat) {.cdecl.}
  glGenerateMipmap:  proc(target: GLenum) {.cdecl.}
  glCopyTexImage2D:  proc(target: GLenum; level: GLint; internalfmt: GLenum;
                          x, y: GLint; w, h: GLsizei; border: GLint) {.cdecl.}
  glCopyTexSubImage2D: proc(target: GLenum; level: GLint; xoff, yoff: GLint;
                            x, y: GLint; w, h: GLsizei) {.cdecl.}
  # Framebuffers
  glGenFramebuffers:      proc(n: GLsizei; fbs: ptr GLuint) {.cdecl.}
  glDeleteFramebuffers:   proc(n: GLsizei; fbs: ptr GLuint) {.cdecl.}
  glBindFramebuffer:      proc(target: GLenum; fb: GLuint) {.cdecl.}
  glFramebufferTexture2D: proc(target, attachment, textarget: GLenum;
                               texture: GLuint; level: GLint) {.cdecl.}
  glFramebufferRenderbuffer: proc(target, attachment, rbtarget: GLenum;
                                  rb: GLuint) {.cdecl.}
  glCheckFramebufferStatus: proc(target: GLenum): GLenum {.cdecl.}
  # Renderbuffers
  glGenRenderbuffers:    proc(n: GLsizei; rbs: ptr GLuint) {.cdecl.}
  glDeleteRenderbuffers: proc(n: GLsizei; rbs: ptr GLuint) {.cdecl.}
  glBindRenderbuffer:    proc(target: GLenum; rb: GLuint) {.cdecl.}
  glRenderbufferStorage: proc(target, internalfmt: GLenum; w, h: GLsizei) {.cdecl.}
  glGetRenderbufferParameteriv: proc(target, pname: GLenum; params: ptr GLint) {.cdecl.}
  # Drawing
  glDrawArrays:      proc(mode: GLenum; first: GLint; count: GLsizei) {.cdecl.}
  glDrawElements:    proc(mode: GLenum; count: GLsizei; typ: GLenum; indices: pointer) {.cdecl.}
  # Uniforms
  glUniform1f: proc(loc: GLint; v0: GLfloat) {.cdecl.}
  glUniform2f: proc(loc: GLint; v0, v1: GLfloat) {.cdecl.}
  glUniform3f: proc(loc: GLint; v0, v1, v2: GLfloat) {.cdecl.}
  glUniform4f: proc(loc: GLint; v0, v1, v2, v3: GLfloat) {.cdecl.}
  glUniform1i: proc(loc: GLint; v0: GLint) {.cdecl.}
  glUniform2i: proc(loc: GLint; v0, v1: GLint) {.cdecl.}
  glUniform3i: proc(loc: GLint; v0, v1, v2: GLint) {.cdecl.}
  glUniform4i: proc(loc: GLint; v0, v1, v2, v3: GLint) {.cdecl.}
  glUniform1fv: proc(loc: GLint; count: GLsizei; v: ptr GLfloat) {.cdecl.}
  glUniform2fv: proc(loc: GLint; count: GLsizei; v: ptr GLfloat) {.cdecl.}
  glUniform3fv: proc(loc: GLint; count: GLsizei; v: ptr GLfloat) {.cdecl.}
  glUniform4fv: proc(loc: GLint; count: GLsizei; v: ptr GLfloat) {.cdecl.}
  glUniform1iv: proc(loc: GLint; count: GLsizei; v: ptr GLint) {.cdecl.}
  glUniform2iv: proc(loc: GLint; count: GLsizei; v: ptr GLint) {.cdecl.}
  glUniform3iv: proc(loc: GLint; count: GLsizei; v: ptr GLint) {.cdecl.}
  glUniform4iv: proc(loc: GLint; count: GLsizei; v: ptr GLint) {.cdecl.}
  glUniformMatrix2fv: proc(loc: GLint; count: GLsizei; transpose: GLboolean; v: ptr GLfloat) {.cdecl.}
  glUniformMatrix3fv: proc(loc: GLint; count: GLsizei; transpose: GLboolean; v: ptr GLfloat) {.cdecl.}
  glUniformMatrix4fv: proc(loc: GLint; count: GLsizei; transpose: GLboolean; v: ptr GLfloat) {.cdecl.}
  # Reading
  glReadPixels: proc(x, y: GLint; w, h: GLsizei; format, typ: GLenum; pixels: pointer) {.cdecl.}
  # Vertex Array Objects (Core Profile requires a VAO to be bound)
  glGenVertexArrays:    proc(n: GLsizei; arrays: ptr GLuint) {.cdecl.}
  glDeleteVertexArrays: proc(n: GLsizei; arrays: ptr GLuint) {.cdecl.}
  glBindVertexArray:    proc(arr: GLuint) {.cdecl.}
  # Instanced rendering (for ANGLE_instanced_arrays extension)
  glDrawArraysInstanced:   proc(mode: GLenum; first: GLint; count, instanceCount: GLsizei) {.cdecl.}
  glDrawElementsInstanced: proc(mode: GLenum; count: GLsizei; typ: GLenum;
                                indices: pointer; instanceCount: GLsizei) {.cdecl.}
  glVertexAttribDivisor:   proc(index: GLuint; divisor: GLuint) {.cdecl.}
  # Shader precision (GL 4.1 / GL ES 2.0; may be nil on GL 3.3)
  glGetShaderPrecisionFormat: proc(shaderType, precisionType: GLenum;
                                   range: ptr GLint; precision: ptr GLint) {.cdecl.}

# Default VAO handle (Core Profile requires a VAO to be bound at all times)
var glDefaultVAO: GLuint = 0

# WebGL-specific pixelStorei state (no OpenGL equivalent)
var glUnpackFlipY: bool = false
var glUnpackPremultiplyAlpha: bool = false

proc loadGLProcs() =
  ## Load all OpenGL function pointers via SDL_GL_GetProcAddress.
  ## Must be called after SDL_GL_CreateContext.
  template load(name: untyped) =
    name = cast[typeof(name)](SDL_GL_GetProcAddress(astToStr(name)))

  load(glViewport); load(glClearColor); load(glClear)
  load(glEnable); load(glDisable)
  load(glBlendFunc); load(glBlendFuncSeparate)
  load(glBlendEquation); load(glBlendEquationSeparate); load(glBlendColor)
  load(glDepthFunc); load(glDepthMask); load(glDepthRange); load(glClearDepth)
  load(glCullFace); load(glFrontFace); load(glScissor); load(glLineWidth)
  load(glColorMask)
  load(glStencilFunc); load(glStencilFuncSeparate)
  load(glStencilOp); load(glStencilOpSeparate)
  load(glStencilMask); load(glStencilMaskSeparate)
  load(glClearStencil); load(glPixelStorei)
  load(glFlush); load(glFinish)
  load(glGetError); load(glGetIntegerv); load(glGetFloatv)
  load(glGetBooleanv); load(glGetString); load(glIsEnabled)
  load(glCreateShader); load(glDeleteShader)
  load(glShaderSource); load(glCompileShader)
  load(glGetShaderiv); load(glGetShaderInfoLog)
  load(glCreateProgram); load(glDeleteProgram)
  load(glAttachShader); load(glDetachShader); load(glLinkProgram)
  load(glGetProgramiv); load(glGetProgramInfoLog)
  load(glUseProgram); load(glValidateProgram)
  load(glGetAttribLocation); load(glGetUniformLocation); load(glBindAttribLocation)
  load(glGetActiveAttrib); load(glGetActiveUniform)
  load(glGenBuffers); load(glDeleteBuffers); load(glBindBuffer)
  load(glBufferData); load(glBufferSubData)
  load(glVertexAttribPointer)
  load(glEnableVertexAttribArray); load(glDisableVertexAttribArray)
  load(glGenTextures); load(glDeleteTextures); load(glBindTexture)
  load(glActiveTexture)
  load(glTexImage2D); load(glTexSubImage2D)
  load(glTexParameteri); load(glTexParameterf)
  load(glGenerateMipmap); load(glCopyTexImage2D); load(glCopyTexSubImage2D)
  load(glGenFramebuffers); load(glDeleteFramebuffers); load(glBindFramebuffer)
  load(glFramebufferTexture2D); load(glFramebufferRenderbuffer)
  load(glCheckFramebufferStatus)
  load(glGenRenderbuffers); load(glDeleteRenderbuffers); load(glBindRenderbuffer)
  load(glRenderbufferStorage); load(glGetRenderbufferParameteriv)
  load(glDrawArrays); load(glDrawElements)
  load(glUniform1f); load(glUniform2f); load(glUniform3f); load(glUniform4f)
  load(glUniform1i); load(glUniform2i); load(glUniform3i); load(glUniform4i)
  load(glUniform1fv); load(glUniform2fv); load(glUniform3fv); load(glUniform4fv)
  load(glUniform1iv); load(glUniform2iv); load(glUniform3iv); load(glUniform4iv)
  load(glUniformMatrix2fv); load(glUniformMatrix3fv); load(glUniformMatrix4fv)
  load(glReadPixels)
  load(glGenVertexArrays); load(glDeleteVertexArrays); load(glBindVertexArray)
  load(glDrawArraysInstanced); load(glDrawElementsInstanced); load(glVertexAttribDivisor)
  # Optional — may be nil on GL 3.3 (only in GL 4.1+ / GL ES 2.0)
  glGetShaderPrecisionFormat = cast[typeof(glGetShaderPrecisionFormat)](
    SDL_GL_GetProcAddress("glGetShaderPrecisionFormat"))

  # Create and bind the default VAO (Core Profile requires a VAO)
  glGenVertexArrays(1, addr glDefaultVAO)
  glBindVertexArray(glDefaultVAO)

# ===========================================================================
# Phase 5 — Canvas 2D state types and globals
# ===========================================================================

type
  Canvas2DSavedState = object
    fillR, fillG, fillB, fillA: uint8
    globalAlpha: float32
    fontSize: float32
    fontFamily: string
    textBaseline: string
    textAlign: string
    transform: array[6, float32]  # a,b,c,d,e,f

  Canvas2DState = object
    width, height: int
    pixels: seq[uint8]      # RGBA, width*height*4 bytes
    fillR, fillG, fillB, fillA: uint8
    globalAlpha: float32
    fontSize: float32
    fontFamily: string
    textBaseline: string
    textAlign: string
    transform: array[6, float32]  # a,b,c,d,e,f
    stateStack: seq[Canvas2DSavedState]
    canvasJsVal: JSValue    # reference to the canvas JS element (for width/height sync)

var canvas2dStates: seq[Canvas2DState]
var ttfFontCache: Table[string, ptr TTF_Font]  # key = "family:size"
var ttfInitialized: bool = false
var defaultFontPath: string = ""  # resolved on first use

proc initCanvas2DState(w, h: int): Canvas2DState =
  result.width = w
  result.height = h
  result.pixels = newSeq[uint8](w * h * 4)
  result.fillR = 0; result.fillG = 0; result.fillB = 0; result.fillA = 255
  result.globalAlpha = 1.0f
  result.fontSize = 10.0f
  result.fontFamily = "sans-serif"
  result.textBaseline = "alphabetic"
  result.textAlign = "start"
  result.transform = [1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f]  # identity

proc resizeCanvas2D(state: var Canvas2DState; w, h: int) =
  if w == state.width and h == state.height: return
  state.width = w
  state.height = h
  state.pixels = newSeq[uint8](w * h * 4)

proc getOrLoadFont(family: string; size: float32; baseDir: string): ptr TTF_Font =
  if not ttfInitialized:
    if not TTF_Init():
      stderr.writeLine("[rwebview] TTF_Init failed")
      return nil
    ttfInitialized = true
  let key = family & ":" & $size
  if key in ttfFontCache:
    return ttfFontCache[key]
  # Try to find the font file
  var path = ""
  let lowerFamily = family.toLowerAscii()
  # Try common font paths relative to baseDir
  for dir in [baseDir / "fonts", baseDir / ".." / "fonts", baseDir]:
    for ext in [".ttf", ".otf", ".TTF", ".OTF"]:
      let candidate = dir / family & ext
      if fileExists(candidate):
        path = candidate
        break
      # Also try case-insensitive match
      if fileExists(dir):
        for f in walkDir(dir, relative = true):
          let lcName = f.path.toLowerAscii()
          if lcName == lowerFamily & ext.toLowerAscii():
            path = dir / f.path
            break
    if path != "": break
  # Fallback: try the cached default font path
  if path == "" and defaultFontPath != "" and fileExists(defaultFontPath):
    path = defaultFontPath
  if path == "":
    stderr.writeLine("[rwebview] font not found: " & family)
    return nil
  let font = TTF_OpenFont(cstring(path), cfloat(size))
  if font == nil:
    stderr.writeLine("[rwebview] TTF_OpenFont failed for: " & path)
    return nil
  if defaultFontPath == "":
    defaultFontPath = path  # cache first successfully loaded font as default
  ttfFontCache[key] = font
  font

proc parseCssColor(s: string; r, g, b, a: var uint8) =
  ## Parse CSS color string into RGBA components.
  ## Supports: #RGB, #RRGGBB, #RRGGBBAA, rgb(), rgba(), named colors.
  let s = s.strip()
  if s.len == 0: return
  if s[0] == '#':
    let hex = s[1..^1]
    if hex.len == 3:
      r = uint8(parseHexInt(hex[0..0] & hex[0..0]))
      g = uint8(parseHexInt(hex[1..1] & hex[1..1]))
      b = uint8(parseHexInt(hex[2..2] & hex[2..2]))
      a = 255
    elif hex.len == 6:
      r = uint8(parseHexInt(hex[0..1]))
      g = uint8(parseHexInt(hex[2..3]))
      b = uint8(parseHexInt(hex[4..5]))
      a = 255
    elif hex.len == 8:
      r = uint8(parseHexInt(hex[0..1]))
      g = uint8(parseHexInt(hex[2..3]))
      b = uint8(parseHexInt(hex[4..5]))
      a = uint8(parseHexInt(hex[6..7]))
  elif s.startsWith("rgba(") or s.startsWith("rgb("):
    let inner = s[s.find('(') + 1 ..< s.find(')')]
    let parts = inner.split(',')
    if parts.len >= 3:
      r = uint8(parseInt(parts[0].strip()) and 255)
      g = uint8(parseInt(parts[1].strip()) and 255)
      b = uint8(parseInt(parts[2].strip()) and 255)
      if parts.len >= 4:
        a = uint8(parseFloat(parts[3].strip()) * 255.0)
      else:
        a = 255
  else:
    # Named color lookup (common ones used by RPG Maker)
    case s.toLowerAscii()
    of "white":   r = 255; g = 255; b = 255; a = 255
    of "black":   r = 0;   g = 0;   b = 0;   a = 255
    of "red":     r = 255; g = 0;   b = 0;   a = 255
    of "green":   r = 0;   g = 128; b = 0;   a = 255
    of "blue":    r = 0;   g = 0;   b = 255; a = 255
    of "yellow":  r = 255; g = 255; b = 0;   a = 255
    of "transparent": r = 0; g = 0; b = 0; a = 0
    else: discard

proc parseCssFont(fontStr: string; size: var float32; family: var string) =
  ## Parse CSS font shorthand like "24px GameFont" or "bold 16px Arial".
  let parts = fontStr.strip().splitWhitespace()
  var i = 0
  # Skip optional style/variant/weight tokens
  while i < parts.len:
    let p = parts[i].toLowerAscii()
    if p == "italic" or p == "oblique" or p == "normal" or
       p == "bold" or p == "bolder" or p == "lighter" or
       p == "small-caps" or
       p.len > 0 and p[0].isDigit and not p.endsWith("px") and not p.endsWith("pt"):
      inc i
    else:
      break
  # Next token should be size
  if i < parts.len:
    let sizeStr = parts[i]
    if sizeStr.endsWith("px"):
      try: size = parseFloat(sizeStr[0..^3]).float32
      except: discard
    elif sizeStr.endsWith("pt"):
      try: size = parseFloat(sizeStr[0..^3]).float32 * 1.333f
      except: discard
    inc i
  # Remaining tokens = font family
  if i < parts.len:
    family = parts[i..^1].join(" ").replace("'", "").replace("\"", "")

# ===========================================================================
# Lexbor types  (all opaque — layout never needed on the Nim side)
# ===========================================================================

type
  LxbHtmlParser    = object   # opaque
  LxbHtmlDocument  = object   # opaque
  LxbDomDocument   = object   # opaque  (first field of LxbHtmlDocument)
  LxbDomElement    = object   # opaque
  LxbDomCollection = object   # opaque

# lxb_status_t is uint; 0 = LXB_STATUS_OK
type LxbStatus = cuint

const lxbStatusOk = 0.LxbStatus

# ===========================================================================
# Lexbor FFI  (linked via -llexbor_static)
# ===========================================================================

# -- Parser --
proc lxb_html_parser_create(): ptr LxbHtmlParser
    {.importc: "lxb_html_parser_create".}
proc lxb_html_parser_init(parser: ptr LxbHtmlParser): LxbStatus
    {.importc: "lxb_html_parser_init".}
proc lxb_html_parser_destroy(parser: ptr LxbHtmlParser): ptr LxbHtmlParser
    {.importc: "lxb_html_parser_destroy".}

# -- Parsing --
proc lxb_html_parse(parser: ptr LxbHtmlParser;
                    html: pointer; size: csize_t): ptr LxbHtmlDocument
    {.importc: "lxb_html_parse".}
proc lxb_html_document_destroy(doc: ptr LxbHtmlDocument): ptr LxbHtmlDocument
    {.importc: "lxb_html_document_destroy".}

# -- Collection (non-inline _noi variants are exported symbols) --
proc lxb_dom_collection_make_noi(document: ptr LxbDomDocument;
                                   start_list_size: csize_t): ptr LxbDomCollection
    {.importc: "lxb_dom_collection_make_noi".}
proc lxb_dom_collection_destroy(col: ptr LxbDomCollection;
                                  self_destroy: bool): ptr LxbDomCollection
    {.importc: "lxb_dom_collection_destroy".}
proc lxb_dom_collection_length_noi(col: ptr LxbDomCollection): csize_t
    {.importc: "lxb_dom_collection_length_noi".}
proc lxb_dom_collection_element_noi(col: ptr LxbDomCollection;
                                     idx: csize_t): ptr LxbDomElement
    {.importc: "lxb_dom_collection_element_noi".}

# -- DOM element queries --
proc lxb_dom_elements_by_tag_name(root: ptr LxbDomElement;
                                    col: ptr LxbDomCollection;
                                    qualified_name: pointer;
                                    len: csize_t): LxbStatus
    {.importc: "lxb_dom_elements_by_tag_name".}

# -- Attribute access --
proc lxb_dom_element_get_attribute(element: ptr LxbDomElement;
                                    qualified_name: pointer; qn_len: csize_t;
                                    value_len: ptr csize_t): cstring
    {.importc: "lxb_dom_element_get_attribute".}

# -- Node text content (for inline <script> bodies) --
proc lxb_dom_node_text_content(node: ptr LxbDomElement;
                                len: ptr csize_t): cstring
    {.importc: "lxb_dom_node_text_content".}

# -- Document root element (non-inline) --
proc lxb_dom_document_element_noi(document: ptr LxbDomDocument): ptr LxbDomElement
    {.importc: "lxb_dom_document_element_noi".}

# ===========================================================================
# Lexbor C wrapper (rwebview_lexbor_wrap.c)
# ===========================================================================

# Cast lxb_html_document_t* → lxb_dom_document_t* (first-field pointer)
proc rw_lxb_html_doc_to_dom(doc: ptr LxbHtmlDocument): ptr LxbDomDocument
    {.importc: "rw_lxb_html_doc_to_dom".}

# ===========================================================================
# Internal state
# ===========================================================================

# ===========================================================================
# Internal state
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
  rafPending:   seq[RAfEntry]   ## rAF callbacks to fire this frame
  rafStaging:   seq[RAfEntry]   ## rAF callbacks registered during frame dispatch
  timers:       seq[TimerEntry]
  mouseButtons: uint32   ## bitmask of currently-pressed JS mouse buttons

# ===========================================================================
# Phase 2 — HTML Script Loader
# ===========================================================================

type ScriptEntry = object
  src:    string   ## non-empty → external file path (relative to baseDir)
  inline: string   ## non-empty → inline script text
  isModule: bool   ## true if type="module" (treated as regular script)

proc resolveUrl(url: string; state: ptr RWebviewState): string =
  ## Resolve a URL to an absolute local filesystem path.
  ##
  ## Handles two forms:
  ##   http://rover.assets/<path>  →  virtualHosts["rover.assets"] / <path>
  ##   file:///abs/path            →  /abs/path  (pass-through)
  ##   relative/path               →  state.baseDir / path
  ##
  ## The virtual-host table is populated by
  ## webview_set_virtual_host_name_to_folder_mapping().
  if url.startsWith("http://") or url.startsWith("https://"):
    # strip scheme
    let noScheme = url[url.find("://") + 3 .. ^1]
    let slashPos = noScheme.find('/')
    if slashPos < 0:
      return state.baseDir   # bare host, no path
    let host = noScheme[0 ..< slashPos]
    let path = noScheme[slashPos + 1 .. ^1]  # strip leading /
    let lcHost = host.toLowerAscii()
    if lcHost in state.virtualHosts:
      return state.virtualHosts[lcHost] / path
    # Unknown virtual host — try baseDir as fallback
    return state.baseDir / path
  elif url.startsWith("file:///"):
    return url[8 .. ^1]
  else:
    # Relative path — resolve against baseDir
    if isAbsolute(url):
      return url
    return state.baseDir / url

proc elemAttr(el: ptr LxbDomElement; name: string): string =
  ## Return the value of attribute `name` on element `el`, or "" if absent.
  var vlen: csize_t = 0
  let val = lxb_dom_element_get_attribute(el,
               cast[pointer](cstring(name)), csize_t(name.len), addr vlen)
  if val == nil or vlen == 0:
    return ""
  result = newString(int(vlen))
  copyMem(addr result[0], val, int(vlen))

proc elemTextContent(el: ptr LxbDomElement): string =
  ## Return the text content of element `el` (for inline <script> bodies).
  var tlen: csize_t = 0
  let txt = lxb_dom_node_text_content(el, addr tlen)
  if txt == nil or tlen == 0:
    return ""
  result = newString(int(tlen))
  copyMem(addr result[0], txt, int(tlen))

proc parseScripts(htmlContent: string; baseDir: string): seq[ScriptEntry] =
  ## Parse *htmlContent* with Lexbor, walk the DOM, and return all <script>
  ## entries in document order.  Each entry carries either a resolved
  ## filesystem path (`src`) or the inline script text (`inline`).
  result = @[]

  let parser = lxb_html_parser_create()
  if parser == nil:
    stderr.writeLine("[rwebview] lxb_html_parser_create failed")
    return

  if lxb_html_parser_init(parser) != lxbStatusOk:
    stderr.writeLine("[rwebview] lxb_html_parser_init failed")
    discard lxb_html_parser_destroy(parser)
    return

  let doc = lxb_html_parse(parser,
               cast[pointer](cstring(htmlContent)),
               csize_t(htmlContent.len))
  discard lxb_html_parser_destroy(parser)   # parser no longer needed

  if doc == nil:
    stderr.writeLine("[rwebview] lxb_html_parse returned nil")
    return

  let domDoc = rw_lxb_html_doc_to_dom(doc)
  if domDoc == nil:
    stderr.writeLine("[rwebview] rw_lxb_html_doc_to_dom returned nil")
    discard lxb_html_document_destroy(doc)
    return

  let rootEl = lxb_dom_document_element_noi(domDoc)
  if rootEl == nil:
    stderr.writeLine("[rwebview] document root element is nil — empty HTML?")
    discard lxb_html_document_destroy(doc)
    return

  let col = lxb_dom_collection_make_noi(domDoc, 64)
  if col == nil:
    stderr.writeLine("[rwebview] lxb_dom_collection_make_noi failed")
    discard lxb_html_document_destroy(doc)
    return

  let tagScript = "script"
  if lxb_dom_elements_by_tag_name(rootEl, col,
       cast[pointer](cstring(tagScript)), csize_t(tagScript.len)) != lxbStatusOk:
    stderr.writeLine("[rwebview] lxb_dom_elements_by_tag_name failed")
    discard lxb_dom_collection_destroy(col, true)
    discard lxb_html_document_destroy(doc)
    return

  let count = lxb_dom_collection_length_noi(col)

  for i in 0 ..< count:
    let el = lxb_dom_collection_element_noi(col, i)
    if el == nil: continue

    let typAttr = elemAttr(el, "type")
    let isModule = (typAttr.toLowerAscii() == "module")
    if isModule:
      stderr.writeLine("[rwebview] <script type=\"module\"> found — " &
                       "treating as regular script (ES modules not supported)")

    let srcAttr = elemAttr(el, "src")
    if srcAttr.len > 0:
      # External script: resolve URL to a local filesystem path.
      # srcAttr may be a relative path like "js/main.js" or a full URL.
      var resolved: string
      if srcAttr.startsWith("http://") or srcAttr.startsWith("https://") or
         srcAttr.startsWith("file:///"):
        # Full URL: use resolveUrl but we have no state here.
        # Resolve relative to baseDir directly.
        let noScheme = srcAttr[srcAttr.find("://") + 3 .. ^1]
        let slashPos = noScheme.find('/')
        if slashPos >= 0:
          resolved = baseDir / noScheme[slashPos + 1 .. ^1]
        else:
          resolved = baseDir
      else:
        resolved = baseDir / srcAttr
      result.add(ScriptEntry(src: resolved, isModule: isModule))
    else:
      let inlineCode = elemTextContent(el)
      if inlineCode.len > 0:
        result.add(ScriptEntry(inline: inlineCode, isModule: isModule))
      # else: empty script tag — skip

  discard lxb_dom_collection_destroy(col, true)
  discard lxb_html_document_destroy(doc)

proc executeScripts(scripts: seq[ScriptEntry]; ctx: ptr JSContext;
                    label: string) =
  ## Execute *scripts* sequentially in the given QuickJS context.
  ## Halts (but does not crash) on the first JS exception.
  for entry in scripts:
    if entry.src.len > 0:
      # External script file
      if not fileExists(entry.src):
        stderr.writeLine("[rwebview] script file not found: " & entry.src)
        continue
      let code = readFile(entry.src)
      let ret = JS_Eval(ctx, cstring(code), csize_t(code.len),
                        cstring(entry.src), JS_EVAL_TYPE_GLOBAL)
      if not jsCheck(ctx, ret, entry.src):
        stderr.writeLine("[rwebview] halting script execution after error in: " &
                         entry.src)
        return
    else:
      # Inline script
      let ret = JS_Eval(ctx, cstring(entry.inline), csize_t(entry.inline.len),
                        cstring("<" & label & " inline>"), JS_EVAL_TYPE_GLOBAL)
      if not jsCheck(ctx, ret, "<" & label & " inline>"):
        stderr.writeLine("[rwebview] halting script execution after inline error")
        return

# ===========================================================================
# Phase 3 — DOM preamble (JS)
# ===========================================================================

proc domPreamble(w, h: cint): string =
  ## Return the JS source that installs minimal window/document stubs.
  ## Injected before every page's scripts.
  result = """
/* ── helpers ────────────────────────────────────────────────────────────── */

function _makeElement(tag) {
  var el = {
    tagName: tag.toUpperCase(),
    id: '',
    className: '',
    style: {},
    children: [],
    _listeners: {},
    innerHTML: '',
    textContent: '',
    nodeType: 1,
    parentNode: null,
    appendChild: function(child) { this.children.push(child); child.parentNode = this; return child; },
    removeChild: function(child) {
      var i = this.children.indexOf(child);
      if (i >= 0) this.children.splice(i, 1);
      return child;
    },
    setAttribute: function(k,v) { this[k] = v; },
    getAttribute: function(k) { return this[k] !== undefined ? String(this[k]) : null; },
    addEventListener: function(type, fn, opts) {
      if (!this._listeners[type]) this._listeners[type] = [];
      this._listeners[type].push(fn);
    },
    removeEventListener: function(type, fn) {
      if (!this._listeners[type]) return;
      var a = this._listeners[type];
      var i = a.indexOf(fn);
      if (i >= 0) a.splice(i, 1);
    },
    dispatchEvent: function(evt) {
      var fns = this._listeners[evt.type] || [];
      for (var i = 0; i < fns.length; i++) { try { fns[i](evt); } catch(e) {} }
    },
    getBoundingClientRect: function() {
      return { left:0, top:0, right:this.width||0, bottom:this.height||0,
               width:this.width||0, height:this.height||0 };
    },
    getContext: function(type) { return null; },
    focus: function() {},
    blur: function() {}
  };
  return el;
}

/* ── document ───────────────────────────────────────────────────────────── */

var _body = _makeElement('body');
_body.style = { background: '#000', margin: '0', padding: '0', overflow: 'hidden' };
_body.offsetWidth = """ & $w & """;
_body.offsetHeight = """ & $h & """;

var _docEl = _makeElement('html');
_docEl.appendChild(_body);

var _elemById = {};
var _docListeners = {};

var document = {
  body: _body,
  documentElement: _docEl,
  head: _makeElement('head'),
  nodeType: 9,
  readyState: 'complete',
  visibilityState: 'visible',
  hidden: false,
  fullscreenElement: null,
  fonts: { ready: Promise.resolve() },
  _title: '',
  get title() { return this._title; },
  set title(v) { this._title = String(v); },
  createElement: function(tag) {
    var el = _makeElement(tag);
    if (tag.toLowerCase() === 'canvas') {
      el.width  = """ & $w & """;
      el.height = """ & $h & """;
      el.getContext = function(type) {
        if (type === 'webgl' || type === 'webgl2' || type === 'experimental-webgl') {
          if (typeof __rw_glContext !== 'undefined') {
            __rw_glContext.canvas = el;
            return __rw_glContext;
          }
        }
        if (type === '2d') {
          if (el.__ctx2d) return el.__ctx2d;
          var ctx2d = __rw_createCanvas2D(el);
          ctx2d.canvas = el;
          // Wrap properties with setters that call native
          var _font = '10px sans-serif';
          var _fillStyle = '#000000';
          var _globalAlpha = 1.0;
          var _globalCompositeOp = 'source-over';
          var _textBaseline = 'alphabetic';
          var _textAlign = 'start';
          var _strokeStyle = '#000000';
          var _lineWidth = 1;
          var _lineCap = 'butt';
          var _lineJoin = 'miter';
          var _shadowColor = 'rgba(0,0,0,0)';
          var _shadowBlur = 0;
          var _shadowOffsetX = 0;
          var _shadowOffsetY = 0;
          var _imageSmoothingEnabled = true;
          Object.defineProperty(ctx2d, 'font', {
            get: function() { return _font; },
            set: function(v) { _font = v; ctx2d.__rw_setFont(v); }
          });
          Object.defineProperty(ctx2d, 'fillStyle', {
            get: function() { return _fillStyle; },
            set: function(v) { _fillStyle = v; if (typeof v === 'string') ctx2d.__rw_setFillStyle(v); }
          });
          Object.defineProperty(ctx2d, 'globalAlpha', {
            get: function() { return _globalAlpha; },
            set: function(v) { _globalAlpha = v; ctx2d.__rw_setGlobalAlpha(v); }
          });
          Object.defineProperty(ctx2d, 'globalCompositeOperation', {
            get: function() { return _globalCompositeOp; },
            set: function(v) { _globalCompositeOp = v; }
          });
          Object.defineProperty(ctx2d, 'textBaseline', {
            get: function() { return _textBaseline; },
            set: function(v) { _textBaseline = v; ctx2d.__rw_setTextBaseline(v); }
          });
          Object.defineProperty(ctx2d, 'textAlign', {
            get: function() { return _textAlign; },
            set: function(v) { _textAlign = v; ctx2d.__rw_setTextAlign(v); }
          });
          Object.defineProperty(ctx2d, 'strokeStyle', {
            get: function() { return _strokeStyle; },
            set: function(v) { _strokeStyle = v; }
          });
          Object.defineProperty(ctx2d, 'lineWidth', {
            get: function() { return _lineWidth; },
            set: function(v) { _lineWidth = v; }
          });
          Object.defineProperty(ctx2d, 'lineCap', {
            get: function() { return _lineCap; },
            set: function(v) { _lineCap = v; }
          });
          Object.defineProperty(ctx2d, 'lineJoin', {
            get: function() { return _lineJoin; },
            set: function(v) { _lineJoin = v; }
          });
          Object.defineProperty(ctx2d, 'shadowColor', {
            get: function() { return _shadowColor; },
            set: function(v) { _shadowColor = v; }
          });
          Object.defineProperty(ctx2d, 'shadowBlur', {
            get: function() { return _shadowBlur; },
            set: function(v) { _shadowBlur = v; }
          });
          Object.defineProperty(ctx2d, 'shadowOffsetX', {
            get: function() { return _shadowOffsetX; },
            set: function(v) { _shadowOffsetX = v; }
          });
          Object.defineProperty(ctx2d, 'shadowOffsetY', {
            get: function() { return _shadowOffsetY; },
            set: function(v) { _shadowOffsetY = v; }
          });
          Object.defineProperty(ctx2d, 'imageSmoothingEnabled', {
            get: function() { return _imageSmoothingEnabled; },
            set: function(v) { _imageSmoothingEnabled = v; }
          });
          el.__ctx2d = ctx2d;
          return ctx2d;
        }
        return null;
      };
    }
    return el;
  },
  getElementById: function(id) { return _elemById[id] || null; },
  querySelector: function(sel) {
    // Very minimal: handle '#id' and 'tag' only.
    if (sel.charAt(0) === '#') return _elemById[sel.slice(1)] || null;
    return null;
  },
  querySelectorAll: function(sel) { return []; },
  addEventListener: function(type, fn, opts) {
    if (!_docListeners[type]) _docListeners[type] = [];
    _docListeners[type].push(fn);
  },
  removeEventListener: function(type, fn) {
    if (!_docListeners[type]) return;
    var a = _docListeners[type];
    var i = a.indexOf(fn);
    if (i >= 0) a.splice(i, 1);
  },
  dispatchEvent: function(evt) {
    var fns = _docListeners[evt.type] || [];
    for (var i = 0; i < fns.length; i++) { try { fns[i](evt); } catch(e) {} }
  },
  exitFullscreen: function() { return Promise.resolve(); },
  createElementNS: function(ns, tag) { return this.createElement(tag); }
};

/* ── navigator ───────────────────────────────────────────────────────────── */

var navigator = {
  userAgent: 'Mozilla/5.0 rwebview/1.0',
  platform: 'Win32',
  language: 'en',
  onLine: true,
  maxTouchPoints: 0,
  getGamepads: function() { return []; }
};

/* ── window ─────────────────────────────────────────────────────────────── */

var _winListeners = {};

var window = {
  innerWidth:  """ & $w & """,
  innerHeight: """ & $h & """,
  outerWidth:  """ & $w & """,
  outerHeight: """ & $h & """,
  devicePixelRatio: 1,
  scrollX: 0,
  scrollY: 0,
  pageXOffset: 0,
  pageYOffset: 0,
  onload:   null,
  onerror:  null,
  onresize: null,
  onblur:   null,
  onfocus:  null,
  document: document,
  navigator: navigator,
  location: { href: '', hash: '', search: '', pathname: '/', hostname: 'localhost', protocol: 'file:',
               assign: function(){}, replace: function(){}, reload: function(){} },
  history:  { pushState: function(){}, replaceState: function(){}, back: function(){}, forward: function(){} },
  screen:   { width: """ & $w & """, height: """ & $h & """, availWidth: """ & $w & """, availHeight: """ & $h & """ },
  performance: {
    now: function() { return __rw_getTicksMs(); }
  },
  console: console,
  // rAF / timer — native implementations installed below by bindDom
  requestAnimationFrame: null,
  cancelAnimationFrame:  null,
  setTimeout:   null,
  clearTimeout: null,
  setInterval:  null,
  clearInterval:null,
  addEventListener: function(type, fn, opts) {
    if (!_winListeners[type]) _winListeners[type] = [];
    _winListeners[type].push(fn);
    if (type === 'load' && window.onload == null) window.onload = fn;
  },
  removeEventListener: function(type, fn) {
    if (!_winListeners[type]) return;
    var a = _winListeners[type];
    var i = a.indexOf(fn);
    if (i >= 0) a.splice(i, 1);
  },
  dispatchEvent: function(evt) {
    var fns = _winListeners[evt.type] || [];
    for (var i = 0; i < fns.length; i++) { try { fns[i](evt); } catch(e) {} }
    var handler = window['on' + evt.type];
    if (typeof handler === 'function') { try { handler(evt); } catch(e) {} }
  },
  open:  function() { return null; },
  close: function() {},
  focus: function() {},
  blur:  function() {},
  alert:   function(msg) { console.log('[alert] ' + msg); },
  confirm: function(msg) { console.log('[confirm] ' + msg); return false; },
  prompt:  function(msg) { console.log('[prompt] ' + msg); return ''; },
  clearImmediate: function(){},
  setImmediate: function(fn){ return window.setTimeout(fn, 0); },
  URL: { createObjectURL: function(){ return ''; }, revokeObjectURL: function(){} },
  Blob: function(){},
  Worker: function(){ return { postMessage:function(){}, terminate:function(){}, onmessage:null }; },
  XMLHttpRequest: function(){
    return {
      open:function(){}, send:function(){}, setRequestHeader:function(){},
      abort:function(){},
      onload:null, onerror:null, onprogress:null,
      readyState:0, status:0, responseText:'', response:null
    };
  }
};

/* ── Image constructor ───────────────────────────────────────────────────── */

function Image() {
  this._src = '';
  this.onload  = null;
  this.onerror = null;
  this.complete = false;
  this.naturalWidth  = 0;
  this.naturalHeight = 0;
  this.width  = 0;
  this.height = 0;
}
Object.defineProperty(Image.prototype, 'src', {
  get: function() { return this._src; },
  set: function(v) {
    this._src = v;
    this.complete = false;
    // Native __rw_loadImage fires onload/onerror asynchronously.
    __rw_loadImage(this, v);
  }
});

/* ── Audio constructor ───────────────────────────────────────────────────── */

function Audio() {
  this.src = '';
  this.volume = 1;
  this.loop = false;
  this.paused = true;
  this.currentTime = 0;
  this.duration = 0;
  this.onended = null;
  this.play  = function() { return Promise.resolve(); };
  this.pause = function() {};
  this.load  = function() {};
  this.addEventListener = function(){};
}

/* ── globals: make window props available at top scope ───────────────────── */

var performance      = window.performance;
var location         = window.location;
var navigator        = window.navigator;
var screen           = window.screen;
var history          = window.history;
var requestAnimationFrame  = function(fn) { return window.requestAnimationFrame(fn); };
var cancelAnimationFrame   = function(id) { return window.cancelAnimationFrame(id); };
var setTimeout   = function(fn,ms)  { return window.setTimeout(fn,ms); };
var clearTimeout = function(id)     { return window.clearTimeout(id); };
var setInterval  = function(fn,ms)  { return window.setInterval(fn,ms); };
var clearInterval = function(id)    { return window.clearInterval(id); };

/* ── internal event dispatch helper ─────────────────────────────────────── */

function __rw_dispatchEvent(target, type, props) {
  var evt = { type: type, bubbles: false, cancelable: false,
              preventDefault: function(){}, stopPropagation: function(){} };
  if (props) {
    for (var k in props) evt[k] = props[k];
  }
  if (target && typeof target.dispatchEvent === 'function') {
    target.dispatchEvent(evt);
  }
}
"""

# ===========================================================================
# Phase 3 — Native JS bindings installed by bindDom
# ===========================================================================

# Forward declaration — webview state is needed for rAF/timer callbacks.
# We store the state pointer in a module-level global because QuickJS
# `JS_NewCFunction2` only gives us a `magic` int, not a user-data pointer.
# For a single-window runtime this is fine.
var gState {.global.}: ptr RWebviewState = nil

proc jsGetTicks(ctx: ptr JSContext; thisVal: JSValue;
                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_getTicksMs() → number   (milliseconds since SDL init)
  rw_JS_NewFloat64(ctx, float64(SDL_GetTicks()))

proc jsRequestAnimationFrame(ctx: ptr JSContext; thisVal: JSValue;
                              argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## requestAnimationFrame(callback) → id  (int)
  if argc < 1: return rw_JS_NewInt32(ctx, 0)
  let fn = cast[ptr JSValue](argv)[]
  if JS_IsFunction(ctx, fn) == 0: return rw_JS_NewInt32(ctx, 0)
  let state = gState
  if state == nil: return rw_JS_NewInt32(ctx, 0)
  let id = state.nextTimerId
  inc state.nextTimerId
  state.rafStaging.add(RAfEntry(id: id, fn: rw_JS_DupValue(ctx, fn)))
  rw_JS_NewInt32(ctx, int32(id))

proc jsCancelAnimationFrame(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc < 1 or gState == nil: return rw_JS_Undefined()
  var id: int32
  discard JS_ToInt32(ctx, addr id, cast[ptr JSValue](argv)[])
  let state = gState
  for i in 0..<state.rafStaging.len:
    if state.rafStaging[i].id == int(id):
      rw_JS_FreeValue(ctx, state.rafStaging[i].fn)
      state.rafStaging.delete(i)
      break
  for i in 0..<state.rafPending.len:
    if state.rafPending[i].id == int(id):
      rw_JS_FreeValue(ctx, state.rafPending[i].fn)
      state.rafPending.delete(i)
      break
  rw_JS_Undefined()

proc jsSetTimeout(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc < 1 or gState == nil: return rw_JS_NewInt32(ctx, 0)
  let fn = cast[ptr JSValue](cast[uint](argv))[]
  if JS_IsFunction(ctx, fn) == 0: return rw_JS_NewInt32(ctx, 0)
  var ms: int32 = 0
  if argc >= 2:
    discard JS_ToInt32(ctx, addr ms, cast[ptr JSValue](cast[uint](argv) + uint(sizeof(JSValue)))[])
  if ms < 0: ms = 0
  let state = gState
  let id = state.nextTimerId
  inc state.nextTimerId
  state.timers.add(TimerEntry(
    id: id, fn: rw_JS_DupValue(ctx, fn),
    fireAt: SDL_GetTicks() + uint64(ms),
    interval: 0, active: true))
  rw_JS_NewInt32(ctx, int32(id))

proc jsSetInterval(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc < 1 or gState == nil: return rw_JS_NewInt32(ctx, 0)
  let fn = cast[ptr JSValue](cast[uint](argv))[]
  if JS_IsFunction(ctx, fn) == 0: return rw_JS_NewInt32(ctx, 0)
  var ms: int32 = 0
  if argc >= 2:
    discard JS_ToInt32(ctx, addr ms, cast[ptr JSValue](cast[uint](argv) + uint(sizeof(JSValue)))[])
  if ms <= 0: ms = 1
  let state = gState
  let id = state.nextTimerId
  inc state.nextTimerId
  state.timers.add(TimerEntry(
    id: id, fn: rw_JS_DupValue(ctx, fn),
    fireAt: SDL_GetTicks() + uint64(ms),
    interval: uint64(ms), active: true))
  rw_JS_NewInt32(ctx, int32(id))

proc jsClearTimer(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc < 1 or gState == nil: return rw_JS_Undefined()
  var id: int32
  discard JS_ToInt32(ctx, addr id, cast[ptr JSValue](argv)[])
  for t in gState.timers.mitems:
    if t.id == int(id) and t.active:
      t.active = false
      # Do NOT free t.fn here — dispatchTimers owns lifetime and will free it
      # when it sweeps inactive entries.  Freeing here causes use-after-free.
      break
  rw_JS_Undefined()

proc jsLoadImage(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_loadImage(imgObj, src) — stub: immediately fires onload with size 1×1.
  ## A real implementation would load via SDL_image and set naturalWidth/Height.
  if argc < 1: return rw_JS_Undefined()
  let imgObj = cast[ptr JSValue](argv)[]
  # Mark complete
  discard JS_SetPropertyStr(ctx, imgObj, "complete",      rw_JS_True())
  discard JS_SetPropertyStr(ctx, imgObj, "naturalWidth",  rw_JS_NewInt32(ctx, 1))
  discard JS_SetPropertyStr(ctx, imgObj, "naturalHeight", rw_JS_NewInt32(ctx, 1))
  discard JS_SetPropertyStr(ctx, imgObj, "width",         rw_JS_NewInt32(ctx, 1))
  discard JS_SetPropertyStr(ctx, imgObj, "height",        rw_JS_NewInt32(ctx, 1))
  # Call onload if set
  let onload = JS_GetPropertyStr(ctx, imgObj, "onload")
  if JS_IsFunction(ctx, onload) != 0:
    let r = JS_Call(ctx, onload, imgObj, 0, nil)
    discard jsCheck(ctx, r, "Image.onload")
  rw_JS_FreeValue(ctx, onload)
  rw_JS_Undefined()

proc bindDom(state: ptr RWebviewState) =
  ## Install native C functions into the QuickJS global object.
  gState = state
  let ctx    = state.jsCtx
  let global = JS_GetGlobalObject(ctx)
  let winObj = JS_GetPropertyStr(ctx, global, "window")

  template installFn(obj: JSValue; name: cstring; fn: JSCFunction; nargs: cint) =
    let f = JS_NewCFunction(ctx, fn, name, nargs)
    discard JS_SetPropertyStr(ctx, obj, name, f)
    # Also install on global so bare `setTimeout(...)` works.
    let g2 = JS_NewCFunction(ctx, fn, name, nargs)
    discard JS_SetPropertyStr(ctx, global, name, g2)

  # performance.now native
  let perfObj = JS_GetPropertyStr(ctx, winObj, "performance")
  let nowFn   = JS_NewCFunction(ctx, jsGetTicks, "now", 0)
  discard JS_SetPropertyStr(ctx, perfObj, "now", nowFn)
  # Also update the global performance.now
  let gPerfObj = JS_GetPropertyStr(ctx, global, "performance")
  let nowFn2   = JS_NewCFunction(ctx, jsGetTicks, "now", 0)
  discard JS_SetPropertyStr(ctx, gPerfObj, "now", nowFn2)
  rw_JS_FreeValue(ctx, perfObj)
  rw_JS_FreeValue(ctx, gPerfObj)

  # rAF / timer natives on window + global
  installFn(winObj, "requestAnimationFrame",  cast[JSCFunction](jsRequestAnimationFrame), 1)
  installFn(winObj, "cancelAnimationFrame",   cast[JSCFunction](jsCancelAnimationFrame),  1)
  installFn(winObj, "setTimeout",             cast[JSCFunction](jsSetTimeout),            2)
  installFn(winObj, "setInterval",            cast[JSCFunction](jsSetInterval),           2)
  installFn(winObj, "clearTimeout",           cast[JSCFunction](jsClearTimer),            1)
  installFn(winObj, "clearInterval",          cast[JSCFunction](jsClearTimer),            1)

  # __rw_getTicksMs and __rw_loadImage on global (used by JS preamble)
  let tmFn = JS_NewCFunction(ctx, jsGetTicks, "__rw_getTicksMs", 0)
  discard JS_SetPropertyStr(ctx, global, "__rw_getTicksMs", tmFn)
  let liFn = JS_NewCFunction(ctx, cast[JSCFunction](jsLoadImage), "__rw_loadImage", 2)
  discard JS_SetPropertyStr(ctx, global, "__rw_loadImage", liFn)

  rw_JS_FreeValue(ctx, winObj)
  rw_JS_FreeValue(ctx, global)

# ===========================================================================
# Phase 3 — per-frame timer/rAF dispatch helpers
# ===========================================================================

proc dispatchTimers(state: ptr RWebviewState) =
  ## Fire any timers whose fireAt <= now.  setInterval timers reschedule themselves.
  let ctx  = state.jsCtx
  let now  = SDL_GetTicks()
  var i = 0
  while i < state.timers.len:
    let t = addr state.timers[i]
    if not t.active:
      rw_JS_FreeValue(ctx, t.fn)
      state.timers.delete(i)
      continue
    if now >= t.fireAt:
      if t.interval > 0:
        # setInterval: reschedule first, then call (so cleared interval in callback works)
        t.fireAt = now + t.interval
        let fn = rw_JS_DupValue(ctx, t.fn)
        let r  = JS_Call(ctx, fn, rw_JS_Undefined(), 0, nil)
        discard jsCheck(ctx, r, "setInterval callback")
        rw_JS_FreeValue(ctx, fn)
        inc i
      else:
        # setTimeout: deactivate, extract fn, delete, call
        t.active = false
        let fn = t.fn   # don't dup — we take ownership
        state.timers.delete(i)
        let r = JS_Call(ctx, fn, rw_JS_Undefined(), 0, nil)
        discard jsCheck(ctx, r, "setTimeout callback")
        rw_JS_FreeValue(ctx, fn)
        # don't inc i: slot was removed
    else:
      inc i

proc dispatchRaf(state: ptr RWebviewState) =
  ## Swap pending→running, dispatch all with DOMHighResTimeStamp, pump JS jobs.
  let ctx = state.jsCtx
  # Swap staging → pending (callbacks registered during dispatch go to next frame)
  var toRun = move(state.rafPending)
  state.rafPending = move(state.rafStaging)
  state.rafStaging = @[]
  let ts = rw_JS_NewFloat64(ctx, float64(SDL_GetTicks()))
  for e in toRun:
    var tsArg = ts
    let r = JS_Call(ctx, e.fn, rw_JS_Undefined(), 1, addr tsArg)
    discard jsCheck(ctx, r, "requestAnimationFrame callback")
    rw_JS_FreeValue(ctx, e.fn)
  rw_JS_FreeValue(ctx, ts)
  # Pump any micro-tasks / Promise continuations
  discard JS_ExecutePendingJob(state.rt, nil)

# ===========================================================================
# Phase 4 — WebGL JS bindings (JSCFunction callbacks + bindWebGL)
# ===========================================================================

# -- Argument extraction helpers (argv is a C array of 16-byte JSValue) ------

proc arg(argv: ptr JSValue; i: int): JSValue {.inline.} =
  cast[ptr JSValue](cast[uint](argv) + uint(i * sizeof(JSValue)))[]

proc argI32(ctx: ptr JSContext; argv: ptr JSValue; i: int): int32 {.inline.} =
  var v: int32
  discard JS_ToInt32(ctx, addr v, arg(argv, i))
  v

proc argU32(ctx: ptr JSContext; argv: ptr JSValue; i: int): uint32 {.inline.} =
  var v: uint32
  discard rw_JS_ToUint32(ctx, addr v, arg(argv, i))
  v

proc argF64(ctx: ptr JSContext; argv: ptr JSValue; i: int): float64 {.inline.} =
  var v: float64
  discard JS_ToFloat64(ctx, addr v, arg(argv, i))
  v

proc argF32(ctx: ptr JSContext; argv: ptr JSValue; i: int): float32 {.inline.} =
  float32(argF64(ctx, argv, i))

proc argBool(ctx: ptr JSContext; argv: ptr JSValue; i: int): bool {.inline.} =
  argI32(ctx, argv, i) != 0

proc argStr(ctx: ptr JSContext; argv: ptr JSValue; i: int): string =
  let v = arg(argv, i)
  let s = jsToCString(ctx, v)
  if s == nil: return ""
  result = $s
  JS_FreeCString(ctx, s)

# -- GL handle helpers -------------------------------------------------------

proc jsNewGLHandle(ctx: ptr JSContext; id: uint32): JSValue =
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "__id", rw_JS_NewInt32(ctx, int32(id)))
  obj

proc jsNewGLLocHandle(ctx: ptr JSContext; loc: int32): JSValue =
  if loc < 0: return rw_JS_Null()
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "__id", rw_JS_NewInt32(ctx, loc))
  obj

const JS_TAG_NULL_C      = 2.cint
const JS_TAG_UNDEFINED_C = 3.cint
const JS_TAG_INT_C       = 0.cint
const JS_TAG_FLOAT64_C   = 7.cint

proc jsGetGLId(ctx: ptr JSContext; v: JSValue): uint32 =
  let tag = rw_JS_VALUE_GET_TAG(v)
  if tag == JS_TAG_NULL_C or tag == JS_TAG_UNDEFINED_C: return 0
  let idVal = JS_GetPropertyStr(ctx, v, "__id")
  var id: int32
  discard JS_ToInt32(ctx, addr id, idVal)
  rw_JS_FreeValue(ctx, idVal)
  uint32(id)

proc jsGetGLLocId(ctx: ptr JSContext; v: JSValue): int32 =
  let tag = rw_JS_VALUE_GET_TAG(v)
  if tag == JS_TAG_NULL_C or tag == JS_TAG_UNDEFINED_C: return -1
  let idVal = JS_GetPropertyStr(ctx, v, "__id")
  var id: int32
  discard JS_ToInt32(ctx, addr id, idVal)
  rw_JS_FreeValue(ctx, idVal)
  id

# -- Typed array / ArrayBuffer data extraction --------------------------------

proc jsGetBufferData(ctx: ptr JSContext; v: JSValue): tuple[data: pointer, size: csize_t] =
  ## Extract raw pointer + byte length from an ArrayBuffer or TypedArray.
  ## Returns (nil, 0) if the argument is not a buffer type.
  var size: csize_t
  let buf = JS_GetArrayBuffer(ctx, addr size, v)
  if buf != nil:
    return (cast[pointer](buf), size)
  # Try TypedArray → underlying ArrayBuffer
  var byteOffset, byteLength, bytesPerElement: csize_t
  let ab = JS_GetTypedArrayBuffer(ctx, v, addr byteOffset, addr byteLength, addr bytesPerElement)
  if rw_JS_IsException(ab) == 0:
    let abBuf = JS_GetArrayBuffer(ctx, addr size, ab)
    rw_JS_FreeValue(ctx, ab)
    if abBuf != nil:
      return (cast[pointer](cast[uint](abBuf) + uint(byteOffset)), byteLength)
  else:
    rw_JS_FreeValue(ctx, ab)
  (nil, csize_t(0))

# ---------------------------------------------------------------------------
# WebGL JSCFunction callbacks — grouped by category
# ---------------------------------------------------------------------------

# ── State management ─────────────────────────────────────────────────────

proc jsGlViewport(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glViewport(GLint(argI32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
             GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlClearColor(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glClearColor(argF32(ctx, argv, 0), argF32(ctx, argv, 1),
               argF32(ctx, argv, 2), argF32(ctx, argv, 3))
  rw_JS_Undefined()

proc jsGlClear(ctx: ptr JSContext; thisVal: JSValue;
               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glClear(GLbitfield(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlEnable(ctx: ptr JSContext; thisVal: JSValue;
                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glEnable(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlDisable(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDisable(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlBlendFunc(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendFunc(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)))
  rw_JS_Undefined()

proc jsGlBlendFuncSeparate(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendFuncSeparate(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                      GLenum(argU32(ctx, argv, 2)), GLenum(argU32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlBlendEquation(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendEquation(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlBlendEquationSeparate(ctx: ptr JSContext; thisVal: JSValue;
                               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendEquationSeparate(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)))
  rw_JS_Undefined()

proc jsGlBlendColor(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendColor(argF32(ctx, argv, 0), argF32(ctx, argv, 1),
               argF32(ctx, argv, 2), argF32(ctx, argv, 3))
  rw_JS_Undefined()

proc jsGlDepthFunc(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDepthFunc(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlDepthMask(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDepthMask(GLboolean(if argBool(ctx, argv, 0): 1 else: 0))
  rw_JS_Undefined()

proc jsGlDepthRange(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDepthRange(argF64(ctx, argv, 0), argF64(ctx, argv, 1))
  rw_JS_Undefined()

proc jsGlClearDepth(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glClearDepth(argF64(ctx, argv, 0))
  rw_JS_Undefined()

proc jsGlCullFace(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glCullFace(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlFrontFace(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFrontFace(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlScissor(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glScissor(GLint(argI32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
            GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlLineWidth(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glLineWidth(argF32(ctx, argv, 0))
  rw_JS_Undefined()

proc jsGlColorMask(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glColorMask(GLboolean(if argBool(ctx, argv, 0): 1 else: 0),
              GLboolean(if argBool(ctx, argv, 1): 1 else: 0),
              GLboolean(if argBool(ctx, argv, 2): 1 else: 0),
              GLboolean(if argBool(ctx, argv, 3): 1 else: 0))
  rw_JS_Undefined()

proc jsGlStencilFunc(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilFunc(GLenum(argU32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
                GLuint(argU32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlStencilFuncSeparate(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilFuncSeparate(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                        GLint(argI32(ctx, argv, 2)), GLuint(argU32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlStencilOp(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilOp(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
              GLenum(argU32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlStencilOpSeparate(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilOpSeparate(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                      GLenum(argU32(ctx, argv, 2)), GLenum(argU32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlStencilMask(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilMask(GLuint(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlStencilMaskSeparate(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilMaskSeparate(GLenum(argU32(ctx, argv, 0)), GLuint(argU32(ctx, argv, 1)))
  rw_JS_Undefined()

proc jsGlClearStencil(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glClearStencil(GLint(argI32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlPixelStorei(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let pname = GLenum(argU32(ctx, argv, 0))
  let param = argI32(ctx, argv, 1)
  # Handle WebGL-specific pixel storage params
  if pname == 0x9240'u32:   # UNPACK_FLIP_Y_WEBGL
    glUnpackFlipY = param != 0
  elif pname == 0x9241'u32: # UNPACK_PREMULTIPLY_ALPHA_WEBGL
    glUnpackPremultiplyAlpha = param != 0
  elif pname == 0x9243'u32: # UNPACK_COLORSPACE_CONVERSION_WEBGL
    discard  # no-op
  else:
    glPixelStorei(pname, GLint(param))
  rw_JS_Undefined()

proc jsGlFlush(ctx: ptr JSContext; thisVal: JSValue;
               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFlush()
  rw_JS_Undefined()

proc jsGlFinish(ctx: ptr JSContext; thisVal: JSValue;
                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFinish()
  rw_JS_Undefined()

proc jsGlGetError(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_NewInt32(ctx, int32(glGetError()))

proc jsGlIsEnabled(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_NewBool(ctx, cint(glIsEnabled(GLenum(argU32(ctx, argv, 0)))))

# ── Shaders ──────────────────────────────────────────────────────────────

proc jsGlCreateShader(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let id = glCreateShader(GLenum(argU32(ctx, argv, 0)))
  jsNewGLHandle(ctx, id)

proc jsGlDeleteShader(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDeleteShader(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlShaderSource(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let shader = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  var src = argStr(ctx, argv, 1)
  # Preprocess GLSL ES → desktop GLSL 3.30 Core:
  # 1. Strip 'precision mediump/highp/lowp float/int;' lines
  # 2. Add #version 330 core if not present
  # 3. Convert attribute→in, varying→in/out (vertex→out, fragment→in)
  var lines = src.split('\n')
  var hasVersion = false
  var isFragShader = false
  for line in lines:
    let trimmed = line.strip()
    if trimmed.startsWith("#version"): hasVersion = true
    if trimmed.contains("gl_FragColor") or trimmed.contains("gl_FragData"):
      isFragShader = true
  var output: seq[string] = @[]
  if not hasVersion:
    output.add("#version 330 core")
  if isFragShader:
    output.add("out vec4 _rw_FragColor;")
  for line in lines:
    let trimmed = line.strip()
    if trimmed.startsWith("precision ") and (trimmed.contains("float") or trimmed.contains("int")) and trimmed.endsWith(";"):
      continue  # strip precision qualifiers
    if trimmed.startsWith("#version"):
      continue  # we already added our own
    var l = line
    if isFragShader:
      l = l.replace("varying ", "in ")
      l = l.replace("gl_FragColor", "_rw_FragColor")
      l = l.replace("gl_FragData[0]", "_rw_FragColor")
    else:
      l = l.replace("attribute ", "in ")
      l = l.replace("varying ", "out ")
    # Replace texture2D→texture (GLSL 3.30)
    l = l.replace("texture2D(", "texture(")
    l = l.replace("textureCube(", "texture(")
    output.add(l)
  src = output.join("\n")
  var csrc = cstring(src)
  var slen = GLint(src.len)
  glShaderSource(shader, 1, addr csrc, addr slen)
  rw_JS_Undefined()

proc jsGlCompileShader(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glCompileShader(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlGetShaderParameter(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let shader = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let pname = GLenum(argU32(ctx, argv, 1))
  var v: GLint
  glGetShaderiv(shader, pname, addr v)
  if pname == 0x8B81'u32 or pname == 0x8B80'u32:  # COMPILE_STATUS, DELETE_STATUS
    return rw_JS_NewBool(ctx, cint(v))
  rw_JS_NewInt32(ctx, v)

proc jsGlGetShaderInfoLog(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let shader = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  var logLen: GLint
  glGetShaderiv(shader, 0x8B84'u32, addr logLen)  # INFO_LOG_LENGTH
  if logLen <= 0: return rw_JS_NewString(ctx, "")
  var buf = newString(logLen)
  var actual: GLsizei
  glGetShaderInfoLog(shader, GLsizei(logLen), addr actual, cstring(buf))
  buf.setLen(actual)
  rw_JS_NewString(ctx, cstring(buf))

proc jsGlCreateProgram(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  jsNewGLHandle(ctx, glCreateProgram())

proc jsGlDeleteProgram(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDeleteProgram(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlAttachShader(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glAttachShader(GLuint(jsGetGLId(ctx, arg(argv, 0))),
                 GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlDetachShader(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDetachShader(GLuint(jsGetGLId(ctx, arg(argv, 0))),
                 GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlLinkProgram(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glLinkProgram(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlGetProgramParameter(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let pname = GLenum(argU32(ctx, argv, 1))
  var v: GLint
  glGetProgramiv(prog, pname, addr v)
  if pname == 0x8B82'u32 or pname == 0x8B83'u32 or pname == 0x8B80'u32:
    # LINK_STATUS, VALIDATE_STATUS, DELETE_STATUS
    return rw_JS_NewBool(ctx, cint(v))
  rw_JS_NewInt32(ctx, v)

proc jsGlGetProgramInfoLog(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  var logLen: GLint
  glGetProgramiv(prog, 0x8B84'u32, addr logLen)  # INFO_LOG_LENGTH
  if logLen <= 0: return rw_JS_NewString(ctx, "")
  var buf = newString(logLen)
  var actual: GLsizei
  glGetProgramInfoLog(prog, GLsizei(logLen), addr actual, cstring(buf))
  buf.setLen(actual)
  rw_JS_NewString(ctx, cstring(buf))

proc jsGlUseProgram(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUseProgram(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlValidateProgram(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glValidateProgram(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

# ── Attributes / Uniforms Location ───────────────────────────────────────

proc jsGlGetAttribLocation(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let name = argStr(ctx, argv, 1)
  rw_JS_NewInt32(ctx, glGetAttribLocation(prog, cstring(name)))

proc jsGlGetUniformLocation(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let name = argStr(ctx, argv, 1)
  jsNewGLLocHandle(ctx, glGetUniformLocation(prog, cstring(name)))

proc jsGlBindAttribLocation(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glBindAttribLocation(prog, GLuint(argU32(ctx, argv, 1)), cstring(argStr(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlEnableVertexAttribArray(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glEnableVertexAttribArray(GLuint(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlDisableVertexAttribArray(ctx: ptr JSContext; thisVal: JSValue;
                                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDisableVertexAttribArray(GLuint(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlVertexAttribPointer(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glVertexAttribPointer(
    GLuint(argU32(ctx, argv, 0)),
    GLint(argI32(ctx, argv, 1)),
    GLenum(argU32(ctx, argv, 2)),
    GLboolean(if argBool(ctx, argv, 3): 1 else: 0),
    GLsizei(argI32(ctx, argv, 4)),
    cast[pointer](argI32(ctx, argv, 5))  # byte offset → pointer
  )
  rw_JS_Undefined()

proc jsGlGetActiveAttrib(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let index = GLuint(argU32(ctx, argv, 1))
  var nameBuf: array[256, char]
  var length: GLsizei
  var size: GLint
  var typ: GLenum
  glGetActiveAttrib(prog, index, 256, addr length, addr size, addr typ, cast[cstring](addr nameBuf[0]))
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "size", rw_JS_NewInt32(ctx, size))
  discard JS_SetPropertyStr(ctx, obj, "type", rw_JS_NewInt32(ctx, int32(typ)))
  discard JS_SetPropertyStr(ctx, obj, "name", JS_NewStringLen(ctx, cast[cstring](addr nameBuf[0]), csize_t(length)))
  obj

proc jsGlGetActiveUniform(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let index = GLuint(argU32(ctx, argv, 1))
  var nameBuf: array[256, char]
  var length: GLsizei
  var size: GLint
  var typ: GLenum
  glGetActiveUniform(prog, index, 256, addr length, addr size, addr typ, cast[cstring](addr nameBuf[0]))
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "size", rw_JS_NewInt32(ctx, size))
  discard JS_SetPropertyStr(ctx, obj, "type", rw_JS_NewInt32(ctx, int32(typ)))
  discard JS_SetPropertyStr(ctx, obj, "name", JS_NewStringLen(ctx, cast[cstring](addr nameBuf[0]), csize_t(length)))
  obj

# ── Buffers ──────────────────────────────────────────────────────────────

proc jsGlCreateBuffer(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id: GLuint
  glGenBuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteBuffer(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glDeleteBuffers(1, addr id)
  rw_JS_Undefined()

proc jsGlBindBuffer(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBindBuffer(GLenum(argU32(ctx, argv, 0)), GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlBufferData(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let target = GLenum(argU32(ctx, argv, 0))
  let usage  = GLenum(argU32(ctx, argv, 2))
  let tag = rw_JS_VALUE_GET_TAG(arg(argv, 1))
  if tag == JS_TAG_INT_C or tag == JS_TAG_FLOAT64_C:
    # bufferData(target, size, usage) — allocate empty
    let size = argI32(ctx, argv, 1)
    glBufferData(target, int(size), nil, usage)
  else:
    # bufferData(target, typedArray, usage) — allocate with data
    let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
    glBufferData(target, int(size), data, usage)
  rw_JS_Undefined()

proc jsGlBufferSubData(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let target = GLenum(argU32(ctx, argv, 0))
  let offset = argI32(ctx, argv, 1)
  let (data, size) = jsGetBufferData(ctx, arg(argv, 2))
  if data != nil:
    glBufferSubData(target, int(offset), int(size), data)
  rw_JS_Undefined()

# ── Textures ─────────────────────────────────────────────────────────────

proc jsGlCreateTexture(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id: GLuint
  glGenTextures(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteTexture(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glDeleteTextures(1, addr id)
  rw_JS_Undefined()

proc jsGlBindTexture(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBindTexture(GLenum(argU32(ctx, argv, 0)), GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlActiveTexture(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glActiveTexture(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlTexImage2D(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc >= 9:
    # texImage2D(target, level, internalformat, width, height, border, format, type, data)
    let target = GLenum(argU32(ctx, argv, 0))
    let level  = GLint(argI32(ctx, argv, 1))
    let ifmt   = GLint(argI32(ctx, argv, 2))
    let width  = GLsizei(argI32(ctx, argv, 3))
    let height = GLsizei(argI32(ctx, argv, 4))
    let border = GLint(argI32(ctx, argv, 5))
    let fmt    = GLenum(argU32(ctx, argv, 6))
    let typ    = GLenum(argU32(ctx, argv, 7))
    let tag = rw_JS_VALUE_GET_TAG(arg(argv, 8))
    if tag == JS_TAG_NULL_C or tag == JS_TAG_UNDEFINED_C:
      glTexImage2D(target, level, ifmt, width, height, border, fmt, typ, nil)
    else:
      let (data, size) = jsGetBufferData(ctx, arg(argv, 8))
      glTexImage2D(target, level, ifmt, width, height, border, fmt, typ, data)
  elif argc >= 6:
    # texImage2D(target, level, internalformat, format, type, source)
    # source is HTMLImageElement — extract pixel data (stub: 1x1 white pixel)
    let target = GLenum(argU32(ctx, argv, 0))
    let level  = GLint(argI32(ctx, argv, 1))
    let ifmt   = GLint(argI32(ctx, argv, 2))
    let fmt    = GLenum(argU32(ctx, argv, 3))
    let typ    = GLenum(argU32(ctx, argv, 4))
    # Try to get __pixelData from the image object (set by Phase 6 image loader)
    let source = arg(argv, 5)
    # Check if source is a canvas element with a 2D context (__ctxId)
    let ctxIdProp = JS_GetPropertyStr(ctx, source, "__ctxId")
    let ctxIdTag = rw_JS_VALUE_GET_TAG(ctxIdProp)
    if ctxIdTag == JS_TAG_INT_C:
      var srcId: int32
      discard JS_ToInt32(ctx, addr srcId, ctxIdProp)
      rw_JS_FreeValue(ctx, ctxIdProp)
      if srcId >= 0 and srcId < int32(canvas2dStates.len):
        let sc = addr canvas2dStates[srcId]
        if sc.pixels.len > 0:
          glTexImage2D(target, level, ifmt, GLsizei(sc.width), GLsizei(sc.height),
                       0, fmt, typ, addr sc.pixels[0])
        else:
          var px: array[4, uint8] = [255'u8, 255, 255, 255]
          glTexImage2D(target, level, ifmt, 1, 1, 0, fmt, typ, addr px[0])
    else:
      rw_JS_FreeValue(ctx, ctxIdProp)
      let pxProp = JS_GetPropertyStr(ctx, source, "__pixelData")
      let pxTag = rw_JS_VALUE_GET_TAG(pxProp)
      if pxTag != JS_TAG_NULL_C and pxTag != JS_TAG_UNDEFINED_C:
        # Image has pixel data — extract width/height and buffer
        let wProp = JS_GetPropertyStr(ctx, source, "naturalWidth")
        let hProp = JS_GetPropertyStr(ctx, source, "naturalHeight")
        var iw, ih: int32
        discard JS_ToInt32(ctx, addr iw, wProp)
        discard JS_ToInt32(ctx, addr ih, hProp)
        let (data, sz) = jsGetBufferData(ctx, pxProp)
        glTexImage2D(target, level, ifmt, GLsizei(iw), GLsizei(ih), 0, fmt, typ, data)
        rw_JS_FreeValue(ctx, wProp)
        rw_JS_FreeValue(ctx, hProp)
      else:
        # Fallback: 1x1 white pixel
        var px: array[4, uint8] = [255'u8, 255, 255, 255]
        glTexImage2D(target, level, ifmt, 1, 1, 0, fmt, typ, addr px[0])
      rw_JS_FreeValue(ctx, pxProp)
  rw_JS_Undefined()

proc jsGlTexSubImage2D(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc >= 9:
    let (data, size) = jsGetBufferData(ctx, arg(argv, 8))
    glTexSubImage2D(GLenum(argU32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
                    GLint(argI32(ctx, argv, 2)), GLint(argI32(ctx, argv, 3)),
                    GLsizei(argI32(ctx, argv, 4)), GLsizei(argI32(ctx, argv, 5)),
                    GLenum(argU32(ctx, argv, 6)), GLenum(argU32(ctx, argv, 7)), data)
  rw_JS_Undefined()

proc jsGlTexParameteri(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glTexParameteri(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                  GLint(argI32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlTexParameterf(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glTexParameterf(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                  argF32(ctx, argv, 2))
  rw_JS_Undefined()

proc jsGlGenerateMipmap(ctx: ptr JSContext; thisVal: JSValue;
                        argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glGenerateMipmap(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

# ── Framebuffers / Renderbuffers ─────────────────────────────────────────

proc jsGlCreateFramebuffer(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id: GLuint
  glGenFramebuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteFramebuffer(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glDeleteFramebuffers(1, addr id)
  rw_JS_Undefined()

proc jsGlBindFramebuffer(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBindFramebuffer(GLenum(argU32(ctx, argv, 0)), GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlFramebufferTexture2D(ctx: ptr JSContext; thisVal: JSValue;
                              argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFramebufferTexture2D(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                         GLenum(argU32(ctx, argv, 2)),
                         GLuint(jsGetGLId(ctx, arg(argv, 3))),
                         GLint(argI32(ctx, argv, 4)))
  rw_JS_Undefined()

proc jsGlFramebufferRenderbuffer(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFramebufferRenderbuffer(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                            GLenum(argU32(ctx, argv, 2)),
                            GLuint(jsGetGLId(ctx, arg(argv, 3))))
  rw_JS_Undefined()

proc jsGlCheckFramebufferStatus(ctx: ptr JSContext; thisVal: JSValue;
                                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_NewInt32(ctx, int32(glCheckFramebufferStatus(GLenum(argU32(ctx, argv, 0)))))

proc jsGlCreateRenderbuffer(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id: GLuint
  glGenRenderbuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteRenderbuffer(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glDeleteRenderbuffers(1, addr id)
  rw_JS_Undefined()

proc jsGlBindRenderbuffer(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBindRenderbuffer(GLenum(argU32(ctx, argv, 0)), GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlRenderbufferStorage(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glRenderbufferStorage(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                        GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

# ── Drawing ──────────────────────────────────────────────────────────────

proc jsGlDrawArrays(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDrawArrays(GLenum(argU32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
               GLsizei(argI32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlDrawElements(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDrawElements(GLenum(argU32(ctx, argv, 0)), GLsizei(argI32(ctx, argv, 1)),
                 GLenum(argU32(ctx, argv, 2)),
                 cast[pointer](argI32(ctx, argv, 3)))  # byte offset → pointer
  rw_JS_Undefined()

# ── Uniforms ─────────────────────────────────────────────────────────────

proc jsGlUniform1f(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform1f(jsGetGLLocId(ctx, arg(argv, 0)), argF32(ctx, argv, 1))
  rw_JS_Undefined()

proc jsGlUniform2f(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform2f(jsGetGLLocId(ctx, arg(argv, 0)), argF32(ctx, argv, 1), argF32(ctx, argv, 2))
  rw_JS_Undefined()

proc jsGlUniform3f(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform3f(jsGetGLLocId(ctx, arg(argv, 0)), argF32(ctx, argv, 1),
              argF32(ctx, argv, 2), argF32(ctx, argv, 3))
  rw_JS_Undefined()

proc jsGlUniform4f(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform4f(jsGetGLLocId(ctx, arg(argv, 0)), argF32(ctx, argv, 1),
              argF32(ctx, argv, 2), argF32(ctx, argv, 3), argF32(ctx, argv, 4))
  rw_JS_Undefined()

proc jsGlUniform1i(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform1i(jsGetGLLocId(ctx, arg(argv, 0)), GLint(argI32(ctx, argv, 1)))
  rw_JS_Undefined()

proc jsGlUniform2i(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform2i(jsGetGLLocId(ctx, arg(argv, 0)), GLint(argI32(ctx, argv, 1)),
              GLint(argI32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlUniform3i(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform3i(jsGetGLLocId(ctx, arg(argv, 0)), GLint(argI32(ctx, argv, 1)),
              GLint(argI32(ctx, argv, 2)), GLint(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlUniform4i(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform4i(jsGetGLLocId(ctx, arg(argv, 0)), GLint(argI32(ctx, argv, 1)),
              GLint(argI32(ctx, argv, 2)), GLint(argI32(ctx, argv, 3)),
              GLint(argI32(ctx, argv, 4)))
  rw_JS_Undefined()

# Uniform*v and UniformMatrix*fv — take TypedArray data

proc jsGlUniform1fv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform1fv(loc, GLsizei(int(size) div sizeof(GLfloat)), cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniform2fv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform2fv(loc, GLsizei(int(size) div (2 * sizeof(GLfloat))), cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniform3fv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform3fv(loc, GLsizei(int(size) div (3 * sizeof(GLfloat))), cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniform4fv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform4fv(loc, GLsizei(int(size) div (4 * sizeof(GLfloat))), cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniform1iv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform1iv(loc, GLsizei(int(size) div sizeof(GLint)), cast[ptr GLint](data))
  rw_JS_Undefined()

proc jsGlUniform2iv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform2iv(loc, GLsizei(int(size) div (2 * sizeof(GLint))), cast[ptr GLint](data))
  rw_JS_Undefined()

proc jsGlUniform3iv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform3iv(loc, GLsizei(int(size) div (3 * sizeof(GLint))), cast[ptr GLint](data))
  rw_JS_Undefined()

proc jsGlUniform4iv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform4iv(loc, GLsizei(int(size) div (4 * sizeof(GLint))), cast[ptr GLint](data))
  rw_JS_Undefined()

proc jsGlUniformMatrix2fv(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let transpose = GLboolean(if argBool(ctx, argv, 1): 1 else: 0)
  let (data, size) = jsGetBufferData(ctx, arg(argv, 2))
  if data != nil:
    glUniformMatrix2fv(loc, GLsizei(int(size) div (4 * sizeof(GLfloat))), transpose, cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniformMatrix3fv(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let transpose = GLboolean(if argBool(ctx, argv, 1): 1 else: 0)
  let (data, size) = jsGetBufferData(ctx, arg(argv, 2))
  if data != nil:
    glUniformMatrix3fv(loc, GLsizei(int(size) div (9 * sizeof(GLfloat))), transpose, cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniformMatrix4fv(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let transpose = GLboolean(if argBool(ctx, argv, 1): 1 else: 0)
  let (data, size) = jsGetBufferData(ctx, arg(argv, 2))
  if data != nil:
    glUniformMatrix4fv(loc, GLsizei(int(size) div (16 * sizeof(GLfloat))), transpose, cast[ptr GLfloat](data))
  rw_JS_Undefined()

# ── Reading ──────────────────────────────────────────────────────────────

proc jsGlReadPixels(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc >= 7:
    let (data, size) = jsGetBufferData(ctx, arg(argv, 6))
    if data != nil:
      glReadPixels(GLint(argI32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
                   GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)),
                   GLenum(argU32(ctx, argv, 4)), GLenum(argU32(ctx, argv, 5)), data)
  rw_JS_Undefined()

# ── Query / Parameter ────────────────────────────────────────────────────

proc jsGlGetParameter(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let pname = GLenum(argU32(ctx, argv, 0))
  case pname
  of 0x1F00'u32:  # VENDOR
    let s = glGetString(pname)
    if s != nil: return rw_JS_NewString(ctx, cast[cstring](s))
    return rw_JS_NewString(ctx, "rwebview")
  of 0x1F01'u32:  # RENDERER
    let s = glGetString(pname)
    if s != nil: return rw_JS_NewString(ctx, cast[cstring](s))
    return rw_JS_NewString(ctx, "rwebview OpenGL")
  of 0x1F02'u32:  # VERSION
    return rw_JS_NewString(ctx, "WebGL 1.0")
  of 0x8B8C'u32:  # SHADING_LANGUAGE_VERSION
    return rw_JS_NewString(ctx, "WebGL GLSL ES 1.0")
  of 0x0BA2'u32:  # VIEWPORT
    var v: array[4, GLint]
    glGetIntegerv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    for i in 0..3:
      discard JS_SetPropertyUint32(ctx, arr, uint32(i), rw_JS_NewInt32(ctx, v[i]))
    return arr
  of 0x0C23'u32:  # COLOR_WRITEMASK
    var v: array[4, GLboolean]
    glGetBooleanv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    for i in 0..3:
      discard JS_SetPropertyUint32(ctx, arr, uint32(i), rw_JS_NewBool(ctx, cint(v[i])))
    return arr
  of 0x0D3A'u32:  # MAX_VIEWPORT_DIMS
    var v: array[2, GLint]
    glGetIntegerv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    discard JS_SetPropertyUint32(ctx, arr, 0, rw_JS_NewInt32(ctx, v[0]))
    discard JS_SetPropertyUint32(ctx, arr, 1, rw_JS_NewInt32(ctx, v[1]))
    return arr
  of 0x846E'u32:  # ALIASED_LINE_WIDTH_RANGE
    var v: array[2, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    discard JS_SetPropertyUint32(ctx, arr, 0, rw_JS_NewFloat64(ctx, float64(v[0])))
    discard JS_SetPropertyUint32(ctx, arr, 1, rw_JS_NewFloat64(ctx, float64(v[1])))
    return arr
  of 0x846D'u32:  # ALIASED_POINT_SIZE_RANGE
    var v: array[2, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    discard JS_SetPropertyUint32(ctx, arr, 0, rw_JS_NewFloat64(ctx, float64(v[0])))
    discard JS_SetPropertyUint32(ctx, arr, 1, rw_JS_NewFloat64(ctx, float64(v[1])))
    return arr
  of 0x0B72'u32:  # DEPTH_WRITEMASK
    var v: GLboolean
    glGetBooleanv(pname, addr v)
    return rw_JS_NewBool(ctx, cint(v))
  of 0x0BE2'u32:  # BLEND
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0B44'u32:  # CULL_FACE
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0B71'u32:  # DEPTH_TEST
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0BD0'u32:  # DITHER
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x8037'u32:  # POLYGON_OFFSET_FILL
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x80A0'u32:  # SAMPLE_COVERAGE
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0C11'u32:  # SCISSOR_TEST
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0B90'u32:  # STENCIL_TEST
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x9240'u32:  # UNPACK_FLIP_Y_WEBGL
    return rw_JS_NewBool(ctx, cint(ord(glUnpackFlipY)))
  of 0x9241'u32:  # UNPACK_PREMULTIPLY_ALPHA_WEBGL
    return rw_JS_NewBool(ctx, cint(ord(glUnpackPremultiplyAlpha)))
  else:
    # Default: integer query
    var v: GLint
    glGetIntegerv(pname, addr v)
    return rw_JS_NewInt32(ctx, v)

proc jsGlGetExtension(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let name = argStr(ctx, argv, 0)
  case name
  of "OES_element_index_uint", "OES_texture_float",
     "OES_texture_float_linear", "OES_standard_derivatives",
     "EXT_shader_texture_lod", "EXT_frag_depth",
     "EXT_blend_minmax":
    return JS_NewObject(ctx)
  of "OES_texture_half_float":
    let obj = JS_NewObject(ctx)
    discard JS_SetPropertyStr(ctx, obj, "HALF_FLOAT_OES", rw_JS_NewInt32(ctx, 0x8D61))
    return obj
  of "OES_texture_half_float_linear":
    return JS_NewObject(ctx)
  of "OES_vertex_array_object":
    # GL 3.3 Core has native VAO support; expose as OES extension
    let obj = JS_NewObject(ctx)
    # Stub methods — these call the real GL functions via __rw_* natives
    # installed during bindWebGL
    return obj
  of "ANGLE_instanced_arrays":
    let obj = JS_NewObject(ctx)
    return obj
  of "WEBGL_lose_context":
    let obj = JS_NewObject(ctx)
    return obj
  of "WEBGL_depth_texture":
    return JS_NewObject(ctx)
  else:
    return rw_JS_Null()

proc jsGlGetShaderPrecisionFormat(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let obj = JS_NewObject(ctx)
  if glGetShaderPrecisionFormat != nil:
    let shaderType = GLenum(argU32(ctx, argv, 0))
    let precisionType = GLenum(argU32(ctx, argv, 1))
    var range: array[2, GLint]
    var precision: GLint
    glGetShaderPrecisionFormat(shaderType, precisionType, addr range[0], addr precision)
    discard JS_SetPropertyStr(ctx, obj, "rangeMin", rw_JS_NewInt32(ctx, range[0]))
    discard JS_SetPropertyStr(ctx, obj, "rangeMax", rw_JS_NewInt32(ctx, range[1]))
    discard JS_SetPropertyStr(ctx, obj, "precision", rw_JS_NewInt32(ctx, precision))
  else:
    # GL 3.3 may not have this function; return sensible defaults
    discard JS_SetPropertyStr(ctx, obj, "rangeMin", rw_JS_NewInt32(ctx, 127))
    discard JS_SetPropertyStr(ctx, obj, "rangeMax", rw_JS_NewInt32(ctx, 127))
    discard JS_SetPropertyStr(ctx, obj, "precision", rw_JS_NewInt32(ctx, 23))
  obj

proc jsGlIsContextLost(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_False()

# ── Instanced rendering (ANGLE_instanced_arrays extension) ───────────────

proc jsGlDrawArraysInstanced(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if glDrawArraysInstanced != nil:
    glDrawArraysInstanced(GLenum(argU32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
                          GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlDrawElementsInstanced(ctx: ptr JSContext; thisVal: JSValue;
                               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if glDrawElementsInstanced != nil:
    glDrawElementsInstanced(GLenum(argU32(ctx, argv, 0)), GLsizei(argI32(ctx, argv, 1)),
                            GLenum(argU32(ctx, argv, 2)),
                            cast[pointer](argI32(ctx, argv, 3)),
                            GLsizei(argI32(ctx, argv, 4)))
  rw_JS_Undefined()

proc jsGlVertexAttribDivisor(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if glVertexAttribDivisor != nil:
    glVertexAttribDivisor(GLuint(argU32(ctx, argv, 0)), GLuint(argU32(ctx, argv, 1)))
  rw_JS_Undefined()

# ── bindWebGL — create GL context JS object with all methods + constants ──

const glConstantsJS = """
var g=__rw_glContext;
g.DEPTH_BUFFER_BIT=0x100;g.STENCIL_BUFFER_BIT=0x400;g.COLOR_BUFFER_BIT=0x4000;
g.FALSE=0;g.TRUE=1;g.POINTS=0;g.LINES=1;g.LINE_LOOP=2;g.LINE_STRIP=3;
g.TRIANGLES=4;g.TRIANGLE_STRIP=5;g.TRIANGLE_FAN=6;
g.ZERO=0;g.ONE=1;g.SRC_COLOR=0x300;g.ONE_MINUS_SRC_COLOR=0x301;
g.SRC_ALPHA=0x302;g.ONE_MINUS_SRC_ALPHA=0x303;g.DST_ALPHA=0x304;
g.ONE_MINUS_DST_ALPHA=0x305;g.DST_COLOR=0x306;g.ONE_MINUS_DST_COLOR=0x307;
g.SRC_ALPHA_SATURATE=0x308;g.FUNC_ADD=0x8006;g.FUNC_SUBTRACT=0x800A;
g.FUNC_REVERSE_SUBTRACT=0x800B;g.BLEND_EQUATION=0x8009;
g.BLEND_EQUATION_RGB=0x8009;g.BLEND_EQUATION_ALPHA=0x883D;
g.BLEND_DST_RGB=0x80C8;g.BLEND_SRC_RGB=0x80C9;
g.BLEND_DST_ALPHA=0x80CA;g.BLEND_SRC_ALPHA=0x80CB;
g.CONSTANT_COLOR=0x8001;g.ONE_MINUS_CONSTANT_COLOR=0x8002;
g.CONSTANT_ALPHA=0x8003;g.ONE_MINUS_CONSTANT_ALPHA=0x8004;
g.BLEND_COLOR=0x8005;g.BLEND=0x0BE2;
g.CULL_FACE=0x0B44;g.DEPTH_TEST=0x0B71;g.STENCIL_TEST=0x0B90;
g.DITHER=0x0BD0;g.SCISSOR_TEST=0x0C11;g.POLYGON_OFFSET_FILL=0x8037;
g.SAMPLE_ALPHA_TO_COVERAGE=0x809E;g.SAMPLE_COVERAGE=0x80A0;
g.NO_ERROR=0;g.INVALID_ENUM=0x500;g.INVALID_VALUE=0x501;
g.INVALID_OPERATION=0x502;g.OUT_OF_MEMORY=0x505;
g.INVALID_FRAMEBUFFER_OPERATION=0x506;
g.CW=0x900;g.CCW=0x901;g.FRONT=0x404;g.BACK=0x405;g.FRONT_AND_BACK=0x408;
g.NEVER=0x200;g.LESS=0x201;g.EQUAL=0x202;g.LEQUAL=0x203;
g.GREATER=0x204;g.NOTEQUAL=0x205;g.GEQUAL=0x206;g.ALWAYS=0x207;
g.KEEP=0x1E00;g.REPLACE=0x1E01;g.INCR=0x1E02;g.DECR=0x1E03;
g.INVERT=0x150A;g.INCR_WRAP=0x8507;g.DECR_WRAP=0x8508;
g.BYTE=0x1400;g.UNSIGNED_BYTE=0x1401;g.SHORT=0x1402;
g.UNSIGNED_SHORT=0x1403;g.INT=0x1404;g.UNSIGNED_INT=0x1405;g.FLOAT=0x1406;
g.ARRAY_BUFFER=0x8892;g.ELEMENT_ARRAY_BUFFER=0x8893;
g.ARRAY_BUFFER_BINDING=0x8894;g.ELEMENT_ARRAY_BUFFER_BINDING=0x8895;
g.STREAM_DRAW=0x88E0;g.STATIC_DRAW=0x88E4;g.DYNAMIC_DRAW=0x88E8;
g.BUFFER_SIZE=0x8764;g.BUFFER_USAGE=0x8765;
g.CURRENT_VERTEX_ATTRIB=0x8626;
g.TEXTURE0=0x84C0;g.TEXTURE1=0x84C1;g.TEXTURE2=0x84C2;g.TEXTURE3=0x84C3;
g.TEXTURE4=0x84C4;g.TEXTURE5=0x84C5;g.TEXTURE6=0x84C6;g.TEXTURE7=0x84C7;
g.TEXTURE8=0x84C8;g.TEXTURE9=0x84C9;g.TEXTURE10=0x84CA;g.TEXTURE11=0x84CB;
g.TEXTURE12=0x84CC;g.TEXTURE13=0x84CD;g.TEXTURE14=0x84CE;g.TEXTURE15=0x84CF;
g.TEXTURE16=0x84D0;g.TEXTURE17=0x84D1;g.TEXTURE18=0x84D2;g.TEXTURE19=0x84D3;
g.TEXTURE20=0x84D4;g.TEXTURE21=0x84D5;g.TEXTURE22=0x84D6;g.TEXTURE23=0x84D7;
g.TEXTURE24=0x84D8;g.TEXTURE25=0x84D9;g.TEXTURE26=0x84DA;g.TEXTURE27=0x84DB;
g.TEXTURE28=0x84DC;g.TEXTURE29=0x84DD;g.TEXTURE30=0x84DE;g.TEXTURE31=0x84DF;
g.TEXTURE_2D=0x0DE1;g.TEXTURE_CUBE_MAP=0x8513;
g.TEXTURE_CUBE_MAP_POSITIVE_X=0x8515;g.TEXTURE_CUBE_MAP_NEGATIVE_X=0x8516;
g.TEXTURE_CUBE_MAP_POSITIVE_Y=0x8517;g.TEXTURE_CUBE_MAP_NEGATIVE_Y=0x8518;
g.TEXTURE_CUBE_MAP_POSITIVE_Z=0x8519;g.TEXTURE_CUBE_MAP_NEGATIVE_Z=0x851A;
g.TEXTURE_WRAP_S=0x2802;g.TEXTURE_WRAP_T=0x2803;
g.TEXTURE_MIN_FILTER=0x2801;g.TEXTURE_MAG_FILTER=0x2800;
g.NEAREST=0x2600;g.LINEAR=0x2601;
g.NEAREST_MIPMAP_NEAREST=0x2700;g.LINEAR_MIPMAP_NEAREST=0x2701;
g.NEAREST_MIPMAP_LINEAR=0x2702;g.LINEAR_MIPMAP_LINEAR=0x2703;
g.CLAMP_TO_EDGE=0x812F;g.MIRRORED_REPEAT=0x8370;g.REPEAT=0x2901;
g.ALPHA=0x1906;g.RGB=0x1907;g.RGBA=0x1908;
g.LUMINANCE=0x1909;g.LUMINANCE_ALPHA=0x190A;
g.DEPTH_COMPONENT=0x1902;g.DEPTH_STENCIL=0x84F9;
g.DEPTH_COMPONENT16=0x81A5;g.STENCIL_INDEX8=0x8D48;
g.DEPTH24_STENCIL8=0x88F0;
g.UNPACK_ALIGNMENT=0x0CF5;g.PACK_ALIGNMENT=0x0D05;
g.UNPACK_FLIP_Y_WEBGL=0x9240;g.UNPACK_PREMULTIPLY_ALPHA_WEBGL=0x9241;
g.UNPACK_COLORSPACE_CONVERSION_WEBGL=0x9243;
g.FRAGMENT_SHADER=0x8B30;g.VERTEX_SHADER=0x8B31;
g.COMPILE_STATUS=0x8B81;g.LINK_STATUS=0x8B82;g.VALIDATE_STATUS=0x8B83;
g.DELETE_STATUS=0x8B80;g.SHADER_TYPE=0x8B4F;
g.ATTACHED_SHADERS=0x8B85;g.ACTIVE_UNIFORMS=0x8B86;
g.ACTIVE_ATTRIBUTES=0x8B89;g.ACTIVE_UNIFORM_MAX_LENGTH=0x8B87;
g.ACTIVE_ATTRIB_MAX_LENGTH=0x8B8A;
g.FRAMEBUFFER=0x8D40;g.RENDERBUFFER=0x8D41;
g.COLOR_ATTACHMENT0=0x8CE0;g.DEPTH_ATTACHMENT=0x8D00;
g.STENCIL_ATTACHMENT=0x8D20;g.DEPTH_STENCIL_ATTACHMENT=0x821A;
g.FRAMEBUFFER_COMPLETE=0x8CD5;
g.FRAMEBUFFER_INCOMPLETE_ATTACHMENT=0x8CD6;
g.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT=0x8CD7;
g.FRAMEBUFFER_INCOMPLETE_DIMENSIONS=0x8CD9;
g.FRAMEBUFFER_UNSUPPORTED=0x8CDD;g.NONE=0;
g.RENDERBUFFER_WIDTH=0x8D42;g.RENDERBUFFER_HEIGHT=0x8D43;
g.RENDERBUFFER_INTERNAL_FORMAT=0x8D44;
g.RENDERBUFFER_RED_SIZE=0x8D50;g.RENDERBUFFER_GREEN_SIZE=0x8D51;
g.RENDERBUFFER_BLUE_SIZE=0x8D52;g.RENDERBUFFER_ALPHA_SIZE=0x8D53;
g.RENDERBUFFER_DEPTH_SIZE=0x8D54;g.RENDERBUFFER_STENCIL_SIZE=0x8D55;
g.UNSIGNED_SHORT_4_4_4_4=0x8033;g.UNSIGNED_SHORT_5_5_5_1=0x8034;
g.UNSIGNED_SHORT_5_6_5=0x8363;
g.MAX_VERTEX_ATTRIBS=0x8869;g.MAX_VERTEX_UNIFORM_VECTORS=0x8DFB;
g.MAX_VARYING_VECTORS=0x8DFC;g.MAX_COMBINED_TEXTURE_IMAGE_UNITS=0x8B4D;
g.MAX_VERTEX_TEXTURE_IMAGE_UNITS=0x8B4C;g.MAX_TEXTURE_IMAGE_UNITS=0x8872;
g.MAX_FRAGMENT_UNIFORM_VECTORS=0x8DFD;g.MAX_TEXTURE_SIZE=0x0D33;
g.MAX_CUBE_MAP_TEXTURE_SIZE=0x851C;g.MAX_RENDERBUFFER_SIZE=0x84E8;
g.MAX_VIEWPORT_DIMS=0x0D3A;g.VIEWPORT=0x0BA2;
g.COLOR_WRITEMASK=0x0C23;g.DEPTH_WRITEMASK=0x0B72;
g.STENCIL_WRITEMASK=0x0B98;g.STENCIL_BACK_WRITEMASK=0x8CA5;
g.HIGH_FLOAT=0x8DF2;g.MEDIUM_FLOAT=0x8DF1;g.LOW_FLOAT=0x8DF0;
g.HIGH_INT=0x8DF5;g.MEDIUM_INT=0x8DF4;g.LOW_INT=0x8DF3;
g.FLOAT_VEC2=0x8B50;g.FLOAT_VEC3=0x8B51;g.FLOAT_VEC4=0x8B52;
g.INT_VEC2=0x8B53;g.INT_VEC3=0x8B54;g.INT_VEC4=0x8B55;
g.BOOL=0x8B56;g.BOOL_VEC2=0x8B57;g.BOOL_VEC3=0x8B58;g.BOOL_VEC4=0x8B59;
g.FLOAT_MAT2=0x8B5A;g.FLOAT_MAT3=0x8B5B;g.FLOAT_MAT4=0x8B5C;
g.SAMPLER_2D=0x8B5E;g.SAMPLER_CUBE=0x8B60;
g.POLYGON_OFFSET_FACTOR=0x8038;g.POLYGON_OFFSET_UNITS=0x2A00;
g.SAMPLE_BUFFERS=0x80A8;g.SAMPLES=0x80A9;
g.SAMPLE_COVERAGE_VALUE=0x80AA;g.SAMPLE_COVERAGE_INVERT=0x80AB;
g.GENERATE_MIPMAP_HINT=0x8192;g.FASTEST=0x1101;g.NICEST=0x1102;
g.DONT_CARE=0x1100;
g.STENCIL_FUNC=0x0B92;g.STENCIL_FAIL=0x0B94;
g.STENCIL_PASS_DEPTH_FAIL=0x0B95;g.STENCIL_PASS_DEPTH_PASS=0x0B96;
g.STENCIL_REF=0x0B97;g.STENCIL_VALUE_MASK=0x0B93;
g.STENCIL_BACK_FUNC=0x8800;g.STENCIL_BACK_FAIL=0x8801;
g.STENCIL_BACK_PASS_DEPTH_FAIL=0x8802;g.STENCIL_BACK_PASS_DEPTH_PASS=0x8803;
g.STENCIL_BACK_REF=0x8CA3;g.STENCIL_BACK_VALUE_MASK=0x8CA4;
g.DEPTH_FUNC=0x0B74;g.BLEND_SRC=0x0BE1;g.BLEND_DST=0x0BE0;
g.DEPTH_RANGE=0x0B70;g.DEPTH_CLEAR_VALUE=0x0B73;
g.STENCIL_CLEAR_VALUE=0x0B91;g.COLOR_CLEAR_VALUE=0x0C22;
g.SCISSOR_BOX=0x0C10;g.FRONT_FACE=0x0B46;g.CULL_FACE_MODE=0x0B45;
g.LINE_WIDTH=0x0B21;
g.VERTEX_ATTRIB_ARRAY_ENABLED=0x8622;
g.VERTEX_ATTRIB_ARRAY_SIZE=0x8623;
g.VERTEX_ATTRIB_ARRAY_STRIDE=0x8624;
g.VERTEX_ATTRIB_ARRAY_TYPE=0x8625;
g.VERTEX_ATTRIB_ARRAY_NORMALIZED=0x886A;
g.VERTEX_ATTRIB_ARRAY_POINTER=0x8645;
g.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING=0x889F;
g.IMPLEMENTATION_COLOR_READ_TYPE=0x8B9A;
g.IMPLEMENTATION_COLOR_READ_FORMAT=0x8B9B;
g.BROWSER_DEFAULT_WEBGL=0x9244;
g.VERSION=0x1F02;g.VENDOR=0x1F00;g.RENDERER=0x1F01;
g.SHADING_LANGUAGE_VERSION=0x8B8C;
"""

proc bindWebGL(state: ptr RWebviewState) =
  ## Create the WebGL context JS object with all methods and constants,
  ## then store as __rw_glContext global.
  let ctx = state.jsCtx
  let global = JS_GetGlobalObject(ctx)
  let glObj = JS_NewObject(ctx)

  # drawingBufferWidth / drawingBufferHeight
  discard JS_SetPropertyStr(ctx, glObj, "drawingBufferWidth", rw_JS_NewInt32(ctx, state.width))
  discard JS_SetPropertyStr(ctx, glObj, "drawingBufferHeight", rw_JS_NewInt32(ctx, state.height))

  # Install all gl.* native method bindings
  template glFn(jsName: cstring; fn: JSCFunction; nargs: cint) =
    let f = JS_NewCFunction(ctx, fn, jsName, nargs)
    discard JS_SetPropertyStr(ctx, glObj, jsName, f)

  # State
  glFn("viewport",            cast[JSCFunction](jsGlViewport), 4)
  glFn("clearColor",          cast[JSCFunction](jsGlClearColor), 4)
  glFn("clear",               cast[JSCFunction](jsGlClear), 1)
  glFn("enable",              cast[JSCFunction](jsGlEnable), 1)
  glFn("disable",             cast[JSCFunction](jsGlDisable), 1)
  glFn("blendFunc",           cast[JSCFunction](jsGlBlendFunc), 2)
  glFn("blendFuncSeparate",   cast[JSCFunction](jsGlBlendFuncSeparate), 4)
  glFn("blendEquation",       cast[JSCFunction](jsGlBlendEquation), 1)
  glFn("blendEquationSeparate", cast[JSCFunction](jsGlBlendEquationSeparate), 2)
  glFn("blendColor",          cast[JSCFunction](jsGlBlendColor), 4)
  glFn("depthFunc",           cast[JSCFunction](jsGlDepthFunc), 1)
  glFn("depthMask",           cast[JSCFunction](jsGlDepthMask), 1)
  glFn("depthRange",          cast[JSCFunction](jsGlDepthRange), 2)
  glFn("clearDepth",          cast[JSCFunction](jsGlClearDepth), 1)
  glFn("cullFace",            cast[JSCFunction](jsGlCullFace), 1)
  glFn("frontFace",           cast[JSCFunction](jsGlFrontFace), 1)
  glFn("scissor",             cast[JSCFunction](jsGlScissor), 4)
  glFn("lineWidth",           cast[JSCFunction](jsGlLineWidth), 1)
  glFn("colorMask",           cast[JSCFunction](jsGlColorMask), 4)
  glFn("stencilFunc",         cast[JSCFunction](jsGlStencilFunc), 3)
  glFn("stencilFuncSeparate", cast[JSCFunction](jsGlStencilFuncSeparate), 4)
  glFn("stencilOp",           cast[JSCFunction](jsGlStencilOp), 3)
  glFn("stencilOpSeparate",   cast[JSCFunction](jsGlStencilOpSeparate), 4)
  glFn("stencilMask",         cast[JSCFunction](jsGlStencilMask), 1)
  glFn("stencilMaskSeparate", cast[JSCFunction](jsGlStencilMaskSeparate), 2)
  glFn("clearStencil",        cast[JSCFunction](jsGlClearStencil), 1)
  glFn("pixelStorei",         cast[JSCFunction](jsGlPixelStorei), 2)
  glFn("flush",               cast[JSCFunction](jsGlFlush), 0)
  glFn("finish",              cast[JSCFunction](jsGlFinish), 0)
  glFn("getError",            cast[JSCFunction](jsGlGetError), 0)
  glFn("isEnabled",           cast[JSCFunction](jsGlIsEnabled), 1)
  # Shaders & Programs
  glFn("createShader",        cast[JSCFunction](jsGlCreateShader), 1)
  glFn("deleteShader",        cast[JSCFunction](jsGlDeleteShader), 1)
  glFn("shaderSource",        cast[JSCFunction](jsGlShaderSource), 2)
  glFn("compileShader",       cast[JSCFunction](jsGlCompileShader), 1)
  glFn("getShaderParameter",  cast[JSCFunction](jsGlGetShaderParameter), 2)
  glFn("getShaderInfoLog",    cast[JSCFunction](jsGlGetShaderInfoLog), 1)
  glFn("createProgram",       cast[JSCFunction](jsGlCreateProgram), 0)
  glFn("deleteProgram",       cast[JSCFunction](jsGlDeleteProgram), 1)
  glFn("attachShader",        cast[JSCFunction](jsGlAttachShader), 2)
  glFn("detachShader",        cast[JSCFunction](jsGlDetachShader), 2)
  glFn("linkProgram",         cast[JSCFunction](jsGlLinkProgram), 1)
  glFn("getProgramParameter", cast[JSCFunction](jsGlGetProgramParameter), 2)
  glFn("getProgramInfoLog",   cast[JSCFunction](jsGlGetProgramInfoLog), 1)
  glFn("useProgram",          cast[JSCFunction](jsGlUseProgram), 1)
  glFn("validateProgram",     cast[JSCFunction](jsGlValidateProgram), 1)
  # Attributes
  glFn("getAttribLocation",   cast[JSCFunction](jsGlGetAttribLocation), 2)
  glFn("bindAttribLocation",  cast[JSCFunction](jsGlBindAttribLocation), 3)
  glFn("enableVertexAttribArray",  cast[JSCFunction](jsGlEnableVertexAttribArray), 1)
  glFn("disableVertexAttribArray", cast[JSCFunction](jsGlDisableVertexAttribArray), 1)
  glFn("vertexAttribPointer", cast[JSCFunction](jsGlVertexAttribPointer), 6)
  glFn("getActiveAttrib",     cast[JSCFunction](jsGlGetActiveAttrib), 2)
  glFn("getActiveUniform",    cast[JSCFunction](jsGlGetActiveUniform), 2)
  # Uniforms
  glFn("getUniformLocation",  cast[JSCFunction](jsGlGetUniformLocation), 2)
  glFn("uniform1f",           cast[JSCFunction](jsGlUniform1f), 2)
  glFn("uniform2f",           cast[JSCFunction](jsGlUniform2f), 3)
  glFn("uniform3f",           cast[JSCFunction](jsGlUniform3f), 4)
  glFn("uniform4f",           cast[JSCFunction](jsGlUniform4f), 5)
  glFn("uniform1i",           cast[JSCFunction](jsGlUniform1i), 2)
  glFn("uniform2i",           cast[JSCFunction](jsGlUniform2i), 3)
  glFn("uniform3i",           cast[JSCFunction](jsGlUniform3i), 4)
  glFn("uniform4i",           cast[JSCFunction](jsGlUniform4i), 5)
  glFn("uniform1fv",          cast[JSCFunction](jsGlUniform1fv), 2)
  glFn("uniform2fv",          cast[JSCFunction](jsGlUniform2fv), 2)
  glFn("uniform3fv",          cast[JSCFunction](jsGlUniform3fv), 2)
  glFn("uniform4fv",          cast[JSCFunction](jsGlUniform4fv), 2)
  glFn("uniform1iv",          cast[JSCFunction](jsGlUniform1iv), 2)
  glFn("uniform2iv",          cast[JSCFunction](jsGlUniform2iv), 2)
  glFn("uniform3iv",          cast[JSCFunction](jsGlUniform3iv), 2)
  glFn("uniform4iv",          cast[JSCFunction](jsGlUniform4iv), 2)
  glFn("uniformMatrix2fv",    cast[JSCFunction](jsGlUniformMatrix2fv), 3)
  glFn("uniformMatrix3fv",    cast[JSCFunction](jsGlUniformMatrix3fv), 3)
  glFn("uniformMatrix4fv",    cast[JSCFunction](jsGlUniformMatrix4fv), 3)
  # Buffers
  glFn("createBuffer",        cast[JSCFunction](jsGlCreateBuffer), 0)
  glFn("deleteBuffer",        cast[JSCFunction](jsGlDeleteBuffer), 1)
  glFn("bindBuffer",          cast[JSCFunction](jsGlBindBuffer), 2)
  glFn("bufferData",          cast[JSCFunction](jsGlBufferData), 3)
  glFn("bufferSubData",       cast[JSCFunction](jsGlBufferSubData), 3)
  # Textures
  glFn("createTexture",       cast[JSCFunction](jsGlCreateTexture), 0)
  glFn("deleteTexture",       cast[JSCFunction](jsGlDeleteTexture), 1)
  glFn("bindTexture",         cast[JSCFunction](jsGlBindTexture), 2)
  glFn("activeTexture",       cast[JSCFunction](jsGlActiveTexture), 1)
  glFn("texImage2D",          cast[JSCFunction](jsGlTexImage2D), 9)
  glFn("texSubImage2D",       cast[JSCFunction](jsGlTexSubImage2D), 9)
  glFn("texParameteri",       cast[JSCFunction](jsGlTexParameteri), 3)
  glFn("texParameterf",       cast[JSCFunction](jsGlTexParameterf), 3)
  glFn("generateMipmap",      cast[JSCFunction](jsGlGenerateMipmap), 1)
  # Framebuffers
  glFn("createFramebuffer",   cast[JSCFunction](jsGlCreateFramebuffer), 0)
  glFn("deleteFramebuffer",   cast[JSCFunction](jsGlDeleteFramebuffer), 1)
  glFn("bindFramebuffer",     cast[JSCFunction](jsGlBindFramebuffer), 2)
  glFn("framebufferTexture2D", cast[JSCFunction](jsGlFramebufferTexture2D), 5)
  glFn("framebufferRenderbuffer", cast[JSCFunction](jsGlFramebufferRenderbuffer), 4)
  glFn("checkFramebufferStatus", cast[JSCFunction](jsGlCheckFramebufferStatus), 1)
  # Renderbuffers
  glFn("createRenderbuffer",  cast[JSCFunction](jsGlCreateRenderbuffer), 0)
  glFn("deleteRenderbuffer",  cast[JSCFunction](jsGlDeleteRenderbuffer), 1)
  glFn("bindRenderbuffer",    cast[JSCFunction](jsGlBindRenderbuffer), 2)
  glFn("renderbufferStorage", cast[JSCFunction](jsGlRenderbufferStorage), 4)
  # Drawing
  glFn("drawArrays",          cast[JSCFunction](jsGlDrawArrays), 3)
  glFn("drawElements",        cast[JSCFunction](jsGlDrawElements), 4)
  # Reading
  glFn("readPixels",          cast[JSCFunction](jsGlReadPixels), 7)
  # Query
  glFn("getParameter",        cast[JSCFunction](jsGlGetParameter), 1)
  glFn("getExtension",        cast[JSCFunction](jsGlGetExtension), 1)
  glFn("getShaderPrecisionFormat", cast[JSCFunction](jsGlGetShaderPrecisionFormat), 2)
  glFn("isContextLost",       cast[JSCFunction](jsGlIsContextLost), 0)
  # Instanced rendering
  glFn("drawArraysInstanced", cast[JSCFunction](jsGlDrawArraysInstanced), 4)
  glFn("drawElementsInstanced", cast[JSCFunction](jsGlDrawElementsInstanced), 5)
  glFn("vertexAttribDivisor", cast[JSCFunction](jsGlVertexAttribDivisor), 2)

  # Store as global __rw_glContext
  discard JS_SetPropertyStr(ctx, global, "__rw_glContext", glObj)
  rw_JS_FreeValue(ctx, global)

  # Eval the constants JS to set all WebGL enum constants on the context object
  let constRet = JS_Eval(ctx, cstring(glConstantsJS), csize_t(glConstantsJS.len),
                         "<gl-constants>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, constRet, "<gl-constants>")

# ===========================================================================
# Phase 5 — Canvas 2D JSCFunction callbacks and binding
# ===========================================================================

proc getCtx2DState(ctx: ptr JSContext; thisVal: JSValue): ptr Canvas2DState =
  ## Extract the Canvas2DState pointer from `this.__ctxId`.
  let idProp = JS_GetPropertyStr(ctx, thisVal, "__ctxId")
  var id: int32
  discard JS_ToInt32(ctx, addr id, idProp)
  rw_JS_FreeValue(ctx, idProp)
  if id >= 0 and id < int32(canvas2dStates.len):
    return addr canvas2dStates[id]
  return nil

# ── clearRect ────────────────────────────────────────────────────────────
proc jsCtx2dClearRect(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var dx, dy, dw, dh: float64
  discard JS_ToFloat64(ctx, addr dx, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr dy, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr dw, arg(argv, 2))
  discard JS_ToFloat64(ctx, addr dh, arg(argv, 3))
  let x0 = max(0, int(dx))
  let y0 = max(0, int(dy))
  let x1 = min(cs.width, int(dx + dw))
  let y1 = min(cs.height, int(dy + dh))
  for y in y0..<y1:
    let rowOff = y * cs.width * 4
    for x in x0..<x1:
      let off = rowOff + x * 4
      cs.pixels[off] = 0; cs.pixels[off+1] = 0
      cs.pixels[off+2] = 0; cs.pixels[off+3] = 0
  rw_JS_Undefined()

# ── fillRect ─────────────────────────────────────────────────────────────
proc jsCtx2dFillRect(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var dx, dy, dw, dh: float64
  discard JS_ToFloat64(ctx, addr dx, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr dy, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr dw, arg(argv, 2))
  discard JS_ToFloat64(ctx, addr dh, arg(argv, 3))
  let x0 = max(0, int(dx))
  let y0 = max(0, int(dy))
  let x1 = min(cs.width, int(dx + dw))
  let y1 = min(cs.height, int(dy + dh))
  let a = uint8(float32(cs.fillA) * cs.globalAlpha)
  for y in y0..<y1:
    let rowOff = y * cs.width * 4
    for x in x0..<x1:
      let off = rowOff + x * 4
      if a == 255:
        cs.pixels[off] = cs.fillR; cs.pixels[off+1] = cs.fillG
        cs.pixels[off+2] = cs.fillB; cs.pixels[off+3] = 255
      else:
        # Alpha blend: src over dst
        let sa = int(a)
        let da = int(cs.pixels[off+3])
        let outA = sa + da * (255 - sa) div 255
        if outA > 0:
          cs.pixels[off]   = uint8((int(cs.fillR) * sa + int(cs.pixels[off]) * da * (255 - sa) div 255) div outA)
          cs.pixels[off+1] = uint8((int(cs.fillG) * sa + int(cs.pixels[off+1]) * da * (255 - sa) div 255) div outA)
          cs.pixels[off+2] = uint8((int(cs.fillB) * sa + int(cs.pixels[off+2]) * da * (255 - sa) div 255) div outA)
          cs.pixels[off+3] = uint8(outA)
  rw_JS_Undefined()

# ── strokeRect (stub — draws outline using fillStyle) ────────────────────
proc jsCtx2dStrokeRect(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_Undefined()

# ── fillText ─────────────────────────────────────────────────────────────
proc jsCtx2dFillText(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let text = jsToCString(ctx, arg(argv, 0))
  if text == nil or text[0] == '\0':
    if text != nil: JS_FreeCString(ctx, text)
    return rw_JS_Undefined()
  var dx, dy: float64
  discard JS_ToFloat64(ctx, addr dx, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr dy, arg(argv, 2))
  # Apply transform to destination coordinates
  let tx = cs.transform[0] * float32(dx) + cs.transform[2] * float32(dy) + cs.transform[4]
  let ty = cs.transform[1] * float32(dx) + cs.transform[3] * float32(dy) + cs.transform[5]
  let baseDir = if gState != nil: gState.baseDir else: ""
  let font = getOrLoadFont(cs.fontFamily, cs.fontSize, baseDir)
  if font == nil:
    JS_FreeCString(ctx, text)
    return rw_JS_Undefined()
  let color = SDL_Color(r: cs.fillR, g: cs.fillG, b: cs.fillB, a: 255)
  let rawSurf = TTF_RenderText_Blended(font, text, 0, color)
  JS_FreeCString(ctx, text)
  if rawSurf == nil: return rw_JS_Undefined()
  # Convert to RGBA byte order
  let rgbaSurf = cast[ptr SDL_Surface](SDL_ConvertSurface(rawSurf, SDL_PIXELFORMAT_RGBA32))
  SDL_DestroySurface(rawSurf)
  if rgbaSurf == nil: return rw_JS_Undefined()
  let sw = int(rgbaSurf.w)
  let sh = int(rgbaSurf.h)
  let srcPixels = cast[ptr UncheckedArray[uint8]](rgbaSurf.pixels)
  # Adjust Y based on textBaseline
  var iy = int(ty)
  case cs.textBaseline
  of "top": discard  # y is already at top
  of "middle": iy -= sh div 2
  of "bottom", "ideographic": iy -= sh
  else: iy -= sh * 3 div 4  # "alphabetic" — approximate baseline at ~75%
  # Adjust X based on textAlign
  var ix = int(tx)
  case cs.textAlign
  of "center": ix -= sw div 2
  of "right", "end": ix -= sw
  else: discard  # "left", "start"
  # Blit with alpha blending
  let ga = cs.globalAlpha
  for row in 0..<sh:
    let dstY = iy + row
    if dstY < 0 or dstY >= cs.height: continue
    let srcRowOff = row * int(rgbaSurf.pitch)
    let dstRowOff = dstY * cs.width * 4
    for col in 0..<sw:
      let dstX = ix + col
      if dstX < 0 or dstX >= cs.width: continue
      let si = srcRowOff + col * 4
      let di = dstRowOff + dstX * 4
      let sa = int(float32(srcPixels[si + 3]) * ga)
      if sa == 0: continue
      if sa >= 255:
        cs.pixels[di] = srcPixels[si]; cs.pixels[di+1] = srcPixels[si+1]
        cs.pixels[di+2] = srcPixels[si+2]; cs.pixels[di+3] = 255
      else:
        let da = int(cs.pixels[di+3])
        let outA = sa + da * (255 - sa) div 255
        if outA > 0:
          cs.pixels[di]   = uint8((int(srcPixels[si]) * sa + int(cs.pixels[di]) * da * (255 - sa) div 255) div outA)
          cs.pixels[di+1] = uint8((int(srcPixels[si+1]) * sa + int(cs.pixels[di+1]) * da * (255 - sa) div 255) div outA)
          cs.pixels[di+2] = uint8((int(srcPixels[si+2]) * sa + int(cs.pixels[di+2]) * da * (255 - sa) div 255) div outA)
          cs.pixels[di+3] = uint8(outA)
  SDL_DestroySurface(rgbaSurf)
  rw_JS_Undefined()

# ── strokeText (stub) ────────────────────────────────────────────────────
proc jsCtx2dStrokeText(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_Undefined()

# ── measureText ──────────────────────────────────────────────────────────
proc jsCtx2dMeasureText(ctx: ptr JSContext; thisVal: JSValue;
                        argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil:
    let obj = JS_NewObject(ctx)
    discard JS_SetPropertyStr(ctx, obj, "width", rw_JS_NewFloat64(ctx, 0.0))
    return obj
  let text = jsToCString(ctx, arg(argv, 0))
  if text == nil:
    let obj = JS_NewObject(ctx)
    discard JS_SetPropertyStr(ctx, obj, "width", rw_JS_NewFloat64(ctx, 0.0))
    return obj
  let baseDir = if gState != nil: gState.baseDir else: ""
  let font = getOrLoadFont(cs.fontFamily, cs.fontSize, baseDir)
  var tw: cint = 0
  var th: cint = 0
  if font != nil:
    discard TTF_GetStringSize(font, text, 0, addr tw, addr th)
  JS_FreeCString(ctx, text)
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "width", rw_JS_NewFloat64(ctx, float64(tw)))
  obj

# ── drawImage ────────────────────────────────────────────────────────────
proc jsCtx2dDrawImage(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let source = arg(argv, 0)
  # Determine source pixel data, width, height
  var srcPixels: ptr UncheckedArray[uint8] = nil
  var srcW, srcH: int = 0
  # Check if source is a canvas with __ctxId
  let ctxIdProp = JS_GetPropertyStr(ctx, source, "__ctxId")
  let ctxIdTag = rw_JS_VALUE_GET_TAG(ctxIdProp)
  if ctxIdTag == JS_TAG_INT_C:
    var srcId: int32
    discard JS_ToInt32(ctx, addr srcId, ctxIdProp)
    if srcId >= 0 and srcId < int32(canvas2dStates.len):
      let sc = addr canvas2dStates[srcId]
      srcW = sc.width; srcH = sc.height
      if sc.pixels.len > 0:
        srcPixels = cast[ptr UncheckedArray[uint8]](addr sc.pixels[0])
  rw_JS_FreeValue(ctx, ctxIdProp)
  # Also check __pixelData (for HTMLImageElement)
  if srcPixels == nil:
    let pxProp = JS_GetPropertyStr(ctx, source, "__pixelData")
    let pxTag = rw_JS_VALUE_GET_TAG(pxProp)
    if pxTag != JS_TAG_NULL_C and pxTag != JS_TAG_UNDEFINED_C:
      let (data, sz) = jsGetBufferData(ctx, pxProp)
      if data != nil:
        srcPixels = cast[ptr UncheckedArray[uint8]](data)
        let wProp = JS_GetPropertyStr(ctx, source, "naturalWidth")
        let hProp = JS_GetPropertyStr(ctx, source, "naturalHeight")
        var iw, ih: int32
        discard JS_ToInt32(ctx, addr iw, wProp)
        discard JS_ToInt32(ctx, addr ih, hProp)
        rw_JS_FreeValue(ctx, wProp)
        rw_JS_FreeValue(ctx, hProp)
        srcW = int(iw); srcH = int(ih)
    rw_JS_FreeValue(ctx, pxProp)
  if srcPixels == nil or srcW == 0 or srcH == 0:
    return rw_JS_Undefined()
  # Parse arguments: drawImage(img, dx, dy) or (img, dx, dy, dw, dh)
  # or (img, sx, sy, sw, sh, dx, dy, dw, dh)
  var sx, sy, sw, sh: int
  var dx, dy, dw, dh: int
  if argc >= 9:
    var f: float64
    discard JS_ToFloat64(ctx, addr f, arg(argv, 1)); sx = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 2)); sy = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 3)); sw = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 4)); sh = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 5)); dx = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 6)); dy = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 7)); dw = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 8)); dh = int(f)
  elif argc >= 5:
    sx = 0; sy = 0; sw = srcW; sh = srcH
    var f: float64
    discard JS_ToFloat64(ctx, addr f, arg(argv, 1)); dx = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 2)); dy = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 3)); dw = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 4)); dh = int(f)
  else:
    sx = 0; sy = 0; sw = srcW; sh = srcH; dw = srcW; dh = srcH
    var f: float64
    discard JS_ToFloat64(ctx, addr f, arg(argv, 1)); dx = int(f)
    discard JS_ToFloat64(ctx, addr f, arg(argv, 2)); dy = int(f)
  # Simple nearest-neighbor blit (no scaling if sw==dw and sh==dh)
  let ga = cs.globalAlpha
  for row in 0..<dh:
    let dstY = dy + row
    if dstY < 0 or dstY >= cs.height: continue
    let srcRow = sy + (if dh != 0: row * sh div dh else: 0)
    if srcRow < 0 or srcRow >= srcH: continue
    let dstRowOff = dstY * cs.width * 4
    let srcRowOff = srcRow * srcW * 4
    for col in 0..<dw:
      let dstX = dx + col
      if dstX < 0 or dstX >= cs.width: continue
      let srcCol = sx + (if dw != 0: col * sw div dw else: 0)
      if srcCol < 0 or srcCol >= srcW: continue
      let si = srcRowOff + srcCol * 4
      let di = dstRowOff + dstX * 4
      let sa = int(float32(srcPixels[si + 3]) * ga)
      if sa == 0: continue
      if sa >= 255:
        cs.pixels[di] = srcPixels[si]; cs.pixels[di+1] = srcPixels[si+1]
        cs.pixels[di+2] = srcPixels[si+2]; cs.pixels[di+3] = 255
      else:
        let da = int(cs.pixels[di+3])
        let outA = sa + da * (255 - sa) div 255
        if outA > 0:
          cs.pixels[di]   = uint8((int(srcPixels[si]) * sa + int(cs.pixels[di]) * da * (255 - sa) div 255) div outA)
          cs.pixels[di+1] = uint8((int(srcPixels[si+1]) * sa + int(cs.pixels[di+1]) * da * (255 - sa) div 255) div outA)
          cs.pixels[di+2] = uint8((int(srcPixels[si+2]) * sa + int(cs.pixels[di+2]) * da * (255 - sa) div 255) div outA)
          cs.pixels[di+3] = uint8(outA)
  rw_JS_Undefined()

# ── getImageData ─────────────────────────────────────────────────────────
proc jsCtx2dGetImageData(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  var sx, sy, sw, sh: float64
  discard JS_ToFloat64(ctx, addr sx, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr sy, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr sw, arg(argv, 2))
  discard JS_ToFloat64(ctx, addr sh, arg(argv, 3))
  let iw = int(sw); let ih = int(sh)
  let totalBytes = iw * ih * 4
  # Create a Uint8ClampedArray with copies of pixel data
  let jsStr = "new Uint8ClampedArray(" & $totalBytes & ")"
  let arr = JS_Eval(ctx, cstring(jsStr), csize_t(jsStr.len), "<getImageData>", JS_EVAL_TYPE_GLOBAL)
  if cs != nil and totalBytes > 0:
    let abProp = JS_GetPropertyStr(ctx, arr, "buffer")
    var abSize: csize_t
    let abPtr = JS_GetArrayBuffer(ctx, addr abSize, abProp)
    rw_JS_FreeValue(ctx, abProp)
    if abPtr != nil:
      let dst = cast[ptr UncheckedArray[uint8]](abPtr)
      let ix0 = int(sx); let iy0 = int(sy)
      for row in 0..<ih:
        let srcY = iy0 + row
        for col in 0..<iw:
          let srcX = ix0 + col
          let di = (row * iw + col) * 4
          if srcY >= 0 and srcY < cs.height and srcX >= 0 and srcX < cs.width:
            let si = (srcY * cs.width + srcX) * 4
            dst[di] = cs.pixels[si]; dst[di+1] = cs.pixels[si+1]
            dst[di+2] = cs.pixels[si+2]; dst[di+3] = cs.pixels[si+3]
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "data", arr)
  discard JS_SetPropertyStr(ctx, obj, "width", rw_JS_NewInt32(ctx, int32(iw)))
  discard JS_SetPropertyStr(ctx, obj, "height", rw_JS_NewInt32(ctx, int32(ih)))
  obj

# ── putImageData ─────────────────────────────────────────────────────────
proc jsCtx2dPutImageData(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let imageData = arg(argv, 0)
  var dx, dy: float64
  discard JS_ToFloat64(ctx, addr dx, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr dy, arg(argv, 2))
  let dataProp = JS_GetPropertyStr(ctx, imageData, "data")
  let (srcPtr, srcLen) = jsGetBufferData(ctx, dataProp)
  rw_JS_FreeValue(ctx, dataProp)
  if srcPtr == nil: return rw_JS_Undefined()
  let wProp = JS_GetPropertyStr(ctx, imageData, "width")
  let hProp = JS_GetPropertyStr(ctx, imageData, "height")
  var iw, ih: int32
  discard JS_ToInt32(ctx, addr iw, wProp)
  discard JS_ToInt32(ctx, addr ih, hProp)
  rw_JS_FreeValue(ctx, wProp)
  rw_JS_FreeValue(ctx, hProp)
  let src = cast[ptr UncheckedArray[uint8]](srcPtr)
  let ix0 = int(dx); let iy0 = int(dy)
  for row in 0..<int(ih):
    let dstY = iy0 + row
    if dstY < 0 or dstY >= cs.height: continue
    for col in 0..<int(iw):
      let dstX = ix0 + col
      if dstX < 0 or dstX >= cs.width: continue
      let si = (row * int(iw) + col) * 4
      let di = (dstY * cs.width + dstX) * 4
      cs.pixels[di] = src[si]; cs.pixels[di+1] = src[si+1]
      cs.pixels[di+2] = src[si+2]; cs.pixels[di+3] = src[si+3]
  rw_JS_Undefined()

# ── save / restore ───────────────────────────────────────────────────────
proc jsCtx2dSave(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  cs.stateStack.add(Canvas2DSavedState(
    fillR: cs.fillR, fillG: cs.fillG, fillB: cs.fillB, fillA: cs.fillA,
    globalAlpha: cs.globalAlpha, fontSize: cs.fontSize,
    fontFamily: cs.fontFamily, textBaseline: cs.textBaseline,
    textAlign: cs.textAlign, transform: cs.transform
  ))
  rw_JS_Undefined()

proc jsCtx2dRestore(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil or cs.stateStack.len == 0: return rw_JS_Undefined()
  let saved = cs.stateStack.pop()
  cs.fillR = saved.fillR; cs.fillG = saved.fillG
  cs.fillB = saved.fillB; cs.fillA = saved.fillA
  cs.globalAlpha = saved.globalAlpha
  cs.fontSize = saved.fontSize; cs.fontFamily = saved.fontFamily
  cs.textBaseline = saved.textBaseline; cs.textAlign = saved.textAlign
  cs.transform = saved.transform
  rw_JS_Undefined()

# ── transform operations ─────────────────────────────────────────────────
proc jsCtx2dTranslate(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var tx, ty: float64
  discard JS_ToFloat64(ctx, addr tx, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr ty, arg(argv, 1))
  cs.transform[4] += cs.transform[0] * float32(tx) + cs.transform[2] * float32(ty)
  cs.transform[5] += cs.transform[1] * float32(tx) + cs.transform[3] * float32(ty)
  rw_JS_Undefined()

proc jsCtx2dRotate(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var angle: float64
  discard JS_ToFloat64(ctx, addr angle, arg(argv, 0))
  let cosA = cos(angle).float32
  let sinA = sin(angle).float32
  let a = cs.transform[0]; let b = cs.transform[1]
  let c = cs.transform[2]; let d = cs.transform[3]
  cs.transform[0] = a * cosA + c * sinA
  cs.transform[1] = b * cosA + d * sinA
  cs.transform[2] = c * cosA - a * sinA
  cs.transform[3] = d * cosA - b * sinA
  rw_JS_Undefined()

proc jsCtx2dScale(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var sx, sy: float64
  discard JS_ToFloat64(ctx, addr sx, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr sy, arg(argv, 1))
  cs.transform[0] *= float32(sx); cs.transform[1] *= float32(sx)
  cs.transform[2] *= float32(sy); cs.transform[3] *= float32(sy)
  rw_JS_Undefined()

proc jsCtx2dSetTransform(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  if argc >= 6:
    var v: float64
    discard JS_ToFloat64(ctx, addr v, arg(argv, 0)); cs.transform[0] = float32(v)
    discard JS_ToFloat64(ctx, addr v, arg(argv, 1)); cs.transform[1] = float32(v)
    discard JS_ToFloat64(ctx, addr v, arg(argv, 2)); cs.transform[2] = float32(v)
    discard JS_ToFloat64(ctx, addr v, arg(argv, 3)); cs.transform[3] = float32(v)
    discard JS_ToFloat64(ctx, addr v, arg(argv, 4)); cs.transform[4] = float32(v)
    discard JS_ToFloat64(ctx, addr v, arg(argv, 5)); cs.transform[5] = float32(v)
  rw_JS_Undefined()

proc jsCtx2dResetTransform(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  cs.transform = [1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f]
  rw_JS_Undefined()

# ── createLinearGradient / createRadialGradient ──────────────────────────
proc jsCtx2dCreateLinearGradient(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  # Return a stub gradient object with addColorStop
  let grad = JS_NewObject(ctx)
  let addFn = JS_NewCFunction(ctx, cast[JSCFunction](proc(c: ptr JSContext; t: JSValue;
      ac: cint; av: ptr JSValue): JSValue {.cdecl.} = rw_JS_Undefined()), "addColorStop", 2)
  discard JS_SetPropertyStr(ctx, grad, "addColorStop", addFn)
  grad

proc jsCtx2dCreateRadialGradient(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let grad = JS_NewObject(ctx)
  let addFn = JS_NewCFunction(ctx, cast[JSCFunction](proc(c: ptr JSContext; t: JSValue;
      ac: cint; av: ptr JSValue): JSValue {.cdecl.} = rw_JS_Undefined()), "addColorStop", 2)
  discard JS_SetPropertyStr(ctx, grad, "addColorStop", addFn)
  grad

proc jsCtx2dCreatePattern(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  # Return a stub pattern object
  JS_NewObject(ctx)

# ── isPointInPath (stub) ─────────────────────────────────────────────────
proc jsCtx2dIsPointInPath(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_False()

# ── Path stubs ───────────────────────────────────────────────────────────
proc jsCtx2dNoop(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_Undefined()

# ── Property getters/setters ─────────────────────────────────────────────
# These are handled via a JS wrapper that syncs properties to native calls.

proc jsCtx2dSetFont(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let fontStr = jsToCString(ctx, arg(argv, 0))
  if fontStr != nil:
    parseCssFont($fontStr, cs.fontSize, cs.fontFamily)
    JS_FreeCString(ctx, fontStr)
  rw_JS_Undefined()

proc jsCtx2dSetFillStyle(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let tag = rw_JS_VALUE_GET_TAG(arg(argv, 0))
  # If it's an object (gradient/pattern), ignore for now
  if tag == JS_TAG_INT_C or tag == JS_TAG_FLOAT64_C:
    return rw_JS_Undefined()
  let str = jsToCString(ctx, arg(argv, 0))
  if str != nil:
    parseCssColor($str, cs.fillR, cs.fillG, cs.fillB, cs.fillA)
    JS_FreeCString(ctx, str)
  rw_JS_Undefined()

proc jsCtx2dSetGlobalAlpha(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var a: float64
  discard JS_ToFloat64(ctx, addr a, arg(argv, 0))
  cs.globalAlpha = float32(max(0.0, min(1.0, a)))
  rw_JS_Undefined()

proc jsCtx2dSetTextBaseline(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let s = jsToCString(ctx, arg(argv, 0))
  if s != nil:
    cs.textBaseline = $s
    JS_FreeCString(ctx, s)
  rw_JS_Undefined()

proc jsCtx2dSetTextAlign(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let s = jsToCString(ctx, arg(argv, 0))
  if s != nil:
    cs.textAlign = $s
    JS_FreeCString(ctx, s)
  rw_JS_Undefined()

# ── __rw_createCanvas2D(canvasElement) — called from JS getContext('2d') ─
proc jsCreateCanvas2D(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let canvasEl = arg(argv, 0)
  # Read canvas.width, canvas.height
  let wProp = JS_GetPropertyStr(ctx, canvasEl, "width")
  let hProp = JS_GetPropertyStr(ctx, canvasEl, "height")
  var cw, ch: int32
  discard JS_ToInt32(ctx, addr cw, wProp)
  discard JS_ToInt32(ctx, addr ch, hProp)
  rw_JS_FreeValue(ctx, wProp)
  rw_JS_FreeValue(ctx, hProp)
  if cw <= 0: cw = 300
  if ch <= 0: ch = 150
  # Create a new Canvas2DState
  let id = int32(canvas2dStates.len)
  canvas2dStates.add(initCanvas2DState(int(cw), int(ch)))
  canvas2dStates[id].canvasJsVal = rw_JS_DupValue(ctx, canvasEl)
  # Store __ctxId on the canvas element so texImage2D can find the pixel data
  discard JS_SetPropertyStr(ctx, canvasEl, "__ctxId", rw_JS_NewInt32(ctx, id))
  # Build the context object with all methods
  let ctxObj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, ctxObj, "__ctxId", rw_JS_NewInt32(ctx, id))

  template c2dFn(name: string; fn: JSCFunction; arity: int) =
    discard JS_SetPropertyStr(ctx, ctxObj, name,
              JS_NewCFunction(ctx, fn, name, cint(arity)))

  c2dFn("clearRect",   jsCtx2dClearRect, 4)
  c2dFn("fillRect",    jsCtx2dFillRect, 4)
  c2dFn("strokeRect",  jsCtx2dStrokeRect, 4)
  c2dFn("fillText",    jsCtx2dFillText, 4)
  c2dFn("strokeText",  jsCtx2dStrokeText, 4)
  c2dFn("measureText",  jsCtx2dMeasureText, 1)
  c2dFn("drawImage",   jsCtx2dDrawImage, 9)
  c2dFn("getImageData", jsCtx2dGetImageData, 4)
  c2dFn("putImageData", jsCtx2dPutImageData, 3)
  c2dFn("save",         jsCtx2dSave, 0)
  c2dFn("restore",      jsCtx2dRestore, 0)
  c2dFn("translate",    jsCtx2dTranslate, 2)
  c2dFn("rotate",       jsCtx2dRotate, 1)
  c2dFn("scale",        jsCtx2dScale, 2)
  c2dFn("setTransform", jsCtx2dSetTransform, 6)
  c2dFn("resetTransform", jsCtx2dResetTransform, 0)
  c2dFn("createLinearGradient", jsCtx2dCreateLinearGradient, 4)
  c2dFn("createRadialGradient", jsCtx2dCreateRadialGradient, 6)
  c2dFn("createPattern", jsCtx2dCreatePattern, 2)
  c2dFn("isPointInPath", jsCtx2dIsPointInPath, 2)
  # Path operation stubs
  c2dFn("beginPath", jsCtx2dNoop, 0)
  c2dFn("closePath", jsCtx2dNoop, 0)
  c2dFn("moveTo",    jsCtx2dNoop, 2)
  c2dFn("lineTo",    jsCtx2dNoop, 2)
  c2dFn("arc",       jsCtx2dNoop, 6)
  c2dFn("arcTo",     jsCtx2dNoop, 5)
  c2dFn("rect",      jsCtx2dNoop, 4)
  c2dFn("quadraticCurveTo", jsCtx2dNoop, 4)
  c2dFn("bezierCurveTo", jsCtx2dNoop, 6)
  c2dFn("ellipse",   jsCtx2dNoop, 8)
  c2dFn("fill",      jsCtx2dNoop, 0)
  c2dFn("stroke",    jsCtx2dNoop, 0)
  c2dFn("clip",      jsCtx2dNoop, 0)
  # Native property setters
  c2dFn("__rw_setFont", jsCtx2dSetFont, 1)
  c2dFn("__rw_setFillStyle", jsCtx2dSetFillStyle, 1)
  c2dFn("__rw_setGlobalAlpha", jsCtx2dSetGlobalAlpha, 1)
  c2dFn("__rw_setTextBaseline", jsCtx2dSetTextBaseline, 1)
  c2dFn("__rw_setTextAlign", jsCtx2dSetTextAlign, 1)

  ctxObj

proc bindCanvas2D(state: ptr RWebviewState) =
  ## Bind the __rw_createCanvas2D global function.
  let ctx = state.jsCtx
  let global = JS_GetGlobalObject(ctx)
  discard JS_SetPropertyStr(ctx, global, "__rw_createCanvas2D",
            JS_NewCFunction(ctx, jsCreateCanvas2D, "__rw_createCanvas2D", 1))
  rw_JS_FreeValue(ctx, global)
  # Reset canvas2d states for new page
  canvas2dStates = @[]

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
  for e in state.rafStaging:
    rw_JS_FreeValue(ctx, e.fn)
  for t in state.timers:
    if t.active:
      rw_JS_FreeValue(ctx, t.fn)
  state.rafPending = @[]
  state.rafStaging = @[]
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
  rw_JS_FreeValue(ctx, onload)

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

  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE)

  let sdlWin = SDL_CreateWindow("rwebview", width, height, SDL_WINDOW_OPENGL)
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
  JS_FreeContext(state.jsCtx)
  JS_FreeRuntime(state.rt)
  discard SDL_GL_DestroyContext(state.glCtx)
  SDL_DestroyWindow(state.sdlWindow)
  SDL_Quit()
  `=destroy`(state[])
  dealloc(state)
  WEBVIEW_ERROR_OK

proc webview_run*(w: Webview): cint {.exportc, cdecl, discardable.} =
  ## Block on the SDL event loop until the window is closed.
  ## Phase 3: handles keyboard/mouse/window events, rAF dispatch, timer dispatch.
  if w == nil: return WEBVIEW_ERROR_INVALID_ARGUMENT
  let state = cast[ptr RWebviewState](w)
  var event: SDL_Event

  template evalDisp(js: string) =
    let r = JS_Eval(state.jsCtx, cstring(js), csize_t(js.len),
                    "<event>", JS_EVAL_TYPE_GLOBAL)
    discard jsCheck(state.jsCtx, r, "<event>")

  while state.running:
    while SDL_PollEvent(addr event):
      case event.typ

      of SDL_EVENT_QUIT, SDL_EVENT_WINDOW_CLOSE_REQUESTED:
        state.running = false

      of SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_UP:
        let evType    = if event.typ == SDL_EVENT_KEY_DOWN: "keydown" else: "keyup"
        let keyCode   = int(sdlEvKeyCode(event))
        let scanCode  = int(sdlEvKeyScancode(event))
        let modFlags  = sdlEvKeyMod(event)   # uint16
        let isDown    = event.typ == SDL_EVENT_KEY_DOWN
        let altKey    = (modFlags and SDL_KMOD_ALT)   != 0
        let ctrlKey   = (modFlags and SDL_KMOD_CTRL)  != 0
        let shiftKey  = (modFlags and SDL_KMOD_SHIFT) != 0
        let keyName   = $SDL_GetKeyName(uint32(keyCode))
        let js = "__rw_dispatchEvent(document,'" & evType & "',{" &
                 "keyCode:" & $keyCode & "," &
                 "which:" & $keyCode & "," &
                 "code:'Key" & $scanCode & "'," &
                 "key:" & "'" & keyName & "'," &
                 "altKey:" & (if altKey: "true" else: "false") & "," &
                 "ctrlKey:" & (if ctrlKey: "true" else: "false") & "," &
                 "shiftKey:" & (if shiftKey: "true" else: "false") & "," &
                 "repeat:" & (if isDown and sdlEvKeyRepeat(event): "true" else: "false") &
                 "});"
        evalDisp(js)

      of SDL_EVENT_MOUSE_MOTION:
        let mx = sdlEvMouseX(event)
        let my = sdlEvMouseY(event)
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
        # SDL: 1=Left 2=Middle 3=Right → JS: 0=Left 1=Middle 2=Right
        let btnJS   =
          if btnSDL == 1: 0
          elif btnSDL == 2: 1
          elif btnSDL == 3: 2
          else: btnSDL - 1
        let mask = uint32(1 shl btnJS)
        if isPress: state.mouseButtons = state.mouseButtons or mask
        else:       state.mouseButtons = state.mouseButtons and not mask
        let evType = if isPress: "mousedown" else: "mouseup"
        let mx = sdlEvMouseX(event)
        let my = sdlEvMouseY(event)
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

    # Per-frame: fire timers, dispatch rAF, swap GL buffer.
    dispatchTimers(state)
    dispatchRaf(state)
    discard SDL_GL_SwapWindow(state.sdlWindow)

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
  ## Phase 3: register a named JS↔Nim binding backed by QuickJS.
  WEBVIEW_ERROR_OK

proc webview_unbind*(w: Webview; name: cstring): cint {.exportc, cdecl, discardable.} =
  WEBVIEW_ERROR_OK

proc webview_return*(w: Webview; id: cstring; status: cint;
                     retval: cstring): cint {.exportc, cdecl, discardable.} =
  WEBVIEW_ERROR_OK

# ===========================================================================
# Phase 4 test  (run: nim c rwebview.nim && rwebview.exe)
# ===========================================================================

when isMainModule:
  echo "rwebview Phase 5 -- Canvas 2D (Text Rendering)"

  # Resolve test.html relative to this source file so the binary can be run
  # from any working directory.  rwebviewRoot is a const defined at the top.
  const testHtml = rwebviewRoot / "test.html"

  let w = webview_create(width = 800, height = 600)
  if w == nil:
    stderr.writeLine("FAIL: webview_create returned nil")
    quit(1)

  # Point baseDir at this directory so relative asset paths resolve correctly.
  webview_set_virtual_host_name_to_folder_mapping(
    w, "rover.assets", cstring(rwebviewRoot), 0)

  const testUrl = "file:///" & testHtml.replace('\\', '/')
  discard webview_navigate(w, cstring(testUrl))

  echo ""
  echo "Phase 5 test started. Close window to finish."
  discard webview_run(w)
  discard webview_destroy(w)
  echo "Phase 5: COMPLETE"