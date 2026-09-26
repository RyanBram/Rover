/*
 * SDL_webui demo 2 — Phase 3b CSS/HTML-mapped API
 *
 * Rewrites demo 1 using the new HTML-tag + CSS-property API:
 *   swu_div/swu_close  instead of swu_open/swu_close
 *   swu_css_*           instead of flex_item_set_*
 *   swu_hr              instead of swu_divider
 *
 * Interactive widgets still use swu_place + mu_* (immediate microui),
 * which gives direct per-frame return values. The swu_div + swu_css_*
 * layer manages all sizing and background rendering transparently.
 *
 * Layout tree (identical to demo 1):
 *   Root (COLUMN, full window)
 *   ├── TopBar (ROW, 34px)  — [Input] [Submit]
 *   ├── Body (ROW, grow 1)
 *   │   ├── Sidebar (COLUMN, 200px)
 *   │   │   ├── Buttons section (collapsible)
 *   │   │   ├── Checkboxes section (collapsible)
 *   │   │   ├── Colors section (collapsible)
 *   │   │   └── Tree section (collapsible)
 *   │   └── MainContent (COLUMN, grow 1)
 *   │       ├── TitleBar (32px)
 *   │       ├── ContentRows (responsive ROW/COLUMN, grow 1)
 *   │       │   ├── Card1 (grow 1)
 *   │       │   ├── Card2 (grow 1)
 *   │       │   └── Card3 (grow 1)
 *   │       └── Console (150px)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <SDL3_webui/SDL_webui.h>
#include "microui.h"

/* SDL3 + SDL_ttf renderer (replaces bitmap atlas with TTF font) */
#include "renderer_sdl3_ttf.h"

/* -------------------------------------------------------
 * Constants
 * ------------------------------------------------------- */
#define RESPONSIVE_BREAKPOINT 700

/* -------------------------------------------------------
 * Colour palette (SDL_Color literals)
 * ------------------------------------------------------- */
#define COL_TOPBAR    (SDL_Color){ 36,  42,  60, 255}
#define COL_SIDEBAR   (SDL_Color){ 38,  46,  66, 255}
#define COL_MAIN      (SDL_Color){ 28,  34,  50, 255}
#define COL_TITLEBAR  (SDL_Color){ 30,  36,  54, 255}
#define COL_CARD1     (SDL_Color){ 48,  58,  80, 255}
#define COL_CARD2     (SDL_Color){ 42,  52,  72, 255}
#define COL_CARD3     (SDL_Color){ 36,  46,  64, 255}
#define COL_CONSOLE   (SDL_Color){ 22,  26,  38, 255}
#define COL_DIVIDER   (SDL_Color){ 70,  80, 100, 255}

/* -------------------------------------------------------
 * Application state
 * ------------------------------------------------------- */
static mu_Context  *g_mu;
static swu_context *g_swu;

static float g_bg[3] = { 90, 95, 100 };
static int   g_checks[3] = { 1, 0, 1 };
static char  g_input[256];
static char  g_logbuf[8000];
static int   g_log_updated;

static int g_show_buttons = 1;
static int g_show_checks  = 1;
static int g_show_colors  = 1;
static int g_show_tree    = 0;
static int g_show_font    = 1;

/* Font colour (text R/G/B, 0–255) adjusted via sidebar sliders */
static float g_text_color[3] = { 220, 220, 220 };
/* 0=Normal (14pt styled), 1=Large (18pt) — selected via radio buttons */
static int   g_body_font_size = 0;

static void write_log(const char *text) {
    if (g_logbuf[0])
        strncat(g_logbuf, "\n", sizeof(g_logbuf) - strlen(g_logbuf) - 1);
    strncat(g_logbuf, text, sizeof(g_logbuf) - strlen(g_logbuf) - 1);
    g_log_updated = 1;
}

/* -------------------------------------------------------
 * microui callback wrappers
 * ------------------------------------------------------- */
static int text_width_fn(mu_Font f, const char *t, int len) {
    (void)f; return r_get_text_width(t, len);
}
static int text_height_fn(mu_Font f) {
    (void)f; return r_get_text_height();
}

/* Set font variant immediately (for layout queries) and deferred (for draw).
 * Must be called before any text-measure or text-draw operation. */
static void set_font(mu_Context *ctx, int font_id) {
    r_set_font(font_id);
    mu_push_font(ctx, font_id);
}

/* Radio button — inspired by mu_checkbox but enforces group exclusion.
 * Returns 1 when the user selects this option (caller updates *selected). */
