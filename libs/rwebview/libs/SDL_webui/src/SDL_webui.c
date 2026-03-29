/*
 * SDL_webui — Phase 3b: CSS/HTML-mapped layout + widget wrapper
 *
 * Manages a per-frame flex tree with per-element metadata (color, overflow,
 * text_align, text content, widget type). After layout(), absolute screen
 * rects are cached by name for O(1) lookup.
 */

#include <SDL3_webui/SDL_webui.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

/* -------------------------------------------------------
 * Per-element metadata (stored via flex_item managed_ptr)
 * ------------------------------------------------------- */
typedef struct swu_elem swu_elem;

/* Element kind — determines rendering behaviour */
typedef enum {
    SWU_KIND_CONTAINER = 0,   /* div, span — no self-rendering */
    SWU_KIND_TEXT,             /* p — word-wrapped text */
    SWU_KIND_LABEL,            /* label — single-line text */
    SWU_KIND_BUTTON,           /* button */
    SWU_KIND_INPUT,            /* input text */
    SWU_KIND_CHECKBOX,         /* input checkbox */
    SWU_KIND_RANGE,            /* input range */
    SWU_KIND_HR,               /* hr */
    SWU_KIND_SLOT              /* legacy swu_slot — no metadata beyond bg */
} swu_elem_kind;

struct swu_elem {
    struct flex_item *item;
    char              id[SWU_NAME_LEN];

    /* Visual CSS properties */
    SDL_Color         bg_color;       /* background-color (a=0 → none) */
    SDL_Color         border_color;   /* border-color (a=0 → none) */
    SDL_Color         text_color;     /* color (text foreground) */
    float             border_width;
    swu_overflow_t    overflow;
    swu_text_align_t  text_align;
    swu_display_t     display;

    /* Content (for text elements) */
    const char       *text;           /* pointer to caller's string (p, label) */

    /* Widget state pointers (for interactive elements) */
    char             *buf;            /* input text buffer */
    int               bufsz;
    int              *int_state;      /* checkbox state */
    mu_Real          *real_value;     /* range value */
    mu_Real           range_lo, range_hi, range_step;
    const char       *fmt;            /* range format */
    const char       *label;          /* button/checkbox label */

    swu_elem_kind     kind;
    int               widget_result;  /* result from this frame's widget call */
};

/* -------------------------------------------------------
 * Slot entry (name → rect lookup)
 * ------------------------------------------------------- */
typedef struct {
    char              name[SWU_NAME_LEN];
    struct flex_item *item;
    swu_elem         *elem;
    mu_Rect           rect;
} swu_slot_entry;

/* -------------------------------------------------------
 * Context
 * ------------------------------------------------------- */
struct swu_context {
    SDL_Renderer *renderer;
    mu_Context   *mu;

    struct flex_item *root;

    struct flex_item *stack[SWU_MAX_STACK];
    int               stack_top;

    swu_slot_entry slots[SWU_MAX_ITEMS];
    int            slot_count;

    /* Pool of per-element metadata (freed each frame) */
    swu_elem elems[SWU_MAX_ITEMS];
    int      elem_count;
};

/* -------------------------------------------------------
 * Helpers
 * ------------------------------------------------------- */
static swu_elem *alloc_elem(swu_context *ctx) {
    if (ctx->elem_count >= SWU_MAX_ITEMS) return NULL;
    swu_elem *e = &ctx->elems[ctx->elem_count++];
    memset(e, 0, sizeof(*e));
    e->text_color = (SDL_Color){230, 230, 230, 255}; /* default text */
    return e;
}

static void register_slot(swu_context *ctx, const char *name,
                           struct flex_item *item, swu_elem *elem) {
    if (!name || ctx->slot_count >= SWU_MAX_ITEMS) return;
    swu_slot_entry *s = &ctx->slots[ctx->slot_count++];
    strncpy(s->name, name, SWU_NAME_LEN - 1);
    s->name[SWU_NAME_LEN - 1] = '\0';
    s->item = item;
    s->elem = elem;
    s->rect = mu_rect(0, 0, 0, 0);
}

static swu_slot_entry *find_slot(swu_context *ctx, const char *name) {
    for (int i = 0; i < ctx->slot_count; i++) {
        if (strcmp(ctx->slots[i].name, name) == 0)
            return &ctx->slots[i];
    }
    return NULL;
}

