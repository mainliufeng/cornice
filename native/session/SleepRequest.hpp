#pragma once
#include <cstdint>

// Scheduling only: the caller must still verify a secure full lock and use the
// ordinary authenticated logind API. No clock, bus or compositor is touched here.
class SleepRequest {
public:
  using Time = std::int64_t;
  static constexpr Time lifetime = 120000;
  bool active = false;
  bool fromLid = false;
  unsigned generation = 0;
  unsigned attempts = 0;

  bool begin(Time now, bool lid, unsigned limit = 3) {
    if (active)
      return false;
    active = true;
    fromLid = lid;
    attempts = 0;
    maxAttempts = limit;
    started = nextAttempt = now;
    nextLock = now + 15000;
    lockRequests = 1; // The caller emits the initial full-lock-required event.
    ++generation;
    return true;
  }
  bool cancel() {
    if (!active)
      return false;
    active = false;
    ++generation;
    return true;
  }
  bool lidOpened() { return active && fromLid && cancel(); }
  bool current(unsigned token) const { return active && generation == token; }
  bool expired(Time now) const { return active && now - started >= lifetime; }
  bool ready(Time now, bool secure) const {
    return active && !expired(now) && secure && attempts < maxAttempts &&
           now >= nextAttempt;
  }
  bool retryLock(Time now) {
    if (!active || expired(now) || lockRequests >= 3 || now < nextLock)
      return false;
    ++lockRequests;
    nextLock = now + 30000;
    return true;
  }
  unsigned takeAttempt() { ++attempts; return generation; }
  bool failed(Time now, bool retryable = true) {
    if (!active)
      return false;
    if (!retryable || attempts >= maxAttempts || expired(now)) {
      cancel();
      return false;
    }
    nextAttempt = now + (attempts <= 1 ? 15000 : 30000);
    return true;
  }
private:
  unsigned maxAttempts = 3, lockRequests = 0;
  Time started = 0, nextAttempt = 0, nextLock = 0;
};
