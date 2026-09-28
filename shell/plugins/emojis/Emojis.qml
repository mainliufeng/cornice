import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Emoji picker.
//
// The list is bundled on purpose: no emoji database ships with Arch, and a
// picker that needs a package (or the network) to work is worse than a curated
// set. Search matches the name and the keywords.
PanelFrame {
  id: root

  edge: "center"
  panelWidth: 620
  panelHeight: 480
  takesKeyboard: true

  property string query: ""
  property int selected: 0
  property string copied: ""

  readonly property var data: [
    { c: "😀", n: "grinning face", k: "smile happy grin" },
    { c: "😃", n: "grinning face big eyes", k: "smile happy" },
    { c: "😄", n: "grinning face smiling eyes", k: "happy laugh" },
    { c: "😁", n: "beaming face", k: "grin happy" },
    { c: "😆", n: "grinning squinting face", k: "laugh haha" },
    { c: "😅", n: "grinning face sweat", k: "phew relief" },
    { c: "🤣", n: "rolling on the floor laughing", k: "rofl lol" },
    { c: "😂", n: "face with tears of joy", k: "lol cry laugh" },
    { c: "🙂", n: "slightly smiling face", k: "smile" },
    { c: "🙃", n: "upside down face", k: "silly" },
    { c: "😉", n: "winking face", k: "wink" },
    { c: "😊", n: "smiling face smiling eyes", k: "blush happy" },
    { c: "😇", n: "smiling face with halo", k: "angel innocent" },
    { c: "🥰", n: "smiling face with hearts", k: "love adore" },
    { c: "😍", n: "smiling face heart eyes", k: "love" },
    { c: "🤩", n: "star struck", k: "wow excited" },
    { c: "😘", n: "face blowing a kiss", k: "kiss love" },
    { c: "😗", n: "kissing face", k: "kiss" },
    { c: "😚", n: "kissing face closed eyes", k: "kiss" },
    { c: "😋", n: "face savoring food", k: "yum tasty" },
    { c: "😛", n: "face with tongue", k: "tongue" },
    { c: "🤪", n: "zany face", k: "crazy silly" },
    { c: "🤨", n: "face with raised eyebrow", k: "skeptical doubt" },
    { c: "🧐", n: "face with monocle", k: "inspect hmm" },
    { c: "🤓", n: "nerd face", k: "geek glasses" },
    { c: "😎", n: "smiling face with sunglasses", k: "cool" },
    { c: "🥳", n: "partying face", k: "party celebrate" },
    { c: "😏", n: "smirking face", k: "smirk" },
    { c: "😒", n: "unamused face", k: "meh" },
    { c: "😞", n: "disappointed face", k: "sad" },
    { c: "😔", n: "pensive face", k: "sad" },
    { c: "😟", n: "worried face", k: "worry" },
    { c: "😕", n: "confused face", k: "confused" },
    { c: "🙁", n: "slightly frowning face", k: "sad" },
    { c: "😣", n: "persevering face", k: "struggle" },
    { c: "😖", n: "confounded face", k: "frustrated" },
    { c: "😫", n: "tired face", k: "exhausted" },
    { c: "😩", n: "weary face", k: "tired" },
    { c: "🥺", n: "pleading face", k: "please puppy" },
    { c: "😢", n: "crying face", k: "sad tear" },
    { c: "😭", n: "loudly crying face", k: "sob sad" },
    { c: "😤", n: "face with steam from nose", k: "angry triumph" },
    { c: "😠", n: "angry face", k: "angry" },
    { c: "😡", n: "enraged face", k: "rage angry" },
    { c: "🤬", n: "face with symbols on mouth", k: "swearing" },
    { c: "🤯", n: "exploding head", k: "mind blown shock" },
    { c: "😳", n: "flushed face", k: "embarrassed" },
    { c: "🥵", n: "hot face", k: "heat sweating" },
    { c: "🥶", n: "cold face", k: "freezing" },
    { c: "😱", n: "face screaming in fear", k: "shock fear" },
    { c: "😨", n: "fearful face", k: "fear" },
    { c: "😰", n: "anxious face with sweat", k: "nervous" },
    { c: "🤗", n: "hugging face", k: "hug" },
    { c: "🤔", n: "thinking face", k: "think hmm" },
    { c: "🤭", n: "face with hand over mouth", k: "oops giggle" },
    { c: "🤫", n: "shushing face", k: "quiet secret" },
    { c: "😶", n: "face without mouth", k: "speechless" },
    { c: "😐", n: "neutral face", k: "meh" },
    { c: "😑", n: "expressionless face", k: "blank" },
    { c: "😬", n: "grimacing face", k: "awkward" },
    { c: "🙄", n: "face with rolling eyes", k: "eyeroll" },
    { c: "😯", n: "hushed face", k: "surprised" },
    { c: "😴", n: "sleeping face", k: "sleep zzz" },
    { c: "🤤", n: "drooling face", k: "drool" },
    { c: "😪", n: "sleepy face", k: "tired" },
    { c: "😵", n: "face with crossed out eyes", k: "dead dizzy" },
    { c: "🤐", n: "zipper mouth face", k: "silence" },
    { c: "🥴", n: "woozy face", k: "drunk" },
    { c: "🤢", n: "nauseated face", k: "sick" },
    { c: "🤮", n: "face vomiting", k: "sick" },
    { c: "🤧", n: "sneezing face", k: "sick" },
    { c: "😷", n: "face with medical mask", k: "sick mask" },
    { c: "🤒", n: "face with thermometer", k: "sick fever" },
    { c: "🥳", n: "party face", k: "celebrate" },
    { c: "😈", n: "smiling face with horns", k: "devil" },
    { c: "👻", n: "ghost", k: "halloween boo" },
    { c: "💀", n: "skull", k: "dead" },
    { c: "🤖", n: "robot", k: "ai bot agent" },
    { c: "👽", n: "alien", k: "ufo" },
    { c: "🤡", n: "clown", k: "clown" },
    { c: "🙈", n: "see no evil monkey", k: "monkey" },
    { c: "🙉", n: "hear no evil monkey", k: "monkey" },
    { c: "🙊", n: "speak no evil monkey", k: "monkey" },
    { c: "🐱", n: "cat", k: "animal kitty" },
    { c: "🐶", n: "dog", k: "animal puppy" },
    { c: "🦊", n: "fox", k: "animal" },
    { c: "🐻", n: "bear", k: "animal" },
    { c: "🐼", n: "panda", k: "animal" },
    { c: "🐨", n: "koala", k: "animal" },
    { c: "🦁", n: "lion", k: "animal" },
    { c: "🐯", n: "tiger", k: "animal" },
    { c: "🐮", n: "cow", k: "animal" },
    { c: "🐷", n: "pig", k: "animal" },
    { c: "🐸", n: "frog", k: "animal" },
    { c: "🐵", n: "monkey face", k: "animal" },
    { c: "🐔", n: "chicken", k: "animal" },
    { c: "🦄", n: "unicorn", k: "animal magic" },
    { c: "🐝", n: "bee", k: "insect" },
    { c: "🦋", n: "butterfly", k: "insect" },
    { c: "🐌", n: "snail", k: "slow" },
    { c: "🐙", n: "octopus", k: "sea" },
    { c: "🦀", n: "crab", k: "sea" },
    { c: "🐟", n: "fish", k: "sea" },
    { c: "🐬", n: "dolphin", k: "sea" },
    { c: "🐳", n: "whale", k: "sea" },
    { c: "🌱", n: "seedling", k: "plant growth" },
    { c: "🌲", n: "tree", k: "plant" },
    { c: "🌳", n: "deciduous tree", k: "plant" },
    { c: "🌴", n: "palm tree", k: "plant beach" },
    { c: "🌵", n: "cactus", k: "plant" },
    { c: "🌷", n: "tulip", k: "flower" },
    { c: "🌹", n: "rose", k: "flower love" },
    { c: "🌻", n: "sunflower", k: "flower" },
    { c: "🌼", n: "blossom", k: "flower" },
    { c: "🍀", n: "four leaf clover", k: "luck" },
    { c: "🍎", n: "red apple", k: "fruit" },
    { c: "🍌", n: "banana", k: "fruit" },
    { c: "🍇", n: "grapes", k: "fruit" },
    { c: "🍓", n: "strawberry", k: "fruit" },
    { c: "🍉", n: "watermelon", k: "fruit" },
    { c: "🍊", n: "tangerine", k: "fruit" },
    { c: "🍋", n: "lemon", k: "fruit" },
    { c: "🍑", n: "peach", k: "fruit" },
    { c: "🥑", n: "avocado", k: "food" },
    { c: "🍞", n: "bread", k: "food" },
    { c: "🧀", n: "cheese", k: "food" },
    { c: "🍳", n: "cooking", k: "food egg" },
    { c: "🍔", n: "hamburger", k: "food" },
    { c: "🍕", n: "pizza", k: "food" },
    { c: "🍜", n: "ramen", k: "food noodles" },
    { c: "🍣", n: "sushi", k: "food" },
    { c: "🍱", n: "bento", k: "food" },
    { c: "🍚", n: "cooked rice", k: "food" },
    { c: "🥟", n: "dumpling", k: "food" },
    { c: "🍰", n: "cake", k: "food dessert" },
    { c: "🎂", n: "birthday cake", k: "food" },
    { c: "🍫", n: "chocolate", k: "food" },
    { c: "🍬", n: "candy", k: "food" },
    { c: "☕", n: "coffee", k: "drink" },
    { c: "🍵", n: "tea", k: "drink" },
    { c: "🍺", n: "beer", k: "drink" },
    { c: "🍷", n: "wine", k: "drink" },
    { c: "🥤", n: "cup with straw", k: "drink" },
    { c: "💻", n: "laptop", k: "computer work" },
    { c: "🖥️", n: "desktop computer", k: "screen" },
    { c: "⌨️", n: "keyboard", k: "typing" },
    { c: "🖱️", n: "mouse", k: "click" },
    { c: "📱", n: "mobile phone", k: "phone" },
    { c: "🔋", n: "battery", k: "power" },
    { c: "🔌", n: "plug", k: "power" },
    { c: "💡", n: "light bulb", k: "idea" },
    { c: "🔧", n: "wrench", k: "fix tool" },
    { c: "🔨", n: "hammer", k: "build tool" },
    { c: "⚙️", n: "gear", k: "settings" },
    { c: "🧪", n: "test tube", k: "experiment" },
    { c: "🔍", n: "magnifying glass", k: "search" },
    { c: "📦", n: "package", k: "box release" },
    { c: "📝", n: "memo", k: "note write" },
    { c: "📄", n: "page", k: "document" },
    { c: "📚", n: "books", k: "read learn" },
    { c: "📊", n: "bar chart", k: "stats data" },
    { c: "📈", n: "chart increasing", k: "growth" },
    { c: "📉", n: "chart decreasing", k: "down" },
    { c: "🗂️", n: "card index dividers", k: "files" },
    { c: "📁", n: "folder", k: "files" },
    { c: "🗑️", n: "wastebasket", k: "delete" },
    { c: "🔒", n: "locked", k: "lock secure" },
    { c: "🔓", n: "unlocked", k: "open" },
    { c: "🔑", n: "key", k: "password" },
    { c: "🛡️", n: "shield", k: "secure" },
    { c: "⚡", n: "high voltage", k: "fast power" },
    { c: "🔥", n: "fire", k: "hot lit" },
    { c: "✨", n: "sparkles", k: "new shiny" },
    { c: "⭐", n: "star", k: "favorite" },
    { c: "🌟", n: "glowing star", k: "favorite" },
    { c: "💯", n: "hundred points", k: "perfect" },
    { c: "✅", n: "check mark button", k: "done ok" },
    { c: "☑️", n: "check box", k: "done" },
    { c: "❌", n: "cross mark", k: "no error" },
    { c: "⚠️", n: "warning", k: "careful" },
    { c: "❗", n: "exclamation", k: "important" },
    { c: "❓", n: "question", k: "help" },
    { c: "🚀", n: "rocket", k: "launch ship fast" },
    { c: "🎯", n: "direct hit", k: "target goal" },
    { c: "🏆", n: "trophy", k: "win" },
    { c: "🎉", n: "party popper", k: "celebrate" },
    { c: "🎊", n: "confetti ball", k: "celebrate" },
    { c: "👍", n: "thumbs up", k: "ok yes" },
    { c: "👎", n: "thumbs down", k: "no" },
    { c: "👏", n: "clapping hands", k: "applause" },
    { c: "🙏", n: "folded hands", k: "please thanks" },
    { c: "🤝", n: "handshake", k: "deal agree" },
    { c: "💪", n: "flexed biceps", k: "strong" },
    { c: "👉", n: "pointing right", k: "arrow" },
    { c: "👀", n: "eyes", k: "look watch" },
    { c: "🧠", n: "brain", k: "think ai" },
    { c: "❤️", n: "red heart", k: "love" },
    { c: "💔", n: "broken heart", k: "sad" },
    { c: "💡", n: "idea bulb", k: "idea" },
    { c: "⏰", n: "alarm clock", k: "time" },
    { c: "⌛", n: "hourglass", k: "time wait" },
    { c: "🕐", n: "one o'clock", k: "time" },
    { c: "📅", n: "calendar", k: "date" },
    { c: "🏠", n: "house", k: "home" },
    { c: "🏢", n: "office building", k: "work" },
    { c: "🌍", n: "globe europe africa", k: "world" },
    { c: "🗺️", n: "world map", k: "map" },
    { c: "🧭", n: "compass", k: "direction" },
    { c: "🚗", n: "car", k: "drive" },
    { c: "🚲", n: "bicycle", k: "bike" },
    { c: "✈️", n: "airplane", k: "flight travel" },
    { c: "🚂", n: "train", k: "travel" },
    { c: "🏃", n: "running", k: "run fast" },
    { c: "🧘", n: "meditation", k: "calm" },
    { c: "🛌", n: "sleeping bed", k: "sleep" },
    { c: "☀️", n: "sun", k: "weather" },
    { c: "🌤️", n: "sun behind small cloud", k: "weather" },
    { c: "☁️", n: "cloud", k: "weather" },
    { c: "🌧️", n: "rain", k: "weather" },
    { c: "⛈️", n: "thunder", k: "weather storm" },
    { c: "❄️", n: "snowflake", k: "weather cold" },
    { c: "🌈", n: "rainbow", k: "weather" },
    { c: "🌙", n: "crescent moon", k: "night" },
    { c: "🌊", n: "water wave", k: "sea" },
    { c: "🎵", n: "musical note", k: "music" },
    { c: "🎧", n: "headphone", k: "music listen" },
    { c: "🎮", n: "video game", k: "game" },
    { c: "📷", n: "camera", k: "photo" },
    { c: "🎬", n: "clapper board", k: "video film" },
    { c: "🖌️", n: "paintbrush", k: "design" },
    { c: "🎨", n: "artist palette", k: "design color" },
    { c: "🧩", n: "puzzle piece", k: "extension plugin" },
    { c: "🪄", n: "magic wand", k: "magic auto" }
  ]

  readonly property var filtered: {
    const text = query.trim().toLowerCase()
    if (text === "") return data
    const out = []
    for (const entry of data) {
      if ((entry.n + " " + entry.k).toLowerCase().indexOf(text) !== -1) out.push(entry)
    }
    return out
  }

  readonly property var current: filtered.length === 0
    ? null
    : filtered[Math.max(0, Math.min(selected, filtered.length - 1))]

  function move(delta) {
    if (filtered.length === 0) return
    const columns = Math.max(1, Math.floor(grid.width / grid.cellWidth))
    let next = selected + delta * columns
    if (next < 0) next = 0
    if (next > filtered.length - 1) next = filtered.length - 1
    selected = next
  }

  function moveHorizontal(delta) {
    if (filtered.length === 0) return
    let next = Math.max(0, Math.min(selected + delta, filtered.length - 1))
    selected = next
  }

  function copy(entry) {
    if (!entry) return
    Util.exec("wl-copy " + JSON.stringify(entry.c))
    copied = entry.c + "  " + entry.n
    close()
  }

  onOpened: {
    field.text = ""
    query = ""
    selected = 0
    copied = ""
    focusTimer.restart()
  }

  Timer {
    id: focusTimer
    interval: 50
    onTriggered: field.forceFocus()
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(0.8)

    TextField {
      id: field
      width: parent.width
      placeholder: "Search emoji"
      onTextChanged: root.query = text
      onAccepted: root.copy(root.current)
      onCanceled: root.close()
      onMoved: delta => root.moveHorizontal(delta)
    }

    Text {
      width: parent.width
      text: root.current !== null
        ? root.current.c + "   " + root.current.n + "        Enter: copy   Esc: close"
        : (root.copied !== "" ? root.copied : "no match")
      color: Color.muted
      elide: Text.ElideRight
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    GridView {
      id: grid

      width: parent.width
      height: parent.height - y
      clip: true
      cellWidth: Style.space(4.2)
      cellHeight: Style.space(4.2)
      model: root.filtered
      currentIndex: root.selected

      delegate: Rectangle {
        required property var modelData
        required property int index

        width: grid.cellWidth - Style.space(0.5)
        height: grid.cellHeight - Style.space(0.5)
        radius: Style.radius
        color: index === root.selected ? Color.hover : "transparent"

        Text {
          anchors.centerIn: parent
          text: modelData.c
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize + 10
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          hoverEnabled: true
          onEntered: root.selected = index
          onClicked: root.copy(modelData)
        }
      }
    }
  }
}