/* Walk tree after layout, filling absolute rects */
static void resolve_rects(swu_context *ctx, struct flex_item *item,
                          float ox, float oy) {
    float x = flex_item_get_frame_x(item) + ox;
    float y = flex_item_get_frame_y(item) + oy;
    float w = flex_item_get_frame_width(item);
    float h = flex_item_get_frame_height(item);

    for (int i = 0; i < ctx->slot_count; i++) {
        if (ctx->slots[i].item == item) {
            ctx->slots[i].rect = mu_rect((int)x, (int)y, (int)w, (int)h);
            break;
        }
    }

    unsigned int n = flex_item_count(item);
    for (unsigned int i = 0; i < n; i++)
        resolve_rects(ctx, flex_item_child(item, i), x, y);
}

static int intersect_clip(SDL_Rect *out, const SDL_Rect *a, const SDL_Rect *b) {
    int x1 = SDL_max(a->x, b->x);
    int y1 = SDL_max(a->y, b->y);
    int x2 = SDL_min(a->x + a->w, b->x + b->w);
    int y2 = SDL_min(a->y + a->h, b->y + b->h);
    if (x2 <= x1 || y2 <= y1) {
        *out = (SDL_Rect){ x1, y1, 0, 0 };
        return 0;
    }
    *out = (SDL_Rect){ x1, y1, x2 - x1, y2 - y1 };
    return 1;
}

/* Walk tree, draw bg rects + borders */
static void render_bg_walk(swu_context *ctx, struct flex_item *item,
                           float ox, float oy) {
    float x = flex_item_get_frame_x(item) + ox;
    float y = flex_item_get_frame_y(item) + oy;
    float w = flex_item_get_frame_width(item);
    float h = flex_item_get_frame_height(item);

    swu_elem *e = (swu_elem *)flex_item_get_managed_ptr(item);
    if (e && w > 0 && h > 0) {
        /* Background */
        if (e->bg_color.a > 0) {
            SDL_SetRenderDrawColor(ctx->renderer, e->bg_color.r, e->bg_color.g,
                                   e->bg_color.b, e->bg_color.a);
            SDL_FRect fr = { x, y, w, h };
            SDL_RenderFillRect(ctx->renderer, &fr);
        }
        /* Border */
        if (e->border_color.a > 0 && e->border_width > 0) {
            SDL_SetRenderDrawColor(ctx->renderer, e->border_color.r, e->border_color.g,
                                   e->border_color.b, e->border_color.a);
            SDL_FRect top   = { x, y, w, e->border_width };
            SDL_FRect bot   = { x, y + h - e->border_width, w, e->border_width };
            SDL_FRect left  = { x, y, e->border_width, h };
            SDL_FRect right = { x + w - e->border_width, y, e->border_width, h };
            SDL_RenderFillRect(ctx->renderer, &top);
            SDL_RenderFillRect(ctx->renderer, &bot);
            SDL_RenderFillRect(ctx->renderer, &left);
            SDL_RenderFillRect(ctx->renderer, &right);
        }
    }

    SDL_Rect prev_clip;
    int has_prev_clip = SDL_GetRenderClipRect(ctx->renderer, &prev_clip);
    int pushed_clip = 0;

    if (e && e->overflow != SWU_OVERFLOW_VISIBLE) {
        SDL_Rect local_clip = { (int)x, (int)y, (int)w, (int)h };
        SDL_Rect next_clip;
        if (has_prev_clip)
            intersect_clip(&next_clip, &prev_clip, &local_clip);
        else
            next_clip = local_clip;
        SDL_SetRenderClipRect(ctx->renderer, &next_clip);
        pushed_clip = 1;
    }

    unsigned int n = flex_item_count(item);
    for (unsigned int i = 0; i < n; i++)
        render_bg_walk(ctx, flex_item_child(item, i), x, y);

    if (pushed_clip) {
        if (has_prev_clip)
            SDL_SetRenderClipRect(ctx->renderer, &prev_clip);
        else
            SDL_SetRenderClipRect(ctx->renderer, NULL);
    }
}

/* Word-wrap helper for text sizing and rendering */
struct swu_line { const char *start; int len; };

