# -*- coding: utf-8 -*-
"""会话43：解析 inc/sfxdata.inc 的 18 个 snd*Buf 字节表，用 wave 模块按标准
RIFF/WAVE 校验（sr=22050/8bit/mono、riffSize=36+dataSize=36+实际 PCM 长度），
并报告首尾样本是否收敛到静音位 128 附近（淡入淡出有效）。"""
import io, struct, sys, wave

cur = None
bufs = {}
for line in open(r"D:\tank-war-asm\inc\sfxdata.inc", encoding="utf-8"):
    s = line.strip()
    if not s or s.startswith(";"):
        continue
    if s.startswith("align"):
        cur = None
        continue
    if s.startswith("db"):
        body = s[2:]
    else:
        name, _, body = s.partition(" db ")
        cur = name
        bufs[cur] = []
    bufs[cur] += [int(x) for x in body.replace("\n", "").split(",") if x.strip()]

assert len(bufs) == 18, sorted(bufs)
bad = 0
for nm, vals in bufs.items():
    blob = bytes(vals)
    riff_sz, data_sz = struct.unpack("<II", blob[4:8] + blob[40:44])
    w = wave.open(io.BytesIO(blob), "rb")
    sr, ch, sw, nf = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
    data = w.readframes(nf)
    ok = (sw == 1 and sr == 22050 and ch == 1 and data_sz == len(data)
          and riff_sz == 36 + len(data) and len(blob) == 44 + len(data))
    lo, hi = min(data), max(data)
    print("%-14s bytes=%6d dur=%.3fs %-4s first=%3d last=%3d rng=%d..%d%s" %
          (nm, len(blob), nf / sr, "OK" if ok else "BAD", data[0], data[-1], lo, hi,
           "" if ok else "  <<<"))
    bad += 0 if ok else 1
print("buffers=%d, bad=%d" % (len(bufs), bad))
sys.exit(1 if bad else 0)
