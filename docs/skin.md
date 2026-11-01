# Skins

Set `skin` in `config.json`, or in settings, to a folder. The file whose declared type matches the mode is used. Files reload
when they change, including during play.

| Format | Files | Reference |
| --- | --- | --- |
| LR2 | `.lr2skin` (CSV) | `#INFORMATION` type, LR2 numeric ids |
| beatoraja JSON | `.json` | lr2oraja-endlessdream `JsonSkinLoader` |
| beatoraja Lua | `.luaskin` | same objects, returned from a script |

**Writing a new skin:** there is no separate actuon format. Use the beatoraja JSON format for declarations and Lua for logic:
both already support hot reload, and they keep skins usable in other players. Lua runs sandboxed, without file access, with
only part of `os`.

What is not implemented is listed in [compat.md](compat.md).
