// M5Stack StopWatch: the character's drawing (stopwatch_draw.cpp), shared with the screen task (stopwatch_ui.cpp).
#pragma once
#ifdef M5_STOPWATCH
#include <M5Unified.h>
#include "src/ui/sw_face.h"
#include "src/ui/sw_model.h"

extern M5Canvas *canvas;  // the whole screen, in PSRAM
namespace sw {
extern int W, H, CX, CY;  // the screen's size and centre
}
static const uint16_t C_AMBER = 0xFD80, C_GREY = 0x8410, C_DIM = 0x4208, C_GREEN = 0x2E8A, C_RED = 0xF186,
                      C_ORANGE = 0xFC60;
static const uint16_t GLOW_INK = lgfx::color565(255, 245, 219);  // AgentFace.glow

// stopwatch_pages.cpp
void font(const lgfx::IFont *f, float size = 1);
void fontFor(const char *s, int big = 1);  // ASCII in a Latin font, the rest in efontCN; big 2 a heading, 3 the largest
String fit(String s, int width);
void line(const char *text, int y, uint16_t color, int lines = 2, int width = 330);  // wrapped, centred
void ring(int permille, uint16_t color, uint16_t track, int r0, int r1);
static const int SW_SCR_STATUS = 100, SW_SCR_WARN = 101;  // the board's own pages
struct View {
  int screen, hold, sel;
  uint8_t battery;
  bool hid, alive;
  uint8_t lang;
  int16_t level;  // the mic's, while listening (in 50ths)
  int32_t elapsed;  // the run's seconds (-1: none)
  char clock[6];
  int8_t charge;   // charging: the ring's pulse step (0..15), -1 not charging
  bool charging;   // on a charger (also when full)
  uint8_t low;     // the low-battery banner: the battery % (0 none)
  uint8_t warn;    // SW_SCR_WARN: the alert (sw_warn_code)
  bool connecting, wifi;  // a Bluetooth link not yet paired; a phone on the board's Wi-Fi
  uint8_t mirror;  // AirPlay: 0 off, 1 starting, 2 on
  bool own;        // the app records the phone's own screen (`o`, sw_screen_state): no mirroring needed
  uint16_t pair;   // seconds left of the pairing window (0 none)
  bool pairing;    // the pairing page (blue held), until yellow cancels, blue goes back, or a phone links
  sw_ui ui;
};
static const int STATUS_Y = 148, STATUS_GAP = 34, STATUS_LANG = 6;  // the language row: a tap there switches
void draw(const View &v, const sw_ctl &c, const swf_pose &pose);
static const int ANSWER_ROWS = 5, ANSWER_GAP = 38, ANSWER_W = 360, ANSWER_LINES = 64;
extern char *answerText;  // the done task's answer (PSRAM)
extern int answerStart[ANSWER_LINES + 1], answerLines;  // where each wrapped line starts
void layoutAnswer();      // once when it comes

// stopwatch_ui.cpp
const char *T(int id);    // a word of the screen in its language
extern char boardName[32];

static const float FACE_S = 330;       // the face's size `s` in AgentFace, in pixels
static const float PX = FACE_S / 128;  // pixels per app point: the Home face is 128 points wide
static const float LOOK_RANGE = 1.6f;  // how far the eyes travel (Home 1, the tiny island 2.4)

extern bool measuring;               // only find what the face will cover (bx0...), draw nothing
extern float bx0, by0, bx1, by1;     // what this frame's face covered, for the partial push
struct FacePlace {
  bool on;
  int cx, cy;
  uint16_t color;
  bool glow, crossed;
};
extern FacePlace place;  // where the last face went, to redraw only it

uint16_t scaled(uint16_t c, float k);  // a colour dimmed toward black
void face(const swf_pose &p, int cx, int cy, uint16_t color, bool glow, bool crossed = false);
#endif
