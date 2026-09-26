#ifndef RENDERER_NVG_SDL3_H
#define RENDERER_NVG_SDL3_H

/*
 * renderer_nvg_sdl3.h — NanoVG-based renderer for SDL_webui demo.
 *
 * Drop-in replacement for renderer_sdl3_ttf.h.
 * Same public API; all rendering goes through NanoVG.
 * Font loading, shaping metrics, atlas generation, and glyph rasterization
 * are owned by NanoVG/fontstash.
 *
 * r_clear()   → SDL_RenderClear + nvgBeginFrame
 * r_present() → nvgEndFrame + SDL_RenderPresent
 *
 * All draw calls between r_clear/r_present are batched by NanoVG
 * and flushed (via SDL_RenderGeometry) on nvgEndFrame.
 *
 * SDL_webui background rendering (swu_render_backgrounds) may call
 * SDL_RenderFillRect directly between r_clear and r_present — this is
 * fine because SDL queues are ordered independently of NanoVG batching.
 */

#include "../../src/microui.h"
#include <SDL3/SDL.h>

extern SDL_Window   *r_window;
extern SDL_Renderer *r_renderer;

/* Font variant IDs — pass to r_set_font() / mu_push_font() */
#define R_FONT_NORMAL    0   /* 14pt regular  */
#define R_FONT_BOLD      1   /* 14pt bold     */
#define R_FONT_ITALIC    2   /* 14pt italic   */
#define R_FONT_UNDERLINE 3   /* 14pt underline (regular + drawn line) */
#define R_FONT_HEADER    4   /* 18pt regular  */
#define R_FONT_COUNT     5

void r_init(void);
void r_set_font(int font_id);
void r_draw_rect(mu_Rect rect, mu_Color color);
void r_draw_text(const char *text, mu_Vec2 pos, mu_Color color);
void r_draw_icon(int id, mu_Rect rect, mu_Color color);
int  r_load_image(const char *path);
void r_draw_image(int image, mu_Rect rect, mu_Color color);
int  r_get_text_width(const char *text, int len);
int  r_get_text_height(void);
void r_set_clip_rect(mu_Rect rect);
void r_clear(mu_Color color);
void r_present(void);

#endif /* RENDERER_NVG_SDL3_H */
