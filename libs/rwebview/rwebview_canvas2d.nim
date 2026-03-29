# =============================================================================
# rwebview_canvas2d.nim
# Canvas 2D state types and globals
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
#   Implementation of Canvas 2D API (nanovg binding) with state types and globals.
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rgss_quickjs_ffi         # JS helpers
#   - rwebview_dom             # gState
#   - rwebview_html            # fontFaceMap
#
# Used by:
#   - rwebview.nim             # included after rwebview_dom.nim
#
# =============================================================================

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
    canvasJsVal: ScriptValue    # reference to the canvas JS element (for width/height sync)
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
    dirty: bool           # true when pixels changed since last GL upload

var canvas2dStates: seq[Canvas2DState]
var patternStore: seq[PatternData]

# -- Fonstash CPU wrapper FFI (rwebview_fonstash_core.c) --------------------
proc rw_fons_init(atlasW: cint; atlasH: cint): cint {.importc, cdecl.}
proc rw_fons_destroy() {.importc, cdecl.}
proc rw_fons_add_font(name: cstring; path: cstring): cint {.importc, cdecl.}
proc rw_fons_find_font(name: cstring): cint {.importc, cdecl.}
proc rw_fons_set_font(fontId: cint) {.importc, cdecl.}
proc rw_fons_set_size(size: cfloat) {.importc, cdecl.}
proc rw_fons_text_width(text: cstring): cfloat {.importc, cdecl.}
proc rw_fons_vert_metrics(ascender: ptr cfloat; descender: ptr cfloat; lineh: ptr cfloat) {.importc, cdecl.}
proc rw_fons_render_text_rgba(text: cstring; r, g, b: uint8;
                              outW, outH: ptr cint;
                              outBaselineY: ptr cint): pointer {.importc, cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

var fonsInitialized: bool = false
var fonsFontCache: Table[string, cint]  # key = "family" -> fonstash font ID
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
  result.dirty = true  # new canvas needs first upload

proc resizeCanvas2D(state: var Canvas2DState; w, h: int) =
  if w == state.width and h == state.height: return
  state.width = w
  state.height = h
  state.pixels = newSeq[uint8](w * h * 4)
  state.dirty = true

proc getOrLoadFonsFont(family: string; size: float32; baseDir: string): cint =
  ## Load or find a font via fonstash, set its size, and return font ID.
  ## Returns -1 on failure.
  if not fonsInitialized:
    if rw_fons_init(1024, 1024) == 0:
      stderr.writeLine("[rwebview] rw_fons_init failed")
      return -1
    fonsInitialized = true
  # Check if this family is already loaded
  let lowerFamily = family.toLowerAscii()
  if lowerFamily in fonsFontCache:
    let fid = fonsFontCache[lowerFamily]
    rw_fons_set_font(fid)
    rw_fons_set_size(cfloat(size))
    return fid
  # Resolve font file path (same logic as before)
  var path = ""
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
    return -1
  let fid = rw_fons_add_font(cstring(lowerFamily), cstring(path))
  if fid < 0:
    stderr.writeLine("[rwebview] rw_fons_add_font failed for: " & path)
    return -1
  if defaultFontPath == "":
    defaultFontPath = path  # cache first successfully loaded font as default
  fonsFontCache[lowerFamily] = fid
  rw_fons_set_font(fid)
  rw_fons_set_size(cfloat(size))
  fid

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

proc getCtx2DState(ctx: ptr ScriptCtx; thisVal: ScriptValue): ptr Canvas2DState =
  ## Extract the Canvas2DState pointer from `this.__ctxId`.
  let idProp = ctx.getProp(thisVal, "__ctxId")
  var id: int32
  id = ctx.toInt32(idProp)
  ctx.freeValue(idProp)
  if id >= 0 and id < int32(canvas2dStates.len):
    return addr canvas2dStates[id]
  return nil

# ── clearRect ────────────────────────────────────────────────────────────
proc jsCtx2dClearRect(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  cs.dirty = true
  var dx, dy, dw, dh: float64
  dx = ctx.toFloat64(args[0])
  dy = ctx.toFloat64(args[1])
  dw = ctx.toFloat64(args[2])
  dh = ctx.toFloat64(args[3])
  let x0 = max(0, int(dx))
  let y0 = max(0, int(dy))
  let x1 = min(cs.width, int(dx + dw))
  let y1 = min(cs.height, int(dy + dh))
  if x1 <= x0 or y1 <= y0: return ctx.newUndefined()
  if x0 == 0 and x1 >= cs.width:
    # Fast path: zero whole rows at once (single memset for the full canvas common case)
    zeroMem(addr cs.pixels[y0 * cs.width * 4], (y1 - y0) * cs.width * 4)
  else:
    let rowBytes = (x1 - x0) * 4
    for y in y0..<y1:
      zeroMem(addr cs.pixels[(y * cs.width + x0) * 4], rowBytes)
  ctx.newUndefined()

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
proc jsCtx2dFillRect(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  cs.dirty = true
  var fdx, fdy, fdw, fdh: float64
  fdx = ctx.toFloat64(args[0])
  fdy = ctx.toFloat64(args[1])
  fdw = ctx.toFloat64(args[2])
  fdh = ctx.toFloat64(args[3])
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
  if x1 <= x0 or y1 <= y0: return ctx.newUndefined()
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
    return ctx.newUndefined()

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
    return ctx.newUndefined()

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
  ctx.newUndefined()

# ── strokeRect (stub — draws outline using fillStyle) ────────────────────
proc jsCtx2dStrokeRect(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ctx.newUndefined()

# ── fillText ─────────────────────────────────────────────────────────────
proc jsCtx2dFillText(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  cs.dirty = true
  let text = ctx.toString(args[0])
  if text == nil or text[0] == '\0':
    if text != nil: ctx.freeCString(text)
    return ctx.newUndefined()
  var dx, dy: float64
  dx = ctx.toFloat64(args[1])
  dy = ctx.toFloat64(args[2])
  # Optional 4th arg: maxWidth (Canvas2D spec — compress text horizontally if wider)
  var maxWidth: float64 = 0.0
  if args.len > 3: maxWidth = ctx.toFloat64(args[3])
  # Apply transform to destination coordinates
  let tx = cs.transform[0] * float32(dx) + cs.transform[2] * float32(dy) + cs.transform[4]
  let ty = cs.transform[1] * float32(dx) + cs.transform[3] * float32(dy) + cs.transform[5]
  let baseDir = if gState != nil: gState.baseDir else: ""
  let fontId = getOrLoadFonsFont(cs.fontFamily, cs.fontSize, baseDir)
  if fontId < 0:
    ctx.freeCString(text)
    return ctx.newUndefined()
  # Get font vertical metrics for accurate baseline/middle positioning
  var ascF, descF, lhF: cfloat
  rw_fons_vert_metrics(addr ascF, addr descF, addr lhF)
  var sw, sh, baselineY: cint
  let rgbaPtr = rw_fons_render_text_rgba(text, cs.fillR, cs.fillG, cs.fillB,
                                          addr sw, addr sh, addr baselineY)
  ctx.freeCString(text)
  if rgbaPtr == nil: return ctx.newUndefined()
  # Guard: reject bogus dimensions
  if sw <= 0 or sh <= 0 or sw > 8192 or sh > 8192:
    c_free(rgbaPtr); return ctx.newUndefined()
  let expectPixLenF = cs.width * cs.height * 4
  if cs.pixels.len != expectPixLenF:
    c_free(rgbaPtr); return ctx.newUndefined()
  let srcPixels = cast[ptr UncheckedArray[uint8]](rgbaPtr)
  let pitch = int(sw) * 4
  # Adjust Y based on textBaseline
  var iy = int(ty)
  case cs.textBaseline
  of "top": discard  # y is already at top
  of "middle":
    # Em-square midpoint: stable across strings with/without descenders.
    # mid_row = baselineY - (ascF + descF) / 2  (descF is negative in fontstash)
    iy -= int(round(float32(baselineY) - (ascF + descF) / 2.0f))
  of "bottom", "ideographic": iy -= int(sh)
  else: iy -= int(baselineY)  # "alphabetic" — exact ascender offset from font metrics
  # maxWidth compression: renderW is the target display width
  let renderW = if maxWidth > 0.0 and float64(sw) > maxWidth: int(maxWidth) else: int(sw)
  let doScaleX = renderW < int(sw)
  # Adjust X based on textAlign (pivot uses renderW, not raw sw)
  var ix = int(tx)
  case cs.textAlign
  of "center": ix -= renderW div 2
  of "right", "end": ix -= renderW
  else: discard  # "left", "start"
  # Blit with alpha blending
  let ga = cs.globalAlpha
  let fullAlpha = ga >= 1.0
  # Pre-compute column clip range once per text render
  let colBeg = max(0, -ix)
  let colEnd = min(renderW, cs.width - ix)
  for row in 0..<int(sh):
    let dstY = iy + row
    if dstY < 0 or dstY >= cs.height: continue
    if colBeg >= colEnd: continue
    let srcRowBase = cast[ptr UncheckedArray[uint8]](addr srcPixels[row * pitch])
    let dstRowBase = cast[ptr UncheckedArray[uint32]](addr cs.pixels[(dstY * cs.width + ix + colBeg) * 4])
    for col in 0..<(colEnd - colBeg):
      # Map destination column back to source (nearest-neighbour horizontal scale)
      let srcCol = if doScaleX: (colBeg + col) * int(sw) div renderW else: colBeg + col
      let src = cast[ptr array[4, uint8]](addr srcRowBase[srcCol * 4])
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
  c_free(rgbaPtr)
  ctx.newUndefined()

# ── strokeText (outline rendering via offset blitting) ───────────────────
proc jsCtx2dStrokeText(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  cs.dirty = true
  let text = ctx.toString(args[0])
  if text == nil or text[0] == '\0':
    if text != nil: ctx.freeCString(text)
    return ctx.newUndefined()
  var dx, dy: float64
  dx = ctx.toFloat64(args[1])
  dy = ctx.toFloat64(args[2])
  # Optional 4th arg: maxWidth (Canvas2D spec — compress text horizontally if wider)
  var maxWidth: float64 = 0.0
  if args.len > 3: maxWidth = ctx.toFloat64(args[3])
  let tx = cs.transform[0] * float32(dx) + cs.transform[2] * float32(dy) + cs.transform[4]
  let ty = cs.transform[1] * float32(dx) + cs.transform[3] * float32(dy) + cs.transform[5]
  let baseDir = if gState != nil: gState.baseDir else: ""
  let fontId = getOrLoadFonsFont(cs.fontFamily, cs.fontSize, baseDir)
  if fontId < 0:
    ctx.freeCString(text)
    return ctx.newUndefined()
  # Get font vertical metrics for accurate baseline/middle positioning
  var ascF, descF, lhF: cfloat
  rw_fons_vert_metrics(addr ascF, addr descF, addr lhF)
  var sw, sh, baselineY: cint
  let rgbaPtr = rw_fons_render_text_rgba(text, cs.strokeR, cs.strokeG, cs.strokeB,
                                          addr sw, addr sh, addr baselineY)
  ctx.freeCString(text)
  if rgbaPtr == nil: return ctx.newUndefined()
  # Guard: reject bogus dimensions
  if sw <= 0 or sh <= 0 or sw > 8192 or sh > 8192:
    c_free(rgbaPtr)
    return ctx.newUndefined()
  let srcBufLen = int(sw) * int(sh) * 4
  let expectPixLen = cs.width * cs.height * 4
  if cs.pixels.len != expectPixLen:
    c_free(rgbaPtr); return ctx.newUndefined()
  let srcPixels = cast[ptr UncheckedArray[uint8]](rgbaPtr)
  let pitch = int(sw) * 4
  var iy = int(ty)
  case cs.textBaseline
  of "top": discard
  of "middle":
    # Em-square midpoint: stable across strings with/without descenders.
    iy -= int(round(float32(baselineY) - (ascF + descF) / 2.0f))
  of "bottom", "ideographic": iy -= int(sh)
  else: iy -= int(baselineY)  # "alphabetic" — exact ascender offset from font metrics
  # maxWidth compression: renderW is the target display width
  let renderW = if maxWidth > 0.0 and float64(sw) > maxWidth: int(maxWidth) else: int(sw)
  let doScaleX = renderW < int(sw)
  var ix = int(tx)
  case cs.textAlign
  of "center": ix -= renderW div 2
  of "right", "end": ix -= renderW
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
    let colEnd = min(renderW, cs.width - ox)
    for row in 0..<int(sh):
      let dstY = oy + row
      if dstY < 0 or dstY >= cs.height: continue
      if colBeg >= colEnd: continue
      let srcRowOff = row * pitch
      # Bounds check against unscaled src buffer
      let srcCheckCol = if doScaleX: (colEnd - 1) * int(sw) div renderW else: colEnd - 1
      let srcLastByte = srcRowOff + srcCheckCol * 4 + 3
      if srcLastByte >= srcBufLen: continue
      let dstBaseOff = (dstY * cs.width + ox + colBeg) * 4
      let dstLastByte = dstBaseOff + (colEnd - colBeg - 1) * 4 + 3
      if dstBaseOff < 0 or dstLastByte >= cs.pixels.len: continue
      let srcRowBase = cast[ptr UncheckedArray[uint8]](addr srcPixels[srcRowOff])
      let dstRowBase = cast[ptr UncheckedArray[uint32]](addr cs.pixels[dstBaseOff])
      for col in 0..<(colEnd - colBeg):
        let srcCol = if doScaleX: (colBeg + col) * int(sw) div renderW else: colBeg + col
        let src = cast[ptr array[4, uint8]](addr srcRowBase[srcCol * 4])
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
  c_free(rgbaPtr)
  ctx.newUndefined()

# ── measureText ──────────────────────────────────────────────────────────
proc jsCtx2dMeasureText(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil:
    let obj = ctx.newObject()
    ctx.setPropSteal(obj, "width", ctx.newFloat(0.0))
    return obj
  let text = ctx.toString(args[0])
  if text == nil:
    let obj = ctx.newObject()
    ctx.setPropSteal(obj, "width", ctx.newFloat(0.0))
    return obj
  let baseDir = if gState != nil: gState.baseDir else: ""
  let fontId = getOrLoadFonsFont(cs.fontFamily, cs.fontSize, baseDir)
  var tw: cfloat = 0.0
  if fontId >= 0:
    tw = rw_fons_text_width(text)
  ctx.freeCString(text)
  let obj = ctx.newObject()
  ctx.setPropSteal(obj, "width", ctx.newFloat(float64(tw)))
  obj

# ── drawImage ────────────────────────────────────────────────────────────
proc jsCtx2dDrawImage(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  cs.dirty = true
  let source = args[0]
  # Determine source pixel data, width, height
  var srcPixels: ptr UncheckedArray[uint8] = nil
  var srcW, srcH: int = 0
  # Check if source is a canvas with __ctxId
  let ctxIdProp = ctx.getProp(source, "__ctxId")
  if ctx.isNumber(ctxIdProp):
    var srcId: int32
    srcId = ctx.toInt32(ctxIdProp)
    if srcId >= 0 and srcId < int32(canvas2dStates.len):
      let sc = addr canvas2dStates[srcId]
      srcW = sc.width; srcH = sc.height
      if sc.pixels.len > 0:
        srcPixels = cast[ptr UncheckedArray[uint8]](addr sc.pixels[0])
  ctx.freeValue(ctxIdProp)
  # Also check __pixelData (for HTMLImageElement)
  if srcPixels == nil:
    let pxProp = ctx.getProp(source, "__pixelData")
    if not ctx.isNull(pxProp) and not ctx.isUndefined(pxProp):
      var bufLen1: int
      let data = ctx.getArrayBufferData(pxProp, bufLen1)
      if data != nil:
        srcPixels = cast[ptr UncheckedArray[uint8]](data)
        let wProp = ctx.getProp(source, "naturalWidth")
        let hProp = ctx.getProp(source, "naturalHeight")
        var iw, ih: int32
        iw = ctx.toInt32(wProp)
        ih = ctx.toInt32(hProp)
        ctx.freeValue(wProp)
        ctx.freeValue(hProp)
        srcW = int(iw); srcH = int(ih)
    ctx.freeValue(pxProp)
  if srcPixels == nil or srcW == 0 or srcH == 0:
    return ctx.newUndefined()
  # Parse arguments: drawImage(img, dx, dy) or (img, dx, dy, dw, dh)
  # or (img, sx, sy, sw, sh, dx, dy, dw, dh)
  var sx, sy, sw, sh: int
  var dx, dy, dw, dh: int
  if args.len >= 9:
    var f: float64
    f = ctx.toFloat64(args[1]); sx = int(f)
    f = ctx.toFloat64(args[2]); sy = int(f)
    f = ctx.toFloat64(args[3]); sw = int(f)
    f = ctx.toFloat64(args[4]); sh = int(f)
    f = ctx.toFloat64(args[5]); dx = int(f)
    f = ctx.toFloat64(args[6]); dy = int(f)
    f = ctx.toFloat64(args[7]); dw = int(f)
    f = ctx.toFloat64(args[8]); dh = int(f)
  elif args.len >= 5:
    sx = 0; sy = 0; sw = srcW; sh = srcH
    var f: float64
    f = ctx.toFloat64(args[1]); dx = int(f)
    f = ctx.toFloat64(args[2]); dy = int(f)
    f = ctx.toFloat64(args[3]); dw = int(f)
    f = ctx.toFloat64(args[4]); dh = int(f)
  else:
    sx = 0; sy = 0; sw = srcW; sh = srcH; dw = srcW; dh = srcH
    var f: float64
    f = ctx.toFloat64(args[1]); dx = int(f)
    f = ctx.toFloat64(args[2]); dy = int(f)
  # Apply CTM [a,b,c,d,e,f] to destination rect. PIXI calls setTransform per sprite
  # then drawImage at logical (0,0) — the CTM carry the world position and scale.
  let ctmA = cs.transform[0]; let ctmB = cs.transform[1]
  let ctmC = cs.transform[2]; let ctmD = cs.transform[3]
  let ctmE = cs.transform[4]; let ctmF = cs.transform[5]
  # Save original destination rect before CTM overwrite (needed for affine path).
  let origDx = dx; let origDy = dy; let origDw = dw; let origDh = dh
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
    return ctx.newUndefined()
  # Affine-sampled path: handles rotation/skew correctly by using per-pixel
  # inverse-transform sampling instead of AABB + linear mapping.
  # Activated when the CTM has a non-zero rotation component (b≠0 or c≠0).
  let hasRotation = abs(ctmB) > 0.001f or abs(ctmC) > 0.001f
  if hasRotation:
    let det = ctmA * ctmD - ctmB * ctmC
    if abs(det) > 1e-8f:
      let invDet = 1.0f / det
      let invA = ctmD * invDet
      let invB = -ctmB * invDet
      let invC = -ctmC * invDet
      let invD = ctmA * invDet
      let invE = (ctmC * ctmF - ctmD * ctmE) * invDet
      let invF = (ctmB * ctmE - ctmA * ctmF) * invDet
      let aabbX0 = max(0, dx)
      let aabbX1 = min(cs.width, dx + dw)
      let aabbY0 = max(0, dy)
      let aabbY1 = min(cs.height, dy + dh)
      let odw = float32(origDw); let odh = float32(origDh)
      let osx = float32(sx); let osy = float32(sy)
      let osw = float32(sw); let osh = float32(sh)
      let odx = float32(origDx); let ody = float32(origDy)
      for canvasY in aabbY0..<aabbY1:
        for canvasX in aabbX0..<aabbX1:
          let localX = invA * float32(canvasX) + invC * float32(canvasY) + invE
          let localY = invB * float32(canvasX) + invD * float32(canvasY) + invF
          let u = (localX - odx) / odw
          let v = (localY - ody) / odh
          if u < 0.0f or u >= 1.0f or v < 0.0f or v >= 1.0f: continue
          let srcIx = int(osx + u * osw)
          let srcIy = int(osy + v * osh)
          if srcIx < sx or srcIx >= sx + sw: continue
          if srcIy < sy or srcIy >= sy + sh: continue
          let si = (srcIy * srcW + srcIx) * 4
          let di = (canvasY * cs.width + canvasX) * 4
          let rawA = srcPixels[si + 3]
          if rawA == 0'u8:
            if cs.compositeOp == copDestinationIn:
              cs.pixels[di+3] = 0
            continue
          let sa = if ga >= 1.0: int(rawA) else: int(float32(rawA) * ga)
          if sa > 0:
            blendPixel(cs, di, srcPixels[si], srcPixels[si+1], srcPixels[si+2], sa)
    return ctx.newUndefined()
  # General path: axis-aligned scaling / compositing / alpha
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
  ctx.newUndefined()

# ── getImageData ─────────────────────────────────────────────────────────
proc jsCtx2dGetImageData(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  var sx, sy, sw, sh: float64
  sx = ctx.toFloat64(args[0])
  sy = ctx.toFloat64(args[1])
  sw = ctx.toFloat64(args[2])
  sh = ctx.toFloat64(args[3])
  let iw = int(sw); let ih = int(sh)
  let totalBytes = iw * ih * 4
  # Create a Uint8ClampedArray with copies of pixel data
  let jsStr = "new Uint8ClampedArray(" & $totalBytes & ")"
  let arr = ctx.eval(cstring(jsStr), "<getImageData>")
  if cs != nil and totalBytes > 0:
    let abProp = ctx.getProp(arr, "buffer")
    var abSize: int
    let abPtr = ctx.getArrayBufferData(abProp, abSize)
    ctx.freeValue(abProp)
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
  let obj = ctx.newObject()
  ctx.setPropSteal(obj, "data", arr)
  ctx.setPropSteal(obj, "width", ctx.newInt(int32(iw)))
  ctx.setPropSteal(obj, "height", ctx.newInt(int32(ih)))
  obj

# ── putImageData ─────────────────────────────────────────────────────────
proc jsCtx2dPutImageData(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  cs.dirty = true
  let imageData = args[0]
  var dx, dy: float64
  dx = ctx.toFloat64(args[1])
  dy = ctx.toFloat64(args[2])
  let dataProp = ctx.getProp(imageData, "data")
  var bufLen2: int
  let srcPtr = ctx.getArrayBufferData(dataProp, bufLen2)
  ctx.freeValue(dataProp)
  if srcPtr == nil: return ctx.newUndefined()
  let wProp = ctx.getProp(imageData, "width")
  let hProp = ctx.getProp(imageData, "height")
  var iw, ih: int32
  iw = ctx.toInt32(wProp)
  ih = ctx.toInt32(hProp)
  ctx.freeValue(wProp)
  ctx.freeValue(hProp)
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
  ctx.newUndefined()

# ── save / restore ───────────────────────────────────────────────────────
proc jsCtx2dSave(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
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
  ctx.newUndefined()

proc jsCtx2dRestore(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil or cs.stateStack.len == 0: return ctx.newUndefined()
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
  ctx.newUndefined()

# ── transform operations ─────────────────────────────────────────────────
proc jsCtx2dTranslate(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  var tx, ty: float64
  tx = ctx.toFloat64(args[0])
  ty = ctx.toFloat64(args[1])
  cs.transform[4] += cs.transform[0] * float32(tx) + cs.transform[2] * float32(ty)
  cs.transform[5] += cs.transform[1] * float32(tx) + cs.transform[3] * float32(ty)
  ctx.newUndefined()

proc jsCtx2dRotate(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  var angle: float64
  angle = ctx.toFloat64(args[0])
  let cosA = cos(angle).float32
  let sinA = sin(angle).float32
  let a = cs.transform[0]; let b = cs.transform[1]
  let c = cs.transform[2]; let d = cs.transform[3]
  cs.transform[0] = a * cosA + c * sinA
  cs.transform[1] = b * cosA + d * sinA
  cs.transform[2] = c * cosA - a * sinA
  cs.transform[3] = d * cosA - b * sinA
  ctx.newUndefined()

proc jsCtx2dScale(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  var sx, sy: float64
  sx = ctx.toFloat64(args[0])
  sy = ctx.toFloat64(args[1])
  cs.transform[0] *= float32(sx); cs.transform[1] *= float32(sx)
  cs.transform[2] *= float32(sy); cs.transform[3] *= float32(sy)
  ctx.newUndefined()

proc jsCtx2dSetTransform(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  if args.len >= 6:
    var v: float64
    v = ctx.toFloat64(args[0]); cs.transform[0] = float32(v)
    v = ctx.toFloat64(args[1]); cs.transform[1] = float32(v)
    v = ctx.toFloat64(args[2]); cs.transform[2] = float32(v)
    v = ctx.toFloat64(args[3]); cs.transform[3] = float32(v)
    v = ctx.toFloat64(args[4]); cs.transform[4] = float32(v)
    v = ctx.toFloat64(args[5]); cs.transform[5] = float32(v)
  ctx.newUndefined()

proc jsCtx2dResetTransform(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  cs.transform = [1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f]
  ctx.newUndefined()

# ── createLinearGradient / createRadialGradient ──────────────────────────
proc jsGradAddColorStop(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## addColorStop(offset, colorString) — stores parsed RGBA on gradient object
  var offset: float64
  offset = ctx.toFloat64(args[0])
  let colorStr = ctx.toString(args[1])
  if colorStr == nil: return ctx.newUndefined()
  var r, g, b, a: uint8
  parseCssColor($colorStr, r, g, b, a)
  ctx.freeCString(colorStr)
  let prefix = if offset <= 0.5: "__c0" else: "__c1"
  let kr = prefix & "r"; let kg = prefix & "g"
  let kb = prefix & "b"; let ka = prefix & "a"
  ctx.setPropSteal(this, cstring(kr), ctx.newInt(int32(r)))
  ctx.setPropSteal(this, cstring(kg), ctx.newInt(int32(g)))
  ctx.setPropSteal(this, cstring(kb), ctx.newInt(int32(b)))
  ctx.setPropSteal(this, cstring(ka), ctx.newInt(int32(a)))
  ctx.newUndefined()

proc jsCtx2dCreateLinearGradient(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var x0, y0, x1, y1: float64
  x0 = ctx.toFloat64(args[0])
  y0 = ctx.toFloat64(args[1])
  x1 = ctx.toFloat64(args[2])
  y1 = ctx.toFloat64(args[3])
  let grad = ctx.newObject()
  ctx.setPropSteal(grad, "__isGradient", ctx.newInt(1))
  ctx.setPropSteal(grad, "__x0", ctx.newFloat(x0))
  ctx.setPropSteal(grad, "__y0", ctx.newFloat(y0))
  ctx.setPropSteal(grad, "__x1", ctx.newFloat(x1))
  ctx.setPropSteal(grad, "__y1", ctx.newFloat(y1))
  let addFn = ctx.newFunction("addColorStop", jsGradAddColorStop, int(2))
  ctx.setPropSteal(grad, "addColorStop", addFn)
  grad

proc jsCtx2dCreateRadialGradient(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  # Treat radial as linear for now (rare in RPG Maker)
  var x0, y0, x1, y1: float64
  x0 = ctx.toFloat64(args[0])
  y0 = ctx.toFloat64(args[1])
  x1 = ctx.toFloat64(args[3])
  y1 = ctx.toFloat64(args[4])
  let grad = ctx.newObject()
  ctx.setPropSteal(grad, "__isGradient", ctx.newInt(1))
  ctx.setPropSteal(grad, "__x0", ctx.newFloat(x0))
  ctx.setPropSteal(grad, "__y0", ctx.newFloat(y0))
  ctx.setPropSteal(grad, "__x1", ctx.newFloat(x1))
  ctx.setPropSteal(grad, "__y1", ctx.newFloat(y1))
  let addFn = ctx.newFunction("addColorStop", jsGradAddColorStop, int(2))
  ctx.setPropSteal(grad, "addColorStop", addFn)
  grad

proc jsCtx2dCreatePattern(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## createPattern(sourceCanvas, repetition) — returns pattern object with source pixel data
  let source = args[0]
  let pat = ctx.newObject()
  ctx.setPropSteal(pat, "__isPattern", ctx.newInt(1))
  # Try to get source canvas pixel data via __ctxId
  let idProp = ctx.getProp(source, "__ctxId")
  var srcId: int32 = -1
  srcId = ctx.toInt32(idProp)
  ctx.freeValue(idProp)
  if srcId >= 0 and srcId < int32(canvas2dStates.len):
    let srcCs = addr canvas2dStates[srcId]
    let patId = int32(patternStore.len)
    patternStore.add(PatternData(width: srcCs.width, height: srcCs.height, pixels: srcCs.pixels))
    ctx.setPropSteal(pat, "__patId", ctx.newInt(patId))
  pat

# ── isPointInPath (stub) ─────────────────────────────────────────────────
proc jsCtx2dIsPointInPath(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ctx.newBool(false)

# ── Path operations ──────────────────────────────────────────────────────
proc jsCtx2dNoop(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ctx.newUndefined()

proc jsCtx2dBeginPath(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs != nil:
    cs.pathActive = false
  ctx.newUndefined()

proc jsCtx2dArc(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  var x, y, radius, startAngle, endAngle: float64
  x = ctx.toFloat64(args[0])
  y = ctx.toFloat64(args[1])
  radius = ctx.toFloat64(args[2])
  startAngle = ctx.toFloat64(args[3])
  endAngle = ctx.toFloat64(args[4])
  # Store arc params — only support full circles (0 to 2π) for now
  cs.pathActive = true
  cs.pathArcX = float32(x)
  cs.pathArcY = float32(y)
  cs.pathArcR = float32(radius)
  ctx.newUndefined()

proc jsCtx2dFill(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil or not cs.pathActive: return ctx.newUndefined()
  cs.dirty = true
  # Fill a circle at (pathArcX, pathArcY) with radius pathArcR
  let cx = cs.pathArcX; let cy = cs.pathArcY; let r = cs.pathArcR
  if r <= 0: return ctx.newUndefined()
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
  ctx.newUndefined()

# ── Property getters/setters ─────────────────────────────────────────────
# These are handled via a JS wrapper that syncs properties to native calls.

proc jsCtx2dSetFont(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  let fontStr = ctx.toString(args[0])
  if fontStr != nil:
    parseCssFont($fontStr, cs.fontSize, cs.fontFamily)
    ctx.freeCString(fontStr)
  ctx.newUndefined()

proc jsCtx2dSetFillStyle(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  if ctx.isNumber(args[0]):
    return ctx.newUndefined()
  let str = ctx.toString(args[0])
  if str != nil:
    parseCssColor($str, cs.fillR, cs.fillG, cs.fillB, cs.fillA)
    cs.fillMode = fmColor
    ctx.freeCString(str)
  ctx.newUndefined()

proc jsCtx2dSetGlobalAlpha(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  var a: float64
  a = ctx.toFloat64(args[0])
  cs.globalAlpha = float32(max(0.0, min(1.0, a)))
  ctx.newUndefined()

proc jsCtx2dSetTextBaseline(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  let s = ctx.toString(args[0])
  if s != nil:
    cs.textBaseline = $s
    ctx.freeCString(s)
  ctx.newUndefined()

proc jsCtx2dSetTextAlign(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  let s = ctx.toString(args[0])
  if s != nil:
    cs.textAlign = $s
    ctx.freeCString(s)
  ctx.newUndefined()

proc jsCtx2dSetStrokeStyle(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  let str = ctx.toString(args[0])
  if str != nil:
    parseCssColor($str, cs.strokeR, cs.strokeG, cs.strokeB, cs.strokeA)
    ctx.freeCString(str)
  ctx.newUndefined()

proc jsCtx2dSetLineWidth(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  var v: float64
  v = ctx.toFloat64(args[0])
  cs.lineWidth = float32(max(0.0, v))
  ctx.newUndefined()

proc jsCtx2dSetCompositeOp(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  let s = ctx.toString(args[0])
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
    ctx.freeCString(s)
  ctx.newUndefined()

proc jsCtx2dSetFillStyleGradient(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_setFillStyleGradient(gradObj) — reads gradient data and stores in Canvas2DState
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  let grad = args[0]
  var v: float64
  let x0p = ctx.getProp(grad, "__x0"); v = ctx.toFloat64(x0p); cs.gradX0 = float32(v); ctx.freeValue(x0p)
  let y0p = ctx.getProp(grad, "__y0"); v = ctx.toFloat64(y0p); cs.gradY0 = float32(v); ctx.freeValue(y0p)
  let x1p = ctx.getProp(grad, "__x1"); v = ctx.toFloat64(x1p); cs.gradX1 = float32(v); ctx.freeValue(x1p)
  let y1p = ctx.getProp(grad, "__y1"); v = ctx.toFloat64(y1p); cs.gradY1 = float32(v); ctx.freeValue(y1p)
  # Read color stops
  proc readComp(ctx: ptr ScriptCtx; obj: ScriptValue; name: string): uint8 =
    let p = ctx.getProp(obj, name.cstring)
    let iv = ctx.toInt32(p)
    ctx.freeValue(p)
    uint8(iv and 255)
  cs.gradR0 = readComp(ctx, grad, "__c0r"); cs.gradG0 = readComp(ctx, grad, "__c0g")
  cs.gradB0 = readComp(ctx, grad, "__c0b"); cs.gradA0 = readComp(ctx, grad, "__c0a")
  cs.gradR1 = readComp(ctx, grad, "__c1r"); cs.gradG1 = readComp(ctx, grad, "__c1g")
  cs.gradB1 = readComp(ctx, grad, "__c1b"); cs.gradA1 = readComp(ctx, grad, "__c1a")
  cs.fillMode = fmGradient
  ctx.newUndefined()

proc jsCtx2dSetFillStylePattern(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_setFillStylePattern(patObj) — reads pattern data and stores in Canvas2DState
  let cs = getCtx2DState(ctx, this)
  if cs == nil: return ctx.newUndefined()
  let pat = args[0]
  let idProp = ctx.getProp(pat, "__patId")
  var patId: int32 = -1
  patId = ctx.toInt32(idProp)
  ctx.freeValue(idProp)
  if patId >= 0 and patId < int32(patternStore.len):
    cs.patternWidth = patternStore[patId].width
    cs.patternHeight = patternStore[patId].height
    cs.patternPixels = patternStore[patId].pixels
    cs.fillMode = fmPattern
  ctx.newUndefined()

proc jsResizeCanvas2D(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_resizeCanvas2D(ctxId, w, h)
  ## Resizes the native pixel buffer for a canvas2d context.
  if args.len < 3: return ctx.newUndefined()
  var id, w, h: int32
  id = ctx.toInt32(args[0])
  w = ctx.toInt32( args[1])
  h = ctx.toInt32( args[2])
  if id >= 0 and id < int32(canvas2dStates.len) and w > 0 and h > 0:
    resizeCanvas2D(canvas2dStates[id], int(w), int(h))
  ctx.newUndefined()

proc jsSetCanvasVisible(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_setCanvasVisible(ctxId, visible)
  ## Mark a canvas as a display target (rendered to screen each frame).
  if args.len < 2: return ctx.newUndefined()
  var id: int32
  id = ctx.toInt32(args[0])
  if id >= 0 and id < int32(canvas2dStates.len):
    var bval: int32
    bval = ctx.toInt32(args[1])
    canvas2dStates[id].isDisplay = bval != 0
  ctx.newUndefined()

# ── __rw_createCanvas2D(canvasElement) — called from JS getContext('2d') ─
proc jsCreateCanvas2D(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let canvasEl = args[0]
  # Read canvas.width, canvas.height
  let wProp = ctx.getProp(canvasEl, "width")
  let hProp = ctx.getProp(canvasEl, "height")
  var cw, ch: int32
  cw = ctx.toInt32(wProp)
  ch = ctx.toInt32(hProp)
  ctx.freeValue(wProp)
  ctx.freeValue(hProp)
  if cw <= 0: cw = 300
  if ch <= 0: ch = 150
  # Create a new Canvas2DState
  let id = int32(canvas2dStates.len)
  canvas2dStates.add(initCanvas2DState(int(cw), int(ch)))
  canvas2dStates[id].canvasJsVal = ctx.dupValue(canvasEl)
  # If this element was appended to document.body before getContext was called,
  # the JS setter set _isDisplayCanvas=true. Check and mark the state.
  let dispProp = ctx.getProp(canvasEl, "_isDisplayCanvas")
  if not ctx.isNull(dispProp) and not ctx.isUndefined(dispProp):
    var bval: int32
    bval = ctx.toInt32(dispProp)
    if bval != 0:
      canvas2dStates[id].isDisplay = true
  ctx.freeValue(dispProp)
  # Store __ctxId on the canvas element so texImage2D can find the pixel data
  ctx.setPropSteal(canvasEl, "__ctxId", ctx.newInt(id))
  # Build the context object with all methods
  let ctxObj = ctx.newObject()
  ctx.setPropSteal(ctxObj, "__ctxId", ctx.newInt(id))

  template c2dFn(name: string; fn: ScriptNativeProc; arity: int) =
    ctx.bindMethod(ctxObj, name, fn, arity)

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

proc bindCanvas2D*(ctx: ptr ScriptCtx) =
  ## Bind the __rw_createCanvas2D global function.
  ctx.bindGlobal("__rw_createCanvas2D", jsCreateCanvas2D, 1)
  ctx.bindGlobal("__rw_resizeCanvas2D", jsResizeCanvas2D, 3)
  ctx.bindGlobal("__rw_setCanvasVisible", jsSetCanvasVisible, 2)
  # Free and reset canvas2d states for new page
  for cs in canvas2dStates:
    ctx.freeValue(cs.canvasJsVal)
  canvas2dStates = @[]
  patternStore = @[]


