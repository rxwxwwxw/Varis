/* Varis SDL3 presentation bridge. Copyright (C) 2026 Varis contributors.
 * See LICENSE. SDL owns its graphics/audio resources; no Lua objects cross this ABI. */
#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_mixer/SDL_mixer.h>
#include <stdlib.h>

static SDL_Window *window;
static SDL_Renderer *renderer;
static TTF_Font *font;
static MIX_Mixer *mixer;

const char *v_error(void) { return SDL_GetError(); }
int v_open(const char *title, const char *font_path, float size, int hidden) {
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) || !TTF_Init() || !MIX_Init()) return 0;
    if (!SDL_CreateWindowAndRenderer(title, 1280, 720,
            SDL_WINDOW_RESIZABLE | (hidden ? SDL_WINDOW_HIDDEN : 0), &window, &renderer)) return 0;
    if (!SDL_SetRenderLogicalPresentation(renderer, 1280, 720, SDL_LOGICAL_PRESENTATION_LETTERBOX)) return 0;
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
    font = TTF_OpenFont(font_path, size);
    if (!font) return 0;
    mixer = MIX_CreateMixerDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, NULL);
    if (!mixer) return 0;
    SDL_StartTextInput(window);
    return 1;
}
void v_close(void) {
    if (mixer) MIX_DestroyMixer(mixer);
    mixer = NULL;
    if (font) TTF_CloseFont(font);
    font = NULL;
    if (renderer) SDL_DestroyRenderer(renderer);
    renderer = NULL;
    if (window) SDL_DestroyWindow(window);
    window = NULL;
    MIX_Quit(); TTF_Quit(); SDL_Quit();
}
void *v_image(const char *path) { return IMG_LoadTexture(renderer, path); }
void *v_text(const char *text, int wrap, unsigned color) {
    if (!*text) return NULL;
    SDL_Color c = {color >> 24, color >> 16, color >> 8, color};
    SDL_Surface *s = TTF_RenderText_Blended_Wrapped(font, text, 0, c, wrap);
    if (!s) return NULL;
    SDL_Texture *t = SDL_CreateTextureFromSurface(renderer, s);
    SDL_DestroySurface(s);
    return t;
}
/* Extra font sizes: the player opens one handle per size. */
void *v_font(const char *path, float size) { return TTF_OpenFont(path, size); }
void v_font_free(void *f) { if (f) TTF_CloseFont(f); }
void *v_text_font(void *f, const char *text, int wrap, unsigned color) {
    if (!*text) return NULL;
    SDL_Color c = {color >> 24, color >> 16, color >> 8, color};
    SDL_Surface *s = TTF_RenderText_Blended_Wrapped(f, text, 0, c, wrap);
    if (!s) return NULL;
    SDL_Texture *t = SDL_CreateTextureFromSurface(renderer, s);
    SDL_DestroySurface(s);
    return t;
}
void v_text_size(void *texture, float *w, float *h) { SDL_GetTextureSize(texture, w, h); }
void v_free(void *texture) { if (texture) SDL_DestroyTexture(texture); }
void v_begin(void) { SDL_SetRenderDrawColor(renderer, 14, 20, 34, 255); SDL_RenderClear(renderer); }
void v_rect(float x, float y, float w, float h, unsigned color) {
    SDL_SetRenderDrawColor(renderer, color >> 24, color >> 16, color >> 8, color);
    SDL_FRect r = {x,y,w,h}; SDL_RenderFillRect(renderer, &r);
}
/* fit: 0 stretch, 1 contain (bottom anchored), 2 natural size (top anchored). */
void v_draw(void *texture, float x, float y, float w, float h, int fit, float alpha) {
    if (!texture) return;
    float tw, th; SDL_GetTextureSize(texture, &tw, &th);
    if (fit == 1) {
        float scale = SDL_min(w / tw, h / th);
        x += (w - tw * scale) / 2; y += h - th * scale;
        w = tw * scale; h = th * scale;
    } else if (fit == 2) { w = tw; h = th; }
    SDL_SetTextureAlphaModFloat(texture, alpha);
    SDL_FRect r = {x,y,w,h}; SDL_RenderTexture(renderer, texture, NULL, &r);
}
int v_capture(const char *path) {
    SDL_Surface *s = SDL_RenderReadPixels(renderer, NULL);
    if (!s) return 0;
    int ok = SDL_SaveBMP(s, path); SDL_DestroySurface(s); return ok;
}
void v_outline(float x, float y, float w, float h, unsigned color) {
    SDL_SetRenderDrawColor(renderer, color >> 24, color >> 16, color >> 8, color);
    SDL_FRect r = {x,y,w,h}; SDL_RenderRect(renderer, &r);
}
void v_volume(float gain) { if (mixer) MIX_SetMixerGain(mixer, gain); }
void v_fullscreen(int on) { if (window) SDL_SetWindowFullscreen(window, on != 0); }
void v_clip(int x, int y, int w, int h) {
    SDL_Rect r = {x,y,w,h}; SDL_SetRenderClipRect(renderer, w ? &r : NULL);
}
void v_end(void) { SDL_RenderPresent(renderer); }
void v_delay(void) { SDL_Delay(16); }
unsigned long long v_ticks(void) { return SDL_GetTicks(); }
/* 1 quit, 2 advance, 3 backspace, 4 text, 5 click, 6 key, 7 motion, 8 wheel (key = +-1). */
int v_event(int *key, float *x, float *y, const char **text) {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        *key = 0; *text = NULL;
        if (e.type == SDL_EVENT_QUIT) return 1;
        if (e.type == SDL_EVENT_KEY_DOWN && !e.key.repeat) {
            *key = e.key.key;
            if (*key == SDLK_ESCAPE) return 6;
            if (*key == SDLK_BACKSPACE) return 3;
            if (*key == SDLK_RETURN || *key == SDLK_SPACE) return 2;
            return 6;
        }
        if (e.type == SDL_EVENT_MOUSE_MOTION) {
            SDL_RenderCoordinatesFromWindow(renderer, e.motion.x, e.motion.y, x, y); return 7;
        }
        if (e.type == SDL_EVENT_MOUSE_WHEEL) { *key = e.wheel.y > 0 ? 1 : -1; return 8; }
        if (e.type == SDL_EVENT_TEXT_INPUT) { *text = e.text.text; return 4; }
        if (e.type == SDL_EVENT_MOUSE_BUTTON_DOWN && e.button.button == SDL_BUTTON_LEFT) {
            SDL_RenderCoordinatesFromWindow(renderer, e.button.x, e.button.y, x, y); return 5;
        }
    }
    return 0;
}
void *v_sound(const char *path) { return MIX_LoadAudio(mixer, path, true); }
void v_sound_free(void *sound) { if (sound) MIX_DestroyAudio(sound); }
void *v_channel(void) { return MIX_CreateTrack(mixer); }
void v_channel_free(void *track) { if (track) MIX_DestroyTrack(track); }
int v_play(void *track, void *sound, int loop) {
    if (!sound) return MIX_StopTrack(track, 0);
    if (!MIX_SetTrackAudio(track, sound)) return 0;
    SDL_PropertiesID props = SDL_CreateProperties();
    SDL_SetNumberProperty(props, MIX_PROP_PLAY_LOOPS_NUMBER, loop ? -1 : 0);
    int ok = MIX_PlayTrack(track, props); SDL_DestroyProperties(props); return ok;
}
