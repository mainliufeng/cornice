import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// World clocks. QML's JS engine has no timezone database, so offsets are asked
// from the system tzdata (`TZ=<zone> date +%z`) — that keeps daylight saving
// correct — and the rendering is then done in the configured language.
// Plugin entry points must be Items (the loader and IpcHandler both rely on
// it), even for a service that draws nothing.
Item {
  id: root

  property var host: null
  property var plugin: null

  readonly property var settings: (host && host.config && host.config.clock) ? host.config.clock : ({})

  // "worldClocks": [ { "name": "东京", "zone": "Asia/Tokyo" },
  //                  { "name": "Oslo", "zone": "Europe/Oslo" } ]
  readonly property var rows: {
    const configured = Util.option(settings, "worldClocks", [])
    if (!configured || configured.length === undefined) return []
    return configured.map((entry, index) => ({
      index: index,
      name: String(entry.name || entry.label || entry.zone || ("zone " + (index + 1))),
      zone: String(entry.zone || entry.timezone || "")
    })).filter(entry => entry.zone !== "")
  }

  // Zones from the list above, plus any clock widget carrying its own timezone.
  property var extraZones: []
  readonly property var wantedZones: {
    const zones = []
    for (let i = 0; i < rows.length; i++) if (zones.indexOf(rows[i].zone) < 0) zones.push(rows[i].zone)
    for (let i = 0; i < extraZones.length; i++) if (zones.indexOf(extraZones[i]) < 0) zones.push(extraZones[i])
    return zones
  }

  // The installed timezone names, read once: the picker filters this list so a
  // typo cannot become a world clock.
  property var allZones: []

  readonly property Process zoneList: Process {
    command: ["bash", "-c",
      "find /usr/share/zoneinfo -type f -printf '%P\\n' 2>/dev/null | grep -E '^[A-Za-z]+/[A-Za-z_+-]+(/[A-Za-z_+-]+)?$' | sort"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Drop the posix/ and right/ copies: same zones, different leap-second
        // bookkeeping, and listing them three times just clutters the picker.
        root.allZones = String(text).split("\n")
          .filter(line => line.trim() !== "")
          .filter(zone => !/^(posix|right)\//.test(zone))
      }
    }
  }

  // Substring match over the "Area/City" name, "Tokyo" finds Asia/Tokyo.
  function matchZones(query, limit) {
    const needle = String(query === undefined ? "" : query).trim().toLowerCase()
    const out = []
    for (let i = 0; i < allZones.length; i++) {
      const zone = allZones[i]
      if (needle !== "" && zone.toLowerCase().indexOf(needle) === -1) continue
      out.push({ label: zone, detail: root.zoneTime(zone, "HH:mm") === "" ? "" : root.zoneTime(zone, "HH:mm") })
      if (limit > 0 && out.length >= limit) break
    }
    return out
  }

  // zone -> offset in minutes east of UTC
  property var zoneMinutes: ({})
  // Whether the panel is showing its world-clock editor.
  property bool editorOpen: false
  property bool ready: false
  // Bumped whenever the offsets change: plain object writes are not observable.
  property int revision: 0

  function offsetFromText(text) {
    const match = String(text).trim().match(/^([+-])(\d{2})(\d{2})$/)
    if (!match) return null
    const minutes = Number(match[2]) * 60 + Number(match[3])
    return match[1] === "-" ? -minutes : minutes
  }

  // The zone's wall clock, as a Date the local formatter can print. Takes the
  // instant explicitly so a clock widget renders the value of its own tick
  // instead of recomputing "now" (which drifted a minute behind the bar).
  function zoneDateAt(zone, epoch) {
    const target = zoneMinutes[zone]
    if (target === undefined || target === null) return null
    const localEast = -new Date(Number(epoch)).getTimezoneOffset()
    return new Date(Number(epoch) + (Number(target) - localEast) * 60000)
  }

  // Pure: callers may use this from a binding, so it must not write state
  // (writing `extraZones` here caused a binding loop in the clock widget).
  function zoneTimeAt(zone, format, epoch) {
    const date = zoneDateAt(zone, epoch)
    if (!date) return ""
    return I18n.dateTime(date, format || "HH:mm")
  }

  function zoneTime(zone, format) {
    return zoneTimeAt(zone, format, Date.now())
  }

  // Resolve a zone that is not configured yet. Only commands (IPC) call this:
  // it mutates state, so a binding must never reach it.
  function requestZone(zone) {
    if (zone !== "" && zoneMinutes[zone] === undefined) watchZone(zone)
  }

  // Difference to local time: "+9h" / "-5:30h" / the localized "same time".
  function zoneDiff(zone) {
    const target = zoneMinutes[zone]
    if (target === undefined || target === null) return ""
    const delta = Number(target) + new Date().getTimezoneOffset()
    if (delta === 0) return I18n.t("clock.sameTime")
    const sign = delta > 0 ? "+" : "-"
    const minutes = Math.abs(delta)
    const hours = Math.floor(minutes / 60)
    const rest = minutes % 60
    return sign + (rest === 0 ? hours + "h" : hours + ":" + String(rest).padStart(2, "0") + "h")
  }

  function zoneOfTimezone(zone) {
    return zoneMinutes[zone] === undefined ? null : zoneMinutes[zone]
  }

  // A widget registers its own zone so it is resolved along with the rest.
  function watchZone(zone) {
    if (!zone || extraZones.indexOf(zone) >= 0) return
    extraZones = extraZones.concat([zone])
  }

  Process {
    id: offsets
    // The command is rebuilt on every start: a binding would be evaluated
    // lazily and could query the previous zone list (the same trap as the
    // weather geocoder, which is why switching was one behind).
    command: ["true"]

    stdout: StdioCollector {
      waitForEnd: true

      onStreamFinished: {
        const parsed = {}
        const lines = String(text).split("\n")
        for (let i = 0; i < lines.length; i++) {
          const parts = lines[i].trim().split(/\s+/)
          if (parts.length !== 2) continue
          const minutes = root.offsetFromText(parts[1])
          if (minutes !== null) parsed[parts[0]] = minutes
        }
        root.zoneMinutes = parsed
        root.ready = true
        root.revision++
      }
    }
  }

  function refresh() {
    const zones = wantedZones
    if (zones.length === 0) {
      zoneMinutes = ({})
      ready = true
      revision++
      return false
    }
    // One shell call for all zones: cheap, atomic, and no per-zone bookkeeping.
    const script = 'for z in "$@"; do printf "%s %s\\n" "$z" "$(TZ=$z date +%z 2>/dev/null)"; done'
    offsets.command = ["bash", "-c", script, "_"].concat(zones)
    offsets.running = false
    offsets.running = true
    return true
  }

  onWantedZonesChanged: refresh()

  // Timezone offsets are tzdata, not clocks: re-resolve rarely, for DST changes.
  Timer {
    interval: 600000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    refresh()
    zoneList.running = true
  }

  function status(): string {
    return JSON.stringify({
      ready: root.ready,
      revision: root.revision,
      editorOpen: root.editorOpen,
      extraZones: root.extraZones,
      zones: root.rows.map(row => ({
        name: row.name,
        zone: row.zone,
        offset: root.zoneOfTimezone(row.zone),
        time: root.zoneTime(row.zone, "HH:mm"),
        date: root.zoneTime(row.zone, "ddd d MMM"),
        diff: root.zoneDiff(row.zone)
      }))
    })
  }

  ShellIpc {
    target: "clock"

    function status(): string {
      return root.status()
    }

    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function zones(query: string): string {
      const limit = Number(query) > 0 ? Number(query) : 200
      return JSON.stringify(root.matchZones("", limit).map(entry => entry.label))
    }

    function match(query: string, limit: string): string {
      return JSON.stringify(root.matchZones(query, Number(limit) > 0 ? Number(limit) : 12))
    }

    function editor(state: string): string {
      const wanted = String(state)
      root.editorOpen = wanted === "on" || wanted === "true" || wanted === "1"
      return root.editorOpen ? "on" : "off"
    }

    function time(zone: string, format: string): string {
      root.requestZone(zone)
      return root.zoneTime(zone, format || "HH:mm")
    }

    function diff(zone: string): string {
      root.requestZone(zone)
      return root.zoneDiff(zone)
    }
  }
}