static int swu_collect_lines(mu_Context *mu, int wrap_w, const char *text,
                              struct swu_line *lines, int max_lines) {
    mu_Font font = mu->style->font;
    int n = 0;
    const char *p = text;
    while (*p && n < max_lines) {
        const char *ls = p;
        int w = 0;
        do {
            const char *word = p;
            while (*p && *p != ' ' && *p != '\n') p++;
            w += mu->text_width(font, word, (int)(p - word));
            if (w > wrap_w && ls != word) { p = word; break; }
            w += mu->text_width(font, p, 1);
            if (*p && *p++ == '\n') break;
        } while (*p);
        const char *le = p;
        while (le > ls && (le[-1] == ' ' || le[-1] == '\n')) le--;
        lines[n].start = ls;
        lines[n].len   = (int)(le - ls);
        n++;
    }
    return n;
}

/* flex_self_sizing callback for <p> elements */
static void SDLCALL swu_p_self_sizer(struct flex_item *item, float size[2]) {
    swu_elem *e = (swu_elem *)flex_item_get_managed_ptr(item);
    if (!e || !e->text) return;
    /* We need mu_Context — it's stored in the swu_context which we stash
     * on the root item's managed_ptr temporarily during layout.  Walk up. */
    struct flex_item *root = flex_item_root(item);
    /* The root's managed_ptr is temporarily a swu_context* during layout */
    swu_context *ctx = NULL;
    /* Actually, we'll use a simpler approach: the swu_elem stores a mu_Context* */
    /* We'll get it from the context global set before flex_layout */
    /* For now, store mu_Context* in a module-level variable during layout */
    extern mu_Context *swu__layout_mu_ctx;
    mu_Context *mu = swu__layout_mu_ctx;
    if (!mu) return;
    (void)root; (void)ctx;

    int avail_w = (int)size[0];
    if (avail_w <= 0) avail_w = 100;
    struct swu_line lines[512];
    int nlines = swu_collect_lines(mu, avail_w, e->text, lines, 512);

    int texth = mu->text_height(mu->style->font);
    size[1] = (float)(nlines * texth);
}

/* Module-level mu_Context* set during layout for self_sizing callbacks */
mu_Context *swu__layout_mu_ctx = NULL;

/* -------------------------------------------------------
 * Create / destroy
 * ------------------------------------------------------- */
swu_context *swu_init(SDL_Renderer *renderer, mu_Context *mu) {
    swu_context *ctx = (swu_context *)calloc(1, sizeof(swu_context));
    ctx->renderer = renderer;
    ctx->mu       = mu;
    return ctx;
}

void swu_destroy(swu_context *ctx) {
    free(ctx);
}

/* -------------------------------------------------------
 * Frame lifecycle
 * ------------------------------------------------------- */
void swu_begin(swu_context *ctx, int w, int h) {
    ctx->slot_count  = 0;
    ctx->stack_top   = 0;
    ctx->elem_count  = 0;

    ctx->root = flex_item_new();
    flex_item_set_direction(ctx->root, FLEX_DIRECTION_COLUMN);
    flex_item_set_width(ctx->root, (float)w);
    flex_item_set_height(ctx->root, (float)h);

    ctx->stack[ctx->stack_top++] = ctx->root;
}

void swu_layout(swu_context *ctx) {
    /* Set module-level mu for self_sizing callbacks */
    swu__layout_mu_ctx = ctx->mu;
    flex_layout(ctx->root);
    swu__layout_mu_ctx = NULL;
    resolve_rects(ctx, ctx->root, 0, 0);
}

void swu_render_backgrounds(swu_context *ctx) {
    render_bg_walk(ctx, ctx->root, 0, 0);
}

void swu_end(swu_context *ctx) {
    if (ctx->root) {
        flex_item_free(ctx->root);
        ctx->root = NULL;
    }
    ctx->stack_top  = 0;
    ctx->elem_count = 0;
}

/* -------------------------------------------------------
 * HTML Tag: <div> — container, default column
 * ------------------------------------------------------- */
swu_elem_t *swu_div(swu_context *ctx, const char *id) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_COLUMN);
    flex_item_set_width(item, NAN);
    flex_item_set_height(item, NAN);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 1);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_CONTAINER;
    strncpy(e->id, id ? id : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, id, item, e);

    if (ctx->stack_top < SWU_MAX_STACK)
        ctx->stack[ctx->stack_top++] = item;

    return e;
}

