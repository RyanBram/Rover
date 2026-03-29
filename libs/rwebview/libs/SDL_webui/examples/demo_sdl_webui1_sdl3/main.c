/*
 * SDL_webui demo — flex layout driving microui widgets via swu_* wrapper
 *
 * Uses the immediate-mode SDL_webui API:
 *   swu_begin → open/close/slot → swu_layout → swu_place → mu widget → swu_end
 *
 * Layout tree:
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
 *   │       │   └── Card2 (grow 1)
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

/* Phase-1 SDL3 renderer (exposes r_window, r_renderer) */
#include "../demo_microui_sdl3/renderer_sdl3.h"

/* -------------------------------------------------------
 * Constants
 * ------------------------------------------------------- */
#define RESPONSIVE_BREAKPOINT 700

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
static int g_show_tree    = 1;

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
 * Render multi-line text inside the CURRENT panel using the microui
 * layout system.  This lets the panel's scrollbar engage when text
 * overflows vertically.
 *
 * h_opt  : 0=left, MU_OPT_ALIGNCENTER, MU_OPT_ALIGNRIGHT
 * v_align: 0=top,  1=middle (center),  2=bottom
 *
 * Two-pass wrapping: if the text overflows at body.w, a vertical
 * scrollbar will appear and steal scrollbar_size px. We detect this
 * in-frame and re-wrap at the reduced width, preventing the one-frame
 * "text under scrollbar" artefact.
 * ------------------------------------------------------- */

/* Collect word-wrapped lines of `text` into `lines[]` at wrap-width `w`.
 * Returns the number of lines produced. */
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

    /* Pass 1: wrap at current body width */
    int avail_w = cnt->body.w;
    int nlines  = collect_lines(ctx, avail_w, text, lines, 512);
    int total_h = nlines * texth;

    /* Pass 2: if this would cause vertical overflow, scrollbar appears and
     * steals scrollbar_size px — re-wrap at the narrower width immediately
     * so no one-frame artefact occurs. */
    if (total_h > panel_h) {
        int narrow_w = avail_w - sb_sz;
        if (narrow_w < 1) narrow_w = 1;
        nlines  = collect_lines(ctx, narrow_w, text, lines, 512);
        total_h = nlines * texth;
        avail_w = narrow_w; /* (informational; layout uses -1 width anyway) */
    }

    /* Vertical alignment spacer (only when text fits) */
    if (total_h < panel_h) {
        int spacer = 0;
        if (v_align == 1) spacer = (panel_h - total_h) / 2;
        if (v_align == 2) spacer = panel_h - total_h;
        if (spacer > 0) {
            mu_layout_row(ctx, 1, (int[]){ 1 }, spacer);
            mu_layout_next(ctx);
        }
    }

    /* Render each line through the layout system */
    char buf[512];
    for (int i = 0; i < nlines; i++) {
        int len = lines[i].len;
        if (len >= (int)sizeof(buf)) len = (int)sizeof(buf) - 1;
        memcpy(buf, lines[i].start, len);
        buf[len] = '\0';
        mu_layout_row(ctx, 1, (int[]){ -1 }, texth);
        mu_draw_control_text(ctx, buf, mu_layout_next(ctx), MU_COLOR_TEXT, h_opt);
    }
    (void)avail_w; /* silence unused-variable warning after the pass-2 branch */
}

/* -------------------------------------------------------
 * Build flex layout tree via swu_* API\n * ------------------------------------------------------- */
