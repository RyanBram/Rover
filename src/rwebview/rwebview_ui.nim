# =============================================================================
# rwebview_ui.nim
# Native UI pipeline for rwebview
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
#   Bridges Lexbor HTML DOM parsing directly to flex (layout),
#   microui (widgets), and NanoVG (rendering).
#
#   HIGH-LEVEL FLOW:
#   rwebview_html.nim (Lexbor parse + CSS extraction)
#       -> rwebview_ui.nim (this file)
#           -> flex   (CSS flexbox layout computation)
#           -> microui (widget state, draw commands, input handling)
#           -> NanoVG  (vector rendering: backgrounds, borders, text)
#
#   DESIGN INTENT:
#   - Bypasses SDL_webui: calls flex/microui/nanovg C APIs directly.
#   - Section 5 of SDL_webui/AI-README.md defines the CSS→API mapping
#     used as reference for property → backend dispatch.
#
#   BACKEND OWNERSHIP:
#   flex    → LAYOUT : position, size, direction, wrap, grow/shrink,
#                      margin, padding, order
#   microui → WIDGET : draw commands, interaction (hover/focus/click),
#                      scroll, clipping
#   NanoVG  → RENDER : backgrounds, borders, rounded rects, text, images
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rwebview_html            # Lexbor DOM mapping
#
# Used by:
#   - rwebview.nim             # included after rwebview_storage.nim
#
# =============================================================================

import tables, strutils, math

# =============================================================================
# NanoVG FFI (GL3 backend)
# =============================================================================

type NVGcontext = object  # opaque

const
  NVG_ANTIALIAS*       = 1 shl 0
  NVG_STENCIL_STROKES* = 1 shl 1

  NVG_ALIGN_LEFT*     = 1 shl 0
  NVG_ALIGN_CENTER*   = 1 shl 1
  NVG_ALIGN_RIGHT*    = 1 shl 2
  NVG_ALIGN_TOP*      = 1 shl 3
  NVG_ALIGN_MIDDLE*   = 1 shl 4
  NVG_ALIGN_BOTTOM*   = 1 shl 5
  NVG_ALIGN_BASELINE* = 1 shl 6

  NVG_CCW* = 1
  NVG_CW*  = 2

type NVGcolor {.importc: "NVGcolor", header: "nanovg.h".} = object
  r*, g*, b*, a*: cfloat

# -- GL3 backend init/destroy --
type RwGLGetProcAddr = proc(name: cstring): pointer {.cdecl.}
proc rw_nvg_gl3_init(getProcAddr: RwGLGetProcAddr): cint
    {.importc: "rw_nvg_gl3_init".}
proc nvgCreateGL3(flags: cint): ptr NVGcontext
    {.importc: "nvgCreateGL3".}
proc nvgDeleteGL3(ctx: ptr NVGcontext)
    {.importc: "nvgDeleteGL3".}

# -- Frame --
proc nvgBeginFrame(ctx: ptr NVGcontext; w, h, dpr: cfloat)
    {.importc: "nvgBeginFrame".}
proc nvgEndFrame(ctx: ptr NVGcontext)
    {.importc: "nvgEndFrame".}
proc nvgCancelFrame(ctx: ptr NVGcontext)
    {.importc: "nvgCancelFrame".}

# -- State --
proc nvgSave(ctx: ptr NVGcontext) {.importc: "nvgSave".}
proc nvgRestore(ctx: ptr NVGcontext) {.importc: "nvgRestore".}
proc nvgReset(ctx: ptr NVGcontext) {.importc: "nvgReset".}

# -- Color --
proc nvgRGBA(r, g, b, a: cuchar): NVGcolor {.importc: "nvgRGBA".}
proc nvgRGBAf(r, g, b, a: cfloat): NVGcolor {.importc: "nvgRGBAf".}

# -- Render style --
proc nvgFillColor(ctx: ptr NVGcontext; color: NVGcolor)
    {.importc: "nvgFillColor".}
proc nvgStrokeColor(ctx: ptr NVGcontext; color: NVGcolor)
    {.importc: "nvgStrokeColor".}
proc nvgStrokeWidth(ctx: ptr NVGcontext; size: cfloat)
    {.importc: "nvgStrokeWidth".}
proc nvgGlobalAlpha(ctx: ptr NVGcontext; alpha: cfloat)
    {.importc: "nvgGlobalAlpha".}

# -- Paths --
proc nvgBeginPath(ctx: ptr NVGcontext) {.importc: "nvgBeginPath".}
proc nvgRect(ctx: ptr NVGcontext; x, y, w, h: cfloat) {.importc: "nvgRect".}
proc nvgRoundedRect(ctx: ptr NVGcontext; x, y, w, h, r: cfloat)
    {.importc: "nvgRoundedRect".}
proc nvgFill(ctx: ptr NVGcontext) {.importc: "nvgFill".}
proc nvgStroke(ctx: ptr NVGcontext) {.importc: "nvgStroke".}

# -- Scissor --
proc nvgScissor(ctx: ptr NVGcontext; x, y, w, h: cfloat)
    {.importc: "nvgScissor".}
proc nvgIntersectScissor(ctx: ptr NVGcontext; x, y, w, h: cfloat)
    {.importc: "nvgIntersectScissor".}
proc nvgResetScissor(ctx: ptr NVGcontext)
    {.importc: "nvgResetScissor".}

# -- Font / Text --
proc nvgCreateFont(ctx: ptr NVGcontext; name: cstring; filename: cstring): cint
    {.importc: "nvgCreateFont".}
proc nvgFindFont(ctx: ptr NVGcontext; name: cstring): cint
    {.importc: "nvgFindFont".}
proc nvgFontSize(ctx: ptr NVGcontext; size: cfloat) {.importc: "nvgFontSize".}
proc nvgFontFace(ctx: ptr NVGcontext; font: cstring) {.importc: "nvgFontFace".}
proc nvgFontFaceId(ctx: ptr NVGcontext; id: cint) {.importc: "nvgFontFaceId".}
proc nvgTextAlign(ctx: ptr NVGcontext; align: cint) {.importc: "nvgTextAlign".}
proc nvgFontBlur(ctx: ptr NVGcontext; blur: cfloat) {.importc: "nvgFontBlur".}
proc nvgTextLetterSpacing(ctx: ptr NVGcontext; spacing: cfloat)
    {.importc: "nvgTextLetterSpacing".}
proc nvgTextLineHeight(ctx: ptr NVGcontext; lineHeight: cfloat)
    {.importc: "nvgTextLineHeight".}
proc nvgText(ctx: ptr NVGcontext; x, y: cfloat; str: cstring;
             strEnd: cstring): cfloat {.importc: "nvgText".}
proc nvgTextBox(ctx: ptr NVGcontext; x, y, breakRowWidth: cfloat;
                str: cstring; strEnd: cstring) {.importc: "nvgTextBox".}
