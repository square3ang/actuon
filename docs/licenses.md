# Licenses

actuon is GPLv3 (`LICENSE`). Everything it links or bundles is compatible with that.

| Component | License | Use |
| --- | --- | --- |
| SDL3, SDL3_ttf | zlib | window, input, rendering, text |
| PortAudio | MIT | audio |
| SQLite | public domain | database |
| Lua 5.4 | MIT | skin scripts |
| libarchive | BSD 2-clause | chart packages |
| FFmpeg | LGPL 2.1+, or GPL by build options | video BGA |
| sokol_gfx | zlib | rendering, bundled in `third_party/` |
| stb_vorbis, stb_image, dr_wav, dr_flac, dr_mp3 | public domain or MIT | decoding, bundled in `third_party/` |
| argon2, getrandom, rusqlite, serde, serde_json, sha2, tiny_http | MIT or Apache-2.0 (Apache-2.0 is GPLv3 compatible) | IR server |
| serde, tiny_http, ureq | MIT or Apache-2.0 | IR web page |
| FSRCNNX | LGPL 3 | BGA upscaling shaders, generated from `third_party/fsrcnnx` |
| ASIO SDK | GPLv3 option from Steinberg | ASIO output on Windows, through the MSYS2 `portaudio-asio` package |

Assets: the player ships no skins or sound files, and the icon is our own. Menu sounds and music are synthesized at runtime by `src/audio/menu_sound.zig`. The SUITE font (SIL OFL 1.1, `assets/fonts/LICENSE-SUITE.txt`) is built into the binary. System CJK fonts are used as fallbacks for characters it lacks.
No IIDX assets may be added. The crate list covers direct dependencies only, so run `cargo license` before a release.

## Projects referenced

actuon learned from these players. Ported code is noted per file.

| Project | License | Use |
| --- | --- | --- |
| [beatoraja](https://github.com/exch-bms2/beatoraja) | GPLv3 | behaviour, skin and score formats, controls |
| [lr2oraja](https://github.com/wcko87/lr2oraja) | GPLv3 | the base of lr2oraja-endlessdream |
| [jbms-parser](https://github.com/seraxis/jbms-parser) | no license file of its own; built as a submodule of lr2oraja-endlessdream (GPLv3) | chart parsing follows it |
| [lr2oraja-endlessdream](https://github.com/seraxis/lr2oraja-endlessdream) | GPLv3 | rules and test reference; the judge, gauges and judge windows are ported |
| [Qwilight](https://vcs.taehui.net/root/qwilight/) | Microsoft Reference Source License | Format compatibility only: `#4K` and `#6K` chart headers and their lane mapping. No Qwilight code is included |
| [osu!](https://github.com/ppy/osu) | MIT for code; its resources have their own terms | osu! mania skin format, behaviour reference |

## Intro page

`site/` shows generated demo charts. Their artwork comes from Wikimedia Commons, credited on the page: photographs by Vyacheslav Argenberg and Radek Kucharski (CC BY 4.0), Florian Fuchs (CC BY 3.0), and the Bureau of Land Management (public domain).
