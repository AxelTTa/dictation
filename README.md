# Dictation

Talk instead of typing, on a Mac or a Windows PC. Free, and nothing leaves your computer. Built on [Handy](https://github.com/cjpais/Handy).

- **Tap a key, talk, tap again.** The text lands in the app you started in, even if you switched apps while talking.
- **It knows your words.** While you talk, a second, stronger model (Whisper) works through what you say. It is given your own list of names, products and jargon, so "YellowForce" stops coming out as "yellow folder". Its text is ready less than a second after you stop. If it is slow or unsure, you get the fast live text instead.
- **Punctuation that holds up.** Long dictations get their full stops and commas back.
- **Never loses words.** If no text box took the paste, the text is still on the clipboard.

## Set it up

### Mac

You need macOS 13 or newer (Apple Silicon recommended), an admin account and about 3 GB free. In Terminal:

```bash
git clone https://github.com/AxelTTa/dictation.git ~/dictation
```

```bash
zsh ~/dictation/mac/setup.sh
```

The script installs everything and tells you the three things only you can click:
- Allow Microphone and Accessibility for Handy.
- Allow the microphone for Handy Router.
- Set the 🌐 key to "Do Nothing".

**To use it, tap Fn.**

### Windows

You need Windows 10 or 11 and about 3 GB free. A graphics card (any recent NVIDIA, AMD or Intel) lets the accurate pass keep up. Without one you still get the live text, punctuation and the paste into the right window.

1. On this page, click **Code > Download ZIP** and unzip it.
2. In the `windows` folder, double-click **`install.cmd`**. If Windows warns you, click "More info", then "Run anyway".

Or paste this in PowerShell:

```
irm https://raw.githubusercontent.com/AxelTTa/dictation/main/windows/install.ps1 | iex
```

**To use it, press Ctrl+Space.** You can change the shortcut in Handy's settings (tray icon).

## Using it

- **Talk:** tap the shortcut, talk, tap it again.
- **Talk while holding:** hold the shortcut for more than a second; the recording stops when you let go.
- **Cancel:** Shift+Escape.
- **Missed paste:** if you weren't in a text box, the words are on the clipboard. Click where they go and paste.

## Your words

Add the names, products and jargon that come out wrong, one per line, spelled the way you want them. Put the most important first: Whisper only reads about the first 65. Each change counts from your next dictation.

- **Mac:** `~/Library/Application Support/handy-router/vocabulary.txt`
- **Windows:** `%LOCALAPPDATA%\dictation\vocabulary.txt`

## Update, remove, logs

| | Mac | Windows |
|---|---|---|
| Update | `cd ~/dictation && git pull && zsh mac/setup.sh` | download again, run `install.cmd` |
| Remove | `zsh ~/dictation/mac/uninstall.sh` | `windows\uninstall.cmd` |
| Logs | `~/Library/Logs/handy-*.log` | `%LOCALAPPDATA%\dictation\logs` |

Removing keeps Handy and your word list. The logs hold counts and timings, never your words.

## Status

- **Mac:** used every day since November 2026, with tests (`zsh mac/build.sh test`).
- **Windows:** new. Its install and test (`windows\test.ps1`) are written but have not yet run on a real Windows PC. Tell Axel what breaks.
- **Handy version:** both setups pin Handy 0.9.8 and turn off its update check, because the helpers read its log.

How it works, and why each piece is there: [docs/how-it-works.md](docs/how-it-works.md).
