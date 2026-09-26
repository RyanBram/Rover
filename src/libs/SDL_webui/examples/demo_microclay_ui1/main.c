/* microclay_ui Phase 3a (v2) — Clay layout driving microui widgets via SDL3.
 *
 * Redesigned layout:
 *   TopBar (input + submit — like a browser URL bar)
 *   Body:  Sidebar (collapsible widget sections) | MainContent
 *          MainContent: Title → Responsive 2-col content → Console log (bottom)
 *   Responsive: two content columns become stacked when window < 700px wide.
 *
 * Integration pattern unchanged:
 *   Clay computes geometry → Clay_GetElementData → mu_layout_set_next → microui widget
 *
 * No upstream files are modified.  Links only -lSDL3 (no TTF/image).
 */

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>

/* microui (from shared source tree) */
#include "../../microui/src/microui.h"

/* Phase-1 renderer (reuse as-is, it exposes r_window / r_renderer) */
#include "../demo_microui_sdl3/renderer_sdl3.h"

/* Clay — header-only, define implementation once */
#define CLAY_IMPLEMENTATION
#include "../../clay/clay.h"

/* -----------------------------------------------------------------------
 * Colour palette
 * --------------------------------------------------------------------- */
#define C_NAVY    (Clay_Color){  32,  40,  58, 255 }
#define C_DARK    (Clay_Color){  44,  54,  74, 255 }
#define C_MID     (Clay_Color){  56,  68,  90, 255 }
#define C_LIGHT   (Clay_Color){  90, 100, 120, 255 }
#define C_ACC     (Clay_Color){ 100, 180, 255, 255 }
#define C_TOPBAR  (Clay_Color){  36,  42,  60, 255 }
#define C_SIDEBAR (Clay_Color){  38,  46,  66, 255 }
#define C_CONTENT (Clay_Color){  28,  34,  50, 255 }
#define C_CARD1   (Clay_Color){  48,  58,  80, 255 }
#define C_CARD2   (Clay_Color){  42,  52,  72, 255 }
#define C_CONSOLE (Clay_Color){  22,  26,  38, 255 }
#define C_DIVIDER (Clay_Color){  70,  80, 100, 255 }
#define C_TITLE   (Clay_Color){  30,  36,  54, 255 }

/* Breakpoint: below this width, 2 columns stack vertically */
#define RESPONSIVE_BREAKPOINT 700

/* -----------------------------------------------------------------------
 * Application state
 * --------------------------------------------------------------------- */
static mu_Context *g_mu;

static float   g_bg[3] = { 90, 95, 100 };
static int     g_checks[3] = { 1, 0, 1 };
static char    g_input[256];
static char    g_logbuf[8000];
static int     g_log_updated;
static float   g_mouse_x, g_mouse_y;
static bool    g_mouse_down;

/* Visibility toggles for collapsible sidebar sections */
static int     g_show_buttons = 1;
static int     g_show_checks  = 1;
static int     g_show_colors  = 1;
static int     g_show_tree    = 1;

static void write_log(const char *text) {
    if (g_logbuf[0]) strncat(g_logbuf, "\n", sizeof(g_logbuf) - strlen(g_logbuf) - 1);
    strncat(g_logbuf, text, sizeof(g_logbuf) - strlen(g_logbuf) - 1);
    g_log_updated = 1;
}

/* -----------------------------------------------------------------------
 * microui callback wrappers
 * --------------------------------------------------------------------- */
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
    if (key == SDLK_BACKSPACE)                       return MU_KEY_BACKSPACE;
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

/* -----------------------------------------------------------------------
 * Minimal clay renderer (rectangles + scissor only, via SDL_Renderer)
 * --------------------------------------------------------------------- */
