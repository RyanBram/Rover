# =============================================================================
# rwebview_html.nim
# Lexbor HTML parser FFI and types
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
#   Lexbor types (opaque) and HTML parser wrapper functions.
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rgss_quickjs_ffi         # JS helpers
#
# Used by:
#   - rwebview.nim             # included after rgss_quickjs_ffi.nim
#
# =============================================================================

type
  LxbHtmlParser    = object   # opaque
  LxbHtmlDocument  = object   # opaque
  LxbDomDocument   = object   # opaque  (first field of LxbHtmlDocument)
  LxbDomNode       = object   # opaque
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
proc lxb_dom_elements_by_attr_contain(root: ptr LxbDomElement;
                    col: ptr LxbDomCollection;
                    qualified_name: pointer;
                    qnameLen: csize_t;
                    value: pointer;
                    valueLen: csize_t;
                    caseInsensitive: bool): LxbStatus
  {.importc: "lxb_dom_elements_by_attr_contain".}

# -- Attribute access --
proc lxb_dom_element_get_attribute(element: ptr LxbDomElement;
                                    qualified_name: pointer; qn_len: csize_t;
                                    value_len: ptr csize_t): cstring
    {.importc: "lxb_dom_element_get_attribute".}

# -- Node text content (for inline <script> bodies) --
proc lxb_dom_node_text_content(node: ptr LxbDomElement;
                                len: ptr csize_t): cstring
    {.importc: "lxb_dom_node_text_content".}

proc lxb_dom_node_name(node: ptr LxbDomNode;
            len: ptr csize_t): cstring
  {.importc: "lxb_dom_node_name".}
proc lxb_dom_node_next_noi(node: ptr LxbDomNode): ptr LxbDomNode
  {.importc: "lxb_dom_node_next_noi".}
proc lxb_dom_node_first_child_noi(node: ptr LxbDomNode): ptr LxbDomNode
  {.importc: "lxb_dom_node_first_child_noi".}
proc lxb_dom_node_type_noi(node: ptr LxbDomNode): cint
  {.importc: "lxb_dom_node_type_noi".}

# -- Document root element (non-inline) --
proc lxb_dom_document_element_noi(document: ptr LxbDomDocument): ptr LxbDomElement
    {.importc: "lxb_dom_document_element_noi".}

# ===========================================================================
# Lexbor C wrapper (rwebview_lexbor_wrap.c)
# ===========================================================================

# Cast lxb_html_document_t* → lxb_dom_document_t* (first-field pointer)
proc rw_lxb_html_doc_to_dom(doc: ptr LxbHtmlDocument): ptr LxbDomDocument
    {.importc: "rw_lxb_html_doc_to_dom".}

# Extract @font-face entries from CSS via Lexbor CSS parser.
# Return format: one entry per line, "family<TAB>srcUrl".
proc rw_lxb_extract_font_faces(css: cstring; cssLen: csize_t;
                 outLen: ptr csize_t): cstring
  {.importc: "rw_lxb_extract_font_faces".}
proc rw_lxb_free(p: pointer)
  {.importc: "rw_lxb_free".}

# ===========================================================================
# Phase 2 — HTML Script Loader
# ===========================================================================

type ScriptEntry = object
  src:    string   ## non-empty → external file path (relative to baseDir)
  inline: string   ## non-empty → inline script text
  isModule: bool   ## true if type="module" (treated as regular script)

# Global @font-face map: family name (lowercase) → absolute TTF/OTF file path.
# Populated by parseStylesheetFonts(); used by rwebview_canvas2d.nim getFont().
var fontFaceMap: Table[string, string]

const
  lxbDomNodeTypeElement = 1.cint

# Forward declarations for helpers defined later in this file.
proc elemAttr(el: ptr LxbDomElement; name: string): string

# ---------------------------------------------------------------------------
# HTML element scanner — creates virtual DOM elements from HTML body markup.
# ---------------------------------------------------------------------------

