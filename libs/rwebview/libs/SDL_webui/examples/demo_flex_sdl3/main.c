/*
 * SDL_webui Phase 2 — flex layout demo on SDL3
 *
 * Demonstrates the flex CSS flexbox layout engine rendered with SDL3.
 * Adapted from ../flex/demo/FlexDemo/ (Objective-C / macOS) to
 * a cross-platform SDL3 + MinGW C application.
 *
 * Layout tree:
 *   Root (COLUMN, full window, padding 10)
 *   ├── Header   (ROW, 48px, grow 0)
 *   │   ├── Logo   (fixed 100×48)
 *   │   └── NavBar (ROW, grow 1)
 *   ├── Body     (ROW, grow 1, NO wrap — sidebar must never wrap)
 *   │   ├── Sidebar   (COLUMN, 200px fixed, grow 0)
 *   │   │   ├── NavItem1 (32px)
 *   │   │   ├── NavItem2 (32px)
 *   │   │   └── NavItem3 (32px)
 *   │   └── CardsArea (ROW, grow 1, FLEX_WRAP_WRAP — cards reflow here only)
 *   │       ├── Card1 (grow 1, basis configurable, margin 4)
 *   │       ├── Card2 (grow 1, basis configurable, margin 4)
 *   │       └── Card3 (grow 1, basis configurable, margin 4)
 *   └── Footer   (ROW, 32px, grow 0)
 *
 * Text labels: SDL_RenderDebugText (SDL3 built-in 8×8 font, no extra deps).
 *
 * ---------- Configurable wrap mode ----------
 *
 * WRAP_NATURAL     — flex default: cards wrap one-by-one as space narrows.
 *                    With 3 cards @200px min: 3→(2+1)→(1+1+1) stages.
 *
 * WRAP_ALL_AT_ONCE — single breakpoint: as soon as the CardsArea is too
 *                    narrow to fit ALL cards side-by-side at CARD_MIN_W,
 *                    every card immediately wraps to its own row (1-per-row).
 *                    Visually: 3-wide → 3-tall (no intermediate state).
 *
 * To change mode: edit `g_wrap_mode` below.
 * To change the per-card minimum width: edit `CARD_MIN_W`.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>

#include <SDL3/SDL.h>
#include "flex.h"

/* ==========================================================================
 * WRAP MODE — edit here to change behaviour
 * ========================================================================== */

typedef enum {
    /* flex natural: cards wrap one-by-one as space narrows.
     * 3-wide → 2-wide + 1-below → 1-per-row  (two breakpoints) */
    WRAP_NATURAL = 0,

    /* single breakpoint: all cards jump to 1-per-row simultaneously once
     * the combined min-width threshold is crossed.
     * 3-wide → 1-per-row  (one breakpoint) */
    WRAP_ALL_AT_ONCE = 1
} WrapMode;

static const WrapMode g_wrap_mode  = WRAP_ALL_AT_ONCE; /* ← change here */
static const float    CARD_MIN_W   = 200.0f;           /* px per card    */
#define               N_CARDS      3                   /* number of cards */

/* Layout constants (must match build_layout values) */
static const float SIDEBAR_W       = 200.0f;
static const float ROOT_PAD_H      = 20.0f; /* padding_left + padding_right */
static const float CARD_MARGIN_H   = 8.0f;  /* margin_left + margin_right per card */

/* ---------- Color palette (matches original FlexDemo) ---------- */

typedef struct { Uint8 r, g, b; } Color3;

static const Color3 palette[4] = {
    { 200, 200, 200 }, /* light gray */
    { 220,  50,  50 }, /* red        */
    {  50, 100, 220 }, /* blue       */
    {  50, 180,  80 }, /* green      */
};

/* Global color counter — incremented as items are created, mod 4 */
static int g_color_index = 0;

static int pick_color(void) {
    int c = g_color_index % 4;
    g_color_index++;
    return c;
}

/* ---------- Item userdata ---------- */

