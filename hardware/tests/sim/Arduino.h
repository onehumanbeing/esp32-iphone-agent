// Host stand-ins for the Arduino bits cli_link.cpp uses (cli_sim.cpp).
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <string>
struct String : std::string {
  using std::string::string;
  String(const std::string &s) : std::string(s) {}
};
struct SerialStub {
  void println(const char *s) { fprintf(stderr, "%s\n", s); }
};
extern SerialStub Serial;
uint32_t millis();