proc jsQuoteSingle(s: string): string =
  ## Escape a string for safe single-quoted JS literals.
  s.replace("\\", "\\\\").replace("'", "\\'")

proc nodeNameLower(node: ptr LxbDomNode): string =
  ## Return lowercase node name from Lexbor node ("div", "script", ...).
  var nlen: csize_t = 0
  let nm = lxb_dom_node_name(node, addr nlen)
  if nm == nil or nlen == 0:
    return ""
  result = newString(int(nlen))
  copyMem(addr result[0], nm, int(nlen))
  result = result.toLowerAscii()

proc isInterestingHtmlTag(tagName: string): bool =
  tagName == "canvas" or tagName == "div" or tagName == "input" or
  tagName == "select" or tagName == "textarea" or tagName == "button" or
  tagName == "form"

proc buildHtmlElemsJs*(html: string): string =
  ## Lexbor-only element extraction for id-bearing HTML controls.
  type HtmlElemDesc = object
    tagName: string
    id: string
    width: string
    height: string
    inputType: string
    className: string

  let parser = lxb_html_parser_create()
  if parser == nil:
    stderr.writeLine("[rwebview] buildHtmlElemsJs: parser create failed")
    return ""

  if lxb_html_parser_init(parser) != lxbStatusOk:
    discard lxb_html_parser_destroy(parser)
    stderr.writeLine("[rwebview] buildHtmlElemsJs: parser init failed")
    return ""

  let doc = lxb_html_parse(parser,
               cast[pointer](cstring(html)),
               csize_t(html.len))
  discard lxb_html_parser_destroy(parser)

  if doc == nil:
    stderr.writeLine("[rwebview] buildHtmlElemsJs: parse returned nil")
    return ""

  let domDoc = rw_lxb_html_doc_to_dom(doc)
  if domDoc == nil:
    discard lxb_html_document_destroy(doc)
    stderr.writeLine("[rwebview] buildHtmlElemsJs: dom cast returned nil")
    return ""

  let rootEl = lxb_dom_document_element_noi(domDoc)
  if rootEl == nil:
    discard lxb_html_document_destroy(doc)
    stderr.writeLine("[rwebview] buildHtmlElemsJs: root element is nil")
    return ""

  var elems: seq[HtmlElemDesc] = @[]

  proc walk(node: ptr LxbDomNode) =
    var cur = node
    while cur != nil:
      if lxb_dom_node_type_noi(cur) == lxbDomNodeTypeElement:
        let tagName = nodeNameLower(cur)
        if tagName.len > 0 and isInterestingHtmlTag(tagName):
          let el = cast[ptr LxbDomElement](cur)
          let id = elemAttr(el, "id")
          if id.len > 0:
            elems.add(HtmlElemDesc(
              tagName: tagName,
              id: id,
              width: elemAttr(el, "width"),
              height: elemAttr(el, "height"),
              inputType: elemAttr(el, "type"),
              className: elemAttr(el, "class")
            ))
      let child = lxb_dom_node_first_child_noi(cur)
      if child != nil:
        walk(child)
      cur = lxb_dom_node_next_noi(cur)

  walk(cast[ptr LxbDomNode](rootEl))
  discard lxb_html_document_destroy(doc)

  if elems.len == 0:
    return ""

  var lines: seq[string] = @[]
  for e in elems:
    var line = "(function(){if(!document.getElementById('" & jsQuoteSingle(e.id) & "')){" &
               "var _e=document.createElement('" & e.tagName & "');" &
               "_e.id='" & jsQuoteSingle(e.id) & "';"
    if e.width.len > 0:
      line &= "try{_e.width=parseInt('" & jsQuoteSingle(e.width) & "',10)||_e.width;}catch(e){}"
    if e.height.len > 0:
      line &= "try{_e.height=parseInt('" & jsQuoteSingle(e.height) & "',10)||_e.height;}catch(e){}"
    if e.inputType.len > 0:
      line &= "_e.setAttribute('type','" & jsQuoteSingle(e.inputType) & "');"
    if e.className.len > 0:
      line &= "_e.className='" & jsQuoteSingle(e.className) & "';"
    line &= "document.body.appendChild(_e);}})()"
    lines.add(line)
  result = lines.join(";\n")

