# Glass for Windows

> **Personal project — not made for public use.** It's built around one specific setup (a local Plex
> Media Server plus a customised mpv) and may not work on yours. There's no support, no warranty, and
> things change often. Use it at your own risk.

A library app for a Plex collection that plays everything in **your own mpv**: same config, shaders,
scripts and Plex sync, in a borderless mpv window that follows the app.

- Home: rotating backdrop with title logos, Continue watching with episode stills, recently added per library
- Show and movie pages with backdrops, season tabs and episode stills
- Right-click to play from the beginning, mark watched or unwatched, go to the season or show
- Sort libraries; rename, reorder and hide them; adjust the tile size
- Reads Plex's database and artwork directly (a private copy), so it also works while Plex is off

## Quick start (if you want to try it anyway)

You need Windows 10 or 11, [mpv](https://mpv.io/installation/) and **Plex Media Server on the same PC**
(it reads Plex's data folder, so the account running Glass needs read access to it).

1. Download `Glass.exe` from the [latest release](../../releases/latest). No install needed.
2. Run it. It looks for `mpv.exe` and Plex's data folder on its own. If it can't find them, set them in
   **Settings** (gear icon).
3. Click anything to play it.

Keys: Ctrl+F search · Esc / Backspace / mouse back button to go back · F5 refresh · Ctrl+wheel tile size

Settings live in `%APPDATA%\Glass\settings.json`. Nothing is sent anywhere except to the Plex server
on your own PC (when it's running) to mark things watched.
