/* SDL_webui renderer — SDL3 + SDL_ttf backend.
 *
 * Drop-in replacement for renderer_sdl3.c using SDL_ttf for text.
 * Supports multiple font variants (normal, bold, italic, underline, header).
 * At init all printable ASCII glyphs (32–126) are pre-rendered per variant
 * into individual textures with white foreground; SDL color-mod tints them
 * at draw time.  Icons still come from the original microui bitmap atlas.
 */

#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <string.h>
#include "renderer_sdl3_ttf.h"

/* atlas.inl provides atlas_texture[], atlas[], ATLAS_WIDTH/HEIGHT, and
 * icon rect entries (MU_ICON_*).  We use it only for icons, not font. */
#include "../../src/microui/atlas.inl"

SDL_Window   *r_window   = NULL;
SDL_Renderer *r_renderer = NULL;

/* ---- Icon atlas (bitmap, for check/close/collapse/expand icons) ---- */
static SDL_Texture *icon_tex = NULL;

/* ---- Per-variant font objects and glyph caches ---- */
static TTF_Font *fonts[R_FONT_COUNT];
static int       font_heights[R_FONT_COUNT];
static int       active_font = R_FONT_NORMAL;

/* Per-glyph texture cache — one small texture per printable ASCII char */
typedef struct {
    SDL_Texture *tex;
    int w, h;
    int advance;
} CachedGlyph;

static CachedGlyph glyph_caches[R_FONT_COUNT][128];

/* ---- helpers ---- */
static SDL_FRect mu_to_frect(mu_Rect r) {
    return (SDL_FRect){ (float)r.x, (float)r.y, (float)r.w, (float)r.h };
}

/* Build the icon atlas from the original bitmap (same as renderer_sdl3.c). */
static SDL_Texture *build_icon_atlas(SDL_Renderer *renderer) {
    Uint8 rgba[ATLAS_WIDTH * ATLAS_HEIGHT * 4];
    for (int i = 0; i < ATLAS_WIDTH * ATLAS_HEIGHT; i++) {
        rgba[i * 4 + 0] = 255;
        rgba[i * 4 + 1] = 255;
        rgba[i * 4 + 2] = 255;
        rgba[i * 4 + 3] = atlas_texture[i];
    }
    SDL_Texture *tex = SDL_CreateTexture(renderer,
        SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC,
        ATLAS_WIDTH, ATLAS_HEIGHT);
    if (tex) {
        SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
        SDL_UpdateTexture(tex, NULL, rgba, ATLAS_WIDTH * 4);
    }
    return tex;
}

/* Pre-render every printable ASCII glyph for font variant fidx. */
static void build_font_cache(int fidx) {
    SDL_Color white = { 255, 255, 255, 255 };
    TTF_Font *fnt   = fonts[fidx];
    if (!fnt) return;
    memset(glyph_caches[fidx], 0, sizeof(glyph_caches[fidx]));

    for (int ch = 32; ch < 127; ch++) {
        char c = (char)ch;
        int w = 0, h = 0;
        TTF_GetStringSize(fnt, &c, 1, &w, &h);
        glyph_caches[fidx][ch].advance = w;

        SDL_Surface *sfc = TTF_RenderGlyph_Blended(fnt, (Uint32)ch, white);
        if (sfc) {
            SDL_Texture *tex = SDL_CreateTextureFromSurface(r_renderer, sfc);
            if (tex) {
                SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
                glyph_caches[fidx][ch].tex = tex;
                glyph_caches[fidx][ch].w   = sfc->w;
                glyph_caches[fidx][ch].h   = sfc->h;
            }
            SDL_DestroySurface(sfc);
        }
    }
}

/* -------------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- */

