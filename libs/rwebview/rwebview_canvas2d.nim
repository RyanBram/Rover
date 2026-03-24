# ===========================================================================
# Phase 5 — Canvas 2D state types and globals
# ===========================================================================

type
  CompositeOp = enum
    copSourceOver = 0, copCopy = 1, copLighter = 2,
    copDifference = 3, copSourceAtop = 4, copDestinationIn = 5,
    copSaturation = 6

  FillMode = enum
    fmColor = 0, fmGradient = 1, fmPattern = 2

  PatternData = object
    width, height: int
    pixels: seq[uint8]

  Canvas2DSavedState = object
    fillR, fillG, fillB, fillA: uint8
    strokeR, strokeG, strokeB, strokeA: uint8
    lineWidth: float32
    globalAlpha: float32
    compositeOp: CompositeOp
    fillMode: FillMode
    fontSize: float32
    fontFamily: string
    textBaseline: string
    textAlign: string
    transform: array[6, float32]  # a,b,c,d,e,f

  Canvas2DState = object
    width, height: int
    pixels: seq[uint8]      # RGBA, width*height*4 bytes
    fillR, fillG, fillB, fillA: uint8
    strokeR, strokeG, strokeB, strokeA: uint8
    lineWidth: float32
    globalAlpha: float32
    compositeOp: CompositeOp
    fillMode: FillMode
    fontSize: float32
    fontFamily: string
    textBaseline: string
    textAlign: string
    transform: array[6, float32]  # a,b,c,d,e,f
    stateStack: seq[Canvas2DSavedState]
    canvasJsVal: JSValue    # reference to the canvas JS element (for width/height sync)
    isDisplay: bool         # true when appended to document.body (shown on screen)
    # Gradient state
    gradX0, gradY0, gradX1, gradY1: float32
    gradR0, gradG0, gradB0, gradA0: uint8
    gradR1, gradG1, gradB1, gradA1: uint8
    # Pattern state
    patternWidth, patternHeight: int
    patternPixels: seq[uint8]
    # Path state (for arc+fill)
    pathActive: bool
    pathArcX, pathArcY, pathArcR: float32

var canvas2dStates: seq[Canvas2DState]
var patternStore: seq[PatternData]
var ttfFontCache: Table[string, ptr TTF_Font]  # key = "family:size"
var ttfInitialized: bool = false
var defaultFontPath: string = ""  # resolved on first use

proc initCanvas2DState(w, h: int): Canvas2DState =
  result.width = w
  result.height = h
  result.pixels = newSeq[uint8](w * h * 4)
  result.fillR = 0; result.fillG = 0; result.fillB = 0; result.fillA = 255
  result.strokeR = 0; result.strokeG = 0; result.strokeB = 0; result.strokeA = 255
  result.lineWidth = 1.0f
  result.globalAlpha = 1.0f
  result.compositeOp = copSourceOver
  result.fillMode = fmColor
  result.fontSize = 10.0f
  result.fontFamily = "sans-serif"
  result.textBaseline = "alphabetic"
  result.textAlign = "start"
  result.transform = [1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f]  # identity
  result.patternWidth = 0; result.patternHeight = 0

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
  # 1. Check @font-face map registered from CSS stylesheets
  if lowerFamily in fontFaceMap:
    path = fontFaceMap[lowerFamily]
  # 2. Try common font paths relative to baseDir
  if path == "":
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
  if x1 <= x0 or y1 <= y0: return rw_JS_Undefined()
  if x0 == 0 and x1 >= cs.width:
    # Fast path: zero whole rows at once (single memset for the full canvas common case)
    zeroMem(addr cs.pixels[y0 * cs.width * 4], (y1 - y0) * cs.width * 4)
  else:
    let rowBytes = (x1 - x0) * 4
    for y in y0..<y1:
      zeroMem(addr cs.pixels[(y * cs.width + x0) * 4], rowBytes)
  rw_JS_Undefined()

