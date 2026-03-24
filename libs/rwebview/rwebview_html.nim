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
# Phase 2 — HTML Script Loader
# ===========================================================================

type ScriptEntry = object
  src:    string   ## non-empty → external file path (relative to baseDir)
  inline: string   ## non-empty → inline script text
  isModule: bool   ## true if type="module" (treated as regular script)

# Global @font-face map: family name (lowercase) → absolute TTF/OTF file path.
# Populated by parseStylesheetFonts(); used by rwebview_canvas2d.nim getFont().
var fontFaceMap: Table[string, string]

proc parseFontFaces(cssContent: string; cssDir: string) =
  ## Parse @font-face rules from CSS text and populate fontFaceMap.
  var pos = 0
  while pos < cssContent.len:
    let ffIdx = cssContent.find("@font-face", pos)
    if ffIdx < 0: break
    let braceOpen = cssContent.find('{', ffIdx)
    if braceOpen < 0: break
    let braceClose = cssContent.find('}', braceOpen)
    if braceClose < 0: break
    let blk = cssContent[braceOpen + 1 ..< braceClose]
    # Extract font-family value
    var family = ""
    let famIdx = blk.toLowerAscii().find("font-family")
    if famIdx >= 0:
      let colonIdx = blk.find(':', famIdx)
      if colonIdx >= 0:
        let semi = blk.find(';', colonIdx + 1)
        let e = if semi >= 0: semi else: blk.len
        family = blk[colonIdx + 1 ..< e].strip().strip(chars = {'"', '\''})
    # Extract src: url("file.ttf")
    var srcUrl = ""
    let srcIdx = blk.toLowerAscii().find("src")
    if srcIdx >= 0:
      let urlIdx = blk.toLowerAscii().find("url(", srcIdx)
      if urlIdx >= 0:
        let parenClose = blk.find(')', urlIdx + 4)
        if parenClose >= 0:
          srcUrl = blk[urlIdx + 4 ..< parenClose].strip().strip(chars = {'"', '\''})
    if family.len > 0 and srcUrl.len > 0:
      let fontPath = if isAbsolute(srcUrl): srcUrl else: cssDir / srcUrl
      if fileExists(fontPath):
        fontFaceMap[family.toLowerAscii()] = fontPath
        stderr.writeLine("[rwebview] @font-face registered: " & family & " → " & fontPath)
    pos = braceClose + 1

proc parseStylesheetFonts(htmlContent: string; baseDir: string) =
  ## Scan HTML for <link rel="stylesheet" href="..."> tags, load each CSS
  ## file, and extract @font-face family→file mappings into fontFaceMap.
  var pos = 0
  while pos < htmlContent.len:
    let linkIdx = htmlContent.find("<link", pos)
    if linkIdx < 0: break
    let closeIdx = htmlContent.find('>', linkIdx)
    if closeIdx < 0: break
    let tag = htmlContent[linkIdx .. closeIdx]
    if "stylesheet" in tag.toLowerAscii():
      # Extract href attribute value
      var href = ""
      for q in ["href=\"", "href='"]:
        let hi = tag.find(q)
        if hi >= 0:
          let start = hi + q.len
          let endChar = if q[^1] == '"': '"' else: '\''
          let e = tag.find(endChar, start)
          if e > start:
            href = tag[start ..< e]
            break
      if href.len > 0:
        let cssPath = if isAbsolute(href): href else: baseDir / href
        if fileExists(cssPath):
          parseFontFaces(readFile(cssPath), cssPath.parentDir())
    pos = closeIdx + 1

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

