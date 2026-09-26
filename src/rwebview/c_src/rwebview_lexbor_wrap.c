/*
 * rwebview_lexbor_wrap.c
 *
 * Thin C wrappers for Lexbor that require struct-internal field access,
 * providing linkable symbols callable from Nim's {.importc.} FFI.
 *
 * Compiled via {.compile: "c_src/rwebview_lexbor_wrap.c".} in rwebview.nim.
 * The include path for lexbor headers is supplied by {.passC.} in rwebview.nim.
 */

#include "lexbor/html/html.h"
#include "lexbor/dom/dom.h"

/*
 * lxb_html_document_t begins with lxb_dom_document_t as its first field.
 * Return a pointer to that embedded field so Nim can call the lxb_dom_*
 * API (which expects lxb_dom_document_t*) without needing full struct layout
 * knowledge on the Nim side.
 */
lxb_dom_document_t *rw_lxb_html_doc_to_dom(lxb_html_document_t *doc)
{
    return &doc->dom_document;
}
