/*
 * nanovg_sdl3.c — NanoVG SDL3 Renderer backend
 *
 * Implements NVGparams callbacks using SDL_RenderGeometry().
 *
 * Fill topology (from nanovg.c internals, confirmed via nanovg_gl.c):
 *   path->fill   → GL_TRIANGLE_FAN   → fan from v[0]
 *   path->stroke → GL_TRIANGLE_STRIP → strip {v[i],v[i+1],v[i+2]}
 *   renderTriangles → GL_TRIANGLES   → packed triples
 *
 * Texture format:
 *   NVG_TEXTURE_ALPHA → stored as SDL_PIXELFORMAT_RGBA32 {255,255,255,alpha}
 *   NVG_TEXTURE_RGBA  → stored as SDL_PIXELFORMAT_RGBA32 as-is
 *
 * renderUpdateTexture receives the FULL atlas buffer; sub-region is extracted
 * using stride = full texture width.
 */

#include <stdlib.h>
#include <string.h>
#include <math.h>

#include <SDL3/SDL.h>
#include "nanovg.h"
#include "nanovg_sdl3.h"

/* ---- Texture store ---- */
#define SDL3NVG_MAX_TEXTURES 128

typedef struct {
    SDL_Texture *tex;
    int          w, h;
    int          type;   /* NVG_TEXTURE_ALPHA or NVG_TEXTURE_RGBA */
    int          flags;
} SDL3NVGtex;

typedef struct {
    SDL_Renderer *renderer;
    SDL3NVGtex    textures[SDL3NVG_MAX_TEXTURES];
    float         view_w, view_h;
} SDL3NVGcontext;

/* ---- Texture helpers ---- */

static int sdl3nvg_alloc_tex(SDL3NVGcontext *s) {
    for (int i = 0; i < SDL3NVG_MAX_TEXTURES; i++) {
        if (!s->textures[i].tex) return i + 1; /* 1-based image handle */
    }
    return 0;
}

static SDL3NVGtex *sdl3nvg_gettex(SDL3NVGcontext *s, int image) {
    int idx = image - 1;
    if (idx < 0 || idx >= SDL3NVG_MAX_TEXTURES) return NULL;
    return &s->textures[idx];
}

/*
 * Expand a packed alpha sub-region to RGBA.
 * src:       full texture alpha buffer (stride = src_full_w bytes per row)
 * dst:       output RGBA buffer, packed w*h*4 bytes
 * x,y,w,h:  sub-region within the full texture
 */
static void sdl3nvg_alpha_subreg_to_rgba(const unsigned char *src,
                                          int src_full_w,
                                          int x, int y, int w, int h,
                                          unsigned char *dst) {
    for (int row = 0; row < h; row++) {
        const unsigned char *srow = src + (y + row) * src_full_w + x;
        unsigned char       *drow = dst  + row * w * 4;
        for (int col = 0; col < w; col++) {
            drow[col * 4 + 0] = 255;
            drow[col * 4 + 1] = 255;
            drow[col * 4 + 2] = 255;
            drow[col * 4 + 3] = srow[col];
        }
    }
}

/* ---- Scissor helper ---- */

/*
 * Apply NVGscissor as SDL clip rect.
 * NVGscissor stores (center, 2x3 transform, half-extents).
 * extent[0] < 0 means "no scissor".
 */
static void sdl3nvg_apply_scissor(SDL3NVGcontext *s, const NVGscissor *sc) {
    if (sc->extent[0] < 0.0f) {
        SDL_SetRenderClipRect(s->renderer, NULL);
        return;
    }
    /*
     * Transform columns: col0 = (xform[0], xform[1]),
     *                    col1 = (xform[2], xform[3])
     * Extent projected onto each axis gives the half-widths.
     */
    float ax = sc->xform[0] * sc->extent[0];
    float ay = sc->xform[1] * sc->extent[0];
    float bx = sc->xform[2] * sc->extent[1];
    float by = sc->xform[3] * sc->extent[1];
    float cx = sc->xform[4];
    float cy = sc->xform[5];

    float minx = cx - fabsf(ax) - fabsf(bx);
    float miny = cy - fabsf(ay) - fabsf(by);
    float maxx = cx + fabsf(ax) + fabsf(bx);
    float maxy = cy + fabsf(ay) + fabsf(by);

    SDL_Rect r = {
        (int)floorf(minx),
        (int)floorf(miny),
        (int)ceilf(maxx - minx),
        (int)ceilf(maxy - miny)
    };
    SDL_SetRenderClipRect(s->renderer, &r);
}

