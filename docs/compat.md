# Compatibility

| Area | State |
| --- | --- |
| BMS, BME, BML, PMS, BMSON; Shift-JIS, EUC-KR, UTF-8 | Works, see [spec.md](spec.md) |
| 4K, 5K, 7K | Played by hand |
| 6K, 10K, 14K, 9K (PMS) | Works in autoplay and tests; manual play by a person is not yet tried |
| Scores | beatoraja and LR2 import, see the gaps in [spec.md](spec.md) |
| Difficulty tables and courses | Works; fetched a real table (Stella: 2379 songs, 26 courses) |
| BGA | Still images and FFmpeg video. Layer video has no transparency |
| Windows | RawInput, WASAPI, ASIO |
| macOS | IOKit HID, CoreAudio |
| Linux | Wayland/X11 key events, optional evdev, JACK, PipeWire, ALSA |

## Skins

Select, decide, play and result skins load in all three formats. Tested with lr2oraja-endlessdream's `default` and `ModernChic`, and KCOOL for LR2. osu! mania `skin.ini` works for play.

Not implemented, so skins using them look incomplete:

- LR2 fonts packed in encrypted `.dxa` archives (unpacked `.lr2font` works, as in beatoraja).
- Pop-up and rarely used beatoraja Lua API: stubs return defaults.

## Versus

In a room, the leading opponent fills the skin's target slots (numbers 121, 151, 153; text 1; float 115), so existing
skins show them with no change. With three or more players the game draws its own score board over the skin.
A skin can show every player itself with private ids, one per player in room order: numbers 90200+ (EX) and
90210+ (notes judged), text 90220+ (name), option 90230+ (seat taken). The game's board stays off for a skin
that uses the EX numbers.