# ── Compositing helper — applies one pixel (sR,sG,sB,sA) to dest ────────
proc blendPixel(cs: ptr Canvas2DState; off: int; sR, sG, sB: uint8; sA: int) {.inline.} =
  case cs.compositeOp
  of copSourceOver:
    if sA >= 255:
      cs.pixels[off] = sR; cs.pixels[off+1] = sG; cs.pixels[off+2] = sB; cs.pixels[off+3] = 255
    elif sA > 0:
      let da = int(cs.pixels[off+3])
      let outA = sA + da * (255 - sA) div 255
      if outA > 0:
        cs.pixels[off]   = uint8((int(sR) * sA + int(cs.pixels[off]) * da * (255 - sA) div 255) div outA)
        cs.pixels[off+1] = uint8((int(sG) * sA + int(cs.pixels[off+1]) * da * (255 - sA) div 255) div outA)
        cs.pixels[off+2] = uint8((int(sB) * sA + int(cs.pixels[off+2]) * da * (255 - sA) div 255) div outA)
        cs.pixels[off+3] = uint8(outA)
  of copCopy:
    cs.pixels[off] = sR; cs.pixels[off+1] = sG; cs.pixels[off+2] = sB; cs.pixels[off+3] = uint8(sA)
  of copLighter:
    # Additive blend: add source (premultiplied by alpha) to dest
    let sa = sA
    if sa > 0:
      let sr = int(sR) * sa div 255
      let sg = int(sG) * sa div 255
      let sb = int(sB) * sa div 255
      cs.pixels[off]   = uint8(min(255, int(cs.pixels[off]) + sr))
      cs.pixels[off+1] = uint8(min(255, int(cs.pixels[off+1]) + sg))
      cs.pixels[off+2] = uint8(min(255, int(cs.pixels[off+2]) + sb))
      cs.pixels[off+3] = uint8(min(255, int(cs.pixels[off+3]) + sa))
  of copDifference:
    let sa = sA
    if sa > 0:
      cs.pixels[off]   = uint8(abs(int(cs.pixels[off]) - int(sR) * sa div 255))
      cs.pixels[off+1] = uint8(abs(int(cs.pixels[off+1]) - int(sG) * sa div 255))
      cs.pixels[off+2] = uint8(abs(int(cs.pixels[off+2]) - int(sB) * sa div 255))
  of copSourceAtop:
    # Draw source where destination has alpha
    let da = int(cs.pixels[off+3])
    if da > 0 and sA > 0:
      let sa = sA * da div 255
      let invSa = 255 - sA
      cs.pixels[off]   = uint8((int(sR) * sa + int(cs.pixels[off]) * invSa) div 255)
      cs.pixels[off+1] = uint8((int(sG) * sa + int(cs.pixels[off+1]) * invSa) div 255)
      cs.pixels[off+2] = uint8((int(sB) * sa + int(cs.pixels[off+2]) * invSa) div 255)
      # Alpha unchanged
  of copDestinationIn:
    # Keep destination only where source has alpha
    let sa = sA
    cs.pixels[off+3] = uint8(int(cs.pixels[off+3]) * sa div 255)
  of copSaturation:
    # Simplified: desaturate destination towards gray, weighted by source alpha
    let da = int(cs.pixels[off+3])
    if da > 0 and sA > 0:
      let sa = sA
      let gray = (int(cs.pixels[off]) * 77 + int(cs.pixels[off+1]) * 150 + int(cs.pixels[off+2]) * 29) shr 8
      cs.pixels[off]   = uint8((gray * sa + int(cs.pixels[off]) * (255 - sa)) div 255)
      cs.pixels[off+1] = uint8((gray * sa + int(cs.pixels[off+1]) * (255 - sa)) div 255)
      cs.pixels[off+2] = uint8((gray * sa + int(cs.pixels[off+2]) * (255 - sa)) div 255)

