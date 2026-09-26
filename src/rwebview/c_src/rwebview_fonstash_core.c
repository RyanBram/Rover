/*
 * rwebview_fonstash_core.c — Standalone FONScontext for Canvas2D text rendering.
 *
 * Creates a CPU-only fonstash context (no GL atlas) that uses the same
 * FreeType2 backend as the NanoVG fonstash (when compiled with
 * FONS_USE_FREETYPE).  Provides functions to:
 *   - Load fonts by file path
 *   - Measure text width
 *   - Render text to a malloc'd RGBA buffer (drop-in for TTF_RenderText_Blended)
 *
 * The fontstash public API (fonsCreateInternal, fonsAddFont, etc.) is compiled
 * once inside nanovg.c via FONTSTASH_IMPLEMENTATION.  This file only includes
 * the header part for declarations.
 */

#include "fontstash.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ── CPU-only render callbacks (no-ops) ─────────────────────────────────── */
static int  rwf_renderCreate(void* uptr, int w, int h) { (void)uptr;(void)w;(void)h; return 1; }
static int  rwf_renderResize(void* uptr, int w, int h) { (void)uptr;(void)w;(void)h; return 1; }
static void rwf_renderUpdate(void* uptr, int* rect, const unsigned char* data)
    { (void)uptr;(void)rect;(void)data; }
static void rwf_renderDraw(void* uptr, const float* verts, const float* tcoords,
                           const unsigned int* colors, int nverts)
    { (void)uptr;(void)verts;(void)tcoords;(void)colors;(void)nverts; }
static void rwf_renderDelete(void* uptr) { (void)uptr; }

/* ── Global state ───────────────────────────────────────────────────────── */
static FONScontext* g_fons = NULL;

int rw_fons_init(int atlasW, int atlasH)
{
    if (g_fons) return 1;  /* already initialised */
    FONSparams p;
    memset(&p, 0, sizeof(p));
    p.width  = atlasW;
    p.height = atlasH;
    p.flags  = FONS_ZERO_TOPLEFT;
    p.renderCreate = rwf_renderCreate;
    p.renderResize = rwf_renderResize;
    p.renderUpdate = rwf_renderUpdate;
    p.renderDraw   = rwf_renderDraw;
    p.renderDelete = rwf_renderDelete;
    g_fons = fonsCreateInternal(&p);
    return g_fons != NULL;
}

void rw_fons_destroy(void)
{
    if (g_fons) { fonsDeleteInternal(g_fons); g_fons = NULL; }
}

int rw_fons_add_font(const char* name, const char* path)
{
    if (!g_fons) return -1;
    int fid = fonsAddFont(g_fons, name, path, 0);
    return fid;
}

int rw_fons_find_font(const char* name)
{
    if (!g_fons) return -1;
    return fonsGetFontByName(g_fons, name);
}

void rw_fons_set_font(int fontId)
{
    if (g_fons && fontId >= 0) {
        fonsSetFont(g_fons, fontId);
    }
}

void rw_fons_set_size(float size)
{
    if (g_fons) {
        fonsSetSize(g_fons, size);
    }
}

/* Return horizontal advance width of the string. */
float rw_fons_text_width(const char* text)
{
    if (!g_fons || !text || !text[0]) return 0.0f;
    fonsSetAlign(g_fons, FONS_ALIGN_LEFT | FONS_ALIGN_TOP);
    return fonsTextBounds(g_fons, 0, 0, text, NULL, NULL);
}

/* Fill ascender / descender / lineHeight for the current font+size. */
void rw_fons_vert_metrics(float* ascender, float* descender, float* lineh)
{
    if (g_fons) fonsVertMetrics(g_fons, ascender, descender, lineh);
}

/*
 * Render text to a newly-allocated RGBA buffer (pre-multiplied alpha = 0).
 *
 * On success *out_w / *out_h are filled and a calloc'd buffer is returned.
 * Caller must free() the buffer.  Returns NULL on failure / empty text.
 *
 * The output is equivalent to what SDL TTF_RenderText_Blended produces:
 * each pixel has (R,G,B) = fill colour and A = glyph coverage from FreeType.
 */