typedef struct {
    int  color_idx;    /* index into palette[] */
    char name[24];     /* display label */
} ItemData;

static ItemData *item_data_new(int color_idx, const char *name) {
    ItemData *d = (ItemData *)malloc(sizeof(ItemData));
    d->color_idx = color_idx;
    strncpy(d->name, name, sizeof(d->name) - 1);
    d->name[sizeof(d->name) - 1] = '\0';
    return d;
}

/* ---------- Helper: create a named flex item ---------- */

static struct flex_item *make_item(
    const char    *name,
    flex_direction dir,
    float          width, float height,
    float          grow,  float shrink,
    flex_wrap      wrap
) {
    struct flex_item *it = flex_item_new();
    flex_item_set_direction(it, dir);
    flex_item_set_width(it, width);
    flex_item_set_height(it, height);
    flex_item_set_grow(it, grow);
    flex_item_set_shrink(it, shrink);
    flex_item_set_wrap(it, wrap);
    flex_item_set_managed_ptr(it, item_data_new(pick_color(), name));
    return it;
}

/* ---------- Build the demo layout tree ----------
 * Out-params: cards_area_out, cards_out[] receive pointers to the live items
 * so the caller can adjust bases before each flex_layout() call.           */

static struct flex_item *build_layout(float win_w, float win_h,
    struct flex_item **cards_area_out,
    struct flex_item *cards_out[N_CARDS])
{
    g_color_index = 0;

    /* Root: COLUMN, full window, padding 10 */
    struct flex_item *root = make_item("Root", FLEX_DIRECTION_COLUMN, win_w, win_h, 0, 1, FLEX_WRAP_NO_WRAP);
    flex_item_set_padding_left(root, 10);
    flex_item_set_padding_right(root, 10);
    flex_item_set_padding_top(root, 10);
    flex_item_set_padding_bottom(root, 10);

    /* Header: ROW, 48px height, grow 0 */
    struct flex_item *header = make_item("Header", FLEX_DIRECTION_ROW, NAN, 48, 0, 1, FLEX_WRAP_NO_WRAP);
    {
        struct flex_item *logo   = make_item("Logo",   FLEX_DIRECTION_ROW,    100, 48,  0, 0, FLEX_WRAP_NO_WRAP);
        struct flex_item *navbar = make_item("NavBar", FLEX_DIRECTION_COLUMN, NAN, NAN, 1, 1, FLEX_WRAP_NO_WRAP);
        flex_item_add(header, logo);
        flex_item_add(header, navbar);
    }
    flex_item_add(root, header);

    /* Body: ROW, grow 1, NO wrap — Sidebar must never participate in wrapping */
    struct flex_item *body = make_item("Body", FLEX_DIRECTION_ROW, NAN, NAN, 1, 1, FLEX_WRAP_NO_WRAP);
    {
        /* Sidebar: COLUMN, fixed 200px, grow 0 */
        struct flex_item *sidebar = make_item("Sidebar", FLEX_DIRECTION_COLUMN, SIDEBAR_W, NAN, 0, 0, FLEX_WRAP_NO_WRAP);
        flex_item_set_align_items(sidebar, FLEX_ALIGN_STRETCH);
        {
            struct flex_item *nav1 = make_item("NavItem1", FLEX_DIRECTION_ROW, NAN, 32, 0, 0, FLEX_WRAP_NO_WRAP);
            struct flex_item *nav2 = make_item("NavItem2", FLEX_DIRECTION_ROW, NAN, 32, 0, 0, FLEX_WRAP_NO_WRAP);
            struct flex_item *nav3 = make_item("NavItem3", FLEX_DIRECTION_ROW, NAN, 32, 0, 0, FLEX_WRAP_NO_WRAP);
            flex_item_add(sidebar, nav1);
            flex_item_add(sidebar, nav2);
            flex_item_add(sidebar, nav3);
        }
        flex_item_add(body, sidebar);