/* ---- Geometry helpers ---- */

/* Convert NVGcolor (float 0-1) to SDL_FColor. */
static SDL_FColor sdl3nvg_col(NVGcolor c) {
    return (SDL_FColor){ c.r, c.g, c.b, c.a };
}

/*
 * Resolve paint → (SDL_Texture*, SDL_FColor).
 * If paint has an image, use that texture and its inner colour as tint.
 * Otherwise, no texture, solid inner colour.
 */
static SDL_Texture *sdl3nvg_resolve_paint(SDL3NVGcontext *s,
                                           const NVGpaint *paint,
                                           SDL_FColor     *out_col) {
    *out_col = sdl3nvg_col(paint->innerColor);
    if (paint->image != 0) {
        SDL3NVGtex *t = sdl3nvg_gettex(s, paint->image);
        if (t && t->tex) return t->tex;
    }
    return NULL;
}

/*
 * Render triangle fan: v[0], v[i-1], v[i] for i = 2..nverts-1
 * (matches GL_TRIANGLE_FAN used by NanoVG for convex fills)
 */
static void sdl3nvg_draw_fan(SDL3NVGcontext *s,
                              const NVGvertex *verts, int nverts,
                              SDL_FColor col, SDL_Texture *tex) {
    if (nverts < 3) return;
    int ntris = nverts - 2;
    SDL_Vertex *sv = (SDL_Vertex *)SDL_malloc(ntris * 3 * sizeof(SDL_Vertex));
    if (!sv) return;

    for (int i = 0; i < ntris; i++) {
        const NVGvertex *v0 = &verts[0];
        const NVGvertex *v1 = &verts[i + 1];
        const NVGvertex *v2 = &verts[i + 2];
        SDL_Vertex *sv0 = &sv[i * 3 + 0];
        SDL_Vertex *sv1 = &sv[i * 3 + 1];
        SDL_Vertex *sv2 = &sv[i * 3 + 2];

        sv0->position.x = v0->x;  sv0->position.y = v0->y;
        sv1->position.x = v1->x;  sv1->position.y = v1->y;
        sv2->position.x = v2->x;  sv2->position.y = v2->y;

        sv0->color = sv1->color = sv2->color = col;

        sv0->tex_coord.x = v0->u;  sv0->tex_coord.y = v0->v;
        sv1->tex_coord.x = v1->u;  sv1->tex_coord.y = v1->v;
        sv2->tex_coord.x = v2->u;  sv2->tex_coord.y = v2->v;
    }
    SDL_RenderGeometry(s->renderer, tex, sv, ntris * 3, NULL, 0);
    SDL_free(sv);
}

/*
 * Render triangle strip: {v[i], v[i+1], v[i+2]} for i = 0..nverts-3
 * (matches GL_TRIANGLE_STRIP used by NanoVG for strokes)
 */
static void sdl3nvg_draw_strip(SDL3NVGcontext *s,
                                const NVGvertex *verts, int nverts,
                                SDL_FColor col, SDL_Texture *tex) {
    if (nverts < 3) return;
    int ntris = nverts - 2;
    SDL_Vertex *sv = (SDL_Vertex *)SDL_malloc(ntris * 3 * sizeof(SDL_Vertex));
    if (!sv) return;

    for (int i = 0; i < ntris; i++) {
        const NVGvertex *va, *vb, *vc;
        /* Flip winding every other triangle to keep front-face consistent */
        if (i & 1) {
            va = &verts[i + 2];
            vb = &verts[i + 1];
            vc = &verts[i];
        } else {
            va = &verts[i];
            vb = &verts[i + 1];
            vc = &verts[i + 2];
        }
        SDL_Vertex *sv0 = &sv[i * 3 + 0];
        SDL_Vertex *sv1 = &sv[i * 3 + 1];
        SDL_Vertex *sv2 = &sv[i * 3 + 2];

        sv0->position.x = va->x;  sv0->position.y = va->y;
        sv1->position.x = vb->x;  sv1->position.y = vb->y;
        sv2->position.x = vc->x;  sv2->position.y = vc->y;

        sv0->color = sv1->color = sv2->color = col;

        sv0->tex_coord.x = va->u;  sv0->tex_coord.y = va->v;
        sv1->tex_coord.x = vb->u;  sv1->tex_coord.y = vb->v;
        sv2->tex_coord.x = vc->u;  sv2->tex_coord.y = vc->v;
    }
    SDL_RenderGeometry(s->renderer, tex, sv, ntris * 3, NULL, 0);
    SDL_free(sv);
}