unsigned char* rw_fons_render_text_rgba(
    const char* text,
    unsigned char colorR, unsigned char colorG, unsigned char colorB,
    int* out_w, int* out_h, int* out_baseline_y)
{
    *out_w = 0;
    *out_h = 0;
    *out_baseline_y = 0;
    if (!g_fons || !text || !text[0]) return NULL;

    /* Use BASELINE alignment so that y=0 sits on the baseline,
       matching the behaviour of SDL_ttf (ascender above, descender below). */
    fonsSetAlign(g_fons, FONS_ALIGN_LEFT | FONS_ALIGN_BASELINE);

    /* ── Compute bounding box ───────────────────────────────────────────── */
    float ascender, descender, lineh;
    fonsVertMetrics(g_fons, &ascender, &descender, &lineh);

    /* If metrics are zero, the font is broken — bail out instead of
       returning a useless 2x2 buffer that causes downstream crashes. */
    if (lineh <= 0.0f) {
        return NULL;
    }

    float bounds[4];
    float advance = fonsTextBounds(g_fons, 0, ascender, text, NULL, bounds);
    (void)advance;

    /* bounds: xmin, ymin, xmax, ymax (FONS_ZERO_TOPLEFT)                  */
    int bw = (int)ceilf(bounds[2] - bounds[0]) + 2;   /* +2 safety margin */
    int bh = (int)ceilf(bounds[3] - bounds[1]) + 2;
    if (bw <= 0 || bh <= 0 || bw > 8192 || bh > 8192) {
        return NULL;
    }

    unsigned char* rgba = (unsigned char*)calloc((size_t)bw * bh * 4, 1);
    if (!rgba) return NULL;

    float ox = -bounds[0];   /* shift so that xmin maps to pixel column 0  */
    float oy = -bounds[1];   /* shift so that ymin maps to pixel row 0     */

    /* ── Pass 1 — rasterise all glyphs into the atlas ───────────────────── */
    FONStextIter iter;
    FONSquad     q;
    fonsTextIterInit(g_fons, &iter, 0, ascender, text, NULL,
                     FONS_GLYPH_BITMAP_REQUIRED);
    while (fonsTextIterNext(g_fons, &iter, &q))
        ;   /* just force rasterisation */

    /* ── Fetch atlas data (stable now — all glyphs cached) ──────────────── */
    int atlasW, atlasH;
    const unsigned char* atlas = fonsGetTextureData(g_fons, &atlasW, &atlasH);
    if (!atlas) { free(rgba); return NULL; }

    /* ── Pass 2 — blit glyph quads from atlas into RGBA buffer ──────────── */
    fonsTextIterInit(g_fons, &iter, 0, ascender, text, NULL,
                     FONS_GLYPH_BITMAP_REQUIRED);
    while (fonsTextIterNext(g_fons, &iter, &q)) {
        /* Quad screen coords (relative to x=0, y=ascender) */
        int qx0 = (int)floorf(q.x0 + ox);
        int qy0 = (int)floorf(q.y0 + oy);
        /* Atlas pixel region */
        int ax0 = (int)(q.s0 * atlasW);
        int ay0 = (int)(q.t0 * atlasH);
        int ax1 = (int)(q.s1 * atlasW);
        int ay1 = (int)(q.t1 * atlasH);
        int gw  = ax1 - ax0;
        int gh  = ay1 - ay0;

        for (int r = 0; r < gh; r++) {
            int dy = qy0 + r;
            if (dy < 0 || dy >= bh) continue;
            int ay = ay0 + r;
            if (ay < 0 || ay >= atlasH) continue;
            for (int c = 0; c < gw; c++) {
                int dx = qx0 + c;
                if (dx < 0 || dx >= bw) continue;
                int ax = ax0 + c;
                if (ax < 0 || ax >= atlasW) continue;
                unsigned char alpha = atlas[ay * atlasW + ax];
                if (alpha == 0) continue;
                int di = (dy * bw + dx) * 4;
                /* Max-blend: if two glyphs overlap (e.g. kerning), keep
                   the higher alpha so we don't double-darken edges. */
                if (alpha > rgba[di + 3]) {
                    rgba[di]     = colorR;
                    rgba[di + 1] = colorG;
                    rgba[di + 2] = colorB;
                    rgba[di + 3] = alpha;
                }
            }
        }
    }

    /* Exact baseline row within the bitmap: baseline was placed at y=ascender,
       then shifted by oy=-bounds[1], so baseline_y = ascender - bounds[1]. */
    *out_baseline_y = (int)roundf(ascender - bounds[1]);
    *out_w = bw;
    *out_h = bh;
    return rgba;
}
