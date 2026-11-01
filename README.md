# actuon

A BMS player for Windows, macOS and Linux, licensed under GPLv3. It keeps your beatoraja and LR2 scores,
difficulty tables and skins, and judges from input hardware timestamps and the audio clock, not from frames.

**Status: public beta preparation.** Developed and tested on Linux. Windows and macOS code paths exist but have
never been run. See [docs/compat.md](docs/compat.md) for what works and what does not yet.

## Build

Needs Zig 0.17.x and these libraries, found through pkg-config:
SDL3, SDL3_ttf, PortAudio, SQLite, Lua 5.4, libarchive, FFmpeg (avformat, avcodec, avutil, swscale).

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/actuon
```

Packaging scripts for each OS are in `packaging/`.

## First run

1. Press F10 for settings and add a library folder. Charts are scanned in the background.
2. Enter opens a folder or starts a chart. Esc leaves play.

| Key | Action |
| --- | --- |
| F1 / F2 / F3 / F4 | random option / gauge / HS fix / sort |
| F5 | autoplay |
| F6 / F7 / F8 | search / rescan / update difficulty tables |
| F9 / F10 | IR ranking and rivals / settings |
| Up, Down | green number while playing |
| Page Up, Page Down | lane cover while playing |
| Left, Right, mouse click | seek in autoplay (5 s steps, or to the clicked fraction of the song) |

Default key bindings and audio devices are in settings. `actuon latency` measures your setup.

### Linux input

Without extra setup the player uses SDL's keyboard events. For kernel timestamps it needs to read `/dev/input`:

```sh
sudo install -m644 packaging/linux/70-actuon-input.rules /etc/udev/rules.d/
```

This lets any program of the logged-in user read all keystrokes. Install it only on a machine you trust.

## Features beyond playing

- **Download**: Enter on a chart a table lists but you do not own. See `download_url` in `config.json`.
  The default source is a third-party service; packages land in `<first library folder>/downloads/`.
- **Editor preview**: see [docs/editors.md](docs/editors.md).
- **Import**: beatoraja and LR2 score databases, see settings.
- **Online**: a self-hosted IR in `server/`, see [docs/ir.md](docs/ir.md).
- **Skins**: see [docs/skin.md](docs/skin.md).

## Crash reports

A crash writes `crash.txt` to the data folder, and the next start moves it to `crash-last.txt` and says so.
Nothing is sent anywhere; attach the file to a bug report if you want to.

## Documents

[Rules and sources](docs/spec.md) · [compatibility](docs/compat.md) · [licenses](docs/licenses.md)
