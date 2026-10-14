# Ghosty

A native macOS terminal emulator in the spirit of Ghostty, typeset like a newspaper.

Every window is a page: a nameplate in the titlebar, a kicker and headline that track
what you're doing (`~/Projects` while idle, **Now running · vim** while a program has the
foreground), a thick-and-thin rule, and a folio line at the foot. Selections are drawn
with a highlighter pen.

## Editions

| Edition | Look |
| --- | --- |
| **Broadsheet** | Off-white stock, black ink, red accent, serif headlines |
| **Night Edition** | Dark newsprint, cream ink |
| **Wired** | Bright white, condensed black grotesk, signal-orange bar, fluoro highlighter |

`theme = auto` follows the system appearance (Broadsheet / Night Edition). Switch with
**View → Edition** or ⌃⌘1–3.

## Build

Requires only the Xcode Command Line Tools.

```sh
./build.sh          # → build/Ghosty.app
open build/Ghosty.app
```

## Features

- Own VT/xterm parser: 16/256/truecolor, bold/italic/underline/strike/dim/inverse,
  alternate screen, scroll regions, DEC line drawing, bracketed paste, focus events,
  SGR mouse reporting, DECSCUSR cursor shapes, OSC 0/2 titles, OSC 10/11 colour queries,
  OSC 52 clipboard writes
- Core Text rendering with pixel-snapped backgrounds and hand-drawn box drawing,
  block elements and Powerline glyphs
- Wide characters (CJK, emoji), combining marks, IME input
- 10k-line scrollback, word/line selection, ⌘-click links
- Native tabs; new tabs and windows open in the current directory
- ⌘← / ⌘→ / ⌘⌫ / ⌥← / ⌥→ / ⌥⌫ behave like other macOS text fields

## Choosing a folder

- **The path bar** under the masthead shows the current folder as breadcrumbs — click any
  folder to go there. Click the empty part of the bar (or press **⌘L**) to type a path:
  **Tab** completes folder names, **Return** goes, **Esc** cancels. `~` and relative paths work.
- **Click the headline** (the folder name, marked ▾) for a menu of enclosing folders,
  subfolders, recently visited folders and common places.
- **⌘O Go to Folder…** picks a folder with the standard open panel; **⇧⌘O** opens it in a new tab.
- **Drop a folder** on the page to `cd` into it; dropping files pastes their quoted paths.
- **⇧⌘R** reveals the current folder in Finder.
- **⇧⌘B Find Biggest Files** scans the whole disk and lists the 50 largest files (over 100 MB),
  biggest first. External volumes are skipped, and so are files you don't have permission to read.

If a program such as vim is running, the shell can't take a `cd`, so the folder
opens in a new tab instead.

## Configuration

`~/.config/ghosty/config` (⌘, opens it, ⇧⌘, reloads):

```
theme = auto                  # auto | broadsheet | night | wired | light:dark
edition-name = The Ghosty Gazette
font-family = JetBrains Mono  # default: SF Mono
font-size = 13
line-height = 1.25
cursor-style = block          # block | bar | underline
macos-option-as-alt = false
copy-on-select = false
scrollback-limit = 10000
window-padding-x = 30
window-padding-y = 10
window-width = 100
window-height = 30
```
