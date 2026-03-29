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

# Finger/Touch event accessors (SDL_TouchFingerEvent offsets)
proc sdlEvFingerX(e: var SDL_Event): float32 {.inline.} =
  cast[ptr float32](cast[uint](addr e) + 32)[]
proc sdlEvFingerY(e: var SDL_Event): float32 {.inline.} =
  cast[ptr float32](cast[uint](addr e) + 36)[]
proc sdlEvFingerID(e: var SDL_Event): uint64 {.inline.} =
  cast[ptr uint64](cast[uint](addr e) + 24)[]
proc sdlEvFingerPressure(e: var SDL_Event): float32 {.inline.} =
  cast[ptr float32](cast[uint](addr e) + 48)[]

# SDL_GLAttr ordinal values — counted from SDL3's SDL_video.h SDL_GLAttr enum:
# 0=RED_SIZE, 1=GREEN_SIZE, 2=BLUE_SIZE, 3=ALPHA_SIZE, 4=BUFFER_SIZE,
# 5=DOUBLEBUFFER, 6=DEPTH_SIZE, 7=STENCIL_SIZE, 8=ACCUM_RED_SIZE,
# 9=ACCUM_GREEN_SIZE, 10=ACCUM_BLUE_SIZE, 11=ACCUM_ALPHA_SIZE,
# 12=STEREO, 13=MULTISAMPLEBUFFERS, 14=MULTISAMPLESAMPLES,
# 15=ACCELERATED_VISUAL, 16=RETAINED_BACKING (deprecated),
# 17=CONTEXT_MAJOR_VERSION, 18=CONTEXT_MINOR_VERSION,
# 19=CONTEXT_FLAGS, 20=CONTEXT_PROFILE_MASK, ...
const
  SDL_GL_DOUBLEBUFFER*            = 5.cint
  SDL_GL_DEPTH_SIZE*              = 6.cint
  SDL_GL_ACCELERATED_VISUAL*      = 15.cint
  SDL_GL_CONTEXT_MAJOR_VERSION*   = 17.cint
  SDL_GL_CONTEXT_MINOR_VERSION*   = 18.cint
  SDL_GL_CONTEXT_PROFILE_MASK*    = 20.cint
  SDL_GL_CONTEXT_PROFILE_CORE*    = 0x0001.cint

const
  SDL_INIT_AUDIO* = 0x00000010'u32
  SDL_INIT_VIDEO* = 0x00000020'u32

const
  SDL_WINDOW_OPENGL*     = 0x0000000000000002'u64
  SDL_WINDOW_RESIZABLE*   = 0x0000000000000020'u64

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
  # Touch/Finger events
  SDL_EVENT_FINGER_DOWN*            = 0x700'u32
  SDL_EVENT_FINGER_UP*              = 0x701'u32
  SDL_EVENT_FINGER_MOTION*          = 0x702'u32
  SDL_EVENT_FINGER_CANCELED*        = 0x703'u32

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
# SDL3 FFI
# With -d:sdlStatic, links SDL3 statically (libSDL3.a).
# Otherwise links dynamically (SDL3.dll).
# ===========================================================================

when defined(sdlStatic):
  const sdlStaticLibPath = rwebviewRoot / "bin" / "staticlib" / "lib" / "libSDL3.a"
  {.passL: sdlStaticLibPath.}
  # Static SDL3 on Windows needs system libraries
  {.passL: "-lgdi32 -luser32 -lshell32 -lole32 -loleaut32 -limm32 -lwinmm -lsetupapi -lversion -ladvapi32 -luuid -lcfgmgr32 -lhid".}

proc SDL_Init(flags: uint32): bool
    {.importc: "SDL_Init".}
proc SDL_Quit()
    {.importc: "SDL_Quit".}
proc SDL_CreateWindow(title: cstring; w: cint; h: cint; flags: uint64): ptr SDL_Window
    {.importc: "SDL_CreateWindow".}
proc SDL_DestroyWindow(window: ptr SDL_Window)
    {.importc: "SDL_DestroyWindow".}
proc SDL_SetWindowTitle(window: ptr SDL_Window; title: cstring): bool
    {.importc: "SDL_SetWindowTitle".}
proc SDL_SetWindowSize(window: ptr SDL_Window; w: cint; h: cint): bool
    {.importc: "SDL_SetWindowSize".}
proc SDL_GL_SetAttribute(attr: cint; value: cint): bool
    {.importc: "SDL_GL_SetAttribute".}
proc SDL_GL_CreateContext(window: ptr SDL_Window): SDL_GLContext
    {.importc: "SDL_GL_CreateContext".}
proc SDL_GL_DestroyContext(ctx: SDL_GLContext): bool
    {.importc: "SDL_GL_DestroyContext".}
proc SDL_GL_SwapWindow(window: ptr SDL_Window): bool
    {.importc: "SDL_GL_SwapWindow".}
proc SDL_PollEvent(event: ptr SDL_Event): bool
    {.importc: "SDL_PollEvent".}
proc SDL_GetWindowProperties(window: ptr SDL_Window): uint32
    {.importc: "SDL_GetWindowProperties".}
proc SDL_GetPointerProperty(props: uint32; name: cstring; default: pointer): pointer
    {.importc: "SDL_GetPointerProperty".}
proc SDL_GetError(): cstring
    {.importc: "SDL_GetError".}
proc SDL_GetTicks(): uint64
    {.importc: "SDL_GetTicks".}
proc SDL_GetKeyName(key: uint32): cstring
    {.importc: "SDL_GetKeyName".}
proc SDL_GL_GetProcAddress(name: cstring): pointer
    {.importc: "SDL_GL_GetProcAddress".}
proc SDL_GL_SetSwapInterval(interval: cint): bool
    {.importc: "SDL_GL_SetSwapInterval".}
proc SDL_Delay(ms: uint32)
    {.importc: "SDL_Delay".}
proc SDL_DestroySurface(surface: pointer)
    {.importc: "SDL_DestroySurface".}
proc SDL_ConvertSurface(surface: pointer; format: uint32): pointer
    {.importc: "SDL_ConvertSurface".}
proc SDL_MaximizeWindow(window: ptr SDL_Window): bool
    {.importc: "SDL_MaximizeWindow".}
proc SDL_GetWindowSizeInPixels(window: ptr SDL_Window; w: ptr cint; h: ptr cint): bool
    {.importc: "SDL_GetWindowSizeInPixels".}
proc SDL_SetHint(name: cstring; value: cstring): bool
    {.importc: "SDL_SetHint".}

# Windows timer resolution — set to 1 ms for accurate Sleep/SDL_Delay timing.
when defined(windows):
  proc timeBeginPeriod(uPeriod: cuint): cuint
      {.importc: "timeBeginPeriod", dynlib: "winmm.dll", discardable.}
  proc timeEndPeriod(uPeriod: cuint): cuint
      {.importc: "timeEndPeriod", dynlib: "winmm.dll", discardable.}

  const WM_CLOSE_MSG = 0x0010'u32  # WM_CLOSE
  proc PostMessageA(hWnd: pointer; Msg: uint32; wParam: uint; lParam: int): cint
      {.importc: "PostMessageA", dynlib: "user32.dll", discardable.}

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