        /* CardsArea: ROW, grow 1, WRAP — cards reflow within this scope only.
         * align_content=STRETCH: wrapped lines share height equally. */
        struct flex_item *cards_area = make_item("CardsArea", FLEX_DIRECTION_ROW, NAN, NAN, 1, 1, FLEX_WRAP_WRAP);
        *cards_area_out = cards_area;
        {
            for (int i = 0; i < N_CARDS; i++) {
                char name[12];
                SDL_snprintf(name, sizeof(name), "Card%d", i + 1);
                struct flex_item *card = make_item(name, FLEX_DIRECTION_COLUMN, NAN, NAN, 1, 1, FLEX_WRAP_NO_WRAP);
                flex_item_set_basis(card, CARD_MIN_W);
                flex_item_set_margin_left(card,   4);
                flex_item_set_margin_right(card,  4);
                flex_item_set_margin_top(card,    4);
                flex_item_set_margin_bottom(card, 4);
                flex_item_add(cards_area, card);
                cards_out[i] = card;
            }
        }
        flex_item_add(body, cards_area);
    }
    flex_item_add(root, body);

    /* Footer: ROW, 32px height, grow 0 */
    struct flex_item *footer = make_item("Footer", FLEX_DIRECTION_ROW, NAN, 32, 0, 1, FLEX_WRAP_NO_WRAP);
    flex_item_add(root, footer);

    return root;
}

/* ---------- Free ItemData from tree (recursive) ---------- */

static void free_item_data(struct flex_item *item) {
    ItemData *d = (ItemData *)flex_item_get_managed_ptr(item);
    if (d) {
        free(d);
        flex_item_set_managed_ptr(item, NULL);
    }
    unsigned int n = flex_item_count(item);
    for (unsigned int i = 0; i < n; i++) {
        free_item_data(flex_item_child(item, i));
    }
}

/* ---------- Render the flex tree recursively (parent-before-children) ---------- */

static void render_item(SDL_Renderer *renderer, struct flex_item *item,
                        float offset_x, float offset_y)
{
    float x = flex_item_get_frame_x(item) + offset_x;
    float y = flex_item_get_frame_y(item) + offset_y;
    float w = flex_item_get_frame_width(item);
    float h = flex_item_get_frame_height(item);

    ItemData *d = (ItemData *)flex_item_get_managed_ptr(item);
    if (d && w > 0 && h > 0) {
        const Color3 *c = &palette[d->color_idx];

        /* Fill */
        SDL_SetRenderDrawColor(renderer, c->r, c->g, c->b, 255);
        SDL_FRect rect = { x, y, w, h };
        SDL_RenderFillRect(renderer, &rect);

        /* 1px dark border */
        SDL_SetRenderDrawColor(renderer,
            (Uint8)(c->r * 0.55f),
            (Uint8)(c->g * 0.55f),
            (Uint8)(c->b * 0.55f), 255);
        SDL_RenderRect(renderer, &rect);

        /* Label: name (white) */
        SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
        SDL_RenderDebugText(renderer, x + 4.0f, y + 4.0f, d->name);

        /* Label: dimensions (light gray) */
        SDL_SetRenderDrawColor(renderer, 220, 220, 220, 255);
        SDL_RenderDebugTextFormat(renderer, x + 4.0f, y + 14.0f,
            "%.0f x %.0f", w, h);
    }

    /* Recurse — children are positioned relative to this item's top-left */
    unsigned int n = flex_item_count(item);
    for (unsigned int i = 0; i < n; i++) {
        render_item(renderer, flex_item_child(item, i), x, y);
    }
}

/* ---------- Adjust card bases according to wrap mode (call before flex_layout) ----------
 *
 * WRAP_NATURAL:     always basis=CARD_MIN_W; flex wraps cards one by one naturally.
 * WRAP_ALL_AT_ONCE: if area_w < N_CARDS * (CARD_MIN_W + CARD_MARGIN_H),
 *                   set basis = area_w (each card occupies full width → 1-per-row).
 *                   Otherwise basis = CARD_MIN_W (all fit on one row).
 *
 * area_w = win_w minus sidebar and root horizontal padding.
 */
