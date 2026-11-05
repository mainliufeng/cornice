#include "../native/session/SleepRequest.hpp"
#include <cstdlib>
#include <iostream>

static unsigned checks = 0;
static void check(bool value, const char *message) {
  ++checks;
  if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
int main() {
  SleepRequest request;
  check(request.begin(0, true), "a closed lid starts a request");
  const auto first = request.generation;
  check(!request.ready(0, false), "an unconfirmed lock never permits sleep");
  check(!request.retryLock(14999), "no rapid lock retries");
  check(request.retryLock(15000), "retry a failed lock after 15 seconds");
  check(!request.retryLock(15001), "lock retries are rate limited");
  check(request.retryLock(45000), "one final lock retry after 30 seconds");
  check(!request.retryLock(90000), "only three lock requests per operation");
  check(!request.ready(119999, false), "waiting never bypasses the secure lock");
  check(request.expired(120000), "unconfirmed requests have a finite lifetime");
  check(!request.ready(120000, true), "a late lock cannot trigger stale sleep");
  request.cancel();
  check(!request.current(first), "expired/cancelled callbacks are stale");

  request.begin(200000, true);
  check(request.ready(200000, true), "a secure full lock allows the first call");
  const auto token = request.takeAttempt();
  check(request.failed(200000), "a transient failure schedules a retry");
  check(!request.ready(214999, true), "first retry waits 15 seconds");
  check(!request.ready(215000, false), "a retry rechecks the secure lock");
  check(request.ready(215000, true), "first retry becomes due");
  request.takeAttempt();
  check(request.failed(215000), "a second failure schedules the last retry");
  check(!request.ready(244999, true), "second retry waits 30 seconds");
  check(request.ready(245000, true), "last retry becomes due");
  request.takeAttempt();
  check(!request.failed(245000), "third failure exhausts the request");
  check(!request.ready(1000000, true), "exhaustion cannot loop forever");
  check(!request.current(token), "exhausted callbacks are stale");

  request.begin(300000, true);
  const auto closedToken = request.takeAttempt();
  request.failed(300000);
  check(request.lidOpened(), "opening the lid cancels the queued retry");
  check(!request.ready(315000, true), "opening prevents later sleep");
  check(!request.current(closedToken), "an old async result cannot revive a request");
  request.begin(320000, true);
  check(!request.current(closedToken), "closing again uses a new generation");
  request.cancel();

  request.begin(400000, false);
  check(!request.lidOpened() && request.active, "lid opening preserves manual requests");
  request.takeAttempt();
  check(!request.failed(400000, false), "authentication denial is not retried");
  check(!request.active, "permanent failures stop the request");
  request.begin(500000, true, 1);
  request.takeAttempt();
  check(!request.failed(500000), "poweroff/reboot are never automatically repeated");
  request.begin(600000, true);
  request.takeAttempt();
  request.cancel(); // PrepareForSleep/resume completes the operation.
  check(!request.ready(620000, true), "resume cannot replay the old lid request");
  std::cout << "PASS: " << checks << " sleep scheduling checks (no system APIs)\n";
}
