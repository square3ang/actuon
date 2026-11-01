# Compatibility

| Area | State |
| --- | --- |
| BMS, BME, BML, PMS, BMSON; Shift-JIS, EUC-KR, UTF-8 | Works, see [spec.md](spec.md) |
| 4K, 5K, 6K, 7K, 10K, 14K, 9K (PMS) | Works in autoplay and tests; manual play by a person is not yet tried |
| Scores | beatoraja and LR2 import, see the gaps in [spec.md](spec.md) |
| Difficulty tables and courses | Works; fetched a real table (Stella: 2379 songs, 26 courses) |
| BGA | Still images and FFmpeg video. Layer video has no transparency |
| Windows (RawInput, WASAPI, ASIO) | Written, never built or run |
| macOS (IOKit HID, CoreAudio) | Written, never built or run |
| Linux (evdev, JACK, PipeWire, ALSA) | Developed here |

## Skins

Select, decide, play and result skins load in all three formats. Tested with lr2oraja-endlessdream's `default` and `ModernChic`, and KCOOL for LR2. osu! mania `skin.ini` works for play.

Not implemented, so skins using them look incomplete:

- LR2 bitmap fonts.
- Runtime images with `gr` ≥ 100.
- Pop-up and rarely used beatoraja Lua API: stubs return defaults.
