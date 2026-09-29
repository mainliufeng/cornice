import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Weather state, shared by the bar widget and the panel.
//
// Everything comes from open-meteo (no API key, no account):
//   location   — `city` (geocoded), explicit latitude/longitude, or the IP
//                lookup. Auto-locating through a VPN/proxy reports the exit
//                node, so an explicit city or coordinates always wins.
//   forecast   — current conditions, next hours, next days.
//
// Config (`weather` in config.json):
//   { "city": "Beijing", "place": "", "latitude": null, "longitude": null,
//     "unit": "metric", "intervalMinutes": 15, "autoLocate": true }
Item {
  id: root

  property var host: null
  property var plugin: null

  readonly property var settings: (host && host.config && host.config.weather) ? host.config.weather : ({})

  readonly property string unit: Util.option(settings, "unit", "metric") === "imperial" ? "imperial" : "metric"
  readonly property int intervalMinutes: Math.max(5, Util.option(settings, "intervalMinutes", 15))
  readonly property bool autoLocate: Util.option(settings, "autoLocate", true)
  // Located by city name / coordinates / the system timezone / the IP address,
  // in that order. The timezone beats the IP lookup because a VPN or proxy makes
  // the IP report the exit node (on this machine: Los Angeles for a CST user).
  readonly property bool useTimezone: Util.option(settings, "useTimezone", true)
  property string timezoneCity: ""
  readonly property string city: Util.option(settings, "city", "")
  readonly property string configuredPlace: Util.option(settings, "place", "")
  readonly property var configuredLatitude: Util.option(settings, "latitude", null)
  readonly property var configuredLongitude: Util.option(settings, "longitude", null)

  property real latitude: NaN
  property real longitude: NaN
  property string place: ""
  property string locatedBy: ""          // city | config | ip | cache
  property bool busy: false
  property bool geocodingTimezone: false
  // Startup is asynchronous: the timezone probe, the saved location and the
  // cached forecast all arrive on their own schedule. Refreshing before they
  // land made the IP lookup win the race and overwrite a perfectly good saved
  // location (which is how a CST machine ended up showing Los Angeles weather).
  property int bootstrapPending: 3
  property bool dataFromCache: false
  property string status: "idle"         // idle | locating | fetching | ready | error | unconfigured
  property string error: ""

  property real temperature: NaN
  property real apparent: NaN
  property real humidity: NaN
  property real wind: NaN
  property int code: -1
  property bool isDay: true
  property var hourly: []
  property var daily: []
  property double updatedAt: 0
  property int revision: 0

  readonly property string stateDirectory: {
    const base = Quickshell.env("XDG_STATE_HOME")
      || ((Quickshell.env("HOME") || "") + "/.local/state")
    return base + "/cornice"
  }
  readonly property string cachePath: stateDirectory + "/weather.json"
  readonly property string locationPath: stateDirectory + "/weather-location.json"
  readonly property bool locationKnown: !isNaN(latitude) && !isNaN(longitude)

  readonly property string temperatureUnit: unit === "imperial" ? "°F" : "°C"
  readonly property string windUnit: unit === "imperial" ? "mph" : "km/h"

  readonly property string glyph: glyphFor(code, isDay)
  readonly property string label: labelFor(code)
  readonly property bool hasData: !isNaN(temperature)
  readonly property string temperatureLabel: hasData ? Math.round(temperature) + "°" : "--"
  readonly property string updatedLabel: updatedAt === 0 ? "never"
    : Qt.formatDateTime(new Date(updatedAt), "HH:mm")

  // ---- WMO weather codes ---------------------------------------------------
  function glyphFor(value, day) {
    if (value < 0) return "\u{F0590}"                       // unknown → cloudy
    if (value === 0) return day ? "\u{F059C}" : "\u{F0595}" // sunny / night
    if (value === 1) return day ? "\u{F059C}" : "\u{F0596}" // mainly clear
    if (value === 2) return day ? "\u{F0597}" : "\u{F0596}" // partly cloudy
    if (value === 3) return "\u{F0590}"                     // overcast
    if (value === 45 || value === 48) return "\u{F0591}"    // fog
    if (value >= 51 && value <= 57) return "\u{F0599}"      // drizzle
    if (value >= 61 && value <= 67) return "\u{F0598}"      // rain
    if (value >= 71 && value <= 77) return "\u{F059A}"      // snow
    if (value >= 80 && value <= 82) return "\u{F0598}"      // showers
    if (value === 85 || value === 86) return "\u{F059A}"    // snow showers
    if (value >= 95) return "\u{F0593}"                     // thunderstorm
    return "\u{F0590}"
  }

  function labelFor(value) {
    if (value < 0) return "Unknown"
    if (value === 0) return "Clear"
    if (value === 1) return "Mainly clear"
    if (value === 2) return "Partly cloudy"
    if (value === 3) return "Overcast"
    if (value === 45 || value === 48) return "Fog"
    if (value === 51) return "Light drizzle"
    if (value === 53) return "Drizzle"
    if (value === 55) return "Heavy drizzle"
    if (value === 56 || value === 57) return "Freezing drizzle"
    if (value === 61) return "Light rain"
    if (value === 63) return "Rain"
    if (value === 65) return "Heavy rain"
    if (value === 66 || value === 67) return "Freezing rain"
    if (value === 71) return "Light snow"
    if (value === 73) return "Snow"
    if (value === 75) return "Heavy snow"
    if (value === 77) return "Snow grains"
    if (value === 80) return "Light showers"
    if (value === 81) return "Showers"
    if (value === 82) return "Violent showers"
    if (value === 85 || value === 86) return "Snow showers"
    if (value === 95) return "Thunderstorm"
    if (value === 96 || value === 99) return "Thunderstorm, hail"
    return "Unknown"
  }

  function hourLabel(iso) {
    const parsed = new Date(iso)
    return isNaN(parsed.getTime()) ? "" : Qt.formatDateTime(parsed, "HH:mm")
  }

  function dayLabel(iso) {
    const parsed = new Date(iso + "T12:00:00")
    return isNaN(parsed.getTime()) ? "" : Qt.formatDateTime(parsed, "ddd")
  }

  // ---- fetching ------------------------------------------------------------
  function forecastUrl() {
    const unitParams = unit === "imperial"
      ? "&temperature_unit=fahrenheit&wind_speed_unit=mph"
      : ""
    return "https://api.open-meteo.com/v1/forecast?latitude=" + latitude
      + "&longitude=" + longitude
      + "&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m"
      + "&hourly=temperature_2m,weather_code"
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      + "&forecast_days=5&timezone=auto" + unitParams
  }

  // Belt and braces: a probe that never reports back (a hung curl, a missing
  // file watcher) must not leave the widget blank for the whole session.
  Timer {
    interval: 4000
    running: root.bootstrapPending > 0
    onTriggered: {
      if (root.bootstrapPending <= 0) return
      console.warn("cornice weather: bootstrap timed out with " + root.bootstrapPending + " probe(s) pending")
      root.bootstrapPending = 0
      root.refresh(false)
    }
  }

  function finishBootstrap() {
    if (bootstrapPending <= 0) return
    bootstrapPending = bootstrapPending - 1
    if (bootstrapPending === 0) refresh(false)
  }

  function refresh(force) {
    if (busy) return "busy"
    if (status === "ready" && !dataFromCache && !force && (Date.now() - updatedAt) < intervalMinutes * 60000) return "fresh"

    // Already know where we are (config, a previous locate, or the cache):
    // geolocation services are rate limited, so ask them once.
    if (bootstrapPending > 0) return "bootstrapping"
    if (dataFromCache) force = true
    if (locationKnown) return fetch()

    if (configuredLatitude !== null && configuredLongitude !== null) {
      latitude = Number(configuredLatitude)
      longitude = Number(configuredLongitude)
      place = configuredPlace
      locatedBy = "config"
      if (city !== "" && place === "") locatedBy = "config"
      return fetch()
    }
    if (city !== "") {
      status = "locating"
      busy = true
      error = ""
      geocode.running = true
      return "locating"
    }
    if (autoLocate && useTimezone && timezoneCity !== "") {
      status = "locating"
      busy = true
      error = ""
      geocode.command = ["curl", "-fsS", "--max-time", "10", "--compressed",
        "https://geocoding-api.open-meteo.com/v1/search?count=1&language=en&format=json&name="
        + encodeURIComponent(timezoneCity)]
      geocodingTimezone = true
      geocode.running = true
      return "locating"
    }
    if (autoLocate) {
      status = "locating"
      busy = true
      error = ""
      locate.running = true
      return "locating"
    }
    status = "unconfigured"
    error = "Set weather.city or weather.latitude/longitude in config.json"
    return "unconfigured"
  }

  function fetch() {
    if (isNaN(latitude) || isNaN(longitude)) {
      status = "error"
      error = "No coordinates"
      busy = false
      return "no-coordinates"
    }
    status = "fetching"
    busy = true
    fetcher.running = true
    return "fetching"
  }

  readonly property Process geocode: Process {
    command: ["curl", "-fsS", "--max-time", "10", "--compressed",
      "https://geocoding-api.open-meteo.com/v1/search?count=1&language=en&format=json&name="
      + encodeURIComponent(root.city)]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          const data = JSON.parse(text)
          const first = (data.results || [])[0]
          if (!first) throw new Error("no match for '" + root.city + "'")
          root.latitude = Number(first.latitude)
          root.longitude = Number(first.longitude)
          root.place = root.configuredPlace !== ""
            ? root.configuredPlace
            : [first.name, first.country_code].filter(part => part).join(", ")
          root.locatedBy = root.geocodingTimezone ? "timezone" : "city"
          root.rememberLocation()
          root.fetch()
        } catch (error) {
          if (root.geocodingTimezone) {
            // Timezone city did not resolve: fall through to the IP lookup.
            root.geocodingTimezone = false
            locate.running = true
            return
          }
          root.status = "error"
          root.error = "Could not geocode '" + root.city + "': " + error
          root.busy = false
        }
      }
    }
  }

  // Two providers: ipapi.co is friendlier but rate limits, ip-api.com is plain
  // HTTP and has no TLS at all — try the first, fall back to the second.
  readonly property Process locate: Process {
    property int attempt: 0
    command: attempt === 0
      ? ["curl", "-fsS", "--max-time", "8", "--compressed", "https://ipapi.co/json/"]
      : ["curl", "-fsS", "--max-time", "8", "--compressed", "http://ip-api.com/json/?fields=status,lat,lon,city,countryCode"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          const data = JSON.parse(text)
          const latitude = data.latitude !== undefined ? data.latitude : data.lat
          const longitude = data.longitude !== undefined ? data.longitude : data.lon
          if (latitude === undefined || longitude === undefined) throw new Error("no coordinates in reply")
          root.latitude = Number(latitude)
          root.longitude = Number(longitude)
          root.place = root.configuredPlace !== ""
            ? root.configuredPlace
            : [data.city, data.country_code].filter(part => part).join(", ")
          root.locatedBy = "ip"
          root.rememberLocation()
          root.fetch()
        } catch (error) {
          if (locate.attempt === 0) {
            locate.attempt = 1
            locate.running = true
            return
          }
          root.status = "error"
          root.error = "Could not locate this machine: " + error
          root.busy = false
        }
      }
    }
  }

  readonly property Process fetcher: Process {
    command: ["curl", "-fsS", "--max-time", "12", "--compressed", root.forecastUrl()]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.consumeWeather(text)
    }
  }

  function rememberLocation() {
    locationCache.path = root.locationPath
    locationCache.setText(JSON.stringify({
      latitude: root.latitude,
      longitude: root.longitude,
      place: root.place,
      locatedBy: root.locatedBy
    }))
  }

  function consumeWeather(text, fromCache) {
    let data
    try {
      data = JSON.parse(text)
    } catch (error) {
      root.status = "error"
      root.error = "Bad forecast reply: " + error
      root.busy = false
      return
    }
    if (!data || !data.current) {
      root.status = "error"
      root.error = "Forecast reply had no current block"
      root.busy = false
      return
    }

    const current = data.current
    root.temperature = Number(current.temperature_2m)
    root.apparent = Number(current.apparent_temperature)
    root.humidity = Number(current.relative_humidity_2m)
    root.wind = Number(current.wind_speed_10m)
    root.code = Number(current.weather_code)
    root.isDay = Number(current.is_day) === 1

    // Next 12 hours, starting at the current hour.
    const hours = []
    const times = (data.hourly && data.hourly.time) || []
    const temps = (data.hourly && data.hourly.temperature_2m) || []
    const codes = (data.hourly && data.hourly.weather_code) || []
    const now = Date.now()
    for (let index = 0; index < times.length; index++) {
      const at = new Date(times[index])
      if (isNaN(at.getTime()) || at.getTime() < now - 3600000) continue
      hours.push({
        time: times[index],
        label: Qt.formatDateTime(at, "HH:mm"),
        temperature: Number(temps[index]),
        code: Number(codes[index])
      })
      if (hours.length >= 12) break
    }
    root.hourly = hours

    const days = []
    const dayTimes = (data.daily && data.daily.time) || []
    const maxes = (data.daily && data.daily.temperature_2m_max) || []
    const mins = (data.daily && data.daily.temperature_2m_min) || []
    const dayCodes = (data.daily && data.daily.weather_code) || []
    for (let index = 0; index < dayTimes.length; index++) {
      days.push({
        date: dayTimes[index],
        label: index === 0 ? "Today" : root.dayLabel(dayTimes[index]),
        high: Number(maxes[index]),
        low: Number(mins[index]),
        code: Number(dayCodes[index])
      })
    }
    root.daily = days

    // Only a *fresh* forecast may name the place, and only when nothing else
    // told us where we are: a cached forecast from a previous location must not
    // relabel the bar.
    if (fromCache !== true && root.place === "" && data.timezone) root.place = String(data.timezone)
    root.updatedAt = Date.now()
    root.dataFromCache = fromCache === true
    root.status = "ready"
    root.error = ""
    root.busy = false
    root.revision = root.revision + 1
    if (fromCache !== true) {
      cache.path = root.cachePath
      cache.setText(text)
    }
  }

  // Write-only: reading is done with `cat` below, because a FileView pointed at a
  // missing file logs a warning on every shell start.
  FileView {
    id: cache
    path: ""
    blockWrites: true
  }

  FileView {
    id: locationCache
    path: ""
    blockWrites: true
  }

  Process {
    id: timezoneProbe
    command: ["sh", "-c", "readlink -f /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||'"]
    running: true

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const zone = String(text).trim()
        if (zone !== "" && zone.indexOf("/") >= 0) {
          const tail = zone.split("/").pop().replace(/_/g, " ")
          root.timezoneCity = tail
        }
        root.finishBootstrap()
      }
    }
  }

  Process {
    id: makeStateDir
    command: ["mkdir", "-p", root.stateDirectory]
    running: true
    onExited: {
      locationRead.running = true
      cacheRead.running = true
    }
  }

  Process {
    id: locationRead
    command: ["cat", root.locationPath]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // No early return here: every path must release the bootstrap gate, or
        // the widget stays blank forever when the cache file is missing.
        const raw = String(text).trim()
        if (raw !== "") {
          try {
            const saved = JSON.parse(raw)
            if (!isNaN(Number(saved.latitude)) && !isNaN(Number(saved.longitude))) {
              root.latitude = Number(saved.latitude)
              root.longitude = Number(saved.longitude)
              if (root.place === "" && saved.place) root.place = String(saved.place)
              root.locatedBy = String(saved.locatedBy || "cache")
            }
          } catch (error) {
            console.warn("cornice weather: bad saved location: " + error)
          }
        }
        root.finishBootstrap()
      }
    }
  }

  Process {
    id: cacheRead
    command: ["cat", root.cachePath]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text).trim() !== "") {
          // Show the last forecast immediately on startup instead of a blank bar.
          root.consumeWeather(text, true)
        }
        root.finishBootstrap()
      }
    }
  }

  Timer {
    interval: root.intervalMinutes * 60000
    repeat: true
    running: true
    // Not triggeredOnStart: finishBootstrap() owns the first refresh, after the
    // timezone, the saved location and the cached forecast have all been read.
    onTriggered: root.refresh(false)
  }

  ShellIpc {
    target: "weather"

    function status(): string {
      return JSON.stringify({
        status: root.status,
        error: root.error,
        place: root.place,
        locatedBy: root.locatedBy,
        latitude: root.latitude,
        longitude: root.longitude,
        temperature: root.temperature,
        apparent: root.apparent,
        humidity: root.humidity,
        wind: root.wind,
        code: root.code,
        label: root.label,
        glyph: root.glyph,
        unit: root.unit,
        isDay: root.isDay,
        updated: root.updatedLabel,
        hours: root.hourly.length,
        days: root.daily.length
      })
    }

    function refresh(): string {
      return root.refresh(true)
    }

    function locate(): string {
      // Re-resolve the location from scratch (after moving, or when auto-locate
      // picked a proxy exit node instead of the real place).
      root.latitude = NaN
      root.longitude = NaN
      root.updatedAt = 0
      const outcome = root.refresh(true)
      return outcome
    }

    function place(): string {
      return root.place
    }
  }
}
