#!/usr/bin/env python3
"""Export the wave tracks of an Audacity 3 project (.aup3) to WAV without Audacity.

Usage: aup3-export.py <project.aup3> <out dir> [--clips] [--dump]

An .aup3 is sqlite: `project.dict` + `project.doc` hold the project XML in Audacity's binary serialization
(ProjectSerializer), `sampleblocks` the audio. Each wavetrack -> waveclip -> sequence lists waveblocks (start, blockid);
a clip's audio is its blocks in order, placed at the clip's offset. Each track is written as one 32-bit float mono WAV
(16-bit mono, silence between clips); --clips also writes each clip of 3 s or more as its own WAV (stereo pairs are
not merged: each channel track is written on its own).
Opened read-only (immutable). --dump prints the decoded XML tree and writes nothing.
"""
import sqlite3, struct, sys, wave
from pathlib import Path

import numpy as np

FMT = {0x00020001: np.int16, 0x0004000F: np.float32, 0x00040001: np.int32}


def decode(dict_blob, doc_blob):
    names, char = {}, 1
    def strings(buf):
        nonlocal char
        i, out = 0, []
        while i < len(buf):
            op = buf[i]; i += 1
            if op == 0: char = buf[i]; i += 1
            elif op == 15:
                nid, n = struct.unpack_from("<HH", buf, i); i += 4
                names[nid] = buf[i:i + n].decode("utf-16-le" if char == 2 else "utf-32-le" if char == 4 else "utf-8"); i += n
            else: out.append((op, i)); break
        return i
    strings(dict_blob)
    root, stack, i, buf = {"tag": "root", "attrs": {}, "kids": []}, [], 0, doc_blob
    cur = root
    enc = lambda: "utf-16-le" if char == 2 else "utf-32-le" if char == 4 else "utf-8"
    while i < len(buf):
        op = buf[i]; i += 1
        if op == 0: char = buf[i]; i += 1
        elif op == 15:
            nid, n = struct.unpack_from("<HH", buf, i); i += 4
            names[nid] = buf[i:i + n].decode(enc()); i += n
        elif op == 1:
            (nid,) = struct.unpack_from("<H", buf, i); i += 2
            node = {"tag": names[nid], "attrs": {}, "kids": []}
            cur["kids"].append(node); stack.append(cur); cur = node
        elif op == 2:
            i += 2; cur = stack.pop()
        elif op == 3:
            nid, n = struct.unpack_from("<Hi", buf, i); i += 6
            cur["attrs"][names[nid]] = buf[i:i + n].decode(enc()); i += n
        elif op in (4, 6):
            nid, v = struct.unpack_from("<Hi", buf, i); i += 6; cur["attrs"][names[nid]] = v
        elif op == 5:
            nid, v = struct.unpack_from("<HB", buf, i); i += 3; cur["attrs"][names[nid]] = bool(v)
        elif op == 7:
            nid, v = struct.unpack_from("<Hq", buf, i); i += 10; cur["attrs"][names[nid]] = v
        elif op == 8:
            nid, v = struct.unpack_from("<HI", buf, i); i += 6; cur["attrs"][names[nid]] = v
        elif op == 9:
            nid, v, _ = struct.unpack_from("<Hfi", buf, i); i += 10; cur["attrs"][names[nid]] = v
        elif op == 10:
            nid, v, _ = struct.unpack_from("<Hdi", buf, i); i += 14; cur["attrs"][names[nid]] = v
        elif op in (11, 12):
            (n,) = struct.unpack_from("<i", buf, i); i += 4 + n
        elif op in (13, 14): pass
        else: raise ValueError(f"unknown opcode {op} at {i - 1}")
    return root


def walk(n, tag):
    if n["tag"] == tag: yield n
    for k in n["kids"]: yield from walk(k, tag)


def dump(n, d=0):
    print("  " * d + n["tag"], {k: v for k, v in n["attrs"].items()})
    for k in n["kids"]: dump(k, d + 1)


def main():
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    db = sqlite3.connect(f"file:{src}?mode=ro&immutable=1", uri=True)
    d, doc = db.execute("SELECT dict, doc FROM project").fetchone()
    tree = decode(d, doc)
    if "--dump" in sys.argv:
        dump(tree); return
    out.mkdir(parents=True, exist_ok=True)
    rate = int(next(walk(tree, "project"))["attrs"].get("rate", 44100))
    tracks = []
    for t in walk(tree, "wavetrack"):
        tr = int(t["attrs"].get("rate", rate))
        pieces = []
        for clip in walk(t, "waveclip"):
            off = float(clip["attrs"].get("offset", 0.0))
            chunks = []
            for seq in walk(clip, "sequence"):
                for wb in walk(seq, "waveblock"):
                    bid = int(wb["attrs"]["blockid"])
                    if bid <= 0:   # silent block: length in samples
                        chunks.append(np.zeros(int(wb["attrs"].get("len", 0)), np.float32)); continue
                    fmt, blob = db.execute("SELECT sampleformat, samples FROM sampleblocks WHERE blockid = ?", (bid,)).fetchone()
                    chunks.append(np.frombuffer(blob, FMT[fmt]).astype(np.float32) / (32768.0 if fmt == 0x00020001 else 2147483648.0 if fmt == 0x00040001 else 1.0))
            a = np.concatenate(chunks) if chunks else np.zeros(0, np.float32)
            trim_l = float(clip["attrs"].get("trimLeft", 0.0)); trim_r = float(clip["attrs"].get("trimRight", 0.0))
            a = a[int(trim_l * tr): len(a) - int(trim_r * tr) if trim_r else None]
            pieces.append((off + trim_l, a))
        end = max((int(o * tr) + len(a) for o, a in pieces), default=0)
        buf = np.zeros(end, np.float32)
        for o, a in pieces: buf[int(o * tr): int(o * tr) + len(a)] += a
        tracks.append((t["attrs"].get("name", "track"), tr, buf, pieces))
    for n, (name, tr, buf, clips) in enumerate(tracks, 1):
        write(out / f"track{n:02d} {name}.wav", tr, buf)
        print(f"track{n:02d} {name}.wav\t{tr} Hz\t{len(buf) / tr:.1f} s\t{len(clips)} clips")
        if "--clips" in sys.argv:   # one WAV per clip: in a project of recorded calls, each clip is one recording
            for c, (o, a) in enumerate(clips, 1):
                if len(a) < 3 * tr: continue
                write(out / f"track{n:02d} clip{c:02d} at {int(o) // 3600:d}h{int(o) % 3600 // 60:02d}m{int(o) % 60:02d}s.wav", tr, a)


def write(p, tr, buf):
    pcm = (np.clip(buf, -1, 1) * 32767).astype("<i2")
    with wave.open(str(p), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(tr); w.writeframes(pcm.tobytes())

if __name__ == "__main__":
    main()
