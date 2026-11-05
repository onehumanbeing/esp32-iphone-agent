// In-memory NVS for cli_sim.cpp, saved to $CLI_SIM_NVS so pairing survives a restart like on the board.
#pragma once
#include <stddef.h>
#include <stdint.h>
struct Preferences {
  bool begin(const char *ns, bool readOnly);
  void end() {}
  size_t putBytes(const char *key, const void *p, size_t n);
  size_t getBytes(const char *key, void *p, size_t n);
  size_t putUChar(const char *key, uint8_t v);
  uint8_t getUChar(const char *key, uint8_t def);
};