/* -------------------------------------------------------
 * HTML Tag: <span> — container, default row
 * ------------------------------------------------------- */
swu_elem_t *swu_span(swu_context *ctx, const char *id) {
    swu_elem_t *e = swu_div(ctx, id);
    flex_item_set_direction(e->item, FLEX_DIRECTION_ROW);
    return e;
}

/* -------------------------------------------------------
 * Close current container
 * ------------------------------------------------------- */
void swu_close(swu_context *ctx) {
    if (ctx->stack_top > 1)
        ctx->stack_top--;
}

/* -------------------------------------------------------
 * HTML Tag: <p> — word-wrapped text block
 * ------------------------------------------------------- */
swu_elem_t *swu_p(swu_context *ctx, const char *id, const char *text) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_COLUMN);
    flex_item_set_width(item, NAN);
    flex_item_set_height(item, NAN);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 1);
    flex_item_set_self_sizing(item, swu_p_self_sizer);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_TEXT;
    e->text = text;
    strncpy(e->id, id ? id : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, id, item, e);
    return e;
}

/* -------------------------------------------------------
 * HTML Tag: <label> — single-line text
 * ------------------------------------------------------- */
swu_elem_t *swu_label(swu_context *ctx, const char *id, const char *text) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_ROW);
    flex_item_set_width(item, NAN);
    flex_item_set_height(item, NAN);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 0);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_LABEL;
    e->text = text;
    strncpy(e->id, id ? id : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, id, item, e);
    return e;
}

/* -------------------------------------------------------
 * HTML Tag: <button>
 * ------------------------------------------------------- */
swu_result_t swu_button(swu_context *ctx, const char *id, const char *label) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_ROW);
    flex_item_set_width(item, NAN);
    flex_item_set_height(item, NAN);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 0);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_BUTTON;
    e->label = label;
    strncpy(e->id, id ? id : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, id, item, e);

    /* Result is filled later during widget rendering phase.
     * Return pointer to elem so caller can chain css calls;
     * but we return swu_result_t here, so the caller gets 0 for now
     * and must call widget rendering phase to get the result.
     *
     * HOWEVER: in immediate-mode, we need the result THIS frame.
     * The pattern is: declare in layout phase → render in widget phase.
     * For convenience, we store the elem index and the result is written
     * during widget rendering. But the old demo uses the return value
     * of mu_button directly...
     *
     * For Phase 3b: widget elements store their params but the actual
     * mu_* widget call happens in the widget rendering phase. The result
     * is stored in e->widget_result and returned from a separate call.
     *
     * But to keep immediate-mode feel: we return 0 here. The caller
     * gets results via swu_render_widgets() pass. This is different
     * from demo1. For demo2, we'll use a two-phase approach:
     *   Phase A: swu_div/swu_button/swu_css_*  → build flex tree
     *   Phase B: swu_layout + swu_render_backgrounds
     *   Phase C: swu_render_widgets → returns results via stored elem
     *
     * Actually, let's keep it simpler: button/input/etc element creation
     * just records them. The caller renders mu widgets manually like demo1
     * using swu_place + mu_button. The swu_button is just a convenience
     * that creates the flex slot with proper sizing.
     */

    return SWU_RES_NONE; /* actual result comes from widget rendering phase */
}

/* -------------------------------------------------------
 * HTML Tag: <input type="text">
 * ------------------------------------------------------- */
swu_result_t swu_input(swu_context *ctx, const char *id, char *buf, int bufsz) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_ROW);
    flex_item_set_width(item, NAN);
    flex_item_set_height(item, NAN);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 0);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_INPUT;
    e->buf = buf;
    e->bufsz = bufsz;
    strncpy(e->id, id ? id : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, id, item, e);
    return SWU_RES_NONE;
}

/* -------------------------------------------------------
 * HTML Tag: <input type="checkbox">
 * ------------------------------------------------------- */
swu_result_t swu_checkbox(swu_context *ctx, const char *id, const char *label, int *state) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_ROW);
    flex_item_set_width(item, NAN);
    flex_item_set_height(item, NAN);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 0);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_CHECKBOX;
    e->label = label;
    e->int_state = state;
    strncpy(e->id, id ? id : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, id, item, e);
    return SWU_RES_NONE;
}

