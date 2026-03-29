/*
 * renderer_nvg_sdl3.c — NanoVG-based renderer for SDL_webui / microui.
 *
 * Replaces renderer_sdl3_ttf.c.  Same external API; all rendering
 * uses NanoVG instead of SDL_ttf.
 *
 * Font system
 * -----------
 * NanoVG/fontstash owns font metrics and glyph atlas generation.
 * Each font variant gets its own NanoVG font handle:
 *
 *   R_FONT_NORMAL    → Roboto-Regular.ttf  @ 14pt
 *   R_FONT_BOLD      → Roboto-Bold.ttf     @ 14pt  (falls back to Regular)
 *   R_FONT_ITALIC    → Roboto-Regular.ttf  @ 14pt  (no italic TTF in demo)
 *   R_FONT_UNDERLINE → Roboto-Regular.ttf  @ 14pt  + manual underline rect
 *   R_FONT_HEADER    → Roboto-Regular.ttf  @ 18pt
 *
 * Text positioning
 * ----------------
 * microui passes pos = top-left of the text line.
 * NanoVG nvgText() places the baseline at (x, y).
 * We use NVG_ALIGN_LEFT | NVG_ALIGN_TOP to keep pos = top-left.
 *
 * Frame lifecycle
 * ---------------
 * r_clear()   → SDL_RenderClear  +  nvgBeginFrame
 * r_present() → nvgEndFrame      +  SDL_RenderPresent
 *
 * Icons
 * -----
 * The microui icon atlas (128×128, 1-byte alpha) is uploaded as a
 * NanoVG RGBA image.  r_draw_icon() uses nvgImagePattern + nvgFill
 * to blit each icon glyph with colour tinting.
 */

#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

/* ---- NanoVG header (implementation compiled via nanovg.c in build) ---- */
#include "../../src/nanovg.h"

#include "../../src/nanovg_sdl3.h"
#include "renderer_nvg_sdl3.h"

/* microui atlas (for icons only) */
#include "../../src/microui/atlas.inl"

/* ---- Globals ---- */
SDL_Window   *r_window   = NULL;
SDL_Renderer *r_renderer = NULL;

static NVGcontext *g_vg    = NULL;
static int         g_icon_nvg_image = 0;

#define R_MAX_IMAGES 32
static SDL_Texture *g_images[R_MAX_IMAGES];

/* Per-variant: NanoVG font handle and pixel size */
static int   g_font_fid[R_FONT_COUNT];
static float g_font_size[R_FONT_COUNT] = { 14.f, 14.f, 14.f, 14.f, 18.f };

static int g_active_font = R_FONT_NORMAL;

/* Cached line-height per variant (px), filled after font load */
static float g_font_lineh[R_FONT_COUNT];

/* ---- Internal helpers ---- */

/* Probe NanoVG text metrics for all variants and cache lineh. */
static void cache_font_metrics(void) {
    /* Use a throwaway 1×1 frame just to call nvgTextMetrics */
    nvgBeginFrame(g_vg, 1.0f, 1.0f, 1.0f);
    for (int i = 0; i < R_FONT_COUNT; i++) {
        if (g_font_fid[i] < 0) { g_font_lineh[i] = (int)g_font_size[i]; continue; }
        nvgFontFaceId(g_vg, g_font_fid[i]);
        nvgFontSize(g_vg,   g_font_size[i]);
        float asc, desc, lineh;
        nvgTextMetrics(g_vg, &asc, &desc, &lineh);
        g_font_lineh[i] = lineh;
    }
    nvgCancelFrame(g_vg);
}

/* Attempt to open a file from two candidate paths (with resources/ prefix,
 * then bare name in CWD). Returns the first path that opens. */
static const char *find_resource(const char *name) {
    static char buf[512];
    snprintf(buf, sizeof(buf), "resources/%s", name);
    SDL_IOStream *io = SDL_IOFromFile(buf, "rb");
    if (io) { SDL_CloseIO(io); return buf; }
    return name;
}

/* ---- Public API ---- */

