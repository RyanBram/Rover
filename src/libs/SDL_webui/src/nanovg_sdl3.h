/*
 * nanovg_sdl3.h — NanoVG SDL3 Renderer backend
 *
 * Renders NanoVG vector paths using SDL_RenderGeometry() instead of OpenGL.
 *
 * Supported:
 *   - Solid colour fills (most UI elements)
 *   - RGBA image fills / image patterns (icons, images)
 *   - Alpha texture triangles (font atlas via stb_truetype — text rendering)
 *   - Scissor clipping mapped to SDL_SetRenderClipRect
 *   - Strokes rendered from NanoVG stroke vertex buffer (triangle strip)
 *
 * Limitations (acceptable for UI use):
 *   - Gradients approximated as solid innerColor
 *   - edgeAntiAlias disabled (SDL_Renderer has no sub-pixel AA)
 *   - Concave non-convex fills may have artefacts (rare in UI)
 *
 * Usage:
 *   NVGcontext *vg = nvgCreateSDL3(renderer);
 *   // per frame:
 *   nvgBeginFrame(vg, w, h, 1.0f);
 *   // ... nvg draw calls ...
 *   nvgEndFrame(vg);
 *   // cleanup:
 *   nvgDeleteSDL3(vg);
 */

#ifndef NANOVG_SDL3_H_
#define NANOVG_SDL3_H_

#include <SDL3/SDL.h>
#include "nanovg.h"

/*
 * Create a NanoVG context backed by an SDL_Renderer.
 * Returns NULL on failure.
 */
NVGcontext* nvgCreateSDL3(SDL_Renderer *renderer);

/*
 * Destroy a context created by nvgCreateSDL3().
 */
void nvgDeleteSDL3(NVGcontext *ctx);

#endif /* NANOVG_SDL3_H_ */