void r_init(void) {
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
        SDL_Log("SDL_Init failed: %s", SDL_GetError());
        return;
    }

    if (!TTF_Init()) {
        SDL_Log("TTF_Init failed: %s", SDL_GetError());
        return;
    }

    r_window = SDL_CreateWindow("microui demo (SDL3+TTF)", 800, 600,
                                SDL_WINDOW_RESIZABLE);
    if (!r_window) {
        SDL_Log("SDL_CreateWindow failed: %s", SDL_GetError());
        return;
    }

    r_renderer = SDL_CreateRenderer(r_window, NULL);
    if (!r_renderer) {
        SDL_Log("SDL_CreateRenderer failed: %s", SDL_GetError());
        return;
    }

    SDL_SetRenderVSync(r_renderer, 1);
    SDL_SetRenderDrawBlendMode(r_renderer, SDL_BLENDMODE_BLEND);

    /* Icon atlas (bitmap) */
    icon_tex = build_icon_atlas(r_renderer);

    /* Resolve font path */
    const char *font_path = "resources/Roboto-Regular.ttf";
    {
        SDL_IOStream *io = SDL_IOFromFile(font_path, "rb");
        if (!io) font_path = "Roboto-Regular.ttf";
        else SDL_CloseIO(io);
    }

    /* Load font variants:
     *   [0] NORMAL    — 14pt regular
     *   [1] BOLD      — 14pt bold
     *   [2] ITALIC    — 14pt italic
     *   [3] UNDERLINE — 14pt underline
     *   [4] HEADER    — 18pt regular  */
    const float sizes[R_FONT_COUNT]  = { 14.f, 14.f, 14.f, 14.f, 18.f };
    const int   styles[R_FONT_COUNT] = {
        TTF_STYLE_NORMAL,
        TTF_STYLE_BOLD,
        TTF_STYLE_ITALIC,
        TTF_STYLE_UNDERLINE,
        TTF_STYLE_NORMAL
    };

    for (int i = 0; i < R_FONT_COUNT; i++) {
        fonts[i] = TTF_OpenFont(font_path, sizes[i]);
        if (!fonts[i]) {
            SDL_Log("TTF_OpenFont [%d] failed: %s", i, SDL_GetError());
            continue;
        }
        TTF_SetFontStyle(fonts[i], styles[i]);
        font_heights[i] = TTF_GetFontHeight(fonts[i]);
        build_font_cache(i);
    }
}

void r_set_font(int font_id) {
    if (font_id >= 0 && font_id < R_FONT_COUNT)
        active_font = font_id;
}

void r_draw_rect(mu_Rect rect, mu_Color color) {
    SDL_SetRenderDrawColor(r_renderer, color.r, color.g, color.b, color.a);
    SDL_FRect fr = mu_to_frect(rect);
    SDL_RenderFillRect(r_renderer, &fr);
}

void r_draw_text(const char *text, mu_Vec2 pos, mu_Color color) {
    CachedGlyph *cache = glyph_caches[active_font];
    float x = (float)pos.x;
    float y = (float)pos.y;
    for (const char *p = text; *p; p++) {
        if ((*p & 0xc0) == 0x80) { continue; } /* skip UTF-8 continuation */
        unsigned char ch = (unsigned char)*p;
        if (ch >= 127) ch = '?';
        CachedGlyph *g = &cache[ch];
        if (g->tex) {
            SDL_SetTextureColorMod(g->tex, color.r, color.g, color.b);
            SDL_SetTextureAlphaMod(g->tex, color.a);
            SDL_FRect dst = { x, y, (float)g->w, (float)g->h };
            SDL_RenderTexture(r_renderer, g->tex, NULL, &dst);
        }
        x += (float)g->advance;
    }
}

void r_draw_icon(int id, mu_Rect rect, mu_Color color) {
    SDL_SetTextureColorMod(icon_tex, color.r, color.g, color.b);
    SDL_SetTextureAlphaMod(icon_tex, color.a);
    mu_Rect src_mu = atlas[id];
    SDL_FRect src = mu_to_frect(src_mu);
    SDL_FRect dst = {
        (float)(rect.x + (rect.w - src_mu.w) / 2),
        (float)(rect.y + (rect.h - src_mu.h) / 2),
        src.w, src.h
    };
    SDL_RenderTexture(r_renderer, icon_tex, &src, &dst);
}

int r_get_text_width(const char *text, int len) {
    CachedGlyph *cache = glyph_caches[active_font];
    int res = 0;
    for (const char *p = text; *p && len--; p++) {
        if ((*p & 0xc0) == 0x80) { continue; }
        unsigned char ch = (unsigned char)*p;
        if (ch >= 127) ch = '?';
        res += cache[ch].advance;
    }
    return res;
}

int r_get_text_height(void) {
    return font_heights[active_font];
}

void r_set_clip_rect(mu_Rect rect) {
    SDL_Rect ir = { rect.x, rect.y, rect.w, rect.h };
    SDL_SetRenderClipRect(r_renderer, &ir);
}

void r_clear(mu_Color clr) {
    SDL_SetRenderClipRect(r_renderer, NULL);
    SDL_SetRenderDrawColor(r_renderer, clr.r, clr.g, clr.b, clr.a);
    SDL_RenderClear(r_renderer);
}

void r_present(void) {
    SDL_RenderPresent(r_renderer);
}