void r_init(void) {
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
        SDL_Log("SDL_Init failed: %s", SDL_GetError());
        return;
    }

    r_window = SDL_CreateWindow("microui demo (SDL3 + NanoVG)",
                                 800, 600,
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

    /* Create NanoVG context backed by SDL3 Renderer */
    g_vg = nvgCreateSDL3(r_renderer);
    if (!g_vg) {
        SDL_Log("nvgCreateSDL3 failed");
        return;
    }

    /* Load font variants */
    g_font_fid[R_FONT_NORMAL]    = nvgCreateFont(g_vg, "normal",
                                        find_resource("Roboto-Regular.ttf"));
    g_font_fid[R_FONT_BOLD]      = nvgCreateFont(g_vg, "bold",
                                        find_resource("Roboto-Bold.ttf"));
    if (g_font_fid[R_FONT_BOLD] < 0)
        g_font_fid[R_FONT_BOLD] = g_font_fid[R_FONT_NORMAL]; /* fallback */

    /* Italic and underline reuse regular font (no italic TTF in demo res) */
    g_font_fid[R_FONT_ITALIC]    = g_font_fid[R_FONT_NORMAL];
    g_font_fid[R_FONT_UNDERLINE] = g_font_fid[R_FONT_NORMAL];

    /* Header is the same face, just a larger size */
    g_font_fid[R_FONT_HEADER]    = g_font_fid[R_FONT_NORMAL];

    cache_font_metrics();

    /* Upload microui icon atlas as NanoVG RGBA image */
    unsigned char rgba[ATLAS_WIDTH * ATLAS_HEIGHT * 4];
    for (int i = 0; i < ATLAS_WIDTH * ATLAS_HEIGHT; i++) {
        rgba[i * 4 + 0] = 255;
        rgba[i * 4 + 1] = 255;
        rgba[i * 4 + 2] = 255;
        rgba[i * 4 + 3] = atlas_texture[i];
    }
    g_icon_nvg_image = nvgCreateImageRGBA(g_vg, ATLAS_WIDTH, ATLAS_HEIGHT,
                                           NVG_IMAGE_NEAREST, rgba);
}

void r_set_font(int font_id) {
    if (font_id >= 0 && font_id < R_FONT_COUNT)
        g_active_font = font_id;
}

void r_draw_rect(mu_Rect rect, mu_Color color) {
    nvgBeginPath(g_vg);
    nvgRect(g_vg, (float)rect.x, (float)rect.y,
                  (float)rect.w, (float)rect.h);
    nvgFillColor(g_vg, nvgRGBA(color.r, color.g, color.b, color.a));
    nvgFill(g_vg);
}

void r_draw_text(const char *text, mu_Vec2 pos, mu_Color color) {
    int fid = g_font_fid[g_active_font];
    if (fid < 0) return;

    nvgFontFaceId(g_vg, fid);
    nvgFontSize(g_vg,   g_font_size[g_active_font]);
    nvgTextAlign(g_vg,  NVG_ALIGN_LEFT | NVG_ALIGN_TOP);
    nvgFillColor(g_vg,  nvgRGBA(color.r, color.g, color.b, color.a));
    nvgText(g_vg, (float)pos.x, (float)pos.y, text, NULL);

    /* Underline variant: draw a thin rect under the text */
    if (g_active_font == R_FONT_UNDERLINE) {
        float bounds[4];
        nvgTextBounds(g_vg, (float)pos.x, (float)pos.y, text, NULL, bounds);
        float uy = bounds[3] - 1.0f;
        nvgBeginPath(g_vg);
        nvgRect(g_vg, bounds[0], uy, bounds[2] - bounds[0], 1.0f);
        nvgFillColor(g_vg, nvgRGBA(color.r, color.g, color.b, color.a));
        nvgFill(g_vg);
    }
}

