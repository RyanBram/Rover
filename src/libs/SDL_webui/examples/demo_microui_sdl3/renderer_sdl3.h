#ifndef RENDERER_SDL3_H
#define RENDERER_SDL3_H

/* microui SDL3 renderer for microclay_ui Phase 1.
 * Drop-in replacement for ../microui/demo/renderer.h targeting SDL3.
 * Uses SDL_Renderer (no OpenGL) — textures, color-mod blending, SDL_RenderFillRect. */

#include "../../src/microui.h"
#include <SDL3/SDL.h>

/* Exposed so main.c can query window size for layout purposes. */
extern SDL_Window   *r_window;
extern SDL_Renderer *r_renderer;

void r_init(void);
void r_draw_rect(mu_Rect rect, mu_Color color);
void r_draw_text(const char *text, mu_Vec2 pos, mu_Color color);
void r_draw_icon(int id, mu_Rect rect, mu_Color color);
 int r_get_text_width(const char *text, int len);
 int r_get_text_height(void);
void r_set_clip_rect(mu_Rect rect);
void r_clear(mu_Color color);
void r_present(void);

#endif /* RENDERER_SDL3_H */
