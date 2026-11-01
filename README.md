<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/actuon_widelogo.svg">
  <img src="assets/brand/actuon_widelogo_light.svg" alt="actuon" width="360">
</picture>

**A BMS player that judges from input hardware timestamps and the audio clock, not from frames.**

[![CI](https://github.com/square3ang/actuon/actions/workflows/ci.yml/badge.svg)](https://github.com/square3ang/actuon/actions/workflows/ci.yml)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-489CFF)](LICENSE)
[![Zig 0.17](https://img.shields.io/badge/zig-0.17-5C6A86)](https://ziglang.org)

[Quick start](#quick-start) · [Controls](#controls) · [Features](#features) · [Docs](#documents)

</div>

> [!NOTE]
> **Public beta preparation.** Developed and tested on Linux. Windows and macOS code paths exist but have never
> been run. See [docs/compat.md](docs/compat.md) for what works and what does not yet.

## Features

| | |
| --- | --- |
| **Formats** | BMS, BME, BML, PMS, BMSON; Shift-JIS, EUC-KR, UTF-8 |
| **Modes** | 4K, 5K, 6K, 7K, 10K, 14K, 9K |
| **Your data** | Imports beatoraja and LR2 score databases |
| **Tables** | Difficulty tables and courses, with chart downloads |
| **Skins** | beatoraja, LR2 and osu! mania skins, chosen per screen and key mode |
| **BGA** | Still images and FFmpeg video, with optional deblocking and FSRCNNX upscaling |
| **Online** | A self-hosted IR server in [`server/`](server) |

```mermaid
flowchart LR
    I[Input hardware timestamps] --> S[Judge]
    A[Audio clock] --> S
    C[Chart] --> S
    S --> D[(Scores and replays)]
    D -. optional .-> R[Self-hosted IR]
```

## Quick start

Needs Zig 0.17.x and these libraries, found through pkg-config: SDL3, SDL3_ttf, PortAudio, SQLite, Lua 5.4,
libarchive and FFmpeg (avformat, avcodec, avfilter, avutil, swscale). Linux also needs Vulkan.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/actuon
```

1. Press <kbd>F10</kbd> for settings and add a library folder. Charts are scanned in the background.
2. <kbd>Enter</kbd> opens a folder or starts a chart. <kbd>Esc</kbd> leaves play.

Packaging scripts for each OS are in [`packaging/`](packaging).

## Controls

| Key | Action |
| --- | --- |
| <kbd>F1</kbd> <kbd>F2</kbd> <kbd>F3</kbd> <kbd>F4</kbd> | Random option, gauge, HS fix, sort |
| <kbd>F5</kbd> | Autoplay |
| <kbd>F6</kbd> <kbd>F7</kbd> <kbd>F8</kbd> | Search, rescan, update difficulty tables |
| <kbd>F9</kbd> <kbd>F10</kbd> | IR ranking and rivals, settings |
| <kbd>↑</kbd> <kbd>↓</kbd> | Green number while playing |
| <kbd>Page Up</kbd> <kbd>Page Down</kbd> | Lane cover while playing |
| <kbd>←</kbd> <kbd>→</kbd> or mouse click | Seek in autoplay: 5 s steps, or to the clicked fraction of the song |

Key bindings and audio devices are in settings. `actuon latency` measures your setup.

<details>
<summary><b>Linux: kernel input timestamps</b></summary>

Without extra setup the player uses SDL's keyboard events. For kernel timestamps it needs to read `/dev/input`:

```sh
sudo install -m644 packaging/linux/70-actuon-input.rules /etc/udev/rules.d/
```

> [!WARNING]
> This lets any program of the logged-in user read all keystrokes. Install it only on a machine you trust.

</details>

<details>
<summary><b>Chart downloads</b></summary>

Press <kbd>Enter</kbd> on a chart a table lists but you do not own. See `download_url` in `config.json`. The default
source is a third-party service. Packages land in `<first library folder>/downloads/`.

</details>

<details>
<summary><b>Crash reports</b></summary>

A crash writes `crash.txt` to the data folder, and the next start moves it to `crash-last.txt` and says so. Nothing is
sent anywhere. Attach the file to a bug report if you want to.

</details>

## Documents

| | |
| --- | --- |
| [Rules and sources](docs/spec.md) | How judging and parsing are defined |
| [Compatibility](docs/compat.md) | What works and what does not yet |
| [Skins](docs/skin.md) | Skin formats and options |
| [Editor preview](docs/editors.md) | Previewing from a chart editor |
| [IR server](docs/ir.md) | Hosting your own rankings |
| [Licenses](docs/licenses.md) | Third-party licenses |

## License

[GPLv3](LICENSE).
