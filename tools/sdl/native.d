/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/
module tools.sdl.native;
extern (C) @nogc nothrow {
    const(char)* v_error();
    int v_open(const(char)* title, int width, int height, int hidden);
    void v_close();
    void v_output_size(int* w, int* h);
    float v_pixel_scale();
    void* v_image(const(char)* path);
    void* v_font(const(char)* path);
    void v_font_free(void* font);
    void* v_text(void* font, const(char)* text, float px, int wrap, uint color);
    void v_texture_size(void* texture, float* w, float* h);
    void v_free(void* texture);
    void v_begin(uint color);
    void v_rect(float x, float y, float w, float h, uint color);
    void v_outline(float x, float y, float w, float h, uint color);
    void v_draw(void* texture, float x, float y, float w, float h, int fit, uint tint);
    int v_capture(const(char)* path);
    void v_clip(int x, int y, int w, int h);
    void v_end();
    void v_delay();
    ulong v_ticks();
    void v_volume(float gain);
    void v_fullscreen(int on);
    int v_event(int* key, float* x, float* y, const(char)** text);
    void* v_sound(const(char)* path);
    void v_sound_free(void* sound);
    void* v_channel();
    void v_channel_free(void* track);
    int v_play(void* track, void* sound, int loop);
}