proc nvgTextBounds(ctx: ptr NVGcontext; x, y: cfloat; str: cstring;
                   strEnd: cstring; bounds: ptr cfloat): cfloat
    {.importc: "nvgTextBounds".}
proc nvgTextMetrics(ctx: ptr NVGcontext; ascender: ptr cfloat;
                    descender: ptr cfloat; lineh: ptr cfloat)
    {.importc: "nvgTextMetrics".}

# =============================================================================
# flex FFI (CSS Flexbox layout engine)
# =============================================================================

type FlexItem = object  # opaque

type
  FlexAlign {.size: sizeof(cint).} = enum
    faAuto = 0, faStretch, faCenter, faStart, faEnd,
    faSpaceBetween, faSpaceAround, faSpaceEvenly

  FlexPosition {.size: sizeof(cint).} = enum
    fpRelative = 0, fpAbsolute

  FlexDirection {.size: sizeof(cint).} = enum
    fdRow = 0, fdRowReverse, fdColumn, fdColumnReverse

  FlexWrap {.size: sizeof(cint).} = enum
    fwNoWrap = 0, fwWrap, fwWrapReverse

proc flex_item_new(): ptr FlexItem {.importc: "flex_item_new".}
proc flex_item_free(item: ptr FlexItem) {.importc: "flex_item_free".}
proc flex_item_add(item, child: ptr FlexItem) {.importc: "flex_item_add".}
proc flex_item_count(item: ptr FlexItem): cuint {.importc: "flex_item_count".}
proc flex_item_child(item: ptr FlexItem; idx: cuint): ptr FlexItem
    {.importc: "flex_item_child".}
proc flex_layout(item: ptr FlexItem) {.importc: "flex_layout".}

proc flex_item_get_frame_x(item: ptr FlexItem): cfloat
    {.importc: "flex_item_get_frame_x".}
proc flex_item_get_frame_y(item: ptr FlexItem): cfloat
    {.importc: "flex_item_get_frame_y".}
proc flex_item_get_frame_width(item: ptr FlexItem): cfloat
    {.importc: "flex_item_get_frame_width".}
proc flex_item_get_frame_height(item: ptr FlexItem): cfloat
    {.importc: "flex_item_get_frame_height".}