/* -------------------------------------------------------
 * HTML Tag: <input type="range">
 * ------------------------------------------------------- */
swu_result_t swu_range(swu_context *ctx, const char *id, mu_Real *value,
                        mu_Real lo, mu_Real hi, mu_Real step, const char *fmt) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_ROW);
    flex_item_set_width(item, NAN);
    flex_item_set_height(item, NAN);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 0);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_RANGE;
    e->real_value = value;
    e->range_lo = lo;
    e->range_hi = hi;
    e->range_step = step;
    e->fmt = fmt;
    strncpy(e->id, id ? id : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, id, item, e);
    return SWU_RES_NONE;
}

/* -------------------------------------------------------
 * HTML Tag: <hr>
 * ------------------------------------------------------- */
swu_elem_t *swu_hr(swu_context *ctx, const char *id) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_ROW);
    flex_item_set_width(item, NAN);
    flex_item_set_height(item, 1);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 0);
    flex_item_set_margin_top(item, 2);
    flex_item_set_margin_bottom(item, 2);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_HR;
    e->bg_color = (SDL_Color){70, 80, 100, 255};
    strncpy(e->id, id ? id : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, id, item, e);
    return e;
}

/* -------------------------------------------------------
 * CSS Property setters
 * ------------------------------------------------------- */

/* Box model */
void swu_css_width(swu_elem_t *el, float px)  { flex_item_set_width(el->item, px); }
void swu_css_height(swu_elem_t *el, float px) { flex_item_set_height(el->item, px); }

void swu_css_margin(swu_elem_t *el, float px) {
    flex_item_set_margin_top(el->item, px);
    flex_item_set_margin_right(el->item, px);
    flex_item_set_margin_bottom(el->item, px);
    flex_item_set_margin_left(el->item, px);
}
void swu_css_margin_top(swu_elem_t *el, float px)    { flex_item_set_margin_top(el->item, px); }
void swu_css_margin_right(swu_elem_t *el, float px)  { flex_item_set_margin_right(el->item, px); }
void swu_css_margin_bottom(swu_elem_t *el, float px) { flex_item_set_margin_bottom(el->item, px); }
void swu_css_margin_left(swu_elem_t *el, float px)   { flex_item_set_margin_left(el->item, px); }

void swu_css_padding(swu_elem_t *el, float px) {
    flex_item_set_padding_top(el->item, px);
    flex_item_set_padding_right(el->item, px);
    flex_item_set_padding_bottom(el->item, px);
    flex_item_set_padding_left(el->item, px);
}
void swu_css_padding_top(swu_elem_t *el, float px)    { flex_item_set_padding_top(el->item, px); }
void swu_css_padding_right(swu_elem_t *el, float px)  { flex_item_set_padding_right(el->item, px); }
void swu_css_padding_bottom(swu_elem_t *el, float px) { flex_item_set_padding_bottom(el->item, px); }
void swu_css_padding_left(swu_elem_t *el, float px)   { flex_item_set_padding_left(el->item, px); }

void swu_css_position(swu_elem_t *el, swu_position_t v) { flex_item_set_position(el->item, (flex_position)v); }
void swu_css_top(swu_elem_t *el, float px)    { flex_item_set_top(el->item, px); }
void swu_css_right(swu_elem_t *el, float px)  { flex_item_set_right(el->item, px); }
void swu_css_bottom(swu_elem_t *el, float px) { flex_item_set_bottom(el->item, px); }
void swu_css_left(swu_elem_t *el, float px)   { flex_item_set_left(el->item, px); }

/* Flexbox */
void swu_css_display(swu_elem_t *el, swu_display_t v) {
    el->display = v;
    if (v == SWU_DISPLAY_NONE) {
        flex_item_set_width(el->item, 0);
        flex_item_set_height(el->item, 0);
        flex_item_set_margin_top(el->item, 0);
        flex_item_set_margin_right(el->item, 0);
        flex_item_set_margin_bottom(el->item, 0);
        flex_item_set_margin_left(el->item, 0);
        flex_item_set_padding_top(el->item, 0);
        flex_item_set_padding_right(el->item, 0);
        flex_item_set_padding_bottom(el->item, 0);
        flex_item_set_padding_left(el->item, 0);
    }
}
void swu_css_flex_direction(swu_elem_t *el, swu_flex_direction_t v)
    { flex_item_set_direction(el->item, (flex_direction)v); }
