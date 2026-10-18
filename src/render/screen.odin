package render

// The screen's size, and the play field's inside it (U_Display::Init):
// what everything that draws, and the window, is laid out in.

// The original presents a 416x480 play-field inside a 640x480 screen; the
// terrain runtime configures a 416x480x16 source view. We keep that logical
// size and let raylib scale it to the window. The remaining 224x480 strip on
// the right is the score bar panel (U_Display::GetFrontScorebarRect places it
// immediately after the play field; U_Display::Init hardcodes the screen
// itself to 640x480, not a perm float).
PLAY_W :: 416
PLAY_H :: 480
SCREEN_W :: 640
SCREEN_H :: 480

WINDOW_SCALE :: 2