static void mc_clay_render(SDL_Renderer *ren, Clay_RenderCommandArray cmds) {
    for (int32_t i = 0; i < cmds.length; i++) {
        Clay_RenderCommand *c = Clay_RenderCommandArray_Get(&cmds, i);
        switch (c->commandType) {
            case CLAY_RENDER_COMMAND_TYPE_RECTANGLE: {
                Clay_RectangleRenderData *d = &c->renderData.rectangle;
                SDL_SetRenderDrawColor(ren,
                    (Uint8)d->backgroundColor.r, (Uint8)d->backgroundColor.g,
                    (Uint8)d->backgroundColor.b, (Uint8)d->backgroundColor.a);
                SDL_FRect fr = {
                    c->boundingBox.x, c->boundingBox.y,
                    c->boundingBox.width, c->boundingBox.height
                };
                SDL_RenderFillRect(ren, &fr);
                break;
            }
            case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START: {
                SDL_Rect sr = {
                    (int)c->boundingBox.x, (int)c->boundingBox.y,
                    (int)c->boundingBox.width, (int)c->boundingBox.height
                };
                SDL_SetRenderClipRect(ren, &sr);
                break;
            }
            case CLAY_RENDER_COMMAND_TYPE_SCISSOR_END:
                SDL_SetRenderClipRect(ren, NULL);
                break;
            default:
                break;
        }
    }
}

/* -----------------------------------------------------------------------
 * Clay layout tree
 *
 * Structure:
 *   Root (vertical)
 *   ├── TopBar: [Input textbox] [Submit button]
 *   ├── Body (horizontal)
 *   │   ├── Sidebar (fixed 200px, vertical, scrollable widgets)
 *   │   │   ├── Header "Buttons" (collapsible)
 *   │   │   │   └── SlotBtn1..3
 *   │   │   ├── Header "Checkboxes" (collapsible)
 *   │   │   │   └── SlotChk1..3
 *   │   │   ├── Header "Colors" (collapsible)
 *   │   │   │   └── SlotSlR/G/B + SlotColorPrev
 *   │   │   └── Header "Tree" (collapsible)
 *   │   │       └── SlotTree
 *   │   └── MainContent (grows, vertical)
 *   │       ├── Title bar
 *   │       ├── ContentRows (responsive: LTR if wide, TTB if narrow)
 *   │       │   ├── Card1 (Lorem ipsum content)
 *   │       │   └── Card2 (Lorem ipsum content)
 *   │       └── Console (fixed 150px, log panel at bottom)
 *   └── (no footer — cleaner look)
 * --------------------------------------------------------------------- */
