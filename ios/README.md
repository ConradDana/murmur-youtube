# Murmur for iPad

Dictation into any iPad app — including **Jump Desktop**, where the text arrives on your
Mac as typing. It runs on the iPad itself: Apple's on-device speech engine, optional
Apple Intelligence cleanup, and the same dictionary as the Mac app. No audio leaves the
iPad.

**Status:** written but not yet compiled or run. The `iPad` GitHub Actions workflow
builds it on every push, and the first real run on an iPad is the test — see
[What to check first](#what-to-check-first).

---

## How it works

iPadOS doesn't allow what the Mac app does (a global hotkey and typing into other apps),
so the iPad version is two pieces:

- **The Murmur keyboard.** Switch to it with 🌐 in any app. It's a big mic button plus
  space, delete, return and undo. It types the result where your cursor is.
- **The Murmur app.** Keyboards aren't allowed to use the microphone, so the app does the
  listening. The keyboard tells it when to start and stop.

The app can only *start* the microphone while it's on screen. So the first time you tap the
mic, the keyboard opens the app, which starts a **session** and keeps the mic ready in the
background. Tap **◀** in the top-left corner to go back. From then on, the mic button works
instantly until the session ends: by default after 15 idle minutes, or when a call or
another app takes the microphone.

While a session runs you'll see the orange microphone dot. Murmur keeps the mic open so it
can respond instantly, but it throws the audio away unless you're dictating.

### The mic button

- **Hold, talk, release** — push-to-talk, like the Mac.
- **Tap once, talk, tap again** — hands-free, for longer dictation.
- **↶ (undo)** removes the last dictation.

---

## Building it

You need a Mac with **Xcode** (free, from the Mac App Store) and an **Apple ID**. No
programming experience needed — you're running Apple's tools on code that's already
written.

### Free Apple ID vs. the Apple Developer Program ($99/year)

| | Free Apple ID | Developer Program |
|---|---|---|
| App and **Try it here** (dictate, copy, paste) | ✅ | ✅ |
| The Murmur **keyboard** | ❌ needs an App Group | ✅ |
| How long an install lasts | 7 days, then reinstall from Xcode | a year |
| Install without the cable (TestFlight) | ❌ | ✅ |

Set `MURMUR_PAID_ACCOUNT` in `ios/Config.xcconfig` to match. Starting free and switching
later is fine: change it to `YES`, run `ios/setup.sh` again, and press Run.

### Step by step (first time)

1. **Install Xcode** from the Mac App Store and open it once. Let it install any extra
   components it asks for. Sign in with your Apple ID in **Xcode ▸ Settings ▸ Accounts**.
2. **Get the code.** Open Terminal (⌘Space, type Terminal) and paste:
   ```bash
   mkdir -p ~/Developer && cd ~/Developer
   git clone https://github.com/ConradDana/murmur-youtube
   open -e murmur-youtube/ios/Config.xcconfig
   ```
   Keep it out of `~/Desktop` and `~/Documents` — iCloud sync interferes with builds.
3. **Edit the config** that just opened in TextEdit: change `com.example.murmur` to
   something like `com.yourname.murmur`. Save and close.
4. **Generate the project and open it in Xcode:**
   ```bash
   murmur-youtube/ios/setup.sh
   ```
5. **Pick your team.** In Xcode's left sidebar click the blue **Murmur** project icon.
   For each of the targets **Murmur**, **MurmurKeyboard** and **MurmurDictionary**: open the
   **Signing & Capabilities** tab and choose your name under **Team**.
6. **Plug the iPad into the Mac** with a cable. Unlock it and tap **Trust** if asked.
   At the top of the Xcode window, choose your iPad as the run destination.
7. **Press Run** (▶, or ⌘R). The first build takes a minute or two.
8. **One-time iPad prompts:**
   - *Developer Mode:* iPad **Settings ▸ Privacy & Security ▸ Developer Mode**, turn it
     on, restart when asked. Then press Run again.
   - *Untrusted developer:* **Settings ▸ General ▸ VPN & Device Management**, tap your
     Apple ID, **Trust**.

After the first install, Xcode can usually install over Wi-Fi with the cable unplugged, as
long as both are on the same network (**Window ▸ Devices and Simulators ▸ Connect via
network**).

### Later, with the Developer Program

TestFlight installs without the cable: **Product ▸ Archive**, then **Distribute App ▸
TestFlight Internal Only**. Install the TestFlight app on the iPad and the build shows up
there a few minutes later. Xcode offers to create the App Store Connect record it needs.

## Setting up the keyboard

1. **Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard ▸ Murmur.**
2. Tap **Murmur** in that list and turn on **Allow Full Access**. Without it the keyboard
   can't reach the app. "Full Access" is iPadOS's name for that link; Murmur doesn't use
   the network.
3. In any app, hold 🌐 and choose Murmur.

---

## What to check first

None of this has run on a real iPad yet. In this order:

1. **The app on its own.** Open Murmur, tap **Start session**, then hold **Hold to talk**
   and speak. Text should appear under it. This proves the mic, speech engine and cleanup.
2. **The keyboard in Notes.** Switch to Murmur, tap the mic. It should open the app and
   start a session. Go back with ◀, hold the mic and speak.
3. **The keyboard in Jump Desktop.** Two things to find out:
   - whether Jump lets you switch to a third-party keyboard at all, and
   - whether text typed by the keyboard arrives on the Mac correctly.
4. **With a hardware keyboard attached.** iPadOS may hide third-party keyboards when a
   hardware keyboard is connected. If it does, the in-app **Try it here** box plus copy
   and paste is the fallback.

The opening-the-app step uses a workaround (the keyboard finds the system's
`UIApplication` and asks it to open a link). Other dictation keyboards use the same
approach, but Apple has broken it before. If tapping the mic only shows "Open the Murmur
app and tap Start session", open the app yourself and start a session there.

## Code

```
ios/
├── project.yml            XcodeGen spec — targets, Info.plist keys, entitlements
├── Config.xcconfig        your Team ID and bundle ID
├── Shared/Bridge.swift    keyboard ⇄ app: App Group state + Darwin notifications
├── App/
│   ├── MurmurApp.swift
│   ├── SessionController.swift   the mic session and every dictation
│   └── ContentView.swift
└── Keyboard/KeyboardViewController.swift
```

The speech engine, mic capture, cleanup and dictionary aren't copied: `project.yml`
compiles them straight from `Sources/MurmurYouTube` and `Sources/MurmurDictionary`, so
the Mac and iPad apps stay in step.

**Not on the iPad yet:** Parakeet (it's a ~470 MB download on first use; Apple's engine is
the default on the Mac too), compare mode, and the dashboard.
