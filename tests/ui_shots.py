#!/usr/bin/env python3
"""Renders every screen headlessly, to check a change to drawing code leaves them as they were.
Usage: ui_shots.py ACTUON_BIN OUT_DIR [BASELINE_DIR]
Run it on the old build, then on the new one with the old OUT_DIR as baseline. Needs xvfb-run and Vulkan.
Images are not committed: they differ between GPUs."""
import concurrent.futures, json, os, subprocess, sys, tempfile

binary, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
baseline = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else None
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
chart = os.path.join(root, "tests/charts/stop.bms")
KEY_START_MS, KEY_GAP_MS, SETTLE_MS = 2000, 300, 2000
# Share of pixels allowed to differ by more than the noise level. Play moves with the clock.
EXACT, MOVING = 0.002, 0.06


def keys(*names):
    return list(names)


def tab(i, *more):
    return ["F10"] + ["Down"] * i + list(more)


SCREENS = {
    "select_root": (keys(), [], EXACT),
    "select_library": (keys("Return"), [], EXACT),
    "select_songs": (keys("Return", "Return", "Down"), [], EXACT),
    "select_options": (keys("F1", "F2", "F3", "F4", "F5"), [], EXACT),
    "select_search": (keys("F6"), [], EXACT),
    "select_courses": (keys("Up", "Return"), [], EXACT),
    "select_ir": (keys("F9"), [], EXACT),
    "settings_tabs": (tab(0), [], EXACT),
    "settings_library": (tab(0, "Return"), [], EXACT),
    "settings_tables": (tab(1, "Return"), [], EXACT),
    "settings_audio": (tab(2, "Return"), [], EXACT),
    "settings_display": (tab(3, "Return"), [], EXACT),
    "settings_skin": (tab(4, "Return"), [], EXACT),
    "settings_timing": (tab(5, "Return"), [], EXACT),
    "settings_edit": (tab(5, "Return", "Return"), [], EXACT),
    "settings_scores": (tab(6, "Return"), [], EXACT),
    "settings_online": (tab(7, "Return"), [], EXACT),
    "settings_controls": (tab(8, "Return"), [], EXACT),
    "settings_capture": (tab(8, "Return", "Down", "Return"), [], EXACT),
    "play": (keys(), [chart, "--auto"], MOVING),
    "play_double": (keys(), [os.path.join(root, "tests/charts/double.bme"), "--auto"], MOVING),
    "result": (keys(), [chart, "--auto"], EXACT),
}
# After the chart has ended, for the result screen.
RESULT_MS = 30000


def render(name):
    pressed, args, _ = SCREENS[name]
    path = os.path.join(out, name + ".bmp")
    wait = KEY_START_MS + len(pressed) * KEY_GAP_MS + SETTLE_MS
    if name == "result":
        wait = RESULT_MS
    with tempfile.TemporaryDirectory() as data:
        cfg = os.path.join(data, "actuon", "actuon")
        os.makedirs(cfg)
        with open(os.path.join(cfg, "config.json"), "w") as f:
            json.dump({"roots": [os.path.join(root, "tests/charts")], "tables": []}, f)
        # xvfb-run -a races when several start at once, so each screen gets its own display.
        display = str(100 + list(SCREENS).index(name))
        cmd = ["xvfb-run", "-n", display, "-s", "-screen 0 1280x720x24", binary, *args, "--null-audio", "--shot", path, "--shot-after-ms", str(wait)]
        if pressed:
            cmd += ["--shot-keys", ",".join(pressed)]
        env = {**os.environ, "XDG_DATA_HOME": data}
        env.pop("WAYLAND_DISPLAY", None)
        subprocess.run(cmd, env=env, cwd=root, check=True, timeout=wait / 1000 + 60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return name


def pixels(path):
    with open(path, "rb") as f:
        data = f.read()
    return data[int.from_bytes(data[10:14], "little"):]


def difference(a, b):
    if len(a) != len(b):
        return 1.0
    changed = sum(1 for i in range(0, len(a), 4) if max(abs(a[i] - b[i]), abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2])) > 8)
    return changed / (len(a) / 4)


os.makedirs(out, exist_ok=True)
with concurrent.futures.ThreadPoolExecutor(4) as pool:
    list(pool.map(render, SCREENS))
failed = 0
for name, (_, _, allowed) in SCREENS.items():
    new = pixels(os.path.join(out, name + ".bmp"))
    assert any(new), f"{name}: empty image"
    if baseline:
        d = difference(pixels(os.path.join(baseline, name + ".bmp")), new)
        ok = d <= allowed
        failed += not ok
        print(f"{'ok  ' if ok else 'DIFF'} {name}: {d * 100:.2f}% of pixels changed")
print(f"{len(SCREENS)} screens rendered in {out}")
sys.exit(1 if failed else 0)