static Clay_RenderCommandArray build_layout(int sw, int sh) {
    Clay_SetLayoutDimensions((Clay_Dimensions){ (float)sw, (float)sh });
    Clay_BeginLayout();

    Clay_Sizing full = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_GROW(0) };
    /* Responsive direction for content columns */
    int content_area_w = sw - 200; /* approximate sidebar width */
    Clay_LayoutDirection row_dir = (content_area_w >= RESPONSIVE_BREAKPOINT)
        ? CLAY_LEFT_TO_RIGHT : CLAY_TOP_TO_BOTTOM;

    CLAY(CLAY_ID("Root"), {
        .layout = { .layoutDirection = CLAY_TOP_TO_BOTTOM, .sizing = full }
    }) {
        /* ============ TopBar ============ */
        CLAY(CLAY_ID("TopBar"), {
            .layout = {
                .layoutDirection = CLAY_LEFT_TO_RIGHT,
                .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(34) },
                .padding = { 6, 6, 4, 4 },
                .childGap = 6,
                .childAlignment = { CLAY_ALIGN_X_LEFT, CLAY_ALIGN_Y_CENTER }
            },
            .backgroundColor = C_TOPBAR
        }) {
            CLAY(CLAY_ID("SlotInput"), {
                .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(26) } }
            }) {}
            CLAY(CLAY_ID("SlotSubmit"), {
                .layout = { .sizing = { .width = CLAY_SIZING_FIXED(80), .height = CLAY_SIZING_FIXED(26) } }
            }) {}
        }

        /* ============ Body: Sidebar | MainContent ============ */
        CLAY(CLAY_ID("Body"), {
            .layout = { .layoutDirection = CLAY_LEFT_TO_RIGHT, .sizing = full }
        }) {
            /* ---- Sidebar ---- */
            CLAY(CLAY_ID("Sidebar"), {
                .layout = {
                    .layoutDirection = CLAY_TOP_TO_BOTTOM,
                    .sizing = { .width = CLAY_SIZING_FIXED(200), .height = CLAY_SIZING_GROW(0) },
                    .padding = { 6, 6, 6, 6 },
                    .childGap = 2
                },
                .backgroundColor = C_SIDEBAR
            }) {
                /* -- Section: Buttons -- */
                CLAY(CLAY_ID("SlotHdrButtons"), {
                    .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(24) } }
                }) {}
                if (g_show_buttons) {
                    CLAY(CLAY_ID("SlotBtn1"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(26) } }
                    }) {}
                    CLAY(CLAY_ID("SlotBtn2"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(26) } }
                    }) {}
                    CLAY(CLAY_ID("SlotBtn3"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(26) } }
                    }) {}
                }

                /* Divider */
                CLAY(CLAY_ID("Div1"), {
                    .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(1) } },
                    .backgroundColor = C_DIVIDER
                }) {}

                /* -- Section: Checkboxes -- */
                CLAY(CLAY_ID("SlotHdrChecks"), {
                    .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(24) } }
                }) {}
                if (g_show_checks) {
                    CLAY(CLAY_ID("SlotChk1"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(22) } }
                    }) {}
                    CLAY(CLAY_ID("SlotChk2"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(22) } }
                    }) {}
                    CLAY(CLAY_ID("SlotChk3"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(22) } }
                    }) {}
                }

                /* Divider */
                CLAY(CLAY_ID("Div2"), {
                    .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(1) } },
                    .backgroundColor = C_DIVIDER
                }) {}

                /* -- Section: Colors -- */
                CLAY(CLAY_ID("SlotHdrColors"), {
                    .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(24) } }
                }) {}
                if (g_show_colors) {
                    CLAY(CLAY_ID("SlotSlR"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(22) } }
                    }) {}
                    CLAY(CLAY_ID("SlotSlG"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(22) } }
                    }) {}
                    CLAY(CLAY_ID("SlotSlB"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(22) } }
                    }) {}
                    CLAY(CLAY_ID("SlotColorPrev"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(32) } }
                    }) {}
                }

                /* Divider */
                CLAY(CLAY_ID("Div3"), {
                    .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(1) } },
                    .backgroundColor = C_DIVIDER
                }) {}

                /* -- Section: Tree demo -- */
                CLAY(CLAY_ID("SlotHdrTree"), {
                    .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(24) } }
                }) {}
                if (g_show_tree) {
                    CLAY(CLAY_ID("SlotTree"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_GROW(0) } }
                    }) {}
                }
            }

            /* ---- MainContent ---- */
            CLAY(CLAY_ID("MainContent"), {
                .layout = {
                    .layoutDirection = CLAY_TOP_TO_BOTTOM,
                    .sizing = full,
                    .padding = { 0, 0, 0, 0 },
                    .childGap = 0
                },
                .backgroundColor = C_CONTENT
            }) {
                /* Title bar */
                CLAY(CLAY_ID("TitleBar"), {
                    .layout = {
                        .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(32) },
                        .padding = { 12, 12, 4, 4 },
                        .childAlignment = { CLAY_ALIGN_X_CENTER, CLAY_ALIGN_Y_CENTER }
                    },
                    .backgroundColor = C_TITLE
                }) {
                    CLAY(CLAY_ID("SlotTitle"), {
                        .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(24) } }
                    }) {}
                }

                /* Responsive content area: two cards side-by-side or stacked */
                CLAY(CLAY_ID("ContentRows"), {
                    .layout = {
                        .layoutDirection = row_dir,
                        .sizing = full,
                        .padding = { 8, 8, 8, 8 },
                        .childGap = 8
                    }
                }) {
                    /* Card 1 */
                    CLAY(CLAY_ID("Card1"), {
                        .layout = {
                            .layoutDirection = CLAY_TOP_TO_BOTTOM,
                            .sizing = full,
                            .padding = { 10, 10, 8, 8 },
                            .childGap = 4
                        },
                        .backgroundColor = C_CARD1
                    }) {
                        CLAY(CLAY_ID("SlotCard1Title"), {
                            .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(20) } }
                        }) {}
                        CLAY(CLAY_ID("SlotCard1Body"), {
                            .layout = { .sizing = full }
                        }) {}
                    }

                    /* Card 2 */
                    CLAY(CLAY_ID("Card2"), {
                        .layout = {
                            .layoutDirection = CLAY_TOP_TO_BOTTOM,
                            .sizing = full,
                            .padding = { 10, 10, 8, 8 },
                            .childGap = 4
                        },
                        .backgroundColor = C_CARD2
                    }) {
                        CLAY(CLAY_ID("SlotCard2Title"), {
                            .layout = { .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(20) } }
                        }) {}
                        CLAY(CLAY_ID("SlotCard2Body"), {
                            .layout = { .sizing = full }
                        }) {}
                    }
                }

                /* Console log at bottom (like VS Code terminal) */
                CLAY(CLAY_ID("Console"), {
                    .layout = {
                        .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_FIXED(150) },
                        .padding = { 0, 0, 0, 0 }
                    },
                    .backgroundColor = C_CONSOLE
                }) {
                    CLAY(CLAY_ID("SlotLog"), {
                        .layout = { .sizing = full }
                    }) {}
                }
            }
        }
    }

    return Clay_EndLayout();
}