void r_draw_icon(int icon_id, mu_Rect rect, mu_Color color) {
    if (g_icon_nvg_image <= 0) return;

    mu_Rect src = atlas[icon_id];

    /* Centre the icon glyph inside dest rect */
    float dst_x = (float)rect.x + (float)(rect.w - src.w) * 0.5f;
    float dst_y = (float)rect.y + (float)(rect.h - src.h) * 0.5f;

    /*
     * nvgImagePattern(ox, oy, ex, ey, angle, image, alpha)
     * ox,oy = top-left of the whole atlas in screen space
     * ex,ey = size of the whole atlas in screen space
     * The pattern maps the (u,v) coords of each pixel from [0,1] into
     * the atlas, so positioning the atlas correctly maps src.x,src.y
     * to dst_x,dst_y.
     */
    float ox = dst_x - (float)src.x;
    float oy = dst_y - (float)src.y;

    NVGpaint img = nvgImagePattern(g_vg,
                                    ox, oy,
                                    (float)ATLAS_WIDTH,
                                    (float)ATLAS_HEIGHT,
                                    0.0f,
                                    g_icon_nvg_image,
                                    color.a / 255.0f);
    /*
     * innerColor carries the tint; the backend multiplies vertex color
     * by the texture sample, so set it to the desired icon colour.
     */
    img.innerColor = nvgRGBAf(color.r / 255.0f,
                               color.g / 255.0f,
                               color.b / 255.0f,
                               color.a / 255.0f);
    img.outerColor = img.innerColor;

    nvgBeginPath(g_vg);
    nvgRect(g_vg, dst_x, dst_y, (float)src.w, (float)src.h);
    nvgFillPaint(g_vg, img);
    nvgFill(g_vg);
}

int r_load_image(const char *path) {
    if (!r_renderer || !path || !path[0]) return 0;
    for (int i = 1; i < R_MAX_IMAGES; i++) {
        if (!g_images[i]) {
            SDL_Texture *tex = IMG_LoadTexture(r_renderer, find_resource(path));
            if (!tex) return 0;
            SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
            g_images[i] = tex;
            return i;
        }
    }
    return 0;
}

void r_draw_image(int image, mu_Rect rect, mu_Color color) {
    if (image <= 0 || image >= R_MAX_IMAGES || !g_images[image]) return;
    if (rect.w <= 0 || rect.h <= 0) return;

    float img_w = 0.0f;
    float img_h = 0.0f;
    SDL_GetTextureSize(g_images[image], &img_w, &img_h);
    if (img_w <= 0 || img_h <= 0) return;

    float scale = fminf((float)rect.w / img_w,
                        (float)rect.h / img_h);
    float draw_w = img_w * scale;
    float draw_h = img_h * scale;
    float draw_x = (float)rect.x + ((float)rect.w - draw_w) * 0.5f;
    float draw_y = (float)rect.y + ((float)rect.h - draw_h) * 0.5f;

    SDL_SetTextureColorMod(g_images[image], color.r, color.g, color.b);
    SDL_SetTextureAlphaMod(g_images[image], color.a);
    SDL_FRect dst = { draw_x, draw_y, draw_w, draw_h };
    SDL_RenderTexture(r_renderer, g_images[image], NULL, &dst);
}

int r_get_text_width(const char *text, int len) {
    int fid = g_font_fid[g_active_font];
    if (fid < 0) return 0;

    nvgFontFaceId(g_vg, fid);
    nvgFontSize(g_vg,   g_font_size[g_active_font]);
    nvgTextAlign(g_vg,  NVG_ALIGN_LEFT | NVG_ALIGN_TOP);

    const char *end = (len >= 0) ? (text + len) : NULL;
    float advance = nvgTextBounds(g_vg, 0.0f, 0.0f, text, end, NULL);
    return (int)ceilf(advance);
}

int r_get_text_height(void) {
    return (int)ceilf(g_font_lineh[g_active_font]);
}

void r_set_clip_rect(mu_Rect rect) {
    /*
     * microui sends a full-window rect to "reset" clipping; detect that
     * by checking whether the rect covers more than a very large area.
     * In practice just call nvgScissor always — NanoVG clips correctly.
     */
    if (rect.w <= 0 || rect.h <= 0) {
        nvgResetScissor(g_vg);
    } else {
        nvgScissor(g_vg,
                   (float)rect.x, (float)rect.y,
                   (float)rect.w, (float)rect.h);
    }
}

void r_clear(mu_Color clr) {
    nvgResetScissor(g_vg);
    SDL_SetRenderDrawColor(r_renderer, clr.r, clr.g, clr.b, clr.a);
    SDL_RenderClear(r_renderer);

    int w = 0, h = 0;
    SDL_GetWindowSize(r_window, &w, &h);
    nvgBeginFrame(g_vg, (float)w, (float)h, 1.0f);
}

void r_present(void) {
    nvgEndFrame(g_vg);
    SDL_RenderPresent(r_renderer);
}
