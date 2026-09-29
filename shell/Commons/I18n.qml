pragma Singleton
import QtQuick
import Quickshell
import qs.Commons

// Translations and locale-aware formatting.
//
// The tables live in <prefix>/i18n/<code>.json and are loaded by the cn.i18n
// service (which also watches the configured language); this singleton is the
// pure lookup + formatting API the rest of the shell talks to:
//
//   text: I18n.t("weather.nextDays")
//   text: I18n.dayName(isoDate)        // follows the language, not Qt's default
//   text: I18n.dateTime(date, "ddd HH:mm")
//
// English is the fallback for every missing key, and a missing key returns itself
// so a typo is visible on screen instead of turning into an empty label.
QtObject {
  id: root

  property string language: "en"
  property var table: ({})
  property var fallback: ({})

  readonly property var locale: Qt.locale(language === "" ? "en" : language)
  readonly property bool isRightToLeft: locale.textDirection === Qt.RightToLeft

  function t(key, params) {
    if (!key) return ""
    let value = table && table[key] !== undefined ? table[key]
      : (fallback && fallback[key] !== undefined ? fallback[key] : key)
    if (params) {
      for (const name of Object.keys(params)) {
        value = String(value).replace("{" + name + "}", String(params[name]))
      }
    }
    return String(value)
  }

  // Month and weekday names have to come from the chosen locale: Qt's
  // formatDateTime helpers use the process default, which never changes.
  function dateTime(date, format) {
    return date.toLocaleString(locale, format)
  }

  function dayName(dateOrIso, format) {
    const date = (dateOrIso instanceof Date) ? dateOrIso : new Date(dateOrIso)
    if (isNaN(date.getTime())) return String(dateOrIso === undefined ? "" : dateOrIso)
    return date.toLocaleString(locale, format || "ddd")
  }

  function monthYear(date) {
    return date.toLocaleString(locale, "MMMM yyyy")
  }

  function weekdayNames(format) {
    const names = []
    for (let index = 0; index < 7; index++) {
      // 2024-01-01 was a Monday.
      const date = new Date(2024, 0, 1 + index)
      names.push(date.toLocaleString(locale, format || "ddd"))
    }
    return names
  }

  readonly property int firstDayOfWeek: locale.firstDayOfWeek
}