# ── fillRect ─────────────────────────────────────────────────────────────
proc jsCtx2dFillRect(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var fdx, fdy, fdw, fdh: float64
  discard JS_ToFloat64(ctx, addr fdx, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr fdy, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr fdw, arg(argv, 2))
  discard JS_ToFloat64(ctx, addr fdh, arg(argv, 3))
  # Apply CTM to destination rect
  let fA = cs.transform[0]; let fB = cs.transform[1]
  let fC = cs.transform[2]; let fD = cs.transform[3]
  let fE = cs.transform[4]; let fF = cs.transform[5]
  let fsx = fA * float32(fdx) + fC * float32(fdy) + fE
  let fsy = fB * float32(fdx) + fD * float32(fdy) + fF
  let fsw = abs(fA) * float32(fdw) + abs(fC) * float32(fdh)
  let fsh = abs(fB) * float32(fdw) + abs(fD) * float32(fdh)
  let x0 = max(0, int(fsx))
  let y0 = max(0, int(fsy))
  let x1 = min(cs.width, int(fsx + fsw))
  let y1 = min(cs.height, int(fsy + fsh))
  if x1 <= x0 or y1 <= y0: return rw_JS_Undefined()
  let ga = cs.globalAlpha

  # --- Pattern fill ---
  if cs.fillMode == fmPattern and cs.patternWidth > 0 and cs.patternHeight > 0:
    let pw = cs.patternWidth; let ph = cs.patternHeight
    # Use inverse CTM to tile from canvas-space origin (0,0), so that
    # parallax scroll (CTM translate carries -scrollX/-scrollY) is reflected
    let invA = cs.transform[0]; let invB = cs.transform[1]
    let invC = cs.transform[2]; let invD = cs.transform[3]
    let invE = cs.transform[4]; let invF = cs.transform[5]
    let det = invA * invD - invB * invC
    for y in y0..<y1:
      for x in x0..<x1:
        let px = float32(x) - invE
        let py = float32(y) - invF
        var cx, cy: float32
        if abs(det) > 0.0001f:
          cx = (invD * px - invC * py) / det
          cy = (invA * py - invB * px) / det
        else:
          cx = px; cy = py
        let srcX = ((int(cx) mod pw) + pw) mod pw
        let srcY = ((int(cy) mod ph) + ph) mod ph
        let si = (srcY * pw + srcX) * 4
        let sA = int(float32(cs.patternPixels[si+3]) * ga)
        if sA > 0:
          let off = (y * cs.width + x) * 4
          blendPixel(cs, off, cs.patternPixels[si], cs.patternPixels[si+1], cs.patternPixels[si+2], sA)
    return rw_JS_Undefined()

  # --- Gradient fill ---
  if cs.fillMode == fmGradient:
    let gx0 = cs.gradX0; let gy0 = cs.gradY0
    let gx1 = cs.gradX1; let gy1 = cs.gradY1
    let gdx = gx1 - gx0; let gdy = gy1 - gy0
    let glen2 = gdx * gdx + gdy * gdy
    for y in y0..<y1:
      for x in x0..<x1:
        # Compute gradient position t
        var t: float32
        if glen2 > 0.001f:
          t = ((float32(x) - gx0) * gdx + (float32(y) - gy0) * gdy) / glen2
        else:
          t = 0.0f
        t = max(0.0f, min(1.0f, t))
        let invT = 1.0f - t
        let sR = uint8(float32(cs.gradR0) * invT + float32(cs.gradR1) * t)
        let sG = uint8(float32(cs.gradG0) * invT + float32(cs.gradG1) * t)
        let sB = uint8(float32(cs.gradB0) * invT + float32(cs.gradB1) * t)
        let sA = int(float32(uint8(float32(cs.gradA0) * invT + float32(cs.gradA1) * t)) * ga)
        if sA > 0:
          let off = (y * cs.width + x) * 4
          blendPixel(cs, off, sR, sG, sB, sA)
    return rw_JS_Undefined()

  # --- Solid color fill ---
  let a = uint8(float32(cs.fillA) * ga)
  # Fast path: source-over opaque
  if cs.compositeOp == copSourceOver and a == 255:
    let rgba = uint32(cs.fillR) or (uint32(cs.fillG) shl 8) or
               (uint32(cs.fillB) shl 16) or 0xff000000'u32
    let rowLen = x1 - x0
    for y in y0..<y1:
      let rowPtr = cast[ptr UncheckedArray[uint32]](
                     addr cs.pixels[(y * cs.width + x0) * 4])
      for i in 0..<rowLen:
        rowPtr[i] = rgba
  else:
    for y in y0..<y1:
      for x in x0..<x1:
        let off = (y * cs.width + x) * 4
        blendPixel(cs, off, cs.fillR, cs.fillG, cs.fillB, int(a))
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
  let fullAlpha = ga >= 1.0
  # Pre-compute column clip range once per text render (eliminates per-pixel
  # bounds check inside the inner loop — biggest single speedup for fillText)
  let colBeg = max(0, -ix)
  let colEnd = min(sw, cs.width - ix)
  for row in 0..<sh:
    let dstY = iy + row
    if dstY < 0 or dstY >= cs.height: continue
    if colBeg >= colEnd: continue
    let srcRowBase = cast[ptr UncheckedArray[uint8]](addr srcPixels[row * int(rgbaSurf.pitch)])
    let dstRowBase = cast[ptr UncheckedArray[uint32]](addr cs.pixels[(dstY * cs.width + ix + colBeg) * 4])
    let srcBase    = colBeg
    for col in 0..<(colEnd - colBeg):
      let src = cast[ptr array[4, uint8]](addr srcRowBase[(srcBase + col) * 4])
      let rawA = src[3]
      if rawA == 0: continue
      let sa = if fullAlpha: int(rawA) else: int(float32(rawA) * ga)
      if sa >= 255:
        # Opaque pixel: single uint32 write, no blend
        dstRowBase[col] = uint32(src[0]) or (uint32(src[1]) shl 8) or
                          (uint32(src[2]) shl 16) or 0xff000000'u32
      else:
        let dstPtr = cast[ptr array[4, uint8]](addr dstRowBase[col])
        let da = int(dstPtr[3])
        let outA = sa + da * (255 - sa) div 255
        if outA > 0:
          dstPtr[0] = uint8((int(src[0]) * sa + int(dstPtr[0]) * da * (255 - sa) div 255) div outA)
          dstPtr[1] = uint8((int(src[1]) * sa + int(dstPtr[1]) * da * (255 - sa) div 255) div outA)
          dstPtr[2] = uint8((int(src[2]) * sa + int(dstPtr[2]) * da * (255 - sa) div 255) div outA)
          dstPtr[3] = uint8(outA)
  SDL_DestroySurface(rgbaSurf)
  rw_JS_Undefined()

# ── strokeText (outline rendering via offset blitting) ───────────────────
proc jsCtx2dStrokeText(ctx: ptr JSContext; thisVal: JSValue;
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
  let tx = cs.transform[0] * float32(dx) + cs.transform[2] * float32(dy) + cs.transform[4]
  let ty = cs.transform[1] * float32(dx) + cs.transform[3] * float32(dy) + cs.transform[5]
  let baseDir = if gState != nil: gState.baseDir else: ""
  let font = getOrLoadFont(cs.fontFamily, cs.fontSize, baseDir)
  if font == nil:
    JS_FreeCString(ctx, text)
    return rw_JS_Undefined()
  let color = SDL_Color(r: cs.strokeR, g: cs.strokeG, b: cs.strokeB, a: 255)
  let rawSurf = TTF_RenderText_Blended(font, text, 0, color)
  JS_FreeCString(ctx, text)
  if rawSurf == nil: return rw_JS_Undefined()
  let rgbaSurf = cast[ptr SDL_Surface](SDL_ConvertSurface(rawSurf, SDL_PIXELFORMAT_RGBA32))
  SDL_DestroySurface(rawSurf)
  if rgbaSurf == nil: return rw_JS_Undefined()
  let sw = int(rgbaSurf.w)
  let sh = int(rgbaSurf.h)
  let srcPixels = cast[ptr UncheckedArray[uint8]](rgbaSurf.pixels)
  var iy = int(ty)
  case cs.textBaseline
  of "top": discard
  of "middle": iy -= sh div 2
  of "bottom", "ideographic": iy -= sh
  else: iy -= sh * 3 div 4
  var ix = int(tx)
  case cs.textAlign
  of "center": ix -= sw div 2
  of "right", "end": ix -= sw
  else: discard
  # Render at 8 offsets for outline effect
  let lw = max(1, int(cs.lineWidth / 2.0f))
  let ga = cs.globalAlpha
  let offsets = [(-lw, -lw), (-lw, 0), (-lw, lw), (0, -lw),
                 (0, lw), (lw, -lw), (lw, 0), (lw, lw)]
  for off in offsets:
    let ox = ix + off[0]
    let oy = iy + off[1]
    let colBeg = max(0, -ox)
    let colEnd = min(sw, cs.width - ox)
    for row in 0..<sh:
      let dstY = oy + row
      if dstY < 0 or dstY >= cs.height: continue
      if colBeg >= colEnd: continue
      let srcRowBase = cast[ptr UncheckedArray[uint8]](addr srcPixels[row * int(rgbaSurf.pitch)])
      let dstRowBase = cast[ptr UncheckedArray[uint32]](addr cs.pixels[(dstY * cs.width + ox + colBeg) * 4])
      for col in 0..<(colEnd - colBeg):
        let src = cast[ptr array[4, uint8]](addr srcRowBase[(colBeg + col) * 4])
        let rawA = src[3]
        if rawA == 0: continue
        # Apply both globalAlpha and strokeA to the outline opacity
        let sa = int(float32(rawA) * ga * float32(cs.strokeA) / 255.0f)
        if sa <= 0: continue
        if sa >= 255:
          dstRowBase[col] = uint32(src[0]) or (uint32(src[1]) shl 8) or
                            (uint32(src[2]) shl 16) or 0xff000000'u32
        else:
          let dstPtr = cast[ptr array[4, uint8]](addr dstRowBase[col])
          let da = int(dstPtr[3])
          let outA = sa + da * (255 - sa) div 255
          if outA > 0:
            dstPtr[0] = uint8((int(src[0]) * sa + int(dstPtr[0]) * da * (255 - sa) div 255) div outA)
            dstPtr[1] = uint8((int(src[1]) * sa + int(dstPtr[1]) * da * (255 - sa) div 255) div outA)
            dstPtr[2] = uint8((int(src[2]) * sa + int(dstPtr[2]) * da * (255 - sa) div 255) div outA)
            dstPtr[3] = uint8(outA)
  SDL_DestroySurface(rgbaSurf)
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
  # Apply CTM [a,b,c,d,e,f] to destination rect. PIXI calls setTransform per sprite
  # then drawImage at logical (0,0) — the CTM carry the world position and scale.
  let ctmA = cs.transform[0]; let ctmB = cs.transform[1]
  let ctmC = cs.transform[2]; let ctmD = cs.transform[3]
  let ctmE = cs.transform[4]; let ctmF = cs.transform[5]
  let tdx = ctmA * float32(dx) + ctmC * float32(dy) + ctmE
  let tdy = ctmB * float32(dx) + ctmD * float32(dy) + ctmF
  let tdw = abs(ctmA) * float32(dw) + abs(ctmC) * float32(dh)
  let tdh = abs(ctmB) * float32(dw) + abs(ctmD) * float32(dh)
  dx = int(tdx); dy = int(tdy)
  dw = max(1, int(tdw + 0.5'f32)); dh = max(1, int(tdh + 0.5'f32))
  # Nearest-neighbor blit with compositing.
  let ga = cs.globalAlpha
  # Fast path: 1:1 blit (no scaling), full alpha.
  # Handles source-over (per-pixel blend) and copy (direct memcopy per row).
  if sw == dw and sh == dh and ga >= 1.0 and
     (cs.compositeOp == copSourceOver or cs.compositeOp == copCopy):
    let clipX0 = max(dx, 0)
    let clipX1 = min(dx + dw, cs.width)
    if clipX0 < clipX1:
      let srcXOff = sx + (clipX0 - dx)
      for row in 0..<dh:
        let dstY = dy + row
        if dstY < 0 or dstY >= cs.height: continue
        let srcRow = sy + row
        if srcRow < 0 or srcRow >= srcH: continue
        if srcXOff < 0 or srcXOff + (clipX1 - clipX0) > srcW: continue
        let dstBase = (dstY * cs.width + clipX0) * 4
        let srcBase = (srcRow * srcW + srcXOff) * 4
        let rowW = clipX1 - clipX0
        if cs.compositeOp == copCopy:
          # Direct copy: overwrite destination with source (no blending)
          copyMem(addr cs.pixels[dstBase], addr srcPixels[srcBase], rowW * 4)
        else:
          for col in 0..<rowW:
            let si = srcBase + col * 4
            let di = dstBase + col * 4
            let sa = srcPixels[si + 3]
            if sa == 0'u8: discard
            elif sa >= 255'u8:
              cs.pixels[di] = srcPixels[si]; cs.pixels[di+1] = srcPixels[si+1]
              cs.pixels[di+2] = srcPixels[si+2]; cs.pixels[di+3] = 255'u8
            else:
              let sia = int(sa)
              let da = int(cs.pixels[di+3])
              let outA = sia + da * (255 - sia) div 255
              if outA > 0:
                cs.pixels[di]   = uint8((int(srcPixels[si]) * sia + int(cs.pixels[di]) * da * (255 - sia) div 255) div outA)
                cs.pixels[di+1] = uint8((int(srcPixels[si+1]) * sia + int(cs.pixels[di+1]) * da * (255 - sia) div 255) div outA)
                cs.pixels[di+2] = uint8((int(srcPixels[si+2]) * sia + int(cs.pixels[di+2]) * da * (255 - sia) div 255) div outA)
                cs.pixels[di+3] = uint8(outA)
    return rw_JS_Undefined()
  # General path: scaling / compositing / alpha
  for row in 0..<dh:
    let dstY = dy + row
    if dstY < 0 or dstY >= cs.height: continue
    let srcRow = sy + (if dh != 0: row * sh div dh else: 0)
    if srcRow < 0 or srcRow >= srcH: continue
    let srcRowOff = srcRow * srcW * 4
    for col in 0..<dw:
      let dstX = dx + col
      if dstX < 0 or dstX >= cs.width: continue
      let srcCol = sx + (if dw != 0: col * sw div dw else: 0)
      if srcCol < 0 or srcCol >= srcW: continue
      let si = srcRowOff + srcCol * 4
      let di = (dstY * cs.width + dstX) * 4
      let sa = int(float32(srcPixels[si + 3]) * ga)
      if sa > 0:
        blendPixel(cs, di, srcPixels[si], srcPixels[si+1], srcPixels[si+2], sa)
      elif cs.compositeOp == copDestinationIn:
        # source is transparent → erase destination (this clips the outline/highlight
        # to the sprite shape; without this, areas outside the sprite stay lit up)
        cs.pixels[di+3] = 0
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
    strokeR: cs.strokeR, strokeG: cs.strokeG, strokeB: cs.strokeB, strokeA: cs.strokeA,
    lineWidth: cs.lineWidth,
    globalAlpha: cs.globalAlpha, compositeOp: cs.compositeOp,
    fillMode: cs.fillMode,
    fontSize: cs.fontSize,
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
  cs.strokeR = saved.strokeR; cs.strokeG = saved.strokeG
  cs.strokeB = saved.strokeB; cs.strokeA = saved.strokeA
  cs.lineWidth = saved.lineWidth
  cs.globalAlpha = saved.globalAlpha
  cs.compositeOp = saved.compositeOp
  cs.fillMode = saved.fillMode
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
proc jsGradAddColorStop(ctx: ptr JSContext; thisVal: JSValue;
                        argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## addColorStop(offset, colorString) — stores parsed RGBA on gradient object
  var offset: float64
  discard JS_ToFloat64(ctx, addr offset, arg(argv, 0))
  let colorStr = jsToCString(ctx, arg(argv, 1))
  if colorStr == nil: return rw_JS_Undefined()
  var r, g, b, a: uint8
  parseCssColor($colorStr, r, g, b, a)
  JS_FreeCString(ctx, colorStr)
  let prefix = if offset <= 0.5: "__c0" else: "__c1"
  discard JS_SetPropertyStr(ctx, thisVal, prefix & "r", rw_JS_NewInt32(ctx, int32(r)))
  discard JS_SetPropertyStr(ctx, thisVal, prefix & "g", rw_JS_NewInt32(ctx, int32(g)))
  discard JS_SetPropertyStr(ctx, thisVal, prefix & "b", rw_JS_NewInt32(ctx, int32(b)))
  discard JS_SetPropertyStr(ctx, thisVal, prefix & "a", rw_JS_NewInt32(ctx, int32(a)))
  rw_JS_Undefined()

proc jsCtx2dCreateLinearGradient(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var x0, y0, x1, y1: float64
  discard JS_ToFloat64(ctx, addr x0, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr y0, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr x1, arg(argv, 2))
  discard JS_ToFloat64(ctx, addr y1, arg(argv, 3))
  let grad = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, grad, "__isGradient", rw_JS_NewInt32(ctx, 1))
  discard JS_SetPropertyStr(ctx, grad, "__x0", rw_JS_NewFloat64(ctx, x0))
  discard JS_SetPropertyStr(ctx, grad, "__y0", rw_JS_NewFloat64(ctx, y0))
  discard JS_SetPropertyStr(ctx, grad, "__x1", rw_JS_NewFloat64(ctx, x1))
  discard JS_SetPropertyStr(ctx, grad, "__y1", rw_JS_NewFloat64(ctx, y1))
  let addFn = JS_NewCFunction(ctx, jsGradAddColorStop, "addColorStop", 2)
  discard JS_SetPropertyStr(ctx, grad, "addColorStop", addFn)
  grad

proc jsCtx2dCreateRadialGradient(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  # Treat radial as linear for now (rare in RPG Maker)
  var x0, y0, x1, y1: float64
  discard JS_ToFloat64(ctx, addr x0, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr y0, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr x1, arg(argv, 3))
  discard JS_ToFloat64(ctx, addr y1, arg(argv, 4))
  let grad = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, grad, "__isGradient", rw_JS_NewInt32(ctx, 1))
  discard JS_SetPropertyStr(ctx, grad, "__x0", rw_JS_NewFloat64(ctx, x0))
  discard JS_SetPropertyStr(ctx, grad, "__y0", rw_JS_NewFloat64(ctx, y0))
  discard JS_SetPropertyStr(ctx, grad, "__x1", rw_JS_NewFloat64(ctx, x1))
  discard JS_SetPropertyStr(ctx, grad, "__y1", rw_JS_NewFloat64(ctx, y1))
  let addFn = JS_NewCFunction(ctx, jsGradAddColorStop, "addColorStop", 2)
  discard JS_SetPropertyStr(ctx, grad, "addColorStop", addFn)
  grad

proc jsCtx2dCreatePattern(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## createPattern(sourceCanvas, repetition) — returns pattern object with source pixel data
  let source = arg(argv, 0)
  let pat = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, pat, "__isPattern", rw_JS_NewInt32(ctx, 1))
  # Try to get source canvas pixel data via __ctxId
  let idProp = JS_GetPropertyStr(ctx, source, "__ctxId")
  var srcId: int32 = -1
  discard JS_ToInt32(ctx, addr srcId, idProp)
  rw_JS_FreeValue(ctx, idProp)
  if srcId >= 0 and srcId < int32(canvas2dStates.len):
    let srcCs = addr canvas2dStates[srcId]
    let patId = int32(patternStore.len)
    patternStore.add(PatternData(width: srcCs.width, height: srcCs.height, pixels: srcCs.pixels))
    discard JS_SetPropertyStr(ctx, pat, "__patId", rw_JS_NewInt32(ctx, patId))
  pat

# ── isPointInPath (stub) ─────────────────────────────────────────────────
proc jsCtx2dIsPointInPath(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_False()

# ── Path operations ──────────────────────────────────────────────────────
proc jsCtx2dNoop(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_Undefined()

proc jsCtx2dBeginPath(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs != nil:
    cs.pathActive = false
  rw_JS_Undefined()

proc jsCtx2dArc(ctx: ptr JSContext; thisVal: JSValue;
                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var x, y, radius, startAngle, endAngle: float64
  discard JS_ToFloat64(ctx, addr x, arg(argv, 0))
  discard JS_ToFloat64(ctx, addr y, arg(argv, 1))
  discard JS_ToFloat64(ctx, addr radius, arg(argv, 2))
  discard JS_ToFloat64(ctx, addr startAngle, arg(argv, 3))
  discard JS_ToFloat64(ctx, addr endAngle, arg(argv, 4))
  # Store arc params — only support full circles (0 to 2π) for now
  cs.pathActive = true
  cs.pathArcX = float32(x)
  cs.pathArcY = float32(y)
  cs.pathArcR = float32(radius)
  rw_JS_Undefined()

proc jsCtx2dFill(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil or not cs.pathActive: return rw_JS_Undefined()
  # Fill a circle at (pathArcX, pathArcY) with radius pathArcR
  let cx = cs.pathArcX; let cy = cs.pathArcY; let r = cs.pathArcR
  if r <= 0: return rw_JS_Undefined()
  let ga = cs.globalAlpha
  let a = uint8(float32(cs.fillA) * ga)
  let r2 = r * r
  let ix0 = max(0, int(cx - r))
  let ix1 = min(cs.width, int(cx + r + 1))
  let iy0 = max(0, int(cy - r))
  let iy1 = min(cs.height, int(cy + r + 1))
  for y in iy0..<iy1:
    let dy = float32(y) + 0.5f - cy
    for x in ix0..<ix1:
      let dx = float32(x) + 0.5f - cx
      if dx * dx + dy * dy <= r2:
        let off = (y * cs.width + x) * 4
        blendPixel(cs, off, cs.fillR, cs.fillG, cs.fillB, int(a))
  cs.pathActive = false
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
  if tag == JS_TAG_INT_C or tag == JS_TAG_FLOAT64_C:
    return rw_JS_Undefined()
  let str = jsToCString(ctx, arg(argv, 0))
  if str != nil:
    parseCssColor($str, cs.fillR, cs.fillG, cs.fillB, cs.fillA)
    cs.fillMode = fmColor
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

proc jsCtx2dSetStrokeStyle(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let str = jsToCString(ctx, arg(argv, 0))
  if str != nil:
    parseCssColor($str, cs.strokeR, cs.strokeG, cs.strokeB, cs.strokeA)
    JS_FreeCString(ctx, str)
  rw_JS_Undefined()

proc jsCtx2dSetLineWidth(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  var v: float64
  discard JS_ToFloat64(ctx, addr v, arg(argv, 0))
  cs.lineWidth = float32(max(0.0, v))
  rw_JS_Undefined()

proc jsCtx2dSetCompositeOp(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let s = jsToCString(ctx, arg(argv, 0))
  if s != nil:
    case $s
    of "source-over": cs.compositeOp = copSourceOver
    of "copy": cs.compositeOp = copCopy
    of "lighter": cs.compositeOp = copLighter
    of "difference": cs.compositeOp = copDifference
    of "source-atop": cs.compositeOp = copSourceAtop
    of "destination-in": cs.compositeOp = copDestinationIn
    of "saturation": cs.compositeOp = copSaturation
    else: discard
    JS_FreeCString(ctx, s)
  rw_JS_Undefined()

proc jsCtx2dSetFillStyleGradient(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_setFillStyleGradient(gradObj) — reads gradient data and stores in Canvas2DState
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let grad = arg(argv, 0)
  var v: float64
  let x0p = JS_GetPropertyStr(ctx, grad, "__x0"); discard JS_ToFloat64(ctx, addr v, x0p); cs.gradX0 = float32(v); rw_JS_FreeValue(ctx, x0p)
  let y0p = JS_GetPropertyStr(ctx, grad, "__y0"); discard JS_ToFloat64(ctx, addr v, y0p); cs.gradY0 = float32(v); rw_JS_FreeValue(ctx, y0p)
  let x1p = JS_GetPropertyStr(ctx, grad, "__x1"); discard JS_ToFloat64(ctx, addr v, x1p); cs.gradX1 = float32(v); rw_JS_FreeValue(ctx, x1p)
  let y1p = JS_GetPropertyStr(ctx, grad, "__y1"); discard JS_ToFloat64(ctx, addr v, y1p); cs.gradY1 = float32(v); rw_JS_FreeValue(ctx, y1p)
  # Read color stops
  proc readComp(ctx: ptr JSContext; obj: JSValue; name: string): uint8 =
    let p = JS_GetPropertyStr(ctx, obj, name.cstring)
    var iv: int32
    discard JS_ToInt32(ctx, addr iv, p)
    rw_JS_FreeValue(ctx, p)
    uint8(iv and 255)
  cs.gradR0 = readComp(ctx, grad, "__c0r"); cs.gradG0 = readComp(ctx, grad, "__c0g")
  cs.gradB0 = readComp(ctx, grad, "__c0b"); cs.gradA0 = readComp(ctx, grad, "__c0a")
  cs.gradR1 = readComp(ctx, grad, "__c1r"); cs.gradG1 = readComp(ctx, grad, "__c1g")
  cs.gradB1 = readComp(ctx, grad, "__c1b"); cs.gradA1 = readComp(ctx, grad, "__c1a")
  cs.fillMode = fmGradient
  rw_JS_Undefined()

proc jsCtx2dSetFillStylePattern(ctx: ptr JSContext; thisVal: JSValue;
                                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_setFillStylePattern(patObj) — reads pattern data and stores in Canvas2DState
  let cs = getCtx2DState(ctx, thisVal)
  if cs == nil: return rw_JS_Undefined()
  let pat = arg(argv, 0)
  let idProp = JS_GetPropertyStr(ctx, pat, "__patId")
  var patId: int32 = -1
  discard JS_ToInt32(ctx, addr patId, idProp)
  rw_JS_FreeValue(ctx, idProp)
  if patId >= 0 and patId < int32(patternStore.len):
    cs.patternWidth = patternStore[patId].width
    cs.patternHeight = patternStore[patId].height
    cs.patternPixels = patternStore[patId].pixels
    cs.fillMode = fmPattern
  rw_JS_Undefined()

proc jsResizeCanvas2D(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_resizeCanvas2D(ctxId, w, h)
  ## Resizes the native pixel buffer for a canvas2d context.
  if argc < 3: return rw_JS_Undefined()
  var id, w, h: int32
  discard JS_ToInt32(ctx, addr id, arg(argv, 0))
  discard JS_ToInt32(ctx, addr w,  arg(argv, 1))
  discard JS_ToInt32(ctx, addr h,  arg(argv, 2))
  if id >= 0 and id < int32(canvas2dStates.len) and w > 0 and h > 0:
    resizeCanvas2D(canvas2dStates[id], int(w), int(h))
  rw_JS_Undefined()

proc jsSetCanvasVisible(ctx: ptr JSContext; thisVal: JSValue;
                        argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_setCanvasVisible(ctxId, visible)
  ## Mark a canvas as a display target (rendered to screen each frame).
  if argc < 2: return rw_JS_Undefined()
  var id: int32
  discard JS_ToInt32(ctx, addr id, arg(argv, 0))
  if id >= 0 and id < int32(canvas2dStates.len):
    var bval: int32
    discard JS_ToInt32(ctx, addr bval, arg(argv, 1))
    canvas2dStates[id].isDisplay = bval != 0
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
  # If this element was appended to document.body before getContext was called,
  # the JS setter set _isDisplayCanvas=true. Check and mark the state.
  let dispProp = JS_GetPropertyStr(ctx, canvasEl, "_isDisplayCanvas")
  let dispTag = rw_JS_VALUE_GET_TAG(dispProp)
  if dispTag != JS_TAG_NULL_C and dispTag != JS_TAG_UNDEFINED_C:
    var bval: int32
    discard JS_ToInt32(ctx, addr bval, dispProp)
    if bval != 0:
      canvas2dStates[id].isDisplay = true
  rw_JS_FreeValue(ctx, dispProp)
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
  # Path operations
  c2dFn("beginPath", jsCtx2dBeginPath, 0)
  c2dFn("closePath", jsCtx2dNoop, 0)
  c2dFn("moveTo",    jsCtx2dNoop, 2)
  c2dFn("lineTo",    jsCtx2dNoop, 2)
  c2dFn("arc",       jsCtx2dArc, 6)
  c2dFn("arcTo",     jsCtx2dNoop, 5)
  c2dFn("rect",      jsCtx2dNoop, 4)
  c2dFn("quadraticCurveTo", jsCtx2dNoop, 4)
  c2dFn("bezierCurveTo", jsCtx2dNoop, 6)
  c2dFn("ellipse",   jsCtx2dNoop, 8)
  c2dFn("fill",      jsCtx2dFill, 0)
  c2dFn("stroke",    jsCtx2dNoop, 0)
  c2dFn("clip",      jsCtx2dNoop, 0)
  # Native property setters
  c2dFn("__rw_setFont", jsCtx2dSetFont, 1)
  c2dFn("__rw_setFillStyle", jsCtx2dSetFillStyle, 1)
  c2dFn("__rw_setGlobalAlpha", jsCtx2dSetGlobalAlpha, 1)
  c2dFn("__rw_setTextBaseline", jsCtx2dSetTextBaseline, 1)
  c2dFn("__rw_setTextAlign", jsCtx2dSetTextAlign, 1)
  c2dFn("__rw_setStrokeStyle", jsCtx2dSetStrokeStyle, 1)
  c2dFn("__rw_setLineWidth", jsCtx2dSetLineWidth, 1)
  c2dFn("__rw_setCompositeOp", jsCtx2dSetCompositeOp, 1)
  c2dFn("__rw_setFillStyleGradient", jsCtx2dSetFillStyleGradient, 1)
  c2dFn("__rw_setFillStylePattern", jsCtx2dSetFillStylePattern, 1)

  ctxObj

proc bindCanvas2D(state: ptr RWebviewState) =
  ## Bind the __rw_createCanvas2D global function.
  let ctx = state.jsCtx
  let global = JS_GetGlobalObject(ctx)
  discard JS_SetPropertyStr(ctx, global, "__rw_createCanvas2D",
            JS_NewCFunction(ctx, jsCreateCanvas2D, "__rw_createCanvas2D", 1))
  discard JS_SetPropertyStr(ctx, global, "__rw_resizeCanvas2D",
            JS_NewCFunction(ctx, jsResizeCanvas2D, "__rw_resizeCanvas2D", 3))
  discard JS_SetPropertyStr(ctx, global, "__rw_setCanvasVisible",
            JS_NewCFunction(ctx, jsSetCanvasVisible, "__rw_setCanvasVisible", 2))
  rw_JS_FreeValue(ctx, global)
  # Free and reset canvas2d states for new page
  for cs in canvas2dStates:
    rw_JS_FreeValue(ctx, cs.canvasJsVal)
  canvas2dStates = @[]
  patternStore = @[]


