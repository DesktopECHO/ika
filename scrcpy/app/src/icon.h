#ifndef SC_ICON_H
#define SC_ICON_H

#include "common.h"

#include <SDL3/SDL_surface.h>

#define SC_ICON_FILENAME_SCRCPY "scrcpy.png"
#define SC_ICON_FILENAME_DISCONNECTED "disconnected.png"

SDL_Surface *
sc_icon_load(const char *filename);

// Load the icon of the window: IKA_WINDOW_ICON (the icon of an Ika app window),
// or the scrcpy icon
SDL_Surface *
sc_icon_load_window(void);

void
sc_icon_destroy(SDL_Surface *icon);

#endif
