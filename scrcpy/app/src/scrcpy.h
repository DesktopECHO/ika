#ifndef SCRCPY_H
#define SCRCPY_H

#include "common.h"

#include "options.h"

enum scrcpy_exit_code {
    // Normal program termination
    SCRCPY_EXIT_SUCCESS,

    // No connection could be established
    SCRCPY_EXIT_FAILURE,

    // Device was disconnected while running
    SCRCPY_EXIT_DISCONNECTED,

    // With --ika-game-session, the window left fullscreen or was closed
    SCRCPY_EXIT_GAME_SESSION_ENDED,
};

enum scrcpy_exit_code
scrcpy(struct scrcpy_options *options);

#endif
