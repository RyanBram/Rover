#ifndef RENDERER_SDL3_TTF_H
#define RENDERER_SDL3_TTF_H

/* SDL_webui renderer — SDL3 + SDL_ttf backend.
 * Same API as renderer_sdl3.h but uses SDL_ttf for text rendering
 * instead of the fixed-size bitmap atlas. */

#include "../../src/microui.h"
#include <SDL3/SDL.h>

extern SDL_Window   *r_window;
extern SDL_Renderer *r_renderer;

/* Font variant IDs — pass to r_set_font() / mu_push_font() */
#define R_FONT_NORMAL    0  /* 14pt regular */
#define R_FONT_BOLD      1  /* 14pt bold    */
#define R_FONT_ITALIC    2  /* 14pt italic  */
#define R_FONT_UNDERLINE 3  /* 14pt underline */
#define R_FONT_HEADER    4  /* 18pt regular — for titles/headers */
#define R_FONT_COUNT     5

void r_init(void);
void r_set_font(int font_id);       /* change active font (immediate effect) */
void r_draw_rect(mu_Rect rect, mu_Color color);
void r_draw_text(const char *text, mu_Vec2 pos, mu_Color color);
void r_draw_icon(int id, mu_Rect rect, mu_Color color);
 int r_get_text_width(const char *text, int len);
 int r_get_text_height(void);
void r_set_clip_rect(mu_Rect rect);
void r_clear(mu_Color color);
void r_present(void);

#endif /* RENDERER_SDL3_TTF_H */
