#pragma once
#include <atomic>
#include <cstdint>

// 低 16 位保存连接句柄加一。取消订阅或断开时推进代数，避免复用句柄后执行旧指令。
class Note4HidTarget {
  std::atomic<uint32_t> state{0};
public:
  uint32_t session() const { return state.load(); }
  static int peer(uint32_t session) { return int(session & 0xffff) - 1; }

  bool subscribe(uint16_t handle, bool trusted, bool subscribed) {
    auto old = session();
    return trusted && subscribed && peer(old) < 0 && state.compare_exchange_strong(old, old | (uint32_t(handle) + 1));
  }
  void disconnect(uint16_t handle) {
    auto old = session();
    if (peer(old) == handle) state.compare_exchange_strong(old, (old & 0xffff0000u) + 0x10000u);
  }
  bool allows(uint16_t handle, bool trusted) const {
    const int owner = peer(session());
    return trusted && (owner < 0 || owner == handle);
  }
};