static int mu_radio(mu_Context *ctx, const char *label,
                    int value, int *selected)
{
    char buf[128];
    snprintf(buf, sizeof(buf), "%s  %s",
             (*selected == value) ? "(*)" : "( )", label);
    if (mu_button(ctx, buf)) {
        *selected = value;
        return 1;
    }
    return 0;
}

static int sdl3_key_to_mu(SDL_Keycode key) {
    if (key == SDLK_LSHIFT  || key == SDLK_RSHIFT)  return MU_KEY_SHIFT;
    if (key == SDLK_LCTRL   || key == SDLK_RCTRL)   return MU_KEY_CTRL;
    if (key == SDLK_LALT    || key == SDLK_RALT)     return MU_KEY_ALT;
    if (key == SDLK_RETURN  || key == SDLK_RETURN2)  return MU_KEY_RETURN;
    if (key == SDLK_BACKSPACE)                        return MU_KEY_BACKSPACE;
    if (key == SDLK_LEFT)                             return MU_KEY_LEFT;
    if (key == SDLK_RIGHT)                            return MU_KEY_RIGHT;
    if (key == SDLK_HOME)                             return MU_KEY_HOME;
    if (key == SDLK_END)                              return MU_KEY_END;
    if (key == SDLK_DELETE)                           return MU_KEY_DELETE;
    return 0;
}

static int sdl3_button_to_mu(Uint8 btn) {
    switch (btn) {
        case SDL_BUTTON_LEFT:   return MU_MOUSE_LEFT;
        case SDL_BUTTON_RIGHT:  return MU_MOUSE_RIGHT;
        case SDL_BUTTON_MIDDLE: return MU_MOUSE_MIDDLE;
        default: return 0;
    }
}

/* -------------------------------------------------------
 * Console renderer — one label per line
 * ------------------------------------------------------- */
static void render_console_lines(mu_Context *ctx, const char *log) {
    const char *p = log;
    char line[1024];
    while (*p) {
        const char *nl = strchr(p, '\n');
        int len = nl ? (int)(nl - p) : (int)strlen(p);
        if (len >= (int)sizeof(line)) len = (int)sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = '\0';
        int w = r_get_text_width(line, len);
        if (w < 8) w = 8;
        mu_layout_row(ctx, 1, (int[]){ w + 4 }, 0);
        mu_label(ctx, line);
        p += len;
        if (*p == '\n') p++;
    }
}

/* -------------------------------------------------------
 * Two-pass word-wrapped text renderer (same algorithm as demo 1)
 * ------------------------------------------------------- */
struct _tb_line { const char *start; int len; };

