/*
 * SDL_webui — CSS/HTML-mapped layout + widget API over flex + microui
 *
 * SDL_webui is a thin integration layer that wraps two C libraries:
 *   - flex  (CSS Flexbox layout engine)        — computes WHERE widgets live
 *   - microui (immediate-mode widget toolkit)  — draws WHAT and handles input
 *
 * Phase 3b API: HTML-tag functions (swu_div, swu_p, swu_button, …) and
 * CSS-property setters (swu_css_width, swu_css_flex_grow, …) that map 1:1
 * onto CSS/HTML names for easy integration with rwebview.
 *
 * Follows the same header layout convention as SDL_sound / SDL_ttf / SDL_image:
 *   Public header  →  include/SDL3_webui/SDL_webui.h   (this file)
 *   Implementation →  src/SDL_webui.c
 *   Export list    →  src/SDL_webui.exports
 */

#ifndef SDL_WEBUI_H
#define SDL_WEBUI_H

#include <SDL3/SDL.h>
#include "microui.h"   /* mu_Rect, mu_Context */
#include "flex.h"      /* struct flex_item    */

#ifdef __cplusplus
extern "C" {
#endif

/* ===========================
 * Limits
 * =========================== */
#define SWU_MAX_ITEMS   256
#define SWU_MAX_STACK    64
#define SWU_NAME_LEN     32

/* ===========================
 * Enums (CSS-mapped values)
 * =========================== */

typedef enum {
    SWU_POSITION_RELATIVE = FLEX_POSITION_RELATIVE,
    SWU_POSITION_ABSOLUTE = FLEX_POSITION_ABSOLUTE
} swu_position_t;

typedef enum {
    SWU_FLEX_ROW            = FLEX_DIRECTION_ROW,
    SWU_FLEX_ROW_REVERSE    = FLEX_DIRECTION_ROW_REVERSE,
    SWU_FLEX_COLUMN         = FLEX_DIRECTION_COLUMN,
    SWU_FLEX_COLUMN_REVERSE = FLEX_DIRECTION_COLUMN_REVERSE
} swu_flex_direction_t;

typedef enum {
    SWU_NOWRAP       = FLEX_WRAP_NO_WRAP,
    SWU_WRAP         = FLEX_WRAP_WRAP,
    SWU_WRAP_REVERSE = FLEX_WRAP_WRAP_REVERSE
} swu_flex_wrap_t;

typedef enum {
    SWU_AUTO          = FLEX_ALIGN_AUTO,
    SWU_STRETCH       = FLEX_ALIGN_STRETCH,
    SWU_CENTER        = FLEX_ALIGN_CENTER,
    SWU_FLEX_START    = FLEX_ALIGN_START,
    SWU_FLEX_END      = FLEX_ALIGN_END,
    SWU_SPACE_BETWEEN = FLEX_ALIGN_SPACE_BETWEEN,
    SWU_SPACE_AROUND  = FLEX_ALIGN_SPACE_AROUND,
    SWU_SPACE_EVENLY  = FLEX_ALIGN_SPACE_EVENLY
} swu_align_t;

typedef enum {
    SWU_OVERFLOW_VISIBLE = 0,
    SWU_OVERFLOW_HIDDEN,
    SWU_OVERFLOW_AUTO,
    SWU_OVERFLOW_SCROLL
} swu_overflow_t;

typedef enum {
    SWU_TEXT_LEFT = 0,
    SWU_TEXT_CENTER,
    SWU_TEXT_RIGHT
} swu_text_align_t;

typedef enum {
    SWU_DISPLAY_FLEX = 0,
    SWU_DISPLAY_NONE
} swu_display_t;

/* ===========================
 * Result flags
 * =========================== */
typedef int swu_result_t;
#define SWU_RES_NONE    0
#define SWU_RES_CLICK   (1 << 0)
#define SWU_RES_CHANGE  (1 << 1)
#define SWU_RES_ACTIVE  (1 << 2)
#define SWU_RES_SUBMIT  (1 << 3)

/* ===========================
 * Element handle (opaque)
 * =========================== */
typedef struct swu_elem swu_elem_t;

/* ===========================
 * Context
 * =========================== */
typedef struct swu_context swu_context;

swu_context *swu_init(SDL_Renderer *renderer, mu_Context *mu);
void         swu_destroy(swu_context *ctx);

/* ===========================
 * Frame lifecycle
 * =========================== */
void swu_begin(swu_context *ctx, int w, int h);
void swu_layout(swu_context *ctx);
void swu_render_backgrounds(swu_context *ctx);
void swu_end(swu_context *ctx);

/* ===========================
 * HTML Tag functions
 *
 * Container tags: swu_div, swu_span  — must be closed with swu_close()
 * Leaf tags: swu_p, swu_label, swu_button, swu_input, etc. — self-closing
 * =========================== */

/* Container elements (need swu_close) */
swu_elem_t *swu_div(swu_context *ctx, const char *id);
swu_elem_t *swu_span(swu_context *ctx, const char *id);

/* Close current container */
void swu_close(swu_context *ctx);

/* Text elements (leaf, self-closing) */
swu_elem_t *swu_p(swu_context *ctx, const char *id, const char *text);
swu_elem_t *swu_label(swu_context *ctx, const char *id, const char *text);

/* Interactive widget elements (leaf, self-closing) */
swu_result_t swu_button(swu_context *ctx, const char *id, const char *label);
swu_result_t swu_input(swu_context *ctx, const char *id, char *buf, int bufsz);
swu_result_t swu_checkbox(swu_context *ctx, const char *id, const char *label, int *state);
swu_result_t swu_range(swu_context *ctx, const char *id, mu_Real *value,
                        mu_Real lo, mu_Real hi, mu_Real step, const char *fmt);

/* Structural elements (leaf) */
swu_elem_t *swu_hr(swu_context *ctx, const char *id);

/* ===========================
 * CSS Property setters
 * =========================== */

/* Box model */
void swu_css_width(swu_elem_t *el, float px);
void swu_css_height(swu_elem_t *el, float px);

void swu_css_margin(swu_elem_t *el, float px);
void swu_css_margin_top(swu_elem_t *el, float px);
void swu_css_margin_right(swu_elem_t *el, float px);
void swu_css_margin_bottom(swu_elem_t *el, float px);
void swu_css_margin_left(swu_elem_t *el, float px);

void swu_css_padding(swu_elem_t *el, float px);
void swu_css_padding_top(swu_elem_t *el, float px);
void swu_css_padding_right(swu_elem_t *el, float px);
void swu_css_padding_bottom(swu_elem_t *el, float px);
void swu_css_padding_left(swu_elem_t *el, float px);

void swu_css_position(swu_elem_t *el, swu_position_t v);
void swu_css_top(swu_elem_t *el, float px);
void swu_css_right(swu_elem_t *el, float px);
void swu_css_bottom(swu_elem_t *el, float px);
void swu_css_left(swu_elem_t *el, float px);

/* Flexbox */
void swu_css_display(swu_elem_t *el, swu_display_t v);
void swu_css_flex_direction(swu_elem_t *el, swu_flex_direction_t v);
void swu_css_flex_wrap(swu_elem_t *el, swu_flex_wrap_t v);
void swu_css_flex_grow(swu_elem_t *el, float v);
void swu_css_flex_shrink(swu_elem_t *el, float v);
void swu_css_flex_basis(swu_elem_t *el, float px);
void swu_css_justify_content(swu_elem_t *el, swu_align_t v);
void swu_css_align_items(swu_elem_t *el, swu_align_t v);
void swu_css_align_self(swu_elem_t *el, swu_align_t v);
void swu_css_align_content(swu_elem_t *el, swu_align_t v);
void swu_css_order(swu_elem_t *el, int v);

/* Visual */
void swu_css_color(swu_elem_t *el, SDL_Color c);
void swu_css_background_color(swu_elem_t *el, SDL_Color c);
void swu_css_border_color(swu_elem_t *el, SDL_Color c);
void swu_css_border_width(swu_elem_t *el, float px);
void swu_css_overflow(swu_elem_t *el, swu_overflow_t v);
void swu_css_text_align(swu_elem_t *el, swu_text_align_t v);

/* ===========================
 * Query (after swu_layout)
 * =========================== */
mu_Rect swu_get_rect(swu_context *ctx, const char *id);
void swu_place(swu_context *ctx, const char *id);
void swu_clip_push(swu_context *ctx, const char *id);
void swu_clip_pop(swu_context *ctx);

/* Get the microui context (for advanced use) */
mu_Context *swu_get_mu(swu_context *ctx);

/* ===========================
 * Legacy API (Phase 3a compat)
 * =========================== */
struct flex_item *swu_open(swu_context *ctx, const char *name);
struct flex_item *swu_slot(swu_context *ctx, const char *name, float w, float h);
struct flex_item *swu_open_bg(swu_context *ctx, const char *name,
                              Uint8 r, Uint8 g, Uint8 b, Uint8 a);
void swu_divider(swu_context *ctx, Uint8 r, Uint8 g, Uint8 b);

#ifdef __cplusplus
}
#endif

#endif /* SDL_WEBUI_H */
