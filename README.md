# Toss

Drag a file toward the menu bar and drop it on a face to send it on Telegram, from your own account.

A few chat avatars sit in the menu bar. Start dragging a file (or images, text, a link) toward them and a glass panel drops down. Move left or right to pick a chat, let go, and it is sent. The original file stays where it was.

## Requirements

- macOS 15 or later (TDLib's prebuilt binaries target macOS 15)
- Xcode 16+ to build (tested with Xcode 27 / Swift 6.4)
- A Telegram API ID and hash from <https://my.telegram.org/apps>

## Build

```bash
./scripts/build-app.sh
ditto dist/Toss.app /Applications/Toss.app
open /Applications/Toss.app
swift test --build-system native   # double-tap state machine
```

The first build downloads TDLibFramework (a prebuilt TDLib xcframework, about 300 MB) once; SwiftPM caches it. After that a release build compiles only Toss's own sources and takes a few seconds. Nothing in TDLib is compiled locally.

For a universal (Apple silicon + Intel) build: `TOSS_ARCHS="arm64 x86_64" ./scripts/build-app.sh`.

`build-app.sh` signs with your Apple Development identity when there is one, so Keychain keeps trusting the app across rebuilds. Override with `TOSS_SIGNING_IDENTITY`, or set `TOSS_BUNDLE_ID` / `TOSS_APP_PATH` for a side-by-side test build.

## First run

1. Open my.telegram.org, sign in, open **API development tools**, and create an app (any name). Copy **App api_id** and **App api_hash**.
2. In Toss, paste both and press Continue. They are stored in your login Keychain.
3. Enter your phone number, then the code Telegram sends you, then your two-step verification password if you have one.
4. Pick up to six chats for the menu bar in Settings. Saved Messages ("Me") is added by default.

Every builder uses their own `api_id` and `api_hash`; none are included in this repository. Toss reads them only from your login Keychain (service = the app's bundle id), where step 2 or the script below puts them.

Optional: `scripts/import-credentials.sh <env file> [Toss.app]` stores `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` from an env file into the same Keychain items, so step 2 is skipped. It does not log in.

## Using it

- Drag anything toward the avatars: files from Finder, Photos, Mail or a browser, a link from an address bar or a page, selected text (plain or rich), or an image. A small card with a preview follows the pointer inside the panel.
- Let go on an avatar to pick it. Several chats: hold still on an avatar for half a second while dragging until its ring fills; it jumps onto the card. Hold on it again to take it back. A quick shake removes the last pick. With picks, letting go anywhere on the panel keeps them; letting go with no picks and not on an avatar cancels.
- After letting go, nothing is sent yet: the card settles in the middle with the picked names under it, and the panel works like the clipboard panel below (hold on an avatar or click it to change the picks; hold on the card for 1.5 s, click it, or press Space or Return to send; Esc or a click outside cancels). Promised files (Photos, Mail, browsers) are received at the drop, so a later send still has them.
- Settings → Confirm before sending (on by default) controls this for drags. Off: letting go sends right away, to the chat under the pointer (the panel is split into one column per chat when nothing is picked) or to the picks. The clipboard panel always confirms.
- Sends run in parallel; each chat shows its own progress, then a check or a red mark. Hover a failed one until its ring fills to retry.
- Links and text go as messages (links with a preview); text over 4096 characters goes as a .txt file.
- Images go as photos (Settings → Send images as photos to send originals as files). HEIC, TIFF and WebP are converted to JPEG for photos. GIFs and everything else go as files. Folders are zipped. Several items of the same kind are grouped into albums of up to 10.
- Letting go elsewhere or pressing Esc cancels; the card flies back.
- Click the panel to dismiss it while a large upload continues in the background.
- Motion follows the system's Reduce Motion setting.

### Sending what you copied

- Tap Option twice quickly (either Option key), press ⌥⌘V, or click the avatars in the menu bar. The panel drops with a card showing what is on the clipboard (link, text, image or files). The clipboard is read only at that moment.
- No picks: click an avatar to send straight to it.
- Several chats: press 1–5, hold still on avatars for half a second, or click them once you have a pick. Then rest the pointer on the card for 1.5 s (a ring runs round it; moving off cancels), click the card, or press Space or Return. A pointer that was already resting on the card when you picked has to move a little first.
- Esc or a click outside closes without sending; focus goes back to the app you were in.
- An empty clipboard shows an empty card and the panel closes by itself.
- The double tap needs Input Monitoring: Settings → Send clipboard shows "Needs Input Monitoring" with an Allow… button, which opens System Settings → Privacy & Security → Input Monitoring; turn Toss on there. It starts working within a couple of seconds, no relaunch. Toss watches only modifier-key changes, never what you type. Holding Option, ⌥+key, ⌥-click or ⌥-drag never counts. Until it's granted, ⌥⌘V works.
- Settings → Send clipboard: "Double-tap ⌥" (default; the shortcut below keeps working too) or "Shortcut" (only the shortcut).
- Change the shortcut in Settings (Or press / Shortcut): click it and press the new keys (it needs ⌘, ⌥ or ⌃). Delete resets it to ⌥⌘V, Esc cancels. If another app already owns the shortcut, it turns red.
- Right-click (or ⌃/⌥-click) the avatars for Settings and Quit.

## Where things live

- Login session: `~/Library/Application Support/app.toast.toss/tdlib/`, encrypted with a key kept in Keychain.
- API ID, API hash and database key: login Keychain, service `app.toast.toss`.
- Preferences: `defaults read app.toast.toss`.
- Log out from Settings removes the session from Telegram and from disk.

## Layout

```
Package.swift                 SwiftPM manifest (TDLibFramework binary dependency)
Resources/*.lproj             English and Simplified Chinese strings
scripts/build-app.sh          builds and signs dist/Toss.app
scripts/import-credentials.sh optional Keychain pre-fill
Sources/Toss/
  main.swift                  entry point (+ --import-credentials)
  AppDelegate.swift           windows, menu
  TDJSON.swift                async wrapper over TDLib's JSON interface
  Telegram.swift              login flow, chats, avatars, sending, upload progress
  Outgoing.swift              turns drops into Telegram messages; reads the drag pasteboard
  Coordinator.swift           drag and clipboard flows, dwell-to-pick, parallel-send state, sent sound
  HotKey.swift                global clipboard shortcut (Carbon, no Accessibility permission)
  OptionDoubleTap.swift       Option double tap through a listen-only flagsChanged event tap
  Card.swift                  preview card content (link titles and icons, thumbnails)
  DragWatcher.swift           notices drags anywhere on screen
  StatusItem.swift            menu bar avatar cluster and its drop target
  Panel.swift                 the glass drop panel (SwiftUI)
  DropView.swift              AppKit drag destination
  Avatar.swift                avatar drawing (photos, initials, Saved Messages)
  SetupView.swift             first-run login
  SettingsView.swift          chat picker and options
  Keychain.swift              Keychain storage
  Storage.swift               paths and preferences
  Preview.swift               UI preview mode with fake chats
Sources/TapDetection/         the double-tap state machine (no AppKit), unit-tested
Tests/TapDetectionTests/      `swift test` covers holds, ⌥+key, ⌥-drag, other modifiers, timing
```

The app icon is rendered from code: `python3 scripts/make-icon.py` (needs Pillow and numpy) writes `Resources/AppIcon.iconset`, and `build-app.sh` turns it into `AppIcon.icns` with `iconutil`.

TDLib is used through its JSON interface (`td_send` / `td_receive`) rather than TDLibKit, whose ~170k lines of generated Swift would add minutes to every clean build.

## Preview mode

Shows the UI with fake chats, without TDLib or Keychain:

```bash
open -n --env TOSS_PREVIEW=panel --env TOSS_PREVIEW_STATE=demo dist/Toss.app
# TOSS_PREVIEW=panel|setup|settings|lab
# TOSS_PREVIEW_STATE=demo|clipboard|sendcheck|dragcheck|sendring:<0–1>|card:link|card:text|card:image|card:files|shaketest
# TOSS_PREVIEW_REDUCE_MOTION=1 behaves as if Reduce Motion were on
# TOSS_PREVIEW_DISPLAY=<CGDirectDisplayID> puts the window or panel on that display
```

## License

MIT. See [LICENSE](LICENSE).