void swu_css_flex_wrap(swu_elem_t *el, swu_flex_wrap_t v)
    { flex_item_set_wrap(el->item, (flex_wrap)v); }
void swu_css_flex_grow(swu_elem_t *el, float v)   { flex_item_set_grow(el->item, v); }
void swu_css_flex_shrink(swu_elem_t *el, float v) { flex_item_set_shrink(el->item, v); }
void swu_css_flex_basis(swu_elem_t *el, float px)  { flex_item_set_basis(el->item, px); }
void swu_css_justify_content(swu_elem_t *el, swu_align_t v)
    { flex_item_set_justify_content(el->item, (flex_align)v); }
void swu_css_align_items(swu_elem_t *el, swu_align_t v)
    { flex_item_set_align_items(el->item, (flex_align)v); }
void swu_css_align_self(swu_elem_t *el, swu_align_t v)
    { flex_item_set_align_self(el->item, (flex_align)v); }
void swu_css_align_content(swu_elem_t *el, swu_align_t v)
    { flex_item_set_align_content(el->item, (flex_align)v); }
void swu_css_order(swu_elem_t *el, int v) { flex_item_set_order(el->item, v); }

/* Visual */
void swu_css_color(swu_elem_t *el, SDL_Color c)            { el->text_color = c; }
void swu_css_background_color(swu_elem_t *el, SDL_Color c) { el->bg_color = c; }
void swu_css_border_color(swu_elem_t *el, SDL_Color c)     { el->border_color = c; }
void swu_css_border_width(swu_elem_t *el, float px)        { el->border_width = px; }
void swu_css_overflow(swu_elem_t *el, swu_overflow_t v)    { el->overflow = v; }
void swu_css_text_align(swu_elem_t *el, swu_text_align_t v){ el->text_align = v; }

/* -------------------------------------------------------
 * Query (after layout)
 * ------------------------------------------------------- */
mu_Rect swu_get_rect(swu_context *ctx, const char *id) {
    swu_slot_entry *s = find_slot(ctx, id);
    return s ? s->rect : mu_rect(0, 0, 0, 0);
}

void swu_place(swu_context *ctx, const char *id) {
    mu_layout_set_next(ctx->mu, swu_get_rect(ctx, id), 0);
}

void swu_clip_push(swu_context *ctx, const char *id) {
    mu_push_clip_rect(ctx->mu, swu_get_rect(ctx, id));
}

void swu_clip_pop(swu_context *ctx) {
    mu_pop_clip_rect(ctx->mu);
}

mu_Context *swu_get_mu(swu_context *ctx) {
    return ctx->mu;
}

/* -------------------------------------------------------
 * Legacy API (Phase 3a compat) — delegates to new API
 * ------------------------------------------------------- */
struct flex_item *swu_open(swu_context *ctx, const char *name) {
    swu_elem_t *e = swu_div(ctx, name);
    return e->item;
}

struct flex_item *swu_slot(swu_context *ctx, const char *name, float w, float h) {
    struct flex_item *item = flex_item_new();
    flex_item_set_direction(item, FLEX_DIRECTION_ROW);
    flex_item_set_width(item, w);
    flex_item_set_height(item, h);
    flex_item_set_grow(item, 0);
    flex_item_set_shrink(item, 0);

    swu_elem *e = alloc_elem(ctx);
    e->item = item;
    e->kind = SWU_KIND_SLOT;
    strncpy(e->id, name ? name : "", SWU_NAME_LEN - 1);
    flex_item_set_managed_ptr(item, e);

    if (ctx->stack_top > 0)
        flex_item_add(ctx->stack[ctx->stack_top - 1], item);

    register_slot(ctx, name, item, e);
    return item;
}

struct flex_item *swu_open_bg(swu_context *ctx, const char *name,
                              Uint8 r, Uint8 g, Uint8 b, Uint8 a) {
    swu_elem_t *e = swu_div(ctx, name);
    e->bg_color = (SDL_Color){r, g, b, a};
    return e->item;
}

void swu_divider(swu_context *ctx, Uint8 r, Uint8 g, Uint8 b) {
    swu_elem_t *e = swu_hr(ctx, NULL);
    e->bg_color = (SDL_Color){r, g, b, 255};
}