static void prepare_card_bases(struct flex_item *cards[N_CARDS], float win_w) {
    float area_w = win_w - SIDEBAR_W - ROOT_PAD_H;
    if (area_w < 0.0f) area_w = 0.0f;

    float basis;
    if (g_wrap_mode == WRAP_ALL_AT_ONCE) {
        float threshold = (float)N_CARDS * (CARD_MIN_W + CARD_MARGIN_H);
        basis = (area_w < threshold) ? area_w : CARD_MIN_W;
    } else {
        /* WRAP_NATURAL: fixed minimum basis, flex decides wrap naturally */
        basis = CARD_MIN_W;
    }

    for (int i = 0; i < N_CARDS; i++) {
        flex_item_set_basis(cards[i], basis);
    }
}

/* ---------- AppState ---------- */

typedef struct {
    SDL_Window        *window;
    SDL_Renderer      *renderer;
    struct flex_item  *root;
    struct flex_item  *cards[N_CARDS]; /* kept for prepare_card_bases */
} AppState;

static bool resize_event_watch(void *userdata, SDL_Event *event) {
    AppState *state = (AppState *)userdata;
    if (event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
        int w, h;
        SDL_GetWindowSize(state->window, &w, &h);

        flex_item_set_width(state->root, (float)w);
        flex_item_set_height(state->root, (float)h);
        prepare_card_bases(state->cards, (float)w);
        flex_layout(state->root);

        /* Re-render during live resize */
        SDL_SetRenderDrawColor(state->renderer, 40, 40, 40, 255);
        SDL_RenderClear(state->renderer);
        render_item(state->renderer, state->root, 0, 0);
        SDL_RenderPresent(state->renderer);
    }
    return false;
}

/* ---------- Main ---------- */

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    int init_w = 960, init_h = 640;
    SDL_Window *window = SDL_CreateWindow(
        "SDL_webui Phase 2 \xe2\x80\x94 flex layout demo",
        init_w, init_h,
        SDL_WINDOW_RESIZABLE
    );
    if (!window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_Renderer *renderer = SDL_CreateRenderer(window, NULL);
    if (!renderer) {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    /* Build the flex layout tree */
    struct flex_item *cards_area = NULL;
    struct flex_item *cards[N_CARDS] = { NULL };
    struct flex_item *root = build_layout((float)init_w, (float)init_h,
                                         &cards_area, cards);
    prepare_card_bases(cards, (float)init_w);
    flex_layout(root);

    /* Set up live resize event watcher */
    AppState state;
    state.window   = window;
    state.renderer = renderer;
    state.root     = root;
    for (int i = 0; i < N_CARDS; i++) state.cards[i] = cards[i];
    SDL_AddEventWatch(resize_event_watch, &state);

    /* Main loop */
    bool running = true;
    while (running) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            switch (event.type) {
                case SDL_EVENT_QUIT:
                    running = false;
                    break;
                case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED: {
                    int w, h;
                    SDL_GetWindowSize(window, &w, &h);
                    flex_item_set_width(root, (float)w);
                    flex_item_set_height(root, (float)h);
                    prepare_card_bases(cards, (float)w);
                    flex_layout(root);
                    break;
                }
                case SDL_EVENT_KEY_DOWN:
                    if (event.key.key == SDLK_ESCAPE) {
                        running = false;
                    }
                    break;
            }
        }

        /* Clear background (dark gray) */
        SDL_SetRenderDrawColor(renderer, 40, 40, 40, 255);
        SDL_RenderClear(renderer);

        /* Draw the flex layout tree */
        render_item(renderer, root, 0, 0);

        SDL_RenderPresent(renderer);

        /* ~60fps limiter */
        SDL_Delay(16);
    }

    /* Cleanup */
    SDL_RemoveEventWatch(resize_event_watch, &state);
    free_item_data(root);
    flex_item_free(root);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