/*
 * Render pre-packed triangles: 3 vertices per triangle
 * (matches GL_TRIANGLES used by NanoVG for renderTriangles / text)
 */
static void sdl3nvg_draw_triangles(SDL3NVGcontext *s,
                                    const NVGvertex *verts, int nverts,
                                    SDL_FColor col, SDL_Texture *tex) {
    if (nverts < 3) return;
    SDL_Vertex *sv = (SDL_Vertex *)SDL_malloc(nverts * sizeof(SDL_Vertex));
    if (!sv) return;

    for (int i = 0; i < nverts; i++) {
        sv[i].position.x  = verts[i].x;
        sv[i].position.y  = verts[i].y;
        sv[i].color       = col;
        sv[i].tex_coord.x = verts[i].u;
        sv[i].tex_coord.y = verts[i].v;
    }
    SDL_RenderGeometry(s->renderer, tex, sv, nverts, NULL, 0);
    SDL_free(sv);
}

/* ---- NVGparams callbacks ---- */

static int sdl3nvg_cb_create(void *uptr) {
    (void)uptr;
    return 1;
}

static int sdl3nvg_cb_create_texture(void *uptr, int type, int w, int h,
                                      int imageFlags,
                                      const unsigned char *data) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    int handle = sdl3nvg_alloc_tex(s);
    if (!handle) return 0;

    SDL3NVGtex *t = &s->textures[handle - 1];
    t->w     = w;
    t->h     = h;
    t->type  = type;
    t->flags = imageFlags;

    t->tex = SDL_CreateTexture(s->renderer,
                               SDL_PIXELFORMAT_RGBA32,
                               SDL_TEXTUREACCESS_STREAMING, w, h);
    if (!t->tex) return 0;

    SDL_SetTextureBlendMode(t->tex, SDL_BLENDMODE_BLEND);
    if (imageFlags & NVG_IMAGE_NEAREST)
        SDL_SetTextureScaleMode(t->tex, SDL_SCALEMODE_NEAREST);

    if (data) {
        if (type == NVG_TEXTURE_ALPHA) {
            unsigned char *rgba = (unsigned char *)SDL_malloc((size_t)(w * h * 4));
            if (rgba) {
                sdl3nvg_alpha_subreg_to_rgba(data, w, 0, 0, w, h, rgba);
                SDL_UpdateTexture(t->tex, NULL, rgba, w * 4);
                SDL_free(rgba);
            }
        } else {
            SDL_UpdateTexture(t->tex, NULL, data, w * 4);
        }
    }
    return handle;
}

static int sdl3nvg_cb_delete_texture(void *uptr, int image) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    SDL3NVGtex *t = sdl3nvg_gettex(s, image);
    if (!t) return 0;
    if (t->tex) {
        SDL_DestroyTexture(t->tex);
        t->tex = NULL;
    }
    return 1;
}

static int sdl3nvg_cb_update_texture(void *uptr, int image,
                                      int x, int y, int w, int h,
                                      const unsigned char *data) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    SDL3NVGtex *t = sdl3nvg_gettex(s, image);
    if (!t || !t->tex) return 0;

    if (t->type == NVG_TEXTURE_ALPHA) {
        /*
         * data = full atlas buffer (t->w × t->h alpha bytes, row-major).
         * Extract sub-region (x,y,w,h) and convert to RGBA.
         */
        unsigned char *rgba = (unsigned char *)SDL_malloc((size_t)(w * h * 4));
        if (!rgba) return 0;
        sdl3nvg_alpha_subreg_to_rgba(data, t->w, x, y, w, h, rgba);
        SDL_Rect rect = { x, y, w, h };
        SDL_UpdateTexture(t->tex, &rect, rgba, w * 4);
        SDL_free(rgba);
    } else {
        /*
         * data = full RGBA atlas. Sub-region starts at row y, col x.
         * Pitch = t->w * 4 (full texture row stride).
         */
        const unsigned char *src = data + ((size_t)y * (size_t)t->w + (size_t)x) * 4;
        SDL_Rect rect = { x, y, w, h };
        SDL_UpdateTexture(t->tex, &rect, src, t->w * 4);
    }
    return 1;
}

static int sdl3nvg_cb_get_texture_size(void *uptr, int image,
                                        int *w, int *h) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    SDL3NVGtex *t = sdl3nvg_gettex(s, image);
    if (!t) return 0;
    if (w) *w = t->w;
    if (h) *h = t->h;
    return 1;
}