# -- Property setters --
proc flex_item_set_width(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_width".}
proc flex_item_set_height(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_height".}
proc flex_item_set_grow(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_grow".}
proc flex_item_set_shrink(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_shrink".}
proc flex_item_set_basis(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_basis".}
proc flex_item_set_order(item: ptr FlexItem; v: cint)
    {.importc: "flex_item_set_order".}
proc flex_item_set_direction(item: ptr FlexItem; v: FlexDirection)
    {.importc: "flex_item_set_direction".}
proc flex_item_set_wrap(item: ptr FlexItem; v: FlexWrap)
    {.importc: "flex_item_set_wrap".}
proc flex_item_set_justify_content(item: ptr FlexItem; v: FlexAlign)
    {.importc: "flex_item_set_justify_content".}
proc flex_item_set_align_content(item: ptr FlexItem; v: FlexAlign)
    {.importc: "flex_item_set_align_content".}
proc flex_item_set_align_items(item: ptr FlexItem; v: FlexAlign)
    {.importc: "flex_item_set_align_items".}
proc flex_item_set_align_self(item: ptr FlexItem; v: FlexAlign)
    {.importc: "flex_item_set_align_self".}
proc flex_item_set_position(item: ptr FlexItem; v: FlexPosition)
    {.importc: "flex_item_set_position".}
proc flex_item_set_padding_left(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_padding_left".}
proc flex_item_set_padding_right(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_padding_right".}
proc flex_item_set_padding_top(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_padding_top".}
proc flex_item_set_padding_bottom(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_padding_bottom".}
proc flex_item_set_margin_left(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_margin_left".}
proc flex_item_set_margin_right(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_margin_right".}
proc flex_item_set_margin_top(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_margin_top".}
proc flex_item_set_margin_bottom(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_margin_bottom".}
proc flex_item_set_left(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_left".}
proc flex_item_set_right(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_right".}
proc flex_item_set_top(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_top".}
proc flex_item_set_bottom(item: ptr FlexItem; v: cfloat)
    {.importc: "flex_item_set_bottom".}
proc flex_item_set_managed_ptr(item: ptr FlexItem; p: pointer)
    {.importc: "flex_item_set_managed_ptr".}
proc flex_item_get_managed_ptr(item: ptr FlexItem): pointer
    {.importc: "flex_item_get_managed_ptr".}

# =============================================================================
# microui FFI (immediate-mode widget toolkit)
# =============================================================================

type MuContext {.importc: "mu_Context", header: "microui.h".} = object
type MuRect   {.importc: "mu_Rect",    header: "microui.h".} = object
  x*, y*, w*, h*: cint
type MuColor  {.importc: "mu_Color",   header: "microui.h".} = object
  r*, g*, b*, a*: cuchar
type MuVec2   {.importc: "mu_Vec2",    header: "microui.h".} = object
  x*, y*: cint
type MuCommand {.importc: "mu_Command", header: "microui.h".} = object
type MuFont   = pointer

# Typed command structs for pointer casting during command iteration.
type MuClipCommand {.packed.} = object
  typ*, size*: cint
  rect*: MuRect
type MuRectCommand {.packed.} = object
  typ*, size*: cint
  rect*: MuRect
  color*: MuColor
type MuTextCommand {.packed.} = object
  typ*, size*: cint
  font*: MuFont
  pos*: MuVec2
  color*: MuColor
  str*: array[1, char]
type MuIconCommand {.packed.} = object
  typ*, size*: cint
  rect*: MuRect
  id*: cint
  color*: MuColor

const
  MU_OPT_ALIGNCENTER* = 1 shl 0
  MU_OPT_ALIGNRIGHT*  = 1 shl 1
  MU_OPT_NOINTERACT*  = 1 shl 2
  MU_OPT_NOFRAME*     = 1 shl 3
  MU_OPT_NORESIZE*    = 1 shl 4
  MU_OPT_NOSCROLL*    = 1 shl 5
  MU_OPT_NOCLOSE*     = 1 shl 6
  MU_OPT_NOTITLE*     = 1 shl 7
  MU_OPT_HOLDFOCUS*   = 1 shl 8
  MU_OPT_EXPANDED*    = 1 shl 12

  MU_RES_ACTIVE*  = 1 shl 0
  MU_RES_SUBMIT*  = 1 shl 1
  MU_RES_CHANGE*  = 1 shl 2

  MU_COMMAND_JUMP* = 1
  MU_COMMAND_CLIP* = 2
  MU_COMMAND_RECT* = 3
  MU_COMMAND_TEXT* = 4
  MU_COMMAND_ICON* = 5
  MU_COMMAND_FONT* = 6

  MU_COLOR_TEXT*   = 0
  MU_COLOR_BORDER* = 1

  MU_MOUSE_LEFT*   = 1 shl 0
  MU_MOUSE_RIGHT*  = 1 shl 1
  MU_MOUSE_MIDDLE* = 1 shl 2

  MU_KEY_SHIFT*     = 1 shl 0
  MU_KEY_CTRL*      = 1 shl 1
  MU_KEY_ALT*       = 1 shl 2
  MU_KEY_BACKSPACE* = 1 shl 3
  MU_KEY_RETURN*    = 1 shl 4
  MU_KEY_LEFT*      = 1 shl 5
  MU_KEY_RIGHT*     = 1 shl 6
  MU_KEY_HOME*      = 1 shl 7
  MU_KEY_END*       = 1 shl 8
  MU_KEY_DELETE*    = 1 shl 9

proc mu_vec2(x, y: cint): MuVec2 {.importc: "mu_vec2".}
proc mu_rect(x, y, w, h: cint): MuRect {.importc: "mu_rect".}
proc mu_color(r, g, b, a: cint): MuColor {.importc: "mu_color".}

proc mu_init(ctx: ptr MuContext) {.importc: "mu_init".}
proc mu_begin(ctx: ptr MuContext) {.importc: "mu_begin".}
proc mu_end(ctx: ptr MuContext) {.importc: "mu_end".}

proc mu_input_mousemove(ctx: ptr MuContext; x, y: cint)
    {.importc: "mu_input_mousemove".}
proc mu_input_mousedown(ctx: ptr MuContext; x, y, btn: cint)
    {.importc: "mu_input_mousedown".}
proc mu_input_mouseup(ctx: ptr MuContext; x, y, btn: cint)
    {.importc: "mu_input_mouseup".}
proc mu_input_scroll(ctx: ptr MuContext; x, y: cint)
    {.importc: "mu_input_scroll".}
proc mu_input_keydown(ctx: ptr MuContext; key: cint)
    {.importc: "mu_input_keydown".}
proc mu_input_keyup(ctx: ptr MuContext; key: cint)
    {.importc: "mu_input_keyup".}
proc mu_input_text(ctx: ptr MuContext; text: cstring)
    {.importc: "mu_input_text".}

proc mu_next_command(ctx: ptr MuContext; cmd: ptr ptr MuCommand): cint
    {.importc: "mu_next_command".}
proc mu_set_clip(ctx: ptr MuContext; rect: MuRect) {.importc: "mu_set_clip".}
proc mu_draw_rect(ctx: ptr MuContext; rect: MuRect; color: MuColor)
    {.importc: "mu_draw_rect".}
proc mu_draw_text(ctx: ptr MuContext; font: MuFont; str: cstring; len: cint;
                  pos: MuVec2; color: MuColor) {.importc: "mu_draw_text".}
proc mu_draw_control_text(ctx: ptr MuContext; str: cstring; rect: MuRect;
                          colorid: cint; opt: cint)
    {.importc: "mu_draw_control_text".}

proc mu_layout_row(ctx: ptr MuContext; items: cint; widths: ptr cint;
                   height: cint) {.importc: "mu_layout_row".}
proc mu_layout_set_next(ctx: ptr MuContext; r: MuRect; relative: cint)
    {.importc: "mu_layout_set_next".}
proc mu_layout_next(ctx: ptr MuContext): MuRect {.importc: "mu_layout_next".}

proc mu_label(ctx: ptr MuContext; text: cstring) {.importc: "mu_label".}
proc mu_button_ex(ctx: ptr MuContext; label: cstring; icon: cint;
                  opt: cint): cint {.importc: "mu_button_ex".}
proc mu_checkbox(ctx: ptr MuContext; label: cstring; state: ptr cint): cint
    {.importc: "mu_checkbox".}
proc mu_textbox_ex(ctx: ptr MuContext; buf: cstring; bufsz: cint;
                   opt: cint): cint {.importc: "mu_textbox_ex".}
proc mu_slider_ex(ctx: ptr MuContext; value: ptr cfloat;
                  low, high, step: cfloat; fmt: cstring;
                  opt: cint): cint {.importc: "mu_slider_ex".}
proc mu_header_ex(ctx: ptr MuContext; label: cstring; opt: cint): cint
    {.importc: "mu_header_ex".}
proc mu_begin_window_ex(ctx: ptr MuContext; title: cstring; rect: MuRect;
                        opt: cint): cint {.importc: "mu_begin_window_ex".}
proc mu_end_window(ctx: ptr MuContext) {.importc: "mu_end_window".}
proc mu_begin_panel_ex(ctx: ptr MuContext; name: cstring; opt: cint)
    {.importc: "mu_begin_panel_ex".}
proc mu_end_panel(ctx: ptr MuContext) {.importc: "mu_end_panel".}
proc mu_push_font(ctx: ptr MuContext; fontId: cint)
    {.importc: "mu_push_font".}

# C helpers for setting mu_Context callbacks (avoids replicating full struct in Nim)
proc rw_mu_set_text_width(ctx: ptr MuContext;
    fn: proc(font: MuFont; str: cstring; len: cint): cint {.cdecl.})
    {.importc: "rw_mu_set_text_width".}
proc rw_mu_set_text_height(ctx: ptr MuContext;
    fn: proc(font: MuFont): cint {.cdecl.})
    {.importc: "rw_mu_set_text_height".}

# =============================================================================
# UI Data Model
# =============================================================================

type
  RwUiNodeKind* = enum
    rukRoot, rukDiv, rukSpan, rukText, rukLabel,
    rukButton, rukInputText, rukCheckbox, rukRange,
    rukHr, rukCanvas, rukSelect, rukH1, rukH2, rukH3,
    rukH4, rukH5, rukH6, rukP, rukImg, rukA, rukUnknown

  RwUiDisplay* = enum
    rudFlex, rudNone

  RwUiTextAlign* = enum
    rutaLeft, rutaCenter, rutaRight

  RwUiOverflow* = enum
    ruoVisible, ruoHidden, ruoAuto, ruoScroll

  RwUiStyle* = object
    # Box model
    widthPx*:   cfloat
    heightPx*:  cfloat
    marginTopPx*, marginRightPx*, marginBottomPx*, marginLeftPx*: cfloat
    paddingTopPx*, paddingRightPx*, paddingBottomPx*, paddingLeftPx*: cfloat
    # Flexbox
    flexGrow*:   cfloat
    flexShrink*: cfloat
    flexBasisPx*: cfloat
    flexDirection*: FlexDirection
    flexWrap*: FlexWrap
    justifyContent*: FlexAlign
    alignItems*: FlexAlign
    alignSelf*: FlexAlign
    alignContent*: FlexAlign
    order*: cint
    # Position
    position*: FlexPosition
    topPx*, rightPx*, bottomPx*, leftPx*: cfloat
    # Visual
    textColor*:   tuple[r, g, b, a: uint8]
    bgColor*:     tuple[r, g, b, a: uint8]
    borderColor*: tuple[r, g, b, a: uint8]
    borderWidthPx*: cfloat
    borderRadiusPx*: cfloat
    opacity*: cfloat
    # Typography
    fontSize*:       cfloat
    fontWeight*:     cint  # 400=normal, 700=bold
    fontStyleItalic*: bool
    textDecoration*: cint  # 0=none, 1=underline, 2=line-through
    letterSpacing*:  cfloat
    lineHeight*:     cfloat
    fontFamily*:     string
    # Behavior
    display*:   RwUiDisplay
    textAlign*: RwUiTextAlign
    overflow*:  RwUiOverflow

  RwUiNode* = ref object
    id*:       string
    kind*:     RwUiNodeKind
    text*:     string
    classes*:  seq[string]
    style*:    RwUiStyle
    children*: seq[RwUiNode]
    # Internal layout link
    flexItem*: ptr FlexItem

  RwUiTree* = ref object
    root*: RwUiNode

  RwUiPersistentState* = ref object
    inputText*:  Table[string, string]
    checkbox*:   Table[string, cint]
    rangeVal*:   Table[string, cfloat]

  RwUiResult* = object
    clickedIds*: seq[string]
    changedIds*: seq[string]
    submitIds*:  seq[string]

# =============================================================================
# Global UI State
# =============================================================================

var
  gNvg*:        ptr NVGcontext = nil
  gMuCtx*:      MuContext
  gUiTree*:     RwUiTree = nil
  gUiState*:    RwUiPersistentState = nil
  gUiFlexRoot*: ptr FlexItem = nil
  gUiInited*:   bool = false
  gUiDefaultFontId*: cint = -1

# =============================================================================
# Style Defaults
# =============================================================================

proc defaultStyle(): RwUiStyle =
  result.widthPx  = NaN
  result.heightPx = NaN
  result.flexGrow   = 0.0
  result.flexShrink = 1.0
  result.flexBasisPx = NaN
  result.flexDirection = fdColumn
  result.flexWrap = fwNoWrap
  result.justifyContent = faStart
  result.alignItems = faStretch
  result.alignSelf = faAuto
  result.alignContent = faStretch
  result.order = 0
  result.position = fpRelative
  result.topPx    = NaN
  result.rightPx  = NaN
  result.bottomPx = NaN
  result.leftPx   = NaN
  result.textColor   = (220'u8, 220'u8, 220'u8, 255'u8)
  result.bgColor     = (0'u8, 0'u8, 0'u8, 0'u8)
  result.borderColor = (80'u8, 80'u8, 80'u8, 255'u8)
  result.borderWidthPx = 0.0
  result.borderRadiusPx = 0.0
  result.opacity = 1.0
  result.fontSize = 14.0
  result.fontWeight = 400
  result.fontStyleItalic = false
  result.textDecoration = 0
  result.letterSpacing = 0.0
  result.lineHeight = 1.2
  result.fontFamily = ""
  result.display   = rudFlex
  result.textAlign = rutaLeft
  result.overflow  = ruoVisible

# =============================================================================
# microui text width/height callbacks (required by mu_init)
# =============================================================================

proc muTextWidth(font: MuFont; str: cstring; len: cint): cint {.cdecl.} =
  if gNvg == nil: return 0
  nvgFontSize(gNvg, 14.0)
  if gUiDefaultFontId >= 0:
    nvgFontFaceId(gNvg, gUiDefaultFontId)
  var bounds: array[4, cfloat]
  let txt = if len > 0: $str  # use full string if len matches
            else: ""
  if txt.len == 0: return 0
  discard nvgTextBounds(gNvg, 0, 0, cstring(txt), nil, addr bounds[0])
  result = cint(bounds[2] - bounds[0])

proc muTextHeight(font: MuFont): cint {.cdecl.} =
  if gNvg == nil: return 16
  nvgFontSize(gNvg, 14.0)
  if gUiDefaultFontId >= 0:
    nvgFontFaceId(gNvg, gUiDefaultFontId)
  var asc, desc, lineh: cfloat
  nvgTextMetrics(gNvg, addr asc, addr desc, addr lineh)
  result = cint(lineh)

# =============================================================================
# Init / Shutdown
# =============================================================================

proc rwUiInit*() =
  ## Initialize the native UI subsystem.
  ## Must be called after the GL context is current.
  if gUiInited: return

  # Load GL3 function pointers for NanoVG backend
  if rw_nvg_gl3_init(cast[RwGLGetProcAddr](SDL_GL_GetProcAddress)) == 0:
    stderr.writeLine("[rwebview_ui] ERROR: GL3 function loading failed")
    return

  # Create NanoVG context
  gNvg = nvgCreateGL3(cint(NVG_ANTIALIAS or NVG_STENCIL_STROKES))
  if gNvg == nil:
    stderr.writeLine("[rwebview_ui] ERROR: nvgCreateGL3 failed")
    return

  # Initialize microui
  mu_init(addr gMuCtx)
  rw_mu_set_text_width(addr gMuCtx, muTextWidth)
  rw_mu_set_text_height(addr gMuCtx, muTextHeight)

  # Initialize persistent state
  gUiState = RwUiPersistentState(
    inputText: initTable[string, string](),
    checkbox:  initTable[string, cint](),
    rangeVal:  initTable[string, cfloat]()
  )

  gUiInited = true
  stderr.writeLine("[rwebview_ui] Native UI subsystem initialized (NanoVG + flex + microui)")

proc rwUiShutdown*() =
  ## Clean up the native UI subsystem.
  if gUiFlexRoot != nil:
    flex_item_free(gUiFlexRoot)
    gUiFlexRoot = nil
  if gNvg != nil:
    nvgDeleteGL3(gNvg)
    gNvg = nil
  gUiInited = false

# =============================================================================
# HTML Tag → RwUiNodeKind mapping
# =============================================================================

proc tagToNodeKind(tag: string): RwUiNodeKind =
  case tag.toLowerAscii()
  of "div":      rukDiv
  of "span":     rukSpan
  of "p":        rukP
  of "h1":       rukH1
  of "h2":       rukH2
  of "h3":       rukH3
  of "h4":       rukH4
  of "h5":       rukH5
  of "h6":       rukH6
  of "label":    rukLabel
  of "button":   rukButton
  of "input":    rukInputText
  of "select":   rukSelect
  of "textarea": rukInputText
  of "canvas":   rukCanvas
  of "hr":       rukHr
  of "img":      rukImg
  of "a":        rukA
  of "form":     rukDiv   # treat form as div container
  else:          rukUnknown

# =============================================================================
# =============================================================================
# Inline CSS style parser (subset)
# =============================================================================

proc parseCssAlign(val: string): FlexAlign =
  case val.strip().toLowerAscii()
  of "flex-start", "start": faStart
  of "flex-end", "end":     faEnd
  of "center":              faCenter
  of "stretch":             faStretch
  of "space-between":       faSpaceBetween
  of "space-around":        faSpaceAround
  of "space-evenly":        faSpaceEvenly
  else:                     faStart

proc parseCssColor(s: string): tuple[r, g, b, a: uint8] =
  ## Parse a CSS color value: #rgb, #rrggbb, #rrggbbaa, rgb(r,g,b), rgba(r,g,b,a).
  result = (0'u8, 0'u8, 0'u8, 255'u8)
  let t = s.strip()
  if t.len == 0: return

  if t.startsWith("#"):
    let hex = t[1..^1]
    if hex.len == 3:
      result.r = uint8(parseHexInt($hex[0] & $hex[0]) and 0xFF)
      result.g = uint8(parseHexInt($hex[1] & $hex[1]) and 0xFF)
      result.b = uint8(parseHexInt($hex[2] & $hex[2]) and 0xFF)
    elif hex.len >= 6:
      result.r = uint8(parseHexInt(hex[0..1]) and 0xFF)
      result.g = uint8(parseHexInt(hex[2..3]) and 0xFF)
      result.b = uint8(parseHexInt(hex[4..5]) and 0xFF)
      if hex.len >= 8:
        result.a = uint8(parseHexInt(hex[6..7]) and 0xFF)
  elif t.startsWith("rgb"):
    let inner = t.split('(')
    if inner.len >= 2:
      let parts = inner[1].replace(")", "").split(',')
      if parts.len >= 3:
        result.r = uint8(parseInt(parts[0].strip()) and 0xFF)
        result.g = uint8(parseInt(parts[1].strip()) and 0xFF)
        result.b = uint8(parseInt(parts[2].strip()) and 0xFF)
        if parts.len >= 4:
          let af = parseFloat(parts[3].strip())
          result.a = uint8(int(af * 255.0) and 0xFF)

proc parsePxValue(s: string): cfloat =
  ## Parse a CSS px/number value, e.g. "10px", "10", "auto" → NaN.
  let t = s.strip().toLowerAscii()
  if t == "auto" or t == "": return NaN
  let numStr = t.replace("px", "").replace("pt", "").strip()
  try:
    result = cfloat(parseFloat(numStr))
  except ValueError:
    result = NaN

proc parseInlineStyle(node: RwUiNode; styleStr: string) =
  ## Parse inline CSS style string and apply to node.style.
  let decls = styleStr.split(';')
  for decl in decls:
    let colon = decl.find(':')
    if colon < 0: continue
    let prop = decl[0 ..< colon].strip().toLowerAscii()
    let val = decl[colon + 1 .. ^1].strip()
    if prop.len == 0 or val.len == 0: continue

    case prop
    # Box model
    of "width":         node.style.widthPx = parsePxValue(val)
    of "height":        node.style.heightPx = parsePxValue(val)
    of "margin":
      let v = parsePxValue(val)
      node.style.marginTopPx = v; node.style.marginRightPx = v
      node.style.marginBottomPx = v; node.style.marginLeftPx = v
    of "margin-top":    node.style.marginTopPx = parsePxValue(val)
    of "margin-right":  node.style.marginRightPx = parsePxValue(val)
    of "margin-bottom": node.style.marginBottomPx = parsePxValue(val)
    of "margin-left":   node.style.marginLeftPx = parsePxValue(val)
    of "padding":
      let v = parsePxValue(val)
      node.style.paddingTopPx = v; node.style.paddingRightPx = v
      node.style.paddingBottomPx = v; node.style.paddingLeftPx = v
    of "padding-top":    node.style.paddingTopPx = parsePxValue(val)
    of "padding-right":  node.style.paddingRightPx = parsePxValue(val)
    of "padding-bottom": node.style.paddingBottomPx = parsePxValue(val)
    of "padding-left":   node.style.paddingLeftPx = parsePxValue(val)
    # Flexbox → flex engine
    of "flex-direction":
      case val.toLowerAscii()
      of "row":            node.style.flexDirection = fdRow
      of "row-reverse":    node.style.flexDirection = fdRowReverse
      of "column":         node.style.flexDirection = fdColumn
      of "column-reverse": node.style.flexDirection = fdColumnReverse
      else: discard
    of "flex-wrap":
      case val.toLowerAscii()
      of "nowrap":       node.style.flexWrap = fwNoWrap
      of "wrap":         node.style.flexWrap = fwWrap
      of "wrap-reverse": node.style.flexWrap = fwWrapReverse
      else: discard
    of "flex-grow":
      try: node.style.flexGrow = cfloat(parseFloat(val))
      except ValueError: discard
    of "flex-shrink":
      try: node.style.flexShrink = cfloat(parseFloat(val))
      except ValueError: discard
    of "flex-basis": node.style.flexBasisPx = parsePxValue(val)
    of "justify-content": node.style.justifyContent = parseCssAlign(val)
    of "align-items":     node.style.alignItems = parseCssAlign(val)
    of "align-self":      node.style.alignSelf = parseCssAlign(val)
    of "align-content":   node.style.alignContent = parseCssAlign(val)
    of "order":
      try: node.style.order = cint(parseInt(val))
      except ValueError: discard
    # Position
    of "position":
      case val.toLowerAscii()
      of "absolute": node.style.position = fpAbsolute
      else:          node.style.position = fpRelative
    of "top":    node.style.topPx = parsePxValue(val)
    of "right":  node.style.rightPx = parsePxValue(val)
    of "bottom": node.style.bottomPx = parsePxValue(val)
    of "left":   node.style.leftPx = parsePxValue(val)
    # Visual
    of "background-color", "background": node.style.bgColor = parseCssColor(val)
    of "color":         node.style.textColor = parseCssColor(val)
    of "border-color":  node.style.borderColor = parseCssColor(val)
    of "border-width":  node.style.borderWidthPx = parsePxValue(val)
    of "border-radius": node.style.borderRadiusPx = parsePxValue(val)
    of "opacity":
      try: node.style.opacity = cfloat(parseFloat(val))
      except ValueError: discard
    # Typography → nanovg
    of "font-size":       node.style.fontSize = parsePxValue(val)
    of "font-weight":
      case val.toLowerAscii()
      of "bold", "700":   node.style.fontWeight = 700
      of "normal", "400": node.style.fontWeight = 400
      else:
        try: node.style.fontWeight = cint(parseInt(val))
        except ValueError: discard
    of "font-style":
      node.style.fontStyleItalic = (val.toLowerAscii() == "italic")
    of "text-decoration":
      case val.toLowerAscii()
      of "underline":    node.style.textDecoration = 1
      of "line-through": node.style.textDecoration = 2
      else:              node.style.textDecoration = 0
    of "letter-spacing": node.style.letterSpacing = parsePxValue(val)
    of "line-height":
      try: node.style.lineHeight = cfloat(parseFloat(val))
      except ValueError: discard
    of "font-family": node.style.fontFamily = val.replace("'", "").replace("\"", "")
    # Display
    of "display":
      case val.toLowerAscii()
      of "none":  node.style.display = rudNone
      of "flex":  node.style.display = rudFlex
      else:       node.style.display = rudFlex
    of "text-align":
      case val.toLowerAscii()
      of "center": node.style.textAlign = rutaCenter
      of "right":  node.style.textAlign = rutaRight
      else:        node.style.textAlign = rutaLeft
    of "overflow":
      case val.toLowerAscii()
      of "hidden": node.style.overflow = ruoHidden
      of "auto":   node.style.overflow = ruoAuto
      of "scroll": node.style.overflow = ruoScroll
      else:        node.style.overflow = ruoVisible
    else:
      discard  # unhandled CSS property — silently ignore

# =============================================================================
# Lexbor DOM → RwUiTree (recursive walk)
# =============================================================================

proc buildUiNodeFromDom(node: ptr LxbDomNode): RwUiNode =
  ## Recursively convert a Lexbor DOM node to an RwUiNode.
  let tagName = nodeNameLower(node)
  let kind = tagToNodeKind(tagName)

  result = RwUiNode(
    kind: kind,
    style: defaultStyle(),
    children: @[]
  )

  if lxb_dom_node_type_noi(node) == lxbDomNodeTypeElement:
    let el = cast[ptr LxbDomElement](node)
    result.id = elemAttr(el, "id")

    let cls = elemAttr(el, "class")
    if cls.len > 0:
      result.classes = cls.split(' ')

    # Extract text content for leaf text nodes
    if kind in {rukLabel, rukButton, rukP, rukH1, rukH2, rukH3,
                rukH4, rukH5, rukH6, rukA}:
      var tlen: csize_t = 0
      let txt = lxb_dom_node_text_content(el, addr tlen)
      if txt != nil and tlen > 0:
        result.text = newString(int(tlen))
        copyMem(addr result.text[0], txt, int(tlen))

    # Apply kind-specific style defaults per Section 5.2
    case kind
    of rukDiv:
      result.style.flexDirection = fdColumn
      result.style.display = rudFlex
    of rukSpan:
      result.style.flexDirection = fdRow
    of rukH1:
      result.style.fontSize = 32.0
      result.style.fontWeight = 700
    of rukH2:
      result.style.fontSize = 24.0
      result.style.fontWeight = 700
    of rukH3:
      result.style.fontSize = 20.0
      result.style.fontWeight = 700
    of rukH4:
      result.style.fontSize = 16.0
      result.style.fontWeight = 700
    of rukH5:
      result.style.fontSize = 14.0
      result.style.fontWeight = 700
    of rukH6:
      result.style.fontSize = 12.0
      result.style.fontWeight = 700
    of rukP:
      result.style.marginTopPx = 4.0
      result.style.marginBottomPx = 4.0
    of rukButton:
      result.style.paddingLeftPx = 8.0
      result.style.paddingRightPx = 8.0
      result.style.paddingTopPx = 4.0
      result.style.paddingBottomPx = 4.0
    of rukHr:
      result.style.heightPx = 1.0
      result.style.flexGrow = 0.0
      result.style.bgColor = (80'u8, 80'u8, 80'u8, 255'u8)
    of rukInputText:
      result.style.heightPx = 24.0
      result.style.paddingLeftPx = 4.0
    of rukRange:
      result.style.heightPx = 20.0
    else:
      discard

    # Parse inline style attribute
    let styleAttr = elemAttr(el, "style")
    if styleAttr.len > 0:
      parseInlineStyle(result, styleAttr)

  # Recurse children
  var child = lxb_dom_node_first_child_noi(node)
  while child != nil:
    if lxb_dom_node_type_noi(child) == lxbDomNodeTypeElement:
      let childTag = nodeNameLower(child)
      # Skip script/style/head tags — not visible UI
      if childTag != "script" and childTag != "style" and
         childTag != "head" and childTag != "link" and
         childTag != "meta" and childTag != "title":
        let childNode = buildUiNodeFromDom(child)
        result.children.add(childNode)
    child = lxb_dom_node_next_noi(child)

# =============================================================================
# RwUiNode → Flex Item Tree (layout pass)
# =============================================================================

proc applyFlexItem(fi: ptr FlexItem; s: RwUiStyle) =
  ## Apply RwUiStyle layout properties to a flex_item (Section 5.3 mapping).
  # Size
  flex_item_set_width(fi, s.widthPx)
  flex_item_set_height(fi, s.heightPx)
  # Flex
  flex_item_set_grow(fi, s.flexGrow)
  flex_item_set_shrink(fi, s.flexShrink)
  flex_item_set_basis(fi, s.flexBasisPx)
  flex_item_set_direction(fi, s.flexDirection)
  flex_item_set_wrap(fi, s.flexWrap)
  flex_item_set_justify_content(fi, s.justifyContent)
  flex_item_set_align_items(fi, s.alignItems)
  flex_item_set_align_self(fi, s.alignSelf)
  flex_item_set_align_content(fi, s.alignContent)
  flex_item_set_order(fi, s.order)
  # Position
  flex_item_set_position(fi, s.position)
  if not s.topPx.isNaN:    flex_item_set_top(fi, s.topPx)
  if not s.rightPx.isNaN:  flex_item_set_right(fi, s.rightPx)
  if not s.bottomPx.isNaN: flex_item_set_bottom(fi, s.bottomPx)
  if not s.leftPx.isNaN:   flex_item_set_left(fi, s.leftPx)
  # Margin
  if not s.marginTopPx.isNaN:    flex_item_set_margin_top(fi, s.marginTopPx)
  if not s.marginRightPx.isNaN:  flex_item_set_margin_right(fi, s.marginRightPx)
  if not s.marginBottomPx.isNaN: flex_item_set_margin_bottom(fi, s.marginBottomPx)
  if not s.marginLeftPx.isNaN:   flex_item_set_margin_left(fi, s.marginLeftPx)
  # Padding
  if not s.paddingTopPx.isNaN:    flex_item_set_padding_top(fi, s.paddingTopPx)
  if not s.paddingRightPx.isNaN:  flex_item_set_padding_right(fi, s.paddingRightPx)
  if not s.paddingBottomPx.isNaN: flex_item_set_padding_bottom(fi, s.paddingBottomPx)
  if not s.paddingLeftPx.isNaN:   flex_item_set_padding_left(fi, s.paddingLeftPx)

proc buildFlexTree(node: RwUiNode): ptr FlexItem =
  ## Recursively build a flex_item tree from the RwUiNode tree.
  ## Each flex_item stores a pointer back to its RwUiNode via managed_ptr.
  let fi = flex_item_new()
  if fi == nil: return nil

  applyFlexItem(fi, node.style)
  flex_item_set_managed_ptr(fi, cast[pointer](node))
  node.flexItem = fi

  # Skip display:none
  if node.style.display == rudNone:
    flex_item_set_width(fi, 0.0)
    flex_item_set_height(fi, 0.0)
    return fi

  for child in node.children:
    let childFi = buildFlexTree(child)
    if childFi != nil:
      flex_item_add(fi, childFi)

  result = fi

# =============================================================================
# Build UI tree from HTML string
# =============================================================================

proc buildUiTreeFromHtml*(htmlContent: string): RwUiTree =
  ## Parse HTML with Lexbor, walk the DOM, build RwUiTree.
  let parser = lxb_html_parser_create()
  if parser == nil: return nil
  if lxb_html_parser_init(parser) != lxbStatusOk:
    discard lxb_html_parser_destroy(parser)
    return nil

  let doc = lxb_html_parse(parser,
               cast[pointer](cstring(htmlContent)),
               csize_t(htmlContent.len))
  discard lxb_html_parser_destroy(parser)
  if doc == nil: return nil

  let domDoc = rw_lxb_html_doc_to_dom(doc)
  if domDoc == nil:
    discard lxb_html_document_destroy(doc)
    return nil

  let rootEl = lxb_dom_document_element_noi(domDoc)
  if rootEl == nil:
    discard lxb_html_document_destroy(doc)
    return nil

  let rootNode = buildUiNodeFromDom(cast[ptr LxbDomNode](rootEl))
  rootNode.kind = rukRoot
  discard lxb_html_document_destroy(doc)

  result = RwUiTree(root: rootNode)

# =============================================================================
# NanoVG Render Pass — draw backgrounds, borders, text
# =============================================================================

proc nvgColorFrom(c: tuple[r, g, b, a: uint8]): NVGcolor =
  nvgRGBA(cuchar(c.r), cuchar(c.g), cuchar(c.b), cuchar(c.a))

proc renderUiNode(vg: ptr NVGcontext; node: RwUiNode) =
  ## Render a single UI node and its children using NanoVG.
  ## Called after flex_layout() has computed positions.
  if node.style.display == rudNone: return
  if node.flexItem == nil: return

  let fx = flex_item_get_frame_x(node.flexItem)
  let fy = flex_item_get_frame_y(node.flexItem)
  let fw = flex_item_get_frame_width(node.flexItem)
  let fh = flex_item_get_frame_height(node.flexItem)

  nvgSave(vg)

  # Apply opacity
  if node.style.opacity < 1.0:
    nvgGlobalAlpha(vg, node.style.opacity)

  # Draw background
  if node.style.bgColor.a > 0:
    nvgBeginPath(vg)
    if node.style.borderRadiusPx > 0:
      nvgRoundedRect(vg, fx, fy, fw, fh, node.style.borderRadiusPx)
    else:
      nvgRect(vg, fx, fy, fw, fh)
    nvgFillColor(vg, nvgColorFrom(node.style.bgColor))
    nvgFill(vg)

  # Draw border
  if node.style.borderWidthPx > 0 and node.style.borderColor.a > 0:
    nvgBeginPath(vg)
    if node.style.borderRadiusPx > 0:
      nvgRoundedRect(vg, fx, fy, fw, fh, node.style.borderRadiusPx)
    else:
      nvgRect(vg, fx, fy, fw, fh)
    nvgStrokeColor(vg, nvgColorFrom(node.style.borderColor))
    nvgStrokeWidth(vg, node.style.borderWidthPx)
    nvgStroke(vg)

  # Draw text content (for text-bearing nodes)
  if node.text.len > 0 and node.kind in {rukLabel, rukButton, rukP, rukA,
     rukH1, rukH2, rukH3, rukH4, rukH5, rukH6}:
    nvgFontSize(vg, node.style.fontSize)
    if gUiDefaultFontId >= 0:
      nvgFontFaceId(vg, gUiDefaultFontId)
    nvgFillColor(vg, nvgColorFrom(node.style.textColor))
    nvgTextLetterSpacing(vg, node.style.letterSpacing)
    nvgTextLineHeight(vg, node.style.lineHeight)

    let alignFlags = case node.style.textAlign
      of rutaLeft:   NVG_ALIGN_LEFT or NVG_ALIGN_TOP
      of rutaCenter: NVG_ALIGN_CENTER or NVG_ALIGN_TOP
      of rutaRight:  NVG_ALIGN_RIGHT or NVG_ALIGN_TOP
    nvgTextAlign(vg, cint(alignFlags))

    let tx = case node.style.textAlign
      of rutaLeft:   fx + node.style.paddingLeftPx
      of rutaCenter: fx + fw / 2.0
      of rutaRight:  fx + fw - node.style.paddingRightPx
    let ty = fy + node.style.paddingTopPx

    # For short text, use single-line nvgText; for paragraphs, use nvgTextBox
    if node.kind == rukP:
      let maxW = fw - node.style.paddingLeftPx - node.style.paddingRightPx
      if maxW > 0:
        nvgTextBox(vg, fx + node.style.paddingLeftPx, ty, maxW,
                   cstring(node.text), nil)
    else:
      discard nvgText(vg, tx, ty, cstring(node.text), nil)

  # Apply scissor clipping for overflow:hidden
  if node.style.overflow == ruoHidden or node.style.overflow == ruoScroll:
    nvgIntersectScissor(vg, fx, fy, fw, fh)

  # Recurse children
  for child in node.children:
    renderUiNode(vg, child)

  nvgRestore(vg)

# =============================================================================
# microui Widget Pass — interactive elements
# =============================================================================

proc processUiWidgets(muCtx: ptr MuContext; node: RwUiNode;
                      state: RwUiPersistentState;
                      result: var RwUiResult) =
  ## Walk the UI tree and emit microui widget calls for interactive elements.
  if node.style.display == rudNone: return
  if node.flexItem == nil: return

  let fx = flex_item_get_frame_x(node.flexItem)
  let fy = flex_item_get_frame_y(node.flexItem)
  let fw = flex_item_get_frame_width(node.flexItem)
  let fh = flex_item_get_frame_height(node.flexItem)

  let muR = mu_rect(cint(fx), cint(fy), cint(fw), cint(fh))

  case node.kind
  of rukButton:
    mu_layout_set_next(muCtx, muR, 0)
    let label = if node.text.len > 0: node.text else: node.id
    let res = mu_button_ex(muCtx, cstring(label), 0, MU_OPT_ALIGNCENTER)
    if (res and MU_RES_SUBMIT) != 0:
      result.clickedIds.add(node.id)

  of rukInputText:
    let key = if node.id.len > 0: node.id else: "input_" & $cast[int](node.flexItem)
    if key notin state.inputText:
      state.inputText[key] = newString(256)
    mu_layout_set_next(muCtx, muR, 0)
    var buf = state.inputText[key]
    let res = mu_textbox_ex(muCtx, cstring(buf), cint(256), 0)
    state.inputText[key] = buf
    if (res and MU_RES_SUBMIT) != 0:
      result.submitIds.add(key)
    if (res and MU_RES_CHANGE) != 0:
      result.changedIds.add(key)

  of rukCheckbox:
    let key = if node.id.len > 0: node.id else: "chk_" & $cast[int](node.flexItem)
    if key notin state.checkbox:
      state.checkbox[key] = 0
    mu_layout_set_next(muCtx, muR, 0)
    var val = state.checkbox[key]
    let res = mu_checkbox(muCtx, cstring(node.text), addr val)
    state.checkbox[key] = val
    if (res and MU_RES_CHANGE) != 0:
      result.changedIds.add(key)

  of rukRange:
    let key = if node.id.len > 0: node.id else: "rng_" & $cast[int](node.flexItem)
    if key notin state.rangeVal:
      state.rangeVal[key] = 0.0
    mu_layout_set_next(muCtx, muR, 0)
    var val = state.rangeVal[key]
    let res = mu_slider_ex(muCtx, addr val, 0.0, 100.0, 0.0, "%.0f",
                           MU_OPT_ALIGNCENTER)
    state.rangeVal[key] = val
    if (res and MU_RES_CHANGE) != 0:
      result.changedIds.add(key)

  else:
    discard

  # Recurse children
  for child in node.children:
    processUiWidgets(muCtx, child, state, result)

# =============================================================================
# microui Command Rendering via NanoVG
# =============================================================================

proc renderMicrouiCommands(vg: ptr NVGcontext; muCtx: ptr MuContext) =
  ## Render microui draw command list using NanoVG.
  var cmd: ptr MuCommand = nil
  while mu_next_command(muCtx, addr cmd) != 0:
    let cmdType = cast[ptr cint](cmd)[]
    case cmdType
    of MU_COMMAND_CLIP:
      let clip = cast[ptr MuClipCommand](cmd)
      nvgResetScissor(vg)
      nvgScissor(vg, cfloat(clip.rect.x), cfloat(clip.rect.y),
                 cfloat(clip.rect.w), cfloat(clip.rect.h))
    of MU_COMMAND_RECT:
      let rc = cast[ptr MuRectCommand](cmd)
      nvgBeginPath(vg)
      nvgRect(vg, cfloat(rc.rect.x), cfloat(rc.rect.y),
              cfloat(rc.rect.w), cfloat(rc.rect.h))
      nvgFillColor(vg, nvgRGBA(cuchar(rc.color.r), cuchar(rc.color.g),
                                cuchar(rc.color.b), cuchar(rc.color.a)))
      nvgFill(vg)
    of MU_COMMAND_TEXT:
      let tc = cast[ptr MuTextCommand](cmd)
      nvgFontSize(vg, 14.0)
      if gUiDefaultFontId >= 0:
        nvgFontFaceId(vg, gUiDefaultFontId)
      nvgTextAlign(vg, cint(NVG_ALIGN_LEFT or NVG_ALIGN_TOP))
      nvgFillColor(vg, nvgRGBA(cuchar(tc.color.r), cuchar(tc.color.g),
                                cuchar(tc.color.b), cuchar(tc.color.a)))
      discard nvgText(vg, cfloat(tc.pos.x), cfloat(tc.pos.y),
                      cast[cstring](addr tc.str[0]), nil)
    of MU_COMMAND_ICON:
      let ic = cast[ptr MuIconCommand](cmd)
      nvgBeginPath(vg)
      let cx = cfloat(ic.rect.x) + cfloat(ic.rect.w) / 2.0
      let cy = cfloat(ic.rect.y) + cfloat(ic.rect.h) / 2.0
      nvgRect(vg, cx - 4.0, cy - 4.0, 8.0, 8.0)
      nvgFillColor(vg, nvgRGBA(cuchar(ic.color.r), cuchar(ic.color.g),
                                cuchar(ic.color.b), cuchar(ic.color.a)))
      nvgFill(vg)
    else:
      discard  # MU_COMMAND_JUMP, MU_COMMAND_FONT, etc.

# =============================================================================
# Single-Frame Orchestration
# =============================================================================

proc rwUiFrame*(htmlContent: string; w, h: int32): RwUiResult =
  ## Run a single UI frame:
  ##   1. Parse HTML → UI tree (or reuse cached tree)
  ##   2. Build flex item tree + layout
  ##   3. NanoVG render pass (backgrounds, borders, text)
  ##   4. microui widget pass (interactive elements)
  ##   5. Render microui commands via NanoVG
  ##   6. Return interaction results
  result = RwUiResult(
    clickedIds: @[], changedIds: @[], submitIds: @[]
  )

  if not gUiInited:
    rwUiInit()
    if not gUiInited: return

  # Build UI tree from HTML
  gUiTree = buildUiTreeFromHtml(htmlContent)
  if gUiTree == nil or gUiTree.root == nil: return

  # Free previous flex tree and build new one
  if gUiFlexRoot != nil:
    flex_item_free(gUiFlexRoot)
    gUiFlexRoot = nil

  gUiFlexRoot = buildFlexTree(gUiTree.root)
  if gUiFlexRoot == nil: return

  # Set root size and compute layout
  flex_item_set_width(gUiFlexRoot, cfloat(w))
  flex_item_set_height(gUiFlexRoot, cfloat(h))
  flex_layout(gUiFlexRoot)

  # NanoVG render pass
  nvgBeginFrame(gNvg, cfloat(w), cfloat(h), 1.0)

  # Pass 1: Render backgrounds, borders, text via NanoVG
  renderUiNode(gNvg, gUiTree.root)

  # Pass 2: microui widget pass
  mu_begin(addr gMuCtx)
  # Use a fullscreen window for widget layout
  let fullRect = mu_rect(0, 0, cint(w), cint(h))
  if mu_begin_window_ex(addr gMuCtx, "ui", fullRect,
      cint(MU_OPT_NOFRAME or MU_OPT_NOTITLE or MU_OPT_NORESIZE or
           MU_OPT_NOSCROLL or MU_OPT_NOCLOSE)) != 0:
    processUiWidgets(addr gMuCtx, gUiTree.root, gUiState, result)
    mu_end_window(addr gMuCtx)
  mu_end(addr gMuCtx)

  # Pass 3: Render microui command list via NanoVG
  renderMicrouiCommands(gNvg, addr gMuCtx)

  nvgEndFrame(gNvg)

# =============================================================================
# Font Registration
# =============================================================================

proc rwUiRegisterFont*(name: string; path: string): cint =
  ## Register a font with NanoVG. Returns font handle or -1.
  if gNvg == nil: return -1
  result = nvgCreateFont(gNvg, cstring(name), cstring(path))
  if result >= 0 and gUiDefaultFontId < 0:
    gUiDefaultFontId = result
  if result >= 0:
    stderr.writeLine("[rwebview_ui] Font registered: " & name & " → " & path)
  else:
    stderr.writeLine("[rwebview_ui] Font registration FAILED: " & name & " " & path)

proc rwUiRegisterFontsFromFontFaceMap*() =
  ## Register all fonts from the global fontFaceMap (populated by rwebview_html).
  for family, path in fontFaceMap:
    discard rwUiRegisterFont(family, path)
