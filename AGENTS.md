# Working on Actuon

Rules for anyone changing this repository, human or agent. README.md says what it is, docs/spec.md how judging works.

## Clean code

- **Least code that fully solves the task.** Delete before adding. No option, wrapper or abstraction without a second real user.
- **One job per function.** Split when a function mixes jobs, not because it is long. Never add a helper only to shorten a function.
- **One rule in one place.** Near-copies that must change together become one function. The same goes across layers: ranking order lives in `RANK_ORDER`, file access in `src/platform/fs.zig`, HTTP in `src/platform/http.zig`.
- **Names say what a thing is.** Use the surrounding file's words. BMS and beatoraja terms (EX, BP, LN, gauge) are fine.
- **Comment only where needed, in one line.** Write a comment only for the why the code cannot show: a hidden constraint, a non-obvious reason, a trap, a unit or sentinel the type hides. Never write what-comments: no function summaries, field descriptions, module headers or section banners. Do not explain what a reader can work out from the code itself. When unsure, leave it out. A known limit gets `shortcut: <the limit>, <when to upgrade>`.
- **No dead code.** Remove unused declarations, columns and flags in the change that orphans them. Do not comment code out.
- **Handle every error on purpose.** A failure that loses data must reach the player or the log. Never report a save that did not happen.
- **Cleanup keeps behaviour.** Keep it apart from feature work. Leave `third_party/` and the generated `src/bms/enc_tables.zig` alone.

## Safety

- Charts, replays, skins, archives and tables are untrusted. Check them at the boundary, and test the rejection.
- Skins run Lua text only, with no file access or native code.
- `src/core/` is deterministic and shared with the server. A change to judging changes every verified score, so `tests/charts/golden.tsv` must stay right.
- The server computes scores from replays. It never trusts a score from a client, and parses uploads only in a child process.

## Tests

New branches, parsers, data writes and security rules get one test that fails when they break.

```sh
zig fmt --exclude src/bms/enc_tables.zig src tools build.zig
zig build test
zig build
zig build tools -Doptimize=ReleaseSafe
python3 tests/golden_check.py "$PWD/zig-out/bin/chartdump"
```

For changes to `site/`, also run `node tests/site_lang.mjs`. To retake the site's screenshots after a visible change, run `python3 tools/site_shots.py zig-out/bin/actuon ~/.cache/actuon-site-shots`. A new string in the game needs a row in `src/ui/i18n.zig`, and new site copy goes in all four pages.

For drawing changes, render every screen on the old build, then compare on the new one. This needs `xvfb-run` and Vulkan,
and the images are not committed because they differ between GPUs:

```sh
python3 tests/ui_shots.py zig-out/bin/actuon "$OLD_DIR"
python3 tests/ui_shots.py zig-out/bin/actuon "$NEW_DIR" "$OLD_DIR"
```

For server changes, also run:

```sh
zig build core -Doptimize=ReleaseSafe
(cd server && cargo test --release && cargo build --release)
python3 tests/ir_e2e.py server/target/release/actuon-ir zig-out/bin/mkreplay tests/charts/stop.bms "$(mktemp -d)"
python3 tests/backup_check.py server/backup/backup.sh server/target/release/actuon-ir "$(mktemp -d)"
```
