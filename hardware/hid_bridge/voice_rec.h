// M5Stack StopWatch voice (flash.sh --stopwatch): yellow held, the microphone goes to the app over BLE, on the
// `video` characteristic as voice chunks (docs/ble-protocol.md, "StopWatch voice"). Begin and end of the mic run on
// the screen task (they use the internal I2C bus, as touch and IMU do); the recording and sending in a task of its
// own that exists only while a recording does.
#pragma once
#ifdef M5_STOPWATCH
#include <Arduino.h>

bool voice_press(const char *locale);  // yellow down: mic on, sound kept from now on; false: still busy with the last
void voice_stream();                   // the hold is a recording: send it, from the press on
void voice_release();                  // yellow up or cancelled: mic off; a streamed recording ends once all is out
void voice_poll();                     // screen task, every frame: turns the mic off when the task is done with it
int voice_level();                     // 0-1000, the sound of the last 50 ms (the screen's level bar)
#endif
