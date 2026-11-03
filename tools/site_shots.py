#!/usr/bin/env python3
"""Retakes the site's screenshots (site/screens/*.webp) from generated demo charts.
Usage: site_shots.py ACTUON_BIN WORK_DIR
WORK_DIR keeps the downloaded photographs between runs. Needs xvfb-run, Vulkan, ImageMagick and the network once.
The photographs are credited in the footer of every site page: change both together."""
import concurrent.futures, json, math, os, random, shutil, struct, subprocess, sys, urllib.parse, urllib.request, wave

binary, work = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
screens = os.path.join(root, "site/screens")
# Title, difficulty, level, BPM, Wikimedia Commons file.
SONGS = [
    ("Tick Clock", 3, 6, 180, "Pumori,_Nepal,_Asia.jpg"),
    ("Green Number", 2, 5, 150, "Herbert_Lake_beim_Icefields_Parkway.jpg"),
    ("Lane Cover", 4, 9, 170, "Winter_in_Tatry_Mountains_-_Poland.jpg"),
    ("Hard Gauge", 4, 12, 190, "Olkhon_Island,_Capes,_cliffs_at_sunset,_Lake_Baikal,_Russia.jpg"),
    ("Empty Poor", 3, 7, 160, "Utah_Dunes_Landscape_-_West_Desert_District.jpg"),
    ("Kernel Time", 5, 14, 200, "Lake_Kinney_mit_Mount_Whitehorn.jpg"),
]
LANES = ["11", "12", "13", "14", "15", "18", "19"]
# Name: keys pressed in song select (sorted by title, starting on Empty Poor), or a chart and when to shoot it.
SHOTS = {
    "select": (["Return", "Return", "Up"], None, 12000),
    "select2": (["Return", "Return", "Down"], None, 12000),
    "select3": (["Return", "Return", "Down", "Down", "Down"], None, 12000),
    "play": ([], "kernel_time.bms", 26000),
    "result": ([], "kernel_time.bms", 62000),
}


def photo(name, file):
    path = os.path.join(work, "photos", name + ".jpg")
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        url = "https://commons.wikimedia.org/wiki/Special:FilePath/" + urllib.parse.quote(file) + "?width=1280"
        req = urllib.request.Request(url, headers={"User-Agent": "actuon-site-build/1.0"})
        with urllib.request.urlopen(req, timeout=60) as r, open(path + ".part", "wb") as f:
            shutil.copyfileobj(r, f)
        os.replace(path + ".part", path)
    return path


def chart_pack(pack):
    os.makedirs(pack, exist_ok=True)
    with wave.open(os.path.join(pack, "k.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(b"".join(struct.pack("<h", int(9000 * math.exp(-i / 900) * math.sin(i * 0.3))) for i in range(5000)))
    for n, (title, diff, level, bpm, file) in enumerate(SONGS):
        r = random.Random(n)
        slug = title.lower().replace(" ", "_")
        src = photo(slug, file)
        subprocess.run(["magick", src, "-resize", "640x480^", "-gravity", "center", "-extent", "640x480", f"{pack}/{slug}.png"], check=True)
        bmp = []
        for f in range(8):
            subprocess.run(["magick", src, "-resize", "800x", "-gravity", "West", "-crop", f"400x400+{f * 50}+0", "+repage", "-resize", "256x256", f"{pack}/{slug}_{f}.png"], check=True)
            bmp.append(f"#BMP{f + 1:02d} {slug}_{f}.png")
        lines = ["#PLAYER 1", "#GENRE DEMO", f"#TITLE {title}", "#ARTIST actuon demo chart", f"#BPM {bpm}", f"#PLAYLEVEL {level}", f"#DIFFICULTY {diff}", "#RANK 2", f"#STAGEFILE {slug}.png", "#WAV01 k.wav", *bmp]
        for m in range(1, 41):
            lines.append(f"#{m:03d}04:" + "".join(f"{(m * 4 + i) % 8 + 1:02d}" for i in range(4)))
            for ch in LANES:
                lines.append(f"#{m:03d}{ch}:" + "".join("01" if r.random() < 0.1 + level * 0.012 else "00" for _ in range(16)))
            if m % 2 == 0:
                lines.append(f"#{m:03d}16:01" + "00" * 7)
        with open(f"{pack}/{slug}.bms", "w", newline="\r\n") as f:
            f.write("\n".join(lines) + "\n")


def shoot(name):
    pressed, chart, after_ms = SHOTS[name]
    data = os.path.join(work, "data", name)
    shutil.rmtree(data, ignore_errors=True)
    os.makedirs(os.path.join(data, "actuon", "actuon"))
    with open(os.path.join(data, "actuon", "actuon", "config.json"), "w") as f:
        json.dump({"roots": [pack], "tables": []}, f)
    bmp = os.path.join(work, name + ".bmp")
    display = str(170 + list(SHOTS).index(name))
    cmd = ["xvfb-run", "-n", display, "-s", "-screen 0 1280x720x24", binary]
    if chart:
        cmd += [os.path.join(pack, chart), "--auto"]
    cmd += ["--null-audio", "--shot", bmp, "--shot-after-ms", str(after_ms)]
    if pressed:
        cmd += ["--shot-keys", ",".join(pressed)]
    env = {**os.environ, "XDG_DATA_HOME": data}
    env.pop("WAYLAND_DISPLAY", None)
    subprocess.run(cmd, env=env, cwd=root, check=True, timeout=after_ms / 1000 + 60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["magick", bmp, "-quality", "88", os.path.join(screens, name + ".webp")], check=True)
    return name


pack = os.path.join(work, "pack")
chart_pack(pack)
with concurrent.futures.ThreadPoolExecutor(len(SHOTS)) as pool:
    for name in pool.map(shoot, SHOTS):
        print(f"site/screens/{name}.webp")
