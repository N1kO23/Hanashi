# Themes

A theme sets how Hanashi looks on a device: its colours in light and in dark
mode, and if it likes, the title bar's logo and wordmark, the icon in the
tray, and the sounds of new messages and of calls ringing. People import a
theme's file in Settings, under Appearance, and choose there which theme
shows, and whether light, dark or as the system is.

Themes belong to a device. They are not synced to the account's other
devices, and signing out keeps them, as it keeps the choice.

## Built-in themes

The app comes with seven, all of them its own look: the title bar shows the
app's name, the icon is a speech bubble in the theme's colour (drawn by
`app/tool/make_default_icon.dart`, as are the app's launcher icons), and
messages sound as the system's notifications do.

- **Default**: teal over slate. The colours below are Default's.
- **Sakura**: pink over slate, the colours the app had before 0.9.
- **Ocean**, **Forest**, **Lavender**, **Ember** and **Graphite**: blue,
  green, purple, orange and grey.

Each changes a few colours of Default's, as a theme file does
(`app/lib/data/themes/builtin_themes.dart`).

## The file

A theme file is a zip file of `pack.json` and the files it names, all at its
top level:

```json
{
  "format": 1,
  "type": "theme",
  "id": "sakura",
  "title": "Sakura",
  "author": "Me",
  "version": 2,
  "light": {
    "header": "#E87EA1",
    "outgoingBubble": "#D0638A",
    "avatarColors": ["#F7A8B8", "#B5A8F0"]
  },
  "dark": {
    "header": "#8E3B5A",
    "rail": "#2A2230"
  },
  "assets": {
    "logo": "blossom.png",
    "wordmark": "sakura.webp",
    "appIcon": "icon.png",
    "messageSound": "chime.ogg",
    "ringtone": "bells.wav"
  }
}
```

| Field | |
|---|---|
| `format` | `1`. A file of a later format asks for a newer version of Hanashi. |
| `type` | `"theme"`. |
| `id` | 1 to 64 of `a`–`z`, `0`–`9`, `.`, `_` and `-`, starting with a letter or digit. It names the theme: a file of an ID the device has replaces that theme (the app asks first), so a new version of a theme keeps its ID. `default` is taken. |
| `title` | 1 to 64 characters, shown in Settings. |
| `author` | Optional, 1 to 64 characters, shown under the title. |
| `appName` | Optional, 1 to 32 characters: the name the app goes by while the theme shows (see [The app's name](#the-apps-name)). Without it, the app's own. |
| `version` | Optional whole number. |
| `light`, `dark` | The colours in light and in dark mode (see [Colours](#colours)); at least one of them. A theme with only one shows it in both modes. |
| `assets` | Optional: the theme's files by role (see [Files](#files)). |

Anything else in `pack.json` is passed over, so that later versions can add
to the format.

## Colours

Each of `light` and `dark` gives colours by name, as `#RRGGBB` or
`#AARRGGBB` (with opacity). A colour a theme does not give is the built-in
one of that mode, below. A name this version does not know is passed over
(it may be a later version's); a colour it cannot read refuses the file, so
that a mistake shows at once.

Dialogs, menus, switches and other controls take their tones from `header`
in light mode and from `rail` in dark mode, with `replyAccent` as their
accent.

| Name | Light | Dark | What it colours |
|---|---|---|---|
| `header` | `#2AA198` | `#1F7A73` | The title bar. |
| `onHeader` | `#FFFFFF` | `#FFFFFF` | Text and icons on the title bar, and the app's name where a theme has no wordmark. |
| `rail` | `#3E5560` | `#1F2A2D` | The side rail (computers) and bottom tabs (phones). |
| `railSelected` | `#557080` | `#2E3D41` | The selected tab. |
| `railIcon` | `#8FA3AB` | `#7A8E92` | The other tabs' icons. |
| `onRail` | `#FFFFFF` | `#FFFFFF` | The selected tab's icon; text and icons on the rail's colour. |
| `listBackground` | `#F3F7F8` | `#14181E` | Behind lists and panes: chats, contacts, Settings. |
| `listSelected` | `#D5E8E6` | `#1E2C2E` | The selected row of a list. |
| `divider` | `#E0E4E5` | `#262D37` | Lines between rows. |
| `panelDivider` | `#E9E9E9` | `#262D37` | Lines between panes. |
| `chatBackground` | `#FFFFFF` | `#0F1318` | Behind a chat's messages. |
| `surface` | `#FFFFFF` | `#1B2028` | Fields, cards and panels set apart from what is under them. |
| `incomingBubble` | `#3E5560` | `#344A4F` | Other people's messages. |
| `outgoingBubble` | `#2E8C9A` | `#22707A` | Your messages. |
| `onBubble` | `#FFFFFF` | `#FFFFFF` | Text and icons in a bubble of either colour. |
| `replyPanel` | `#DCEEEC` | `#172628` | The composer under a chat. |
| `replyAccent` | `#23968C` | `#4CC3B5` | The accent: buttons, links, switches, the selected tab's indicator. |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | Text and icons on the accent: buttons, badges, pictures' initials. |
| `fieldBorder` | `#CFDADF` | `#364150` | Text fields' borders. |
| `mediaCardBorder` | `#E3E8EB` | `#2A333F` | The borders of photos, videos and files in a chat. |
| `textPrimary` | `#232C31` | `#E6EAEF` | Text. |
| `textHeading` | `#1E2225` | `#F3F5F7` | Headings. |
| `textSecondary` | `#5B6669` | `#A9B3BD` | Secondary text: previews, subtitles. |
| `textMuted` | `#8E989C` | `#7A8592` | Faint text: times, hints. |
| `unreadBadge` | `#FB4619` | `#FF5A2E` | Unread counts. |
| `failed` | `#E5484D` | `#F0585D` | Messages that did not go, and actions that delete. |
| `success` | `#3CB371` | `#4CC285` | What went well; the connected dot. |
| `online` | `#3CB371` | `#4CC285` | Status badge: online. |
| `idle` | `#F2B33D` | `#F2B33D` | Status badge: idle. |
| `focus` | `#F0607E` | `#F2708A` | Status badge: in focus. |
| `offline` | `#A9B3B8` | `#66717B` | Status badge: offline. |
| `profileText` | `#5E6E7E` | `#A2AFBC` | The line under a name on a profile card. |
| `profilePill` | `#E6EDF1` | `#232B36` | A profile's facts (birthday and so on). |
| `birthday` | `#FFD43B` | `#FFD43B` | The "B-DAY" tag on the picture of someone whose birthday is today. |
| `birthdayText` | `#4A3B00` | `#4A3B00` | The tag's text. |
| `warning` | `#B4690E` | `#E8A247` | Security notices in a chat (sending paused, a key changed). |
| `warningBackground` | `#FFF4E0` | `#2E2414` | Those notices' ground. |
| `logWarning` | `#B26A00` | `#E8A247` | Warnings in the app's log. |
| `shadow` | `#000000` | `#000000` | Shadows, at the opacity each needs. |
| `callTile` | `#2B3240` | `#2B3240` | Someone in a call without video. |
| `avatarColors` | `#F7A8B8`, `#8EC5FC`, `#B5A8F0`, `#8FD4B5`, `#FFC98B`, `#9CCFD8`, `#E3A6E0`, `#A9C7A0` | the same | Pictures of people and groups without one: a list, at least one colour. |

## Files

`assets` names a file for each role a theme fills; each role is optional.
A file's name is at most 60 of `A`–`Z`, `a`–`z`, `0`–`9`, `.`, `_` and `-`
before its extension, starting with a letter or digit, and in no folder.

| Role | Files | Shown |
|---|---|---|
| `logo` | PNG or WebP | At the start of the title bar, 30 points high. |
| `wordmark` | PNG or WebP | After the logo, 22 points high, in place of the app's name. |
| `appIcon` | PNG | In the tray on computers, and on Linux notifications. Square works best. A theme without one shows Default's. |
| `messageSound` | WAV, Ogg or MP3 | New messages and contact requests (see [Sounds](#sounds)). A theme without one sounds as the system's notifications do. |
| `ringtone` | WAV, Ogg or MP3 | A call ringing, on computers. A theme without one rings with Default's. |

Pictures are still (not animated), at most 2048×2048 pixels and 1 MiB. Make
them at least three times the size they show (90 and 66 pixels high for the
logo and the wordmark), as sharp screens draw that many pixels to a point. A file must
be what its name says, which the app tells by its first bytes: a `.png` file
that is a WebP picture refuses the theme.

Sounds are at most 2 MiB; keep a message sound short.

### Sounds

How a theme's message sound plays depends on the platform:

- **Android 9 and later**: the notification plays it. A notification
  channel keeps the sound it was made with, so each sound gets channels of
  its own, and those of sounds no longer used go. Choosing a theme with
  another sound therefore starts the channel's settings (importance,
  vibration) over. Android 7 to 8.1 plays the system's sound instead.
  Android rings with the phone's ringtone, not the theme's.
- **Windows and macOS**: the notification is silent and the app plays the
  sound.
- **Linux**: the app plays a theme's sound itself, over a silent
  notification.
- **iOS**: the system's sound.

## The app's name

A theme's `appName`, and its `appIcon`, are what the app goes by while the
theme shows:

- the title bar (unless the theme has a wordmark), the window's title and the
  taskbar's or dock's icon, the tray's icon and menu, and the list of recent
  apps on Android;
- notifications that keep what they are about private, and the app's words
  about itself in Settings and elsewhere;
- on Android 8 and later, a shortcut on the home screen: Settings, under
  Appearance, "Add to home screen" pins one with the theme's icon and name,
  and it follows the theme from then on. The launcher's own entry for the app
  stays the app's: Android changes that for nothing the app was built with.

The app's entries in the system's menus and launchers, its installer and its
notifications' sender stay the app's own name.

## Limits

| | |
|---|---|
| The file | 8 MiB, at most 32 files |
| `pack.json` | 64 KiB |
| Everything unpacked | 16 MiB |
| A picture | 1 MiB, 2048×2048, one frame |
| A sound | 2 MiB |

Files must be stored or deflated, not encrypted, and no links.

## Making one

Put `pack.json` and the files it names in a folder, then pack it; the tool
checks the theme as the app does and writes the file only if the app would
take it. It needs nothing but Python 3:

```sh
python3 app/tool/make_theme.py my-theme/              # writes <id>.zip
python3 app/tool/make_theme.py my-theme/ -o sakura.zip
python3 app/tool/make_theme.py --check sakura.zip
```

It also notes what the app would pass over, such as a misspelt colour's name.

## Where themes live

In the app's support folder (on Android, its files folder):

- `appearance.json`: the theme shown and the mode, as
  `{"theme": "default", "mode": "system"}` (`light`, `dark`). Written whole
  (by renaming), as the push engine reads it while the app runs. Without one,
  the device starts with the default theme, written down at once.
- `themes/<id>/`: each installed theme, as `index.json` (its colours in full
  and its files by role) and its files named by their role
  (`logo.png`, `messageSound.ogg`). A theme is installed in a folder of its
  own beside them and renamed into place, so one is there whole or not at
  all.

On Android a FileProvider (`<package>.themes`) serves `themes/`, for
notification channels to play a theme's sound from it.
