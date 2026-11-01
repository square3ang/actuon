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

Play and result skins load in all three formats. Tested with lr2oraja's `default` and `ModernChic`, and KCOOL for LR2.

Not implemented, so skins using them look incomplete:

- Select and decide screens: these still use the built-in UI.
- LR2 bitmap fonts.
- Runtime images with `gr` ≥ 100.
- The skin's custom option chooser.
- `#SPEED` and hidden or lift covers.
- BPM and judge graphs.
- Pop-up and rarely used beatoraja Lua API: stubs return defaults.
