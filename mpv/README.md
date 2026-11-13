# Glass for mpv

> **Personal project — not made for public use.** Written for one PC and one Plex setup; it may not
> work on yours, and there's no support. Windows only.

The playback interface used by Glass for Windows, as a standalone mpv script: floating glass controls,
a library page when no video is open, Plex titles/posters/resume points, an upscaling switch, and an
optional sync that sends your progress back to Plex.

## Install

1. Install [mpv for Windows](https://mpv.io/installation/) (the shinchiro builds work well).
2. Open `%APPDATA%\mpv` (create it if it doesn't exist) and copy in:
   - `scripts\glass.lua`
   - `script-opts\glass.conf`
   - optionally `mpv.conf.example` → rename to `mpv.conf`, and `input.conf.example` → `input.conf`
     (merge them into yours if you already have them). `osc=no` is required either way.
3. Optional: install the [Inter](https://rsms.me/inter/) font.
4. Open a video in mpv. Move the mouse to see the controls; with no video open you get the library page.

## Set it up for your PC (edit `glass.conf`)

- **Library page:** set `library_folders` to your video folders (see the example in the file).
- **Plex:** set `plex_db` to Plex's database, replacing `YOUR-USER` with the Windows account that runs
  Plex. If you run mpv from a *different* Windows account, give that account read access:
  `icacls "C:\Users\YOUR-USER\AppData\Local\Plex Media Server" /grant OTHER-USER:(OI)(CI)RX /T`
- **Upscaling:** download the shaders into `%APPDATA%\mpv\shaders` (for example
  [FSRCNNX](https://github.com/igv/FSRCNN-TensorFlow/releases),
  [ArtCNN](https://github.com/Artoriuz/ArtCNN), and KrigBilateral / SSimDownscaler from
  [igv's gists](https://gist.github.com/igv)). Without them the switch simply does nothing.

## Optional: send progress back to Plex

Watching in mpv can update Plex's resume points and watched status (newest wins, so it never
overwrites newer progress from another Plex app).

1. Copy the `GlassSync` folder to `C:\Users\Public\GlassSync`.
2. On the Windows account that **runs Plex**, run once in PowerShell:
   `powershell -ExecutionPolicy Bypass -File C:\Users\Public\GlassSync\install-sync-task.ps1`
   This adds a task that syncs at sign-in and every 30 minutes (log: `sync.log` in that folder).
3. On that same account, set `sync_now=yes` in `glass.conf`.

While Plex is running on the same account, Glass also keeps Plex's resume point updated during
playback (every 20 s and when you pause), so another device picks up where you stopped.

## Privacy

Nothing leaves your PC except requests to the Plex server on the same PC. The Plex token is read
from your own registry and is never written into logs or command lines.