/* -----------------------------------------------------------------------
 * Console line renderer — no word-wrap, one label per line.
 * Width is measured per-line so the horizontal scrollbar is proportional.
 * --------------------------------------------------------------------- */
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

/* -----------------------------------------------------------------------
 * Clay → microui rect helper
 * --------------------------------------------------------------------- */
static mu_Rect clay_bb(const char *name) {
    Clay_ElementData d = Clay_GetElementData(
        Clay_GetElementId(CLAY__INIT(Clay_String){ .chars = name, .length = (int32_t)strlen(name) }));
    if (!d.found) return mu_rect(0, 0, 0, 0);
    return mu_rect((int)d.boundingBox.x, (int)d.boundingBox.y,
                   (int)d.boundingBox.width, (int)d.boundingBox.height);
}

static void place(mu_Context *ctx, const char *slot) {
    mu_layout_set_next(ctx, clay_bb(slot), 0); /* 0 = absolute */
}

/* -----------------------------------------------------------------------
 * Build microui widgets, positioned at clay slots
 * --------------------------------------------------------------------- */
static void build_mu_widgets(mu_Context *ctx) {
    mu_begin(ctx);

    /* Full-screen frameless container */
    mu_Container *cnt = mu_get_container(ctx, "microclay");
    if (cnt) {
        int w = 0, h = 0;
        SDL_GetWindowSize(r_window, &w, &h);
        cnt->rect = mu_rect(0, 0, w, h);
    }
    if (mu_begin_window_ex(ctx, "microclay", mu_rect(0, 0, 900, 600),
            MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOFRAME | MU_OPT_NOSCROLL))
    {
        /* ======== TopBar: Input + Submit ======== */
        place(ctx, "SlotInput");
        if (mu_textbox(ctx, g_input, sizeof(g_input)) & MU_RES_SUBMIT) {
            mu_set_focus(ctx, ctx->last_id);
            if (g_input[0]) { write_log(g_input); g_input[0] = '\0'; }
        }
        place(ctx, "SlotSubmit");
        if (mu_button(ctx, "Submit")) {
            if (g_input[0]) { write_log(g_input); g_input[0] = '\0'; }
        }

        /* ======== Sidebar: collapsible sections ======== */

        /* -- Buttons section (mu_header as toggle) -- */
        /* Always pass MU_OPT_EXPANDED so microui's pool is the single source of
         * truth for open/closed state. Changing the opt flag between frames was
         * causing a one-frame oscillation (flicker). */
        place(ctx, "SlotHdrButtons");
        g_show_buttons = (mu_header_ex(ctx, "Buttons", MU_OPT_EXPANDED) != 0);
        if (g_show_buttons) {
            place(ctx, "SlotBtn1");
            if (mu_button(ctx, "Button 1")) write_log("Pressed Button 1");
            place(ctx, "SlotBtn2");
            if (mu_button(ctx, "Button 2")) write_log("Pressed Button 2");
            place(ctx, "SlotBtn3");
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

        /* -- Checkboxes section -- */
        place(ctx, "SlotHdrChecks");
        g_show_checks = (mu_header_ex(ctx, "Checkboxes", MU_OPT_EXPANDED) != 0);
        if (g_show_checks) {
            place(ctx, "SlotChk1");
            mu_checkbox(ctx, "Checkbox 1", &g_checks[0]);
            place(ctx, "SlotChk2");
            mu_checkbox(ctx, "Checkbox 2", &g_checks[1]);
            place(ctx, "SlotChk3");
            mu_checkbox(ctx, "Checkbox 3", &g_checks[2]);
        }

        /* -- Colors section -- */
        place(ctx, "SlotHdrColors");
        g_show_colors = (mu_header_ex(ctx, "Background Color", MU_OPT_EXPANDED) != 0);
        if (g_show_colors) {
            place(ctx, "SlotSlR");
            mu_slider_ex(ctx, &g_bg[0], 0, 255, 0, "Red: %.0f", MU_OPT_ALIGNCENTER);
            place(ctx, "SlotSlG");
            mu_slider_ex(ctx, &g_bg[1], 0, 255, 0, "Green: %.0f", MU_OPT_ALIGNCENTER);
            place(ctx, "SlotSlB");
            mu_slider_ex(ctx, &g_bg[2], 0, 255, 0, "Blue: %.0f", MU_OPT_ALIGNCENTER);

            place(ctx, "SlotColorPrev");
            mu_Rect cr = clay_bb("SlotColorPrev");
            mu_draw_rect(ctx, cr, mu_color((int)g_bg[0], (int)g_bg[1], (int)g_bg[2], 255));
            {
                char buf[32];
                sprintf(buf, "#%02X%02X%02X", (int)g_bg[0], (int)g_bg[1], (int)g_bg[2]);
                mu_draw_control_text(ctx, buf, cr, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
            }
        }

        /* -- Tree demo section -- */
        place(ctx, "SlotHdrTree");
        g_show_tree = (mu_header_ex(ctx, "Tree View", MU_OPT_EXPANDED) != 0);
        if (g_show_tree) {
            place(ctx, "SlotTree");
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
                    mu_label(ctx, "clay.h");
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

        /* ======== Title ======== */
        place(ctx, "SlotTitle");
        mu_draw_control_text(ctx, "MICRO CLAY UI  —  Phase 3a",
                             clay_bb("SlotTitle"), MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);

        /* ======== Content cards (Lorem ipsum) ======== */
        place(ctx, "SlotCard1Title");
        mu_draw_control_text(ctx, "Column 1 — Overview",
                             clay_bb("SlotCard1Title"), MU_COLOR_TEXT, 0);
        place(ctx, "SlotCard1Body");
        mu_begin_panel(ctx, "Card1Panel");
        mu_layout_row(ctx, 1, (int[]){ -1 }, -1);
        mu_text(ctx, "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
            "Maecenas lacinia, sem eu lacinia molestie, mi risus faucibus ipsum, "
            "eu varius magna felis a nulla. Sed in nisl vitae tortor aliquam "
            "interdum. Vestibulum ante ipsum primis in faucibus orci luctus et "
            "ultrices posuere cubilia curae; Donec vehicula augue eu neque "
            "pellentesque, sed auctor nisi congue.");
        mu_end_panel(ctx);

        place(ctx, "SlotCard2Title");
        mu_draw_control_text(ctx, "Column 2 — Details",
                             clay_bb("SlotCard2Title"), MU_COLOR_TEXT, 0);
        place(ctx, "SlotCard2Body");
        mu_begin_panel(ctx, "Card2Panel");
        mu_layout_row(ctx, 1, (int[]){ -1 }, -1);
        mu_text(ctx, "Praesent tincidunt luctus est at sollicitudin. Nullam "
            "aliquet diam id libero dignissim, vel feugiat sapien tristique. "
            "Integer euismod urna a mauris molestie, nec convallis nunc fringilla. "
            "Cras sagittis felis eget quam maximus, non lacinia purus bibendum. "
            "Fusce non turpis magna. Aliquam erat volutpat.");
        mu_end_panel(ctx);

        /* ======== Console log (bottom) ======== */
        /* No word-wrap: render each line individually with measured width.
         * The panel's horizontal scrollbar appears when any line is wider
         * than the panel body.  Auto-scroll uses a large value that microui
         * clamps to the actual content height. */
        place(ctx, "SlotLog");
        mu_begin_panel(ctx, "Console");
        mu_Container *panel = mu_get_current_container(ctx);
        render_console_lines(ctx, g_logbuf);
        mu_end_panel(ctx);
        if (g_log_updated) {
            panel->scroll.y = 1000000; /* clamped to content_size.y - body.h */
            g_log_updated = 0;
        }

        mu_end_window(ctx);
    }

    mu_end(ctx);
}

/* -----------------------------------------------------------------------
 * Combined frame: clay layout → clay bg render → microui widgets → mu render
 * --------------------------------------------------------------------- */
static void do_frame(void) {
    int w = 0, h = 0;
    SDL_GetWindowSize(r_window, &w, &h);
    if (w < 1 || h < 1) return;

    Clay_SetPointerState((Clay_Vector2){ g_mouse_x, g_mouse_y }, g_mouse_down);

    /* 1. Clay layout */
    Clay_RenderCommandArray clay_cmds = build_layout(w, h);

    /* 2. Clear */
    r_clear(mu_color(24, 28, 42, 255));

    /* 3. Clay backgrounds */
    mc_clay_render(r_renderer, clay_cmds);

    /* 4. microui widgets at clay slots */
    build_mu_widgets(g_mu);

    /* 5. Render microui commands */
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
}

/* Event watcher for live resize */
static bool on_resize_event(void *userdata, SDL_Event *event) {
    (void)userdata;
    if (event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
        do_frame();
    }
    return true;
}

/* -----------------------------------------------------------------------
 * Main
 * --------------------------------------------------------------------- */
int main(int argc, char **argv) {
    (void)argc; (void)argv;

    r_init();
    SDL_SetWindowTitle(r_window, "microclay_ui Phase 3a — Clay + microui");
    SDL_SetWindowSize(r_window, 960, 640);

    /* SDL3 text input is opt-in: must call SDL_StartTextInput to receive
     * SDL_EVENT_TEXT_INPUT events (used by mu_textbox / mu_input_text). */
    SDL_StartTextInput(r_window);

    /* Clay init */
    uint32_t clay_mem_size = Clay_MinMemorySize();
    Clay_Arena clay_arena = Clay_CreateArenaWithCapacityAndMemory(
        clay_mem_size, SDL_malloc(clay_mem_size));
    Clay_Initialize(clay_arena, (Clay_Dimensions){ 960, 640 },
                    (Clay_ErrorHandler){ .errorHandlerFunction = NULL });

    /* microui init */
    g_mu = SDL_malloc(sizeof(mu_Context));
    mu_init(g_mu);
    g_mu->text_width  = text_width_fn;
    g_mu->text_height = text_height_fn;

    write_log("microclay_ui Phase 3a v2 ready.");
    write_log("Clay layout + microui widgets + responsive columns.");
    write_log("Try resizing the window narrower than ~900px.");

    SDL_AddEventWatch(on_resize_event, NULL);

    for (;;) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            switch (e.type) {
                case SDL_EVENT_QUIT:
                    SDL_free(g_mu);
                    SDL_Quit();
                    return 0;

                case SDL_EVENT_MOUSE_MOTION:
                    g_mouse_x = e.motion.x;
                    g_mouse_y = e.motion.y;
                    mu_input_mousemove(g_mu, (int)e.motion.x, (int)e.motion.y);
                    break;

                case SDL_EVENT_MOUSE_WHEEL:
                    mu_input_scroll(g_mu, 0, (int)(e.wheel.y * -30.0f));
                    break;

                case SDL_EVENT_TEXT_INPUT:
                    mu_input_text(g_mu, e.text.text);
                    break;

                case SDL_EVENT_MOUSE_BUTTON_DOWN:
                    g_mouse_down = true;
                    /* fall through */
                case SDL_EVENT_MOUSE_BUTTON_UP: {
                    if (e.type == SDL_EVENT_MOUSE_BUTTON_UP) g_mouse_down = false;
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