static int collect_lines(mu_Context *ctx, int wrap_w,
                         const char *text,
                         struct _tb_line *lines, int max_lines)
{
    mu_Font font = ctx->style->font;
    int n = 0;
    const char *p = text;
    while (*p && n < max_lines) {
        const char *ls = p;
        int w = 0;
        do {
            const char *word = p;
            while (*p && *p != ' ' && *p != '\n') p++;
            w += ctx->text_width(font, word, (int)(p - word));
            if (w > wrap_w && ls != word) { p = word; break; }
            w += ctx->text_width(font, p, 1);
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

static void render_text_block(mu_Context *ctx, const char *text,
                               int h_opt, int v_align)
{
    mu_Font font      = ctx->style->font;
    int     texth     = ctx->text_height(font);
    int     sb_sz     = ctx->style->scrollbar_size;
    mu_Container *cnt = mu_get_current_container(ctx);
    int panel_h       = cnt->body.h;

    struct _tb_line lines[512];

    int avail_w = cnt->body.w;
    int nlines  = collect_lines(ctx, avail_w, text, lines, 512);
    int total_h = nlines * texth;

    if (total_h > panel_h) {
        int narrow_w = avail_w - sb_sz;
        if (narrow_w < 1) narrow_w = 1;
        nlines  = collect_lines(ctx, narrow_w, text, lines, 512);
        total_h = nlines * texth;
    }

    if (total_h < panel_h) {
        int spacer = 0;
        if (v_align == 1) spacer = (panel_h - total_h) / 2;
        if (v_align == 2) spacer = panel_h - total_h;
        if (spacer > 0) {
            mu_layout_row(ctx, 1, (int[]){ 1 }, spacer);
            mu_layout_next(ctx);
        }
    }

    char buf[512];
    for (int i = 0; i < nlines; i++) {
        int len = lines[i].len;
        if (len >= (int)sizeof(buf)) len = (int)sizeof(buf) - 1;
        memcpy(buf, lines[i].start, len);
        buf[len] = '\0';
        mu_layout_row(ctx, 1, (int[]){ -1 }, texth);
        mu_draw_control_text(ctx, buf, mu_layout_next(ctx), MU_COLOR_TEXT, h_opt);
    }
    (void)avail_w;
}

/* -------------------------------------------------------
 * Helper: create a leaf <div> with fixed size (replaces swu_slot)
 * ------------------------------------------------------- */
static swu_elem_t *slot(swu_context *swu, const char *id, float w, float h) {
    swu_elem_t *el = swu_div(swu, id);
    if (!isnan(w)) swu_css_width(el, w);
    if (!isnan(h)) swu_css_height(el, h);
    swu_css_flex_shrink(el, 0);
    swu_close(swu);
    return el;
}

/* -------------------------------------------------------
 * Build flex layout tree using new CSS/HTML API
 * ------------------------------------------------------- */
static void build_layout(swu_context *swu, int win_w, int win_h) {
    swu_elem_t *el;

    swu_begin(swu, win_w, win_h);

    /* ======== TopBar (ROW, 34px) ======== */
    el = swu_div(swu, "TopBar");
    swu_css_flex_direction(el, SWU_FLEX_ROW);
    swu_css_height(el, 34);
    swu_css_flex_shrink(el, 0);
    swu_css_padding_left(el, 6);
    swu_css_padding_right(el, 6);
    swu_css_padding_top(el, 4);
    swu_css_padding_bottom(el, 4);
    swu_css_align_items(el, SWU_CENTER);
    swu_css_background_color(el, COL_TOPBAR);
    {
        el = slot(swu, "Input", NAN, 26);
        swu_css_flex_grow(el, 1);
        swu_css_flex_shrink(el, 1);
        swu_css_margin_right(el, 6);

        slot(swu, "Submit", 80, 26);
    }
    swu_close(swu); /* TopBar */

    /* ======== Body (ROW, grow 1) ======== */
    el = swu_div(swu, "Body");
    swu_css_flex_direction(el, SWU_FLEX_ROW);
    swu_css_flex_grow(el, 1);
    {
        /* ---- Sidebar (COLUMN, 200px) ---- */
        el = swu_div(swu, "Sidebar");
        swu_css_width(el, 200);
        swu_css_flex_shrink(el, 0);
        swu_css_padding(el, 6);
        swu_css_background_color(el, COL_SIDEBAR);
        {
            /* -- Buttons -- */
            el = slot(swu, "HdrButtons", NAN, 24);
            swu_css_margin_bottom(el, 2);
            if (g_show_buttons) {
                for (int i = 0; i < 3; i++) {
                    char name[16];
                    snprintf(name, sizeof(name), "Btn%d", i);
                    el = slot(swu, name, NAN, 26);
                    swu_css_margin_bottom(el, 2);
                }
            }
            swu_hr(swu, NULL);

            /* -- Checkboxes -- */
            el = slot(swu, "HdrChecks", NAN, 24);
            swu_css_margin_bottom(el, 2);
            if (g_show_checks) {
                for (int i = 0; i < 3; i++) {
                    char name[16];
                    snprintf(name, sizeof(name), "Chk%d", i);
                    el = slot(swu, name, NAN, 22);
                    swu_css_margin_bottom(el, 2);
                }
            }
            swu_hr(swu, NULL);

            /* -- Colors -- */
            el = slot(swu, "HdrColors", NAN, 24);
            swu_css_margin_bottom(el, 2);
            if (g_show_colors) {
                el = slot(swu, "SlR", NAN, 22);
                swu_css_margin_bottom(el, 2);
                el = slot(swu, "SlG", NAN, 22);
                swu_css_margin_bottom(el, 2);
                el = slot(swu, "SlB", NAN, 22);
                swu_css_margin_bottom(el, 2);
                el = slot(swu, "ColorPrev", NAN, 32);
                swu_css_margin_bottom(el, 2);
            }
            swu_hr(swu, NULL);

            /* -- Font Style -- */
            el = slot(swu, "HdrFont", NAN, 24);
            swu_css_margin_bottom(el, 2);
            if (g_show_font) {
                el = slot(swu, "SlTR", NAN, 22);
                swu_css_margin_bottom(el, 2);
                el = slot(swu, "SlTG", NAN, 22);
                swu_css_margin_bottom(el, 2);
                el = slot(swu, "SlTB", NAN, 22);
                swu_css_margin_bottom(el, 2);
                el = slot(swu, "FontColorPrev", NAN, 24);
                swu_css_margin_bottom(el, 4);
                el = slot(swu, "RadioNormal", NAN, 22);
                swu_css_margin_bottom(el, 2);
                el = slot(swu, "RadioHeader", NAN, 22);
                swu_css_margin_bottom(el, 2);
            }
            swu_hr(swu, NULL);

            /* -- Tree -- */
            el = slot(swu, "HdrTree", NAN, 24);
            swu_css_margin_bottom(el, 2);
            if (g_show_tree) {
                el = swu_div(swu, "TreePanel");
                swu_css_flex_grow(el, 1);
                swu_close(swu);
            }
        }
        swu_close(swu); /* Sidebar */

        /* ---- MainContent (COLUMN, grow 1) ---- */
        el = swu_div(swu, "MainContent");
        swu_css_flex_grow(el, 1);
        swu_css_background_color(el, COL_MAIN);
        {
            /* Title bar */
            el = swu_div(swu, "TitleBar");
            swu_css_flex_direction(el, SWU_FLEX_ROW);
            swu_css_height(el, 36);
            swu_css_flex_shrink(el, 0);
            swu_css_padding_left(el, 12);
            swu_css_padding_right(el, 12);
            swu_css_padding_top(el, 4);
            swu_css_padding_bottom(el, 4);
            swu_css_align_items(el, SWU_CENTER);
            swu_css_background_color(el, COL_TITLEBAR);
            {
                el = slot(swu, "Title", NAN, 28);
                swu_css_flex_grow(el, 1);
            }
            swu_close(swu); /* TitleBar */

            /* ContentRows: responsive direction */
            int content_w = win_w - 200;
            swu_flex_direction_t content_dir = (content_w >= RESPONSIVE_BREAKPOINT)
                ? SWU_FLEX_ROW : SWU_FLEX_COLUMN;

            el = swu_div(swu, "ContentRows");
            swu_css_flex_direction(el, content_dir);
            swu_css_flex_grow(el, 1);
            swu_css_padding(el, 8);
            {
                /* Card 1 */
                el = swu_div(swu, "Card1");
                swu_css_flex_grow(el, 1);
                swu_css_padding_left(el, 10);
                swu_css_padding_right(el, 10);
                swu_css_padding_top(el, 8);
                swu_css_padding_bottom(el, 8);
                swu_css_background_color(el, COL_CARD1);
                if (content_dir == SWU_FLEX_ROW)
                    swu_css_margin_right(el, 4);
                else
                    swu_css_margin_bottom(el, 4);
                {
                    el = slot(swu, "Card1Title", NAN, 26);
                    swu_css_margin_bottom(el, 4);

                    el = swu_div(swu, "Card1Body");
                    swu_css_flex_grow(el, 1);
                    swu_close(swu);
                }
                swu_close(swu); /* Card1 */

                /* Card 2 */
                el = swu_div(swu, "Card2");
                swu_css_flex_grow(el, 1);
                swu_css_padding_left(el, 10);
                swu_css_padding_right(el, 10);
                swu_css_padding_top(el, 8);
                swu_css_padding_bottom(el, 8);
                swu_css_background_color(el, COL_CARD2);
                if (content_dir == SWU_FLEX_ROW) {
                    swu_css_margin_left(el, 4);
                    swu_css_margin_right(el, 4);
                } else {
                    swu_css_margin_top(el, 4);
                    swu_css_margin_bottom(el, 4);
                }
                {
                    el = slot(swu, "Card2Title", NAN, 26);
                    swu_css_margin_bottom(el, 4);

                    el = swu_div(swu, "Card2Body");
                    swu_css_flex_grow(el, 1);
                    swu_close(swu);
                }
                swu_close(swu); /* Card2 */

                /* Card 3 */
                el = swu_div(swu, "Card3");
                swu_css_flex_grow(el, 1);
                swu_css_padding_left(el, 10);
                swu_css_padding_right(el, 10);
                swu_css_padding_top(el, 8);
                swu_css_padding_bottom(el, 8);
                swu_css_background_color(el, COL_CARD3);
                if (content_dir == SWU_FLEX_ROW)
                    swu_css_margin_left(el, 4);
                else
                    swu_css_margin_top(el, 4);
                {
                    el = slot(swu, "Card3Title", NAN, 26);
                    swu_css_margin_bottom(el, 4);

                    el = swu_div(swu, "Card3Body");
                    swu_css_flex_grow(el, 1);
                    swu_close(swu);
                }
                swu_close(swu); /* Card3 */
            }
            swu_close(swu); /* ContentRows */

            /* Console (150px) */
            el = swu_div(swu, "ConsoleArea");
            swu_css_height(el, 150);
            swu_css_flex_shrink(el, 0);
            swu_css_background_color(el, COL_CONSOLE);
            {
                el = swu_div(swu, "Console");
                swu_css_flex_grow(el, 1);
                swu_close(swu);
            }
            swu_close(swu); /* ConsoleArea */
        }
        swu_close(swu); /* MainContent */
    }
    swu_close(swu); /* Body */

    swu_layout(swu);
}

/* -------------------------------------------------------
 * Build microui widgets at flex positions
 * ------------------------------------------------------- */
static void build_mu_widgets(swu_context *swu, mu_Context *ctx) {
    mu_begin(ctx);

    mu_Container *cnt = mu_get_container(ctx, "flexui");
    if (cnt) {
        int w = 0, h = 0;
        SDL_GetWindowSize(r_window, &w, &h);
        cnt->rect = mu_rect(0, 0, w, h);
    }
    if (mu_begin_window_ex(ctx, "flexui", mu_rect(0, 0, 960, 640),
            MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOFRAME | MU_OPT_NOSCROLL))
    {
        /* ======== TopBar ======== */
        swu_place(swu, "Input");
        if (mu_textbox(ctx, g_input, sizeof(g_input)) & MU_RES_SUBMIT) {
            mu_set_focus(ctx, ctx->last_id);
            if (g_input[0]) { write_log(g_input); g_input[0] = '\0'; }
        }
        swu_place(swu, "Submit");
        if (mu_button(ctx, "Submit")) {
            if (g_input[0]) { write_log(g_input); g_input[0] = '\0'; }
        }

        /* ======== Sidebar ======== */

        /* -- Buttons -- */
        swu_place(swu, "HdrButtons");
        g_show_buttons = (mu_header_ex(ctx, "Buttons", MU_OPT_EXPANDED) != 0);
        if (g_show_buttons) {
            swu_place(swu, "Btn0");
            if (mu_button(ctx, "Button 1")) write_log("Pressed Button 1");
            swu_place(swu, "Btn1");
            if (mu_button(ctx, "Button 2")) write_log("Pressed Button 2");
            swu_place(swu, "Btn2");
            if (mu_button(ctx, "Popup")) {
                mu_open_popup(ctx, "DemoPopup");
            }
            if (mu_begin_popup(ctx, "DemoPopup")) {
                if (mu_button(ctx, "Option A")) write_log("Selected Option A");
                if (mu_button(ctx, "Option B")) write_log("Selected Option B");
                if (mu_button(ctx, "Option C")) write_log("Selected Option C");
                mu_end_popup(ctx);
            }
        }

        /* -- Checkboxes -- */
        swu_place(swu, "HdrChecks");
        g_show_checks = (mu_header_ex(ctx, "Checkboxes", MU_OPT_EXPANDED) != 0);
        if (g_show_checks) {
            swu_place(swu, "Chk0");
            mu_checkbox(ctx, "Checkbox 1", &g_checks[0]);
            swu_place(swu, "Chk1");
            mu_checkbox(ctx, "Checkbox 2", &g_checks[1]);
            swu_place(swu, "Chk2");
            mu_checkbox(ctx, "Checkbox 3", &g_checks[2]);
        }

        /* -- Colors -- */
        swu_place(swu, "HdrColors");
        g_show_colors = (mu_header_ex(ctx, "Background Color", MU_OPT_EXPANDED) != 0);
        if (g_show_colors) {
            swu_place(swu, "SlR");
            mu_slider_ex(ctx, &g_bg[0], 0, 255, 0, "Red: %.0f", MU_OPT_ALIGNCENTER);
            swu_place(swu, "SlG");
            mu_slider_ex(ctx, &g_bg[1], 0, 255, 0, "Green: %.0f", MU_OPT_ALIGNCENTER);
            swu_place(swu, "SlB");
            mu_slider_ex(ctx, &g_bg[2], 0, 255, 0, "Blue: %.0f", MU_OPT_ALIGNCENTER);

            swu_place(swu, "ColorPrev");
            mu_Rect cr = swu_get_rect(swu, "ColorPrev");
            mu_draw_rect(ctx, cr, mu_color((int)g_bg[0], (int)g_bg[1], (int)g_bg[2], 255));
            {
                char buf[32];
                snprintf(buf, sizeof(buf), "#%02X%02X%02X",
                         (int)g_bg[0], (int)g_bg[1], (int)g_bg[2]);
                mu_draw_control_text(ctx, buf, cr, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
            }
        }

        /* -- Font Style -- */
        swu_place(swu, "HdrFont");
        g_show_font = (mu_header_ex(ctx, "Font Style", MU_OPT_EXPANDED) != 0);
        if (g_show_font) {
            /* Text colour sliders */
            swu_place(swu, "SlTR");
            mu_slider_ex(ctx, &g_text_color[0], 0, 255, 0, "R: %.0f",
                         MU_OPT_ALIGNCENTER);
            swu_place(swu, "SlTG");
            mu_slider_ex(ctx, &g_text_color[1], 0, 255, 0, "G: %.0f",
                         MU_OPT_ALIGNCENTER);
            swu_place(swu, "SlTB");
            mu_slider_ex(ctx, &g_text_color[2], 0, 255, 0, "B: %.0f",
                         MU_OPT_ALIGNCENTER);

            /* Colour preview swatch */
            swu_place(swu, "FontColorPrev");
            mu_Rect fcr = swu_get_rect(swu, "FontColorPrev");
            mu_draw_rect(ctx, fcr,
                mu_color((int)g_text_color[0],
                         (int)g_text_color[1],
                         (int)g_text_color[2], 255));
            {
                char buf2[32];
                snprintf(buf2, sizeof(buf2), "#%02X%02X%02X",
                         (int)g_text_color[0],
                         (int)g_text_color[1],
                         (int)g_text_color[2]);
                mu_Color inv_col = mu_color(
                    255 - (int)g_text_color[0],
                    255 - (int)g_text_color[1],
                    255 - (int)g_text_color[2], 255);
                mu_Color orig_fc = ctx->style->colors[MU_COLOR_TEXT];
                ctx->style->colors[MU_COLOR_TEXT] = inv_col;
                mu_draw_control_text(ctx, buf2, fcr, MU_COLOR_TEXT,
                                     MU_OPT_ALIGNCENTER);
                ctx->style->colors[MU_COLOR_TEXT] = orig_fc;
            }

            /* Size radio buttons */
            swu_place(swu, "RadioNormal");
            if (mu_radio(ctx, "Normal (14pt)", 0, &g_body_font_size))
                write_log("Font size: Normal (14pt)");
            swu_place(swu, "RadioHeader");
            if (mu_radio(ctx, "Large (18pt)", 1, &g_body_font_size))
                write_log("Font size: Large (18pt)");
        }

        /* -- Tree -- */
        swu_place(swu, "HdrTree");
        g_show_tree = (mu_header_ex(ctx, "Tree View", MU_OPT_EXPANDED) != 0);
        if (g_show_tree) {
            swu_place(swu, "TreePanel");
            mu_begin_panel(ctx, "TreePanel");
            mu_layout_row(ctx, 1, (int[]){ -1 }, 0);
            if (mu_begin_treenode(ctx, "Project Root")) {
                if (mu_begin_treenode(ctx, "src")) {
                    mu_label(ctx, "main.c");
                    mu_label(ctx, "utils.c");
                    if (mu_begin_treenode(ctx, "ui")) {
                        mu_label(ctx, "renderer.c");
                        mu_label(ctx, "layout.c");
                        mu_end_treenode(ctx);
                    }
                    mu_end_treenode(ctx);
                }
                if (mu_begin_treenode(ctx, "libs")) {
                    mu_label(ctx, "flex.h");
                    mu_label(ctx, "microui.h");
                    mu_end_treenode(ctx);
                }
                if (mu_begin_treenode(ctx, "build")) {
                    if (mu_button(ctx, "Run Build")) write_log("Build started...");
                    if (mu_button(ctx, "Clean")) write_log("Clean complete.");
                    mu_end_treenode(ctx);
                }
                mu_end_treenode(ctx);
            }
            mu_end_panel(ctx);
        }

        /* ======== Title bar ======== */
        swu_place(swu, "Title");
        set_font(ctx, R_FONT_HEADER);
        mu_draw_control_text(ctx, "SDL WEBUI \xe2\x80\x94 Phase 3b CSS/HTML API",
                             swu_get_rect(swu, "Title"), MU_COLOR_TEXT,
                             MU_OPT_ALIGNCENTER);
        set_font(ctx, R_FONT_NORMAL);

        /* ======== Content cards ======== */

        /* Snapshot style text colour for card bodies */
        mu_Color orig_text = ctx->style->colors[MU_COLOR_TEXT];
        mu_Color body_col  = mu_color((int)g_text_color[0],
                                     (int)g_text_color[1],
                                     (int)g_text_color[2], 255);

        /* Card 1 — left / top — BOLD */
        swu_place(swu, "Card1Title");
        set_font(ctx, R_FONT_HEADER);
        mu_draw_control_text(ctx, "Column 1 \xe2\x80\x94 Bold",
                             swu_get_rect(swu, "Card1Title"), MU_COLOR_TEXT, 0);
        set_font(ctx, R_FONT_NORMAL);

        swu_place(swu, "Card1Body");
        {
            int fid = (g_body_font_size == 1) ? R_FONT_HEADER : R_FONT_BOLD;
            set_font(ctx, fid);
            ctx->style->colors[MU_COLOR_TEXT] = body_col;
            mu_begin_panel(ctx, "Card1Panel");
            render_text_block(ctx,
                "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
                "Maecenas lacinia, sem eu lacinia molestie, mi risus faucibus ipsum, "
                "eu varius magna felis a nulla. Sed in nisl vitae tortor aliquam "
                "interdum. Vestibulum ante ipsum primis in faucibus orci luctus et "
                "ultrices posuere cubilia curae; Donec vehicula augue eu neque "
                "pellentesque, sed auctor nisi congue.",
                0, 0);
            mu_end_panel(ctx);
            ctx->style->colors[MU_COLOR_TEXT] = orig_text;
            set_font(ctx, R_FONT_NORMAL);
        }

        /* Card 2 — center / middle — ITALIC */
        swu_place(swu, "Card2Title");
        set_font(ctx, R_FONT_HEADER);
        mu_draw_control_text(ctx, "Column 2 \xe2\x80\x94 Italic",
                             swu_get_rect(swu, "Card2Title"), MU_COLOR_TEXT,
                             MU_OPT_ALIGNCENTER);
        set_font(ctx, R_FONT_NORMAL);

        swu_place(swu, "Card2Body");
        {
            int fid = (g_body_font_size == 1) ? R_FONT_HEADER : R_FONT_ITALIC;
            set_font(ctx, fid);
            ctx->style->colors[MU_COLOR_TEXT] = body_col;
            mu_begin_panel(ctx, "Card2Panel");
            render_text_block(ctx,
                "Praesent tincidunt luctus est at sollicitudin. Nullam "
                "aliquet diam id libero dignissim, vel feugiat sapien tristique. "
                "Integer euismod urna a mauris molestie, nec convallis nunc fringilla. "
                "Cras sagittis felis eget quam maximus, non lacinia purus bibendum. "
                "Fusce non turpis magna. Aliquam erat volutpat.",
                MU_OPT_ALIGNCENTER, 1);
            mu_end_panel(ctx);
            ctx->style->colors[MU_COLOR_TEXT] = orig_text;
            set_font(ctx, R_FONT_NORMAL);
        }

        /* Card 3 — right / bottom — UNDERLINE */
        swu_place(swu, "Card3Title");
        set_font(ctx, R_FONT_HEADER);
        mu_draw_control_text(ctx, "Column 3 \xe2\x80\x94 Underline",
                             swu_get_rect(swu, "Card3Title"), MU_COLOR_TEXT,
                             MU_OPT_ALIGNRIGHT);
        set_font(ctx, R_FONT_NORMAL);

        swu_place(swu, "Card3Body");
        {
            int fid = (g_body_font_size == 1) ? R_FONT_HEADER : R_FONT_UNDERLINE;
            set_font(ctx, fid);
            ctx->style->colors[MU_COLOR_TEXT] = body_col;
            mu_begin_panel(ctx, "Card3Panel");
            render_text_block(ctx,
                "Fusce gravida lacus cursus mi dignissim, vel euismod enim "
                "suscipit. Etiam consequat lorem nec lacus condimentum, in "
                "commodo velit laoreet. Duis lacinia facilisis nisl, ut "
                "vulputate ligula tristique vitae. Pellentesque habitant morbi "
                "tristique senectus et netus et malesuada fames ac turpis egestas.",
                MU_OPT_ALIGNRIGHT, 2);
            mu_end_panel(ctx);
            ctx->style->colors[MU_COLOR_TEXT] = orig_text;
            set_font(ctx, R_FONT_NORMAL);
        }

        /* ======== Console ======== */
        swu_place(swu, "Console");
        mu_begin_panel(ctx, "Console");
        mu_Container *panel = mu_get_current_container(ctx);
        /* Console text is always yellow, normal style */
        mu_Color orig_console = ctx->style->colors[MU_COLOR_TEXT];
        ctx->style->colors[MU_COLOR_TEXT] = mu_color(255, 215, 0, 255);
        render_console_lines(ctx, g_logbuf);
        ctx->style->colors[MU_COLOR_TEXT] = orig_console;
        mu_end_panel(ctx);
        if (g_log_updated) {
            panel->scroll.y = 1000000;
            g_log_updated = 0;
        }

        mu_end_window(ctx);
    }

    mu_end(ctx);
}

/* -------------------------------------------------------
 * Frame
 * ------------------------------------------------------- */
static void do_frame(void) {
    int w = 0, h = 0;
    SDL_GetWindowSize(r_window, &w, &h);
    if (w < 1 || h < 1) return;

    /* 1. Build flex tree and compute layout */
    build_layout(g_swu, w, h);

    /* 2. Clear screen */
    r_clear(mu_color(24, 28, 42, 255));

    /* 3. Draw container backgrounds */
    swu_render_backgrounds(g_swu);

    /* 4. Build microui widgets at flex positions */
    build_mu_widgets(g_swu, g_mu);

    /* 5. Render microui command list */
    mu_Command *cmd = NULL;
    while (mu_next_command(g_mu, &cmd)) {
        switch (cmd->type) {
            case MU_COMMAND_TEXT: r_draw_text(cmd->text.str, cmd->text.pos, cmd->text.color); break;
            case MU_COMMAND_RECT: r_draw_rect(cmd->rect.rect, cmd->rect.color);               break;
            case MU_COMMAND_ICON: r_draw_icon(cmd->icon.id,   cmd->icon.rect, cmd->icon.color); break;
            case MU_COMMAND_CLIP: r_set_clip_rect(cmd->clip.rect);                            break;
            case MU_COMMAND_FONT: r_set_font(cmd->font.font_id);                              break;
        }
    }

    r_present();

    /* 6. Free the flex tree */
    swu_end(g_swu);
}

/* Event watcher for live resize */
static bool on_resize_event(void *userdata, SDL_Event *event) {
    (void)userdata;
    if (event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
        do_frame();
    }
    return true;
}

/* -------------------------------------------------------
 * Main
 * ------------------------------------------------------- */
int main(int argc, char **argv) {
    (void)argc; (void)argv;

    r_init();
    SDL_SetWindowTitle(r_window, "SDL_webui \xe2\x80\x94 Phase 3b CSS/HTML API");
    SDL_SetWindowSize(r_window, 960, 640);

    SDL_StartTextInput(r_window);

    /* microui init */
    g_mu = SDL_malloc(sizeof(mu_Context));
    mu_init(g_mu);
    g_mu->text_width  = text_width_fn;
    g_mu->text_height = text_height_fn;

    /* swu wrapper init */
    g_swu = swu_init(r_renderer, g_mu);

    write_log("SDL_webui Phase 3b + SDL_ttf font styling.");
    write_log("Column 1=Bold, Column 2=Italic, Column 3=Underline.");
    write_log("Use Font Style panel to change text colour & size.");

    SDL_AddEventWatch(on_resize_event, NULL);

    for (;;) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            switch (e.type) {
                case SDL_EVENT_QUIT:
                    swu_destroy(g_swu);
                    SDL_free(g_mu);
                    SDL_Quit();
                    return 0;

                case SDL_EVENT_MOUSE_MOTION:
                    mu_input_mousemove(g_mu, (int)e.motion.x, (int)e.motion.y);
                    break;

                case SDL_EVENT_MOUSE_WHEEL:
                    mu_input_scroll(g_mu, 0, (int)(e.wheel.y * -30.0f));
                    break;

                case SDL_EVENT_TEXT_INPUT:
                    mu_input_text(g_mu, e.text.text);
                    break;

                case SDL_EVENT_MOUSE_BUTTON_DOWN:
                case SDL_EVENT_MOUSE_BUTTON_UP: {
                    int b = sdl3_button_to_mu(e.button.button);
                    if (b) {
                        if (e.type == SDL_EVENT_MOUSE_BUTTON_DOWN)
                            mu_input_mousedown(g_mu, (int)e.button.x, (int)e.button.y, b);
                        else
                            mu_input_mouseup(g_mu, (int)e.button.x, (int)e.button.y, b);
                    }
                    break;
                }

                case SDL_EVENT_KEY_DOWN:
                case SDL_EVENT_KEY_UP: {
                    int c = sdl3_key_to_mu(e.key.key);
                    /* Ctrl+C / Ctrl+V override */
                    if (e.key.mod & SDL_KMOD_CTRL) {
                        if      (e.key.key == SDLK_C) c = MU_KEY_COPY;
                        else if (e.key.key == SDLK_V) c = MU_KEY_PASTE;
                    }
                    if (c) {
                        if (e.type == SDL_EVENT_KEY_DOWN) mu_input_keydown(g_mu, c);
                        else                              mu_input_keyup(g_mu, c);
                    }
                    break;
                }
            }
        }

        do_frame();
    }
    return 0;
}
