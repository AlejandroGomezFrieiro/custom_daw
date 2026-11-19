#!/usr/bin/env python3
"""table.py: the runs of paw.sh and daw.sh as JSON lines, and as tables.

  table.py collect <results dir> <set> [tag]  one JSON line per run
  table.py show <file.jsonl | results dir>... [--set S] [--split]

collect reads <results dir>/<label>/cpu.txt (and the window's stats, the
terminal's output) for the labels that rounds.sh and pairs.sh give
(<tag>-<round>[-base|-new]-<setup>-<view>-<size>) and prints one object a
run: set, tag, round, build, setup, view, size, procs ({name: [% of one
core, RSS MB]}), load, and when known frames (a second), drawn (% of the
window drawn a frame), passes (egui passes a second) and term_bytes (bytes
a second to the terminal).

show prints a Markdown table: for each set, setup, build, view and size,
the median (smallest-largest) of the total CPU (every process of the
program and its display server, in % of one core), the program alone, the
display server, the resident memory of the program, and the load average.
--split adds the columns of paw's kernel, its window or emulator, and
the bytes a second written to the terminal.
"""
import glob, json, os, re, statistics, sys

VIEWS = ("arrange", "mixer", "roll", "devices", "split", "session", "notation", "idle")


def parse_label(name):
    f = name.split("-")
    if len(f) < 5 or f[-2] not in VIEWS or "x" not in f[-1]:
        return None
    tag, rnd, rest = f[0], f[1], f[2:-2]
    build = None
    if rest and rest[0] in ("base", "new"):
        build, rest = rest[0], rest[1:]
    return dict(tag=tag, round=int(rnd), build=build, setup="-".join(rest), view=f[-2], size=f[-1])


def read_run(d):
    procs, load, term = {}, None, None
    for line in open(os.path.join(d, "cpu.txt")):
        f = line.split()
        if not f:
            continue
        if f[0] == "load":
            load = float(f[1])
        elif f[0] == "procs":
            pass
        elif f[0] == "bytes":
            b0, b1, s0, s1 = int(f[1]), int(f[2]), float(f[3]), float(f[4])
            if b1 > b0:
                term = (b0, b1, s1 - s0)
        else:
            procs[f[0]] = [float(f[1]), float(f[2])]
    run = dict(procs=procs, load=load)
    if term:
        b0, b1, secs = term
        run["term_bytes"] = round((b1 - b0) / secs)
        with open(os.path.join(d, "ts"), "rb") as ts:
            ts.seek(b0)
            # Each frame of paw's terminal is a synchronized update.
            run["frames"] = round(ts.read(b1 - b0).count(b"\x1b[?2026h") / secs, 1)
    try:
        stats = [l for l in open(os.path.join(d, "stderr")) if "stats:" in l]
    except OSError:
        stats = []
    for line in reversed(stats):
        m = re.search(r"frames shown in [\d.]+ s \(([\d.]+)/s\), \d+ pixels drawn a frame \(([\d.]+)%", line)
        if m:
            run["frames"], run["drawn"] = float(m.group(1)), float(m.group(2))
            p = re.search(r"(\d+) passes.* frames shown in ([\d.]+) s", line)
            if p:
                run["passes"] = round(int(p.group(1)) / float(p.group(2)), 1)
            break
        m = re.search(r"\d+ frames in [\d.]+ s \(([\d.]+)/s\)", line)
        if m:
            run["frames"], run["drawn"] = float(m.group(1)), 100.0
            break
    return run


def collect(results, set_name, tag=None):
    for d in sorted(glob.glob(os.path.join(results, "*"))):
        label = parse_label(os.path.basename(d))
        if not label or (tag and label["tag"] != tag) or not os.path.exists(os.path.join(d, "cpu.txt")):
            continue
        run = dict(set=set_name, **label)
        run.update(read_run(d))
        print(json.dumps(run))


def load(paths):
    runs = []
    for p in paths:
        if os.path.isdir(p):
            for d in sorted(glob.glob(os.path.join(p, "*"))):
                label = parse_label(os.path.basename(d))
                if label and os.path.exists(os.path.join(d, "cpu.txt")):
                    runs.append(dict(set=label["tag"], **label, **read_run(d)))
        else:
            runs += [json.loads(l) for l in open(p) if l.strip()]
    return runs


def spread(xs, fmt="{:.1f}"):
    xs = [x for x in xs if x is not None]
    if not xs:
        return "-"
    return f"{fmt.format(statistics.median(xs))} ({fmt.format(min(xs))}-{fmt.format(max(xs))})"


def show(paths, only=None, split=False):
    rows = {}
    for r in load(paths):
        if only and r["set"] != only:
            continue
        key = (r["set"], r["view"], r["size"], r["setup"], r.get("build") or "")
        rows.setdefault(key, []).append(r)
    head = ["set", "view", "size", "setup", "build", "runs", "total", "program", "server"]
    if split:
        head += ["kernel", "window or emulator", "terminal bytes/s"]
    head += ["RSS MB", "frames/s", "load"]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for key, runs in sorted(rows.items(), key=lambda kv: (kv[0][0], VIEWS.index(kv[0][1]), kv[0][2], kv[0][3], kv[0][4])):
        total = [sum(p[0] for p in r["procs"].values()) for r in runs]
        server = [r["procs"].get("server", [0, 0])[0] for r in runs]
        prog = [t - s for t, s in zip(total, server)]
        rss = [sum(p[1] for k, p in r["procs"].items() if k != "server") for r in runs]
        cells = list(key) + [str(len(runs)), spread(total), spread(prog), spread(server)]
        if split:
            kern = [(r["procs"].get("paw") or r["procs"].get("kernel") or [None])[0] for r in runs]
            emu = [(r["procs"].get("gui") or r["procs"].get("xterm") or r["procs"].get("wezterm") or [None])[0] for r in runs]
            cells += [spread(kern), spread(emu), spread([r.get("term_bytes") for r in runs], "{:.0f}")]
        cells += [spread(rss, "{:.0f}"), spread([r.get("frames") for r in runs]), spread([r["load"] for r in runs])]
        print("| " + " | ".join(cells) + " |")


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == "collect":
        collect(a[1], a[2], a[3] if len(a) > 3 else None)
    elif len(a) >= 2 and a[0] == "show":
        only = a[a.index("--set") + 1] if "--set" in a else None
        paths = [p for i, p in enumerate(a[1:], 1) if not p.startswith("--") and a[i - 1] != "--set"]
        show(paths, only, "--split" in a)
    else:
        print(__doc__)
        sys.exit(2)