static void sdl3nvg_cb_viewport(void *uptr, float width, float height,
                                 float devicePixelRatio) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    s->view_w = width;
    s->view_h = height;
    (void)devicePixelRatio;
}

static void sdl3nvg_cb_cancel(void *uptr) { (void)uptr; }
static void sdl3nvg_cb_flush(void  *uptr) { (void)uptr; }

static void sdl3nvg_cb_fill(void *uptr,
                              NVGpaint *paint,
                              NVGcompositeOperationState compositeOp,
                              NVGscissor *scissor,
                              float fringe,
                              const float *bounds,
                              const NVGpath *paths,
                              int npaths) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    (void)compositeOp; (void)fringe; (void)bounds;

    SDL_FColor   col;
    SDL_Texture *tex = sdl3nvg_resolve_paint(s, paint, &col);

    sdl3nvg_apply_scissor(s, scissor);

    for (int i = 0; i < npaths; i++) {
        const NVGpath *p = &paths[i];
        if (p->nfill > 0)
            sdl3nvg_draw_fan(s, p->fill, p->nfill, col, tex);
        /* AA fringe strokes emitted with fill op in non-convex mode — ignore */
        if (tex == NULL && p->nstroke > 0)
            sdl3nvg_draw_strip(s, p->stroke, p->nstroke, col, NULL);
    }
}

static void sdl3nvg_cb_stroke(void *uptr,
                                NVGpaint *paint,
                                NVGcompositeOperationState compositeOp,
                                NVGscissor *scissor,
                                float fringe,
                                float strokeWidth,
                                const NVGpath *paths,
                                int npaths) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    (void)compositeOp; (void)fringe; (void)strokeWidth;

    SDL_FColor   col;
    SDL_Texture *tex = sdl3nvg_resolve_paint(s, paint, &col);

    sdl3nvg_apply_scissor(s, scissor);

    for (int i = 0; i < npaths; i++) {
        const NVGpath *p = &paths[i];
        if (p->nstroke > 0)
            sdl3nvg_draw_strip(s, p->stroke, p->nstroke, col, tex);
    }
}

static void sdl3nvg_cb_triangles(void *uptr,
                                   NVGpaint *paint,
                                   NVGcompositeOperationState compositeOp,
                                   NVGscissor *scissor,
                                   const NVGvertex *verts,
                                   int nverts,
                                   float fringe) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    (void)compositeOp; (void)fringe;

    SDL_FColor   col;
    SDL_Texture *tex = sdl3nvg_resolve_paint(s, paint, &col);

    sdl3nvg_apply_scissor(s, scissor);
    sdl3nvg_draw_triangles(s, verts, nverts, col, tex);
}

static void sdl3nvg_cb_delete(void *uptr) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)uptr;
    for (int i = 0; i < SDL3NVG_MAX_TEXTURES; i++) {
        if (s->textures[i].tex) {
            SDL_DestroyTexture(s->textures[i].tex);
            s->textures[i].tex = NULL;
        }
    }
    SDL_free(s);
}

/* ---- Public API ---- */

NVGcontext *nvgCreateSDL3(SDL_Renderer *renderer) {
    SDL3NVGcontext *s = (SDL3NVGcontext *)SDL_calloc(1, sizeof(SDL3NVGcontext));
    if (!s) return NULL;
    s->renderer = renderer;

    NVGparams params;
    memset(&params, 0, sizeof(params));
    params.userPtr              = s;
    params.edgeAntiAlias        = 0;   /* SDL_Renderer has no sub-pixel AA */
    params.renderCreate         = sdl3nvg_cb_create;
    params.renderCreateTexture  = sdl3nvg_cb_create_texture;
    params.renderDeleteTexture  = sdl3nvg_cb_delete_texture;
    params.renderUpdateTexture  = sdl3nvg_cb_update_texture;
    params.renderGetTextureSize = sdl3nvg_cb_get_texture_size;
    params.renderViewport       = sdl3nvg_cb_viewport;
    params.renderCancel         = sdl3nvg_cb_cancel;
    params.renderFlush          = sdl3nvg_cb_flush;
    params.renderFill           = sdl3nvg_cb_fill;
    params.renderStroke         = sdl3nvg_cb_stroke;
    params.renderTriangles      = sdl3nvg_cb_triangles;
    params.renderDelete         = sdl3nvg_cb_delete;

    NVGcontext *ctx = nvgCreateInternal(&params);
    if (!ctx) {
        SDL_free(s);
        return NULL;
    }
    return ctx;
}

void nvgDeleteSDL3(NVGcontext *ctx) {
    nvgDeleteInternal(ctx);
}
