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
| stb_vorbis, stb_image, dr_wav, dr_flac, dr_mp3 | public domain or MIT | decoding, bundled in `third_party/` |
| argon2, getrandom, rusqlite, serde, serde_json, sha2, tiny_http | MIT or Apache-2.0 (Apache-2.0 is GPLv3 compatible) | IR server |
| lr2oraja, jbms-parser | GPLv3 | rules and test reference, ported code is noted per file |
| ASIO SDK | GPLv3 option from Steinberg | not bundled; only through a PortAudio built with it |

Assets: the player ships no skins or sound files, and the icon is our own. Menu sounds and music are synthesized at runtime by `src/audio/menu_sound.zig`. The SUITE font (SIL OFL 1.1, `assets/fonts/LICENSE-SUITE.txt`) is built into the binary. System CJK fonts are used as fallbacks for characters it lacks.
No IIDX assets may be added. The crate list covers direct dependencies only, so run `cargo license` before a release.