static void build_layout(swu_context *swu, int win_w, int win_h) {
    struct flex_item *el;

    swu_begin(swu, win_w, win_h);

    /* ======== TopBar (ROW, 34px) ======== */
    el = swu_open_bg(swu, "TopBar", 36, 42, 60, 255);
    flex_item_set_direction(el, FLEX_DIRECTION_ROW);
    flex_item_set_height(el, 34);
    flex_item_set_shrink(el, 0);
    flex_item_set_padding_left(el, 6);
    flex_item_set_padding_right(el, 6);
    flex_item_set_padding_top(el, 4);
    flex_item_set_padding_bottom(el, 4);
    flex_item_set_align_items(el, FLEX_ALIGN_CENTER);
    {
        el = swu_slot(swu, "Input", NAN, 26);
        flex_item_set_grow(el, 1);
        flex_item_set_shrink(el, 1);
        flex_item_set_margin_right(el, 6);

        swu_slot(swu, "Submit", 80, 26);
    }
    swu_close(swu);

    /* ======== Body (ROW, grow 1) ======== */
    el = swu_open(swu, "Body");
    flex_item_set_direction(el, FLEX_DIRECTION_ROW);
    flex_item_set_grow(el, 1);
    {
        /* ---- Sidebar (COLUMN, 200px) ---- */
        el = swu_open_bg(swu, "Sidebar", 38, 46, 66, 255);
        flex_item_set_width(el, 200);
        flex_item_set_shrink(el, 0);
        flex_item_set_padding_left(el, 6);
        flex_item_set_padding_right(el, 6);
        flex_item_set_padding_top(el, 6);
        flex_item_set_padding_bottom(el, 6);
        {
            /* -- Buttons -- */
            el = swu_slot(swu, "HdrButtons", NAN, 24);
            flex_item_set_margin_bottom(el, 2);
            if (g_show_buttons) {
                for (int i = 0; i < 3; i++) {
                    char name[16];
                    snprintf(name, sizeof(name), "Btn%d", i);
                    el = swu_slot(swu, name, NAN, 26);
                    flex_item_set_margin_bottom(el, 2);
                }
            }
            swu_divider(swu, 70, 80, 100);

            /* -- Checkboxes -- */
            el = swu_slot(swu, "HdrChecks", NAN, 24);
            flex_item_set_margin_bottom(el, 2);
            if (g_show_checks) {
                for (int i = 0; i < 3; i++) {
                    char name[16];
                    snprintf(name, sizeof(name), "Chk%d", i);
                    el = swu_slot(swu, name, NAN, 22);
                    flex_item_set_margin_bottom(el, 2);
                }
            }
            swu_divider(swu, 70, 80, 100);

            /* -- Colors -- */
            el = swu_slot(swu, "HdrColors", NAN, 24);
            flex_item_set_margin_bottom(el, 2);
            if (g_show_colors) {
                el = swu_slot(swu, "SlR", NAN, 22);
                flex_item_set_margin_bottom(el, 2);
                el = swu_slot(swu, "SlG", NAN, 22);
                flex_item_set_margin_bottom(el, 2);
                el = swu_slot(swu, "SlB", NAN, 22);
                flex_item_set_margin_bottom(el, 2);
                el = swu_slot(swu, "ColorPrev", NAN, 32);
                flex_item_set_margin_bottom(el, 2);
            }
            swu_divider(swu, 70, 80, 100);

            /* -- Tree -- */
            el = swu_slot(swu, "HdrTree", NAN, 24);
            flex_item_set_margin_bottom(el, 2);
            if (g_show_tree) {
                el = swu_open(swu, "TreePanel");
                flex_item_set_grow(el, 1);
                swu_close(swu);
            }
        }
        swu_close(swu); /* Sidebar */

        /* ---- MainContent (COLUMN, grow 1) ---- */
        el = swu_open_bg(swu, "MainContent", 28, 34, 50, 255);
        flex_item_set_grow(el, 1);
        {
            /* Title bar */
            el = swu_open_bg(swu, "TitleBar", 30, 36, 54, 255);
            flex_item_set_direction(el, FLEX_DIRECTION_ROW);
            flex_item_set_height(el, 32);
            flex_item_set_shrink(el, 0);
            flex_item_set_padding_left(el, 12);
            flex_item_set_padding_right(el, 12);
            flex_item_set_padding_top(el, 4);
            flex_item_set_padding_bottom(el, 4);
            flex_item_set_align_items(el, FLEX_ALIGN_CENTER);
            {
                el = swu_slot(swu, "Title", NAN, 24);
                flex_item_set_grow(el, 1);
            }
            swu_close(swu);

            /* ContentRows: responsive direction */
            int content_w = win_w - 200;
            flex_direction content_dir = (content_w >= RESPONSIVE_BREAKPOINT)
                ? FLEX_DIRECTION_ROW : FLEX_DIRECTION_COLUMN;

            el = swu_open(swu, "ContentRows");
            flex_item_set_direction(el, content_dir);
            flex_item_set_grow(el, 1);
            flex_item_set_padding_left(el, 8);
            flex_item_set_padding_right(el, 8);
            flex_item_set_padding_top(el, 8);
            flex_item_set_padding_bottom(el, 8);
            {
                /* Card 1 */
                el = swu_open_bg(swu, "Card1", 48, 58, 80, 255);
                flex_item_set_grow(el, 1);
                flex_item_set_padding_left(el, 10);
                flex_item_set_padding_right(el, 10);
                flex_item_set_padding_top(el, 8);
                flex_item_set_padding_bottom(el, 8);
                if (content_dir == FLEX_DIRECTION_ROW)
                    flex_item_set_margin_right(el, 4);
                else
                    flex_item_set_margin_bottom(el, 4);
                {
                    el = swu_slot(swu, "Card1Title", NAN, 20);
                    flex_item_set_margin_bottom(el, 4);

                    el = swu_open(swu, "Card1Body");
                    flex_item_set_grow(el, 1);
                    swu_close(swu);
                }
                swu_close(swu);

                /* Card 2 */
                el = swu_open_bg(swu, "Card2", 42, 52, 72, 255);
                flex_item_set_grow(el, 1);
                flex_item_set_padding_left(el, 10);
                flex_item_set_padding_right(el, 10);
                flex_item_set_padding_top(el, 8);
                flex_item_set_padding_bottom(el, 8);
                if (content_dir == FLEX_DIRECTION_ROW) {
                    flex_item_set_margin_left(el, 4);
                    flex_item_set_margin_right(el, 4);
                } else {
                    flex_item_set_margin_top(el, 4);
                    flex_item_set_margin_bottom(el, 4);
                }
                {
                    el = swu_slot(swu, "Card2Title", NAN, 20);
                    flex_item_set_margin_bottom(el, 4);

                    el = swu_open(swu, "Card2Body");
                    flex_item_set_grow(el, 1);
                    swu_close(swu);
                }
                swu_close(swu);

                /* Card 3 */
                el = swu_open_bg(swu, "Card3", 36, 46, 64, 255);
                flex_item_set_grow(el, 1);
                flex_item_set_padding_left(el, 10);
                flex_item_set_padding_right(el, 10);
                flex_item_set_padding_top(el, 8);
                flex_item_set_padding_bottom(el, 8);
                if (content_dir == FLEX_DIRECTION_ROW)
                    flex_item_set_margin_left(el, 4);
                else
                    flex_item_set_margin_top(el, 4);
                {
                    el = swu_slot(swu, "Card3Title", NAN, 20);
                    flex_item_set_margin_bottom(el, 4);

                    el = swu_open(swu, "Card3Body");
                    flex_item_set_grow(el, 1);
                    swu_close(swu);
                }
                swu_close(swu);
            }
            swu_close(swu); /* ContentRows */

            /* Console (150px) */
            el = swu_open_bg(swu, "ConsoleArea", 22, 26, 38, 255);
            flex_item_set_height(el, 150);
            flex_item_set_shrink(el, 0);
            {
                el = swu_open(swu, "Console");
                flex_item_set_grow(el, 1);
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
        mu_draw_control_text(ctx, "SDL WEBUI \xe2\x80\x94 swu_* wrapper (flex + microui)",
                             swu_get_rect(swu, "Title"), MU_COLOR_TEXT,
                             MU_OPT_ALIGNCENTER);

        /* ======== Content cards ======== */

        /* Card 1 — left / top */
        swu_place(swu, "Card1Title");
        mu_draw_control_text(ctx, "Column 1 \xe2\x80\x94 Left / Top",
                             swu_get_rect(swu, "Card1Title"), MU_COLOR_TEXT, 0);
        swu_place(swu, "Card1Body");
        mu_begin_panel(ctx, "Card1Panel");
        render_text_block(ctx,
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
            "Maecenas lacinia, sem eu lacinia molestie, mi risus faucibus ipsum, "
            "eu varius magna felis a nulla. Sed in nisl vitae tortor aliquam "
            "interdum. Vestibulum ante ipsum primis in faucibus orci luctus et "
            "ultrices posuere cubilia curae; Donec vehicula augue eu neque "
            "pellentesque, sed auctor nisi congue.",
            0, 0); /* left, top */
        mu_end_panel(ctx);

        /* Card 2 — center / middle */
        swu_place(swu, "Card2Title");
        mu_draw_control_text(ctx, "Column 2 \xe2\x80\x94 Center / Middle",
                             swu_get_rect(swu, "Card2Title"), MU_COLOR_TEXT,
                             MU_OPT_ALIGNCENTER);
        swu_place(swu, "Card2Body");
        mu_begin_panel(ctx, "Card2Panel");
        render_text_block(ctx,
            "Praesent tincidunt luctus est at sollicitudin. Nullam "
            "aliquet diam id libero dignissim, vel feugiat sapien tristique. "
            "Integer euismod urna a mauris molestie, nec convallis nunc fringilla. "
            "Cras sagittis felis eget quam maximus, non lacinia purus bibendum. "
            "Fusce non turpis magna. Aliquam erat volutpat.",
            MU_OPT_ALIGNCENTER, 1); /* center, middle */
        mu_end_panel(ctx);

        /* Card 3 — right / bottom */
        swu_place(swu, "Card3Title");
        mu_draw_control_text(ctx, "Column 3 \xe2\x80\x94 Right / Bottom",
                             swu_get_rect(swu, "Card3Title"), MU_COLOR_TEXT,
                             MU_OPT_ALIGNRIGHT);
        swu_place(swu, "Card3Body");
        mu_begin_panel(ctx, "Card3Panel");
        render_text_block(ctx,
            "Fusce gravida lacus cursus mi dignissim, vel euismod enim "
            "suscipit. Etiam consequat lorem nec lacus condimentum, in "
            "commodo velit laoreet. Duis lacinia facilisis nisl, ut "
            "vulputate ligula tristique vitae. Pellentesque habitant morbi "
            "tristique senectus et netus et malesuada fames ac turpis egestas.",
            MU_OPT_ALIGNRIGHT, 2); /* right, bottom */
        mu_end_panel(ctx);

        /* ======== Console ======== */
        swu_place(swu, "Console");
        mu_begin_panel(ctx, "Console");
        mu_Container *panel = mu_get_current_container(ctx);
        render_console_lines(ctx, g_logbuf);
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
    SDL_SetWindowTitle(r_window, "SDL_webui \xe2\x80\x94 swu_* wrapper");
    SDL_SetWindowSize(r_window, 960, 640);

    SDL_StartTextInput(r_window);

    /* microui init */
    g_mu = SDL_malloc(sizeof(mu_Context));
    mu_init(g_mu);
    g_mu->text_width  = text_width_fn;
    g_mu->text_height = text_height_fn;

    /* swu wrapper init */
    g_swu = swu_init(r_renderer, g_mu);

    write_log("SDL_webui ready (swu_* wrapper).");
    write_log("flex layout + microui widgets on SDL3.");
    write_log("Try resizing below ~900px width for responsive columns.");

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
