import QtQuick
import QtTest
import CorniceFeedbackTest 1.0 as Commons

TestCase {
  name: "ActionFeedback"
  function cleanup() { Commons.ActionFeedback.clear() }
  function test_source_survives_view_change() {
    Commons.ActionFeedback.show("Delayed tray refusal", "A", "agent-output")
    verify(Commons.ActionFeedback.visibleFor("A", "agent-output"))
    verify(!Commons.ActionFeedback.visibleFor("main", "human-output"))
    verify(!Commons.ActionFeedback.visibleFor("B", "agent-output"))
    verify(!Commons.ActionFeedback.visibleFor("A", "other-output"))
    compare(Commons.ActionFeedback.detail, "Delayed tray refusal")
  }
  function test_missing_source_never_broadcasts() {
    for (const source of [["", "human"], ["main", ""], ["", ""]]) {
      Commons.ActionFeedback.show("No source", source[0], source[1])
      verify(!Commons.ActionFeedback.visibleFor("main", "human"))
      verify(!Commons.ActionFeedback.visibleFor(source[0], source[1]))
    }
  }
  function test_repeated_failure_restarts_expiry() {
    Commons.ActionFeedback.expiry.interval = 200
    Commons.ActionFeedback.show("Same failure", "A", "agent")
    wait(120)
    Commons.ActionFeedback.show("Same failure", "A", "agent")
    wait(120)
    verify(Commons.ActionFeedback.visibleFor("A", "agent"))
    tryCompare(Commons.ActionFeedback, "detail", "", 500)
    verify(!Commons.ActionFeedback.visibleFor("A", "agent"))
  }
  function test_latest_result_and_clear() {
    Commons.ActionFeedback.show("First", "A", "agent-a")
    Commons.ActionFeedback.show("Second", "B", "agent-b")
    verify(!Commons.ActionFeedback.visibleFor("A", "agent-a"))
    verify(Commons.ActionFeedback.visibleFor("B", "agent-b"))
    Commons.ActionFeedback.clear()
    verify(!Commons.ActionFeedback.expiry.running)
    verify(!Commons.ActionFeedback.visibleFor("B", "agent-b"))
  }
}