proc parseFontFaces(cssContent: string; cssDir: string) =
  ## Parse @font-face rules using Lexbor CSS parser and populate fontFaceMap.
  if cssContent.len == 0:
    return

  var outLen: csize_t = 0
  let raw = rw_lxb_extract_font_faces(cstring(cssContent), csize_t(cssContent.len), addr outLen)
  if raw == nil or outLen == 0:
    return

  var payload = newString(int(outLen))
  copyMem(addr payload[0], raw, int(outLen))
  rw_lxb_free(cast[pointer](raw))

  for line in payload.splitLines():
    if line.len == 0: continue
    let tab = line.find('\t')
    if tab <= 0 or tab >= line.high: continue
    let family = line[0 ..< tab].strip()
    let srcUrl = line[tab + 1 .. ^1].strip()
    if family.len == 0 or srcUrl.len == 0: continue
    let fontPath = if isAbsolute(srcUrl): srcUrl else: cssDir / srcUrl
    if fileExists(fontPath):
      fontFaceMap[family.toLowerAscii()] = fontPath
      stderr.writeLine("[rwebview] @font-face registered: " & family & " → " & fontPath)

proc parseStylesheetFonts(htmlContent: string; baseDir: string) =
  ## Scan HTML for stylesheet links via Lexbor DOM + attr matching, then parse
  ## @font-face rules for canvas text rendering.
  let parser = lxb_html_parser_create()
  if parser == nil:
    stderr.writeLine("[rwebview] parseStylesheetFonts: parser create failed")
    return
  if lxb_html_parser_init(parser) != lxbStatusOk:
    discard lxb_html_parser_destroy(parser)
    stderr.writeLine("[rwebview] parseStylesheetFonts: parser init failed")
    return

  let doc = lxb_html_parse(parser,
               cast[pointer](cstring(htmlContent)),
               csize_t(htmlContent.len))
  discard lxb_html_parser_destroy(parser)
  if doc == nil:
    stderr.writeLine("[rwebview] parseStylesheetFonts: parse returned nil")
    return

  let domDoc = rw_lxb_html_doc_to_dom(doc)
  if domDoc == nil:
    discard lxb_html_document_destroy(doc)
    stderr.writeLine("[rwebview] parseStylesheetFonts: dom cast returned nil")
    return

  let rootEl = lxb_dom_document_element_noi(domDoc)
  if rootEl == nil:
    discard lxb_html_document_destroy(doc)
    stderr.writeLine("[rwebview] parseStylesheetFonts: root element is nil")
    return

  let col = lxb_dom_collection_make_noi(domDoc, 16)
  if col == nil:
    discard lxb_html_document_destroy(doc)
    stderr.writeLine("[rwebview] parseStylesheetFonts: collection alloc failed")
    return

  let attrRel = "rel"
  let valStylesheet = "stylesheet"
  if lxb_dom_elements_by_attr_contain(rootEl, col,
       cast[pointer](cstring(attrRel)), csize_t(attrRel.len),
       cast[pointer](cstring(valStylesheet)), csize_t(valStylesheet.len),
       true) == lxbStatusOk:
    let count = lxb_dom_collection_length_noi(col)
    for i in 0 ..< count:
      let el = lxb_dom_collection_element_noi(col, i)
      if el == nil: continue
      let href = elemAttr(el, "href")
      if href.len == 0: continue
      # Skip remote stylesheets in virtual-host mode; only local files can be
      # scanned for @font-face asset paths.
      if href.startsWith("http://") or href.startsWith("https://"):
        continue
      let cssPath = if isAbsolute(href): href else: baseDir / href
      if fileExists(cssPath):
        parseFontFaces(readFile(cssPath), cssPath.parentDir())

  discard lxb_dom_collection_destroy(col, true)
  discard lxb_html_document_destroy(doc)

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

  # Protocol-relative URLs (//host/path) are remote — never resolve locally.
  # On Windows, "//host/path" is a UNC path and fileExists() will block for
  # ~20 seconds waiting for a network timeout.  Reject them immediately.
  if url.len >= 2 and url[0] == '/' and url[1] == '/':
    return ""

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
    # Unknown virtual host (e.g. api.newgrounds.com, external APIs) —
    # return empty string so the caller knows no local file exists.
    return ""
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
  ##
  ## After each successful script, new non-null properties added to the JS
  ## 'window' object are synced to globalThis.  This is required because
  ## QuickJS has a separate global scope from our custom 'window' object.
  ## Without the sync, libraries like PIXI.js that set window.PIXI = exports
  ## would not be visible as the global 'PIXI' expected by pixi-tilemap.js.
  const syncCode = "(function(){" &
    "var w=typeof window!=='undefined'?window:null;" &
    "if(!w)return;" &
    "for(var _k in w){try{var _v=w[_k];" &
    "if(_v!=null&&typeof globalThis[_k]==='undefined')" &
    "globalThis[_k]=_v;}catch(e){}}" &
    "})()"

  for entry in scripts:
    if entry.src.len > 0:
      # External script file
      if not fileExists(entry.src):
        stderr.writeLine("[rwebview] script file not found: " & entry.src)
        continue
      var code = readFile(entry.src)
      # Strip UTF-8 BOM so QuickJS does not choke on \xEF\xBB\xBF
      if code.len >= 3 and code[0] == '\xEF' and code[1] == '\xBB' and code[2] == '\xBF':
        code = code[3 .. ^1]
      # Set document.currentScript to a fake element with src = the absolute path.
      # main.js (and similar entry scripts) access document.currentScript.src
      # synchronously during execution (e.g. RPG Maker MZ's testXhr()).
      let safeSrcForCs = entry.src.replace("\\", "/")
      let setCurrentScript = "(function(){" &
        "var _s=document.createElement('script');" &
        "_s.src='" & safeSrcForCs & "';" &
        "document.currentScript=_s;})()"
      let csSet = JS_Eval(ctx, cstring(setCurrentScript),
                          csize_t(setCurrentScript.len),
                          "<set-currentScript>", JS_EVAL_TYPE_GLOBAL)
      rw_JS_FreeValue(ctx, csSet)
      let ret = JS_Eval(ctx, cstring(code), csize_t(code.len),
                        cstring(entry.src), JS_EVAL_TYPE_GLOBAL)
      # Clear document.currentScript after the script finishes (browser behaviour).
      let clearCs = "document.currentScript=null;"
      let csClr = JS_Eval(ctx, cstring(clearCs), csize_t(clearCs.len),
                          "<clear-currentScript>", JS_EVAL_TYPE_GLOBAL)
      rw_JS_FreeValue(ctx, csClr)
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
    # Sync window properties → globalThis after each script so that libraries
    # setting window.PIXI / window.THREE / etc. are accessible as bare globals
    # in subsequent scripts (mirrors real browser global-scope behaviour).
    let s = JS_Eval(ctx, cstring(syncCode), csize_t(syncCode.len),
                    "<sync>", JS_EVAL_TYPE_GLOBAL)
    rw_JS_FreeValue(ctx, s)
    # Add a <script> element to the DOM for this script entry so that
    # document.getElementsByTagName('script') returns a non-empty list.
    # Utils.canReadGameFiles() (rpg_core.js) relies on this to decide
    # whether local file access is permitted.
    if entry.src.len > 0:
      let safeSrc = entry.src.replace("\\", "/")
      let addScriptJs = "(function(){var _s=document.createElement('script');" &
                        "_s.src='" & safeSrc & "';" &
                        "document.head.appendChild(_s);})()"
      let sr = JS_Eval(ctx, cstring(addScriptJs), csize_t(addScriptJs.len),
                       "<add-script-dom>", JS_EVAL_TYPE_GLOBAL)
      rw_JS_FreeValue(ctx, sr)

