/* rwebview_microui_helper.c
 * Thin C helpers to access mu_Context fields from Nim FFI.
 * mu_Context is a large struct; these functions avoid needing to replicate
 * the full layout in Nim.
 */
#include "microui.h"

void rw_mu_set_text_width(mu_Context *ctx,
                          int (*fn)(mu_Font font, const char *str, int len))
{
    ctx->text_width = fn;
}

void rw_mu_set_text_height(mu_Context *ctx,
                           int (*fn)(mu_Font font))
{
    ctx->text_height = fn;
}
