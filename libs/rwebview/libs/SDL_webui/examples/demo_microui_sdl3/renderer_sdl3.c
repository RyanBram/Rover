/* microui SDL3 renderer for microclay_ui Phase 1.
 *
 * Replaces the OpenGL-based renderer.c from ../microui/demo/ with an
 * SDL_Renderer backend.  All rendering uses SDL3 draw primitives:
 *   - Solid-color rects  → SDL_RenderFillRect (no texture needed)
 *   - Glyphs / icons     → SDL_RenderTexture  + SDL_SetTextureColorMod
 *   - Clip regions       → SDL_SetRenderClipRect
 *
 * The microui atlas (atlas.inl) is a 128×128 single-channel (alpha-only)
 * bitmap.  We upload it as an RGBA32 texture with white (255,255,255) for
 * every pixel and the atlas byte as the alpha channel.  SDL color-modulation
 * then multiplies those white pixels by the requested draw color.
 */

#include <SDL3/SDL.h>
#include <string.h>
#include "renderer_sdl3.h"
/* atlas.inl defines atlas_texture[], atlas[], ATLAS_WIDTH/HEIGHT, ATLAS_WHITE,
 * ATLAS_FONT enums.  It must be included in exactly one .c file. */
#include "../../src/microui/atlas.inl"

SDL_Window   *r_window   = NULL;
SDL_Renderer *r_renderer = NULL;

static SDL_Texture *atlas_tex = NULL;

/* -------------------------------------------------------------------------
 * Helpers
 * ---------------------------------------------------------------------- */

static SDL_FRect mu_to_frect(mu_Rect r) {
    return (SDL_FRect){ (float)r.x, (float)r.y, (float)r.w, (float)r.h };
}

/* Build RGBA32 atlas texture from the single-channel atlas_texture[] array. */
static SDL_Texture *build_atlas_texture(SDL_Renderer *renderer) {
    /* 4 bytes per pixel: R G B A */
    Uint8 rgba[ATLAS_WIDTH * ATLAS_HEIGHT * 4];
    for (int i = 0; i < ATLAS_WIDTH * ATLAS_HEIGHT; i++) {
        rgba[i * 4 + 0] = 255;              /* R — white base */
        rgba[i * 4 + 1] = 255;              /* G */
        rgba[i * 4 + 2] = 255;              /* B */
        rgba[i * 4 + 3] = atlas_texture[i]; /* A — from atlas */
    }
    SDL_Texture *tex = SDL_CreateTexture(renderer,
        SDL_PIXELFORMAT_RGBA32,
        SDL_TEXTUREACCESS_STATIC,
        ATLAS_WIDTH, ATLAS_HEIGHT);
    if (!tex) {
        SDL_Log("build_atlas_texture: SDL_CreateTexture failed: %s", SDL_GetError());
        return NULL;
    }
    SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
    SDL_UpdateTexture(tex, NULL, rgba, ATLAS_WIDTH * 4);
    return tex;
}

/* -------------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- */

void r_init(void) {
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
        SDL_Log("SDL_Init failed: %s", SDL_GetError());
        SDL_Quit();
        return;
    }

    r_window = SDL_CreateWindow("microui demo (SDL3)", 800, 600,
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

    /* Enable VSync (best-effort; carries on if unavailable). */
    SDL_SetRenderVSync(r_renderer, 1);

    /* Premultiplied-alpha blend for the atlas glyph texture. */
    SDL_SetRenderDrawBlendMode(r_renderer, SDL_BLENDMODE_BLEND);

    atlas_tex = build_atlas_texture(r_renderer);
}

/* Draw a solid filled rectangle — no atlas lookup needed. */
void r_draw_rect(mu_Rect rect, mu_Color color) {
    SDL_SetRenderDrawColor(r_renderer, color.r, color.g, color.b, color.a);
    SDL_FRect fr = mu_to_frect(rect);
    SDL_RenderFillRect(r_renderer, &fr);
}

/* Blit atlas glyphs for each character in `text`. */
void r_draw_text(const char *text, mu_Vec2 pos, mu_Color color) {
    SDL_SetTextureColorMod(atlas_tex, color.r, color.g, color.b);
    SDL_SetTextureAlphaMod(atlas_tex, color.a);

    SDL_FRect dst = { (float)pos.x, (float)pos.y, 0.0f, 0.0f };
    for (const char *p = text; *p; p++) {
        if ((*p & 0xc0) == 0x80) { continue; } /* skip UTF-8 continuation bytes */
        int chr = mu_min((unsigned char)*p, 127);
        mu_Rect src_mu = atlas[ATLAS_FONT + chr];
        SDL_FRect src = mu_to_frect(src_mu);
        dst.w = src.w;
        dst.h = src.h;
        SDL_RenderTexture(r_renderer, atlas_tex, &src, &dst);
        dst.x += dst.w;
    }
}

/* Blit a single icon from the atlas, centred inside `rect`. */
void r_draw_icon(int id, mu_Rect rect, mu_Color color) {
    SDL_SetTextureColorMod(atlas_tex, color.r, color.g, color.b);
    SDL_SetTextureAlphaMod(atlas_tex, color.a);

    mu_Rect src_mu = atlas[id];
    SDL_FRect src = mu_to_frect(src_mu);
    SDL_FRect dst = {
        (float)(rect.x + (rect.w - src_mu.w) / 2),
        (float)(rect.y + (rect.h - src_mu.h) / 2),
        src.w, src.h
    };
    SDL_RenderTexture(r_renderer, atlas_tex, &src, &dst);
}

/* Measure text width by summing per-glyph widths from the atlas. */
int r_get_text_width(const char *text, int len) {
    int res = 0;
    for (const char *p = text; *p && len--; p++) {
        if ((*p & 0xc0) == 0x80) { continue; }
        int chr = mu_min((unsigned char)*p, 127);
        res += atlas[ATLAS_FONT + chr].w;
    }
    return res;
}

/* Fixed glyph height from the atlas (all glyphs are 17px tall). */
int r_get_text_height(void) {
    return 18;
}

/* Set SDL clip rect — no Y-flip needed (SDL_Renderer uses Y-down origin).
 * SDL_SetRenderClipRect takes SDL_Rect (integer), not SDL_FRect. */
void r_set_clip_rect(mu_Rect rect) {
    SDL_Rect ir = { rect.x, rect.y, rect.w, rect.h };
    SDL_SetRenderClipRect(r_renderer, &ir);
}

void r_clear(mu_Color clr) {
    /* Disable clip so the clear covers the entire surface. */
    SDL_SetRenderClipRect(r_renderer, NULL);
    SDL_SetRenderDrawColor(r_renderer, clr.r, clr.g, clr.b, clr.a);
    SDL_RenderClear(r_renderer);
}

void r_present(void) {
    SDL_RenderPresent(r_renderer);
}
