# -*- coding: utf-8 -*-
"""会话43：CC0 8-bit 音效样本 → inc/sfxdata.inc（44B WAV 头 + 22050Hz 8-bit PCM 表）。

来源：Juhani Junkala "The Essential Retro Video Game Sound Effects Collection
[512 sounds]"（opengameart.org，CC0/公共领域）。原始均为 44100Hz/16bit/单声道，
2:1 隔样本抽取降到 22050Hz；按引擎惯例映射到 8-bit 无符号、静音位 128、摆幅 ±112。

从项目根运行（只读 dl/ 内数据文件）：
    python -I tools/gen_sfx43.py
"""
import wave, array, os, struct, sys

PACK = os.path.join("dl", "sfx", "retro512",
                    "The Essential Retro Video Game Sound Effects Collection [512 sounds] By Juhani Junkala")
OUT = os.path.join("inc", "sfxdata.inc")
SR, CENTER, SWING = 22050, 128, 112   # 8-bit 无符号标准静音位 128

# (符号名, 包内相对路径, 截取秒数, 游戏用途)
MAP = [
    ("sndShotBuf",    "Weapons/Cannon/sfx_wpn_cannon4.wav",                    0.30, "开炮"),
    ("sndBoomBuf",    "Explosions/Short/sfx_exp_short_hard1.wav",              0.55, "击败爆炸"),
    ("sndPickBuf",    "General Sounds/Coins/sfx_coin_double1.wav",             0.21, "拾取道具"),
    ("sndCntBuf",     "General Sounds/High Pitched Sounds/sfx_sounds_high1.wav",0.082,"倒计时哔"),
    ("sndSwapBuf",    "Weapons/Lasers/sfx_wpn_laser2.wav",                     0.116,"换位成功"),
    ("sndMineBuf",    "General Sounds/Impacts/sfx_sounds_impact1.wav",         0.093,"布雷闷响"),
    ("sndLaserBuf",   "Weapons/Lasers/sfx_wpn_laser1.wav",                     0.364,"激光发射"),
    ("sndShieldBuf",  "General Sounds/Weird Sounds/sfx_sound_bling.wav",       0.40, "冰盾发动"),
    ("sndShatterBuf", "General Sounds/Negative Sounds/sfx_sounds_damage2.wav", 0.139,"冰盾碎裂"),
    ("sndGhostBf",    "General Sounds/Weird Sounds/sfx_sound_vaporizing.wav",  0.50, "穿墙发动"),
    ("sndNitroBf",    "General Sounds/Weird Sounds/sfx_sound_mechanicalnoise4.wav",0.45,"燃油加速"),
    ("sndWaterBf",    "General Sounds/Impacts/sfx_sounds_impact9.wav",         0.40, "驭水水花"),
    ("sndSwapfBf",    "Weapons/Lasers/sfx_wpn_laser7.wav",                     0.393,"换位弹嗖声"),
    ("sndAimBf",      "General Sounds/Buttons/sfx_sounds_button3.wav",         0.155,"激光起瞄"),
    ("sndAch0Bf",     "General Sounds/Fanfares/sfx_sounds_fanfare2.wav",       0.28, "成就·普通"),
    ("sndAchBf",      "General Sounds/Fanfares/sfx_sounds_fanfare3.wav",       0.286,"成就·稀有"),
    ("sndAch2Bf",     "General Sounds/Fanfares/sfx_sounds_fanfare1.wav",       0.516,"成就·史诗"),
    ("sndAch3Bf",     "General Sounds/Weird Sounds/sfx_sound_poweron.wav",     1.20, "成就·传奇"),
]

def load_mono16(path):
    with wave.open(path, "rb") as w:
        sr, ch, sw, nf = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(nf)
    assert sr == 44100 and sw == 2, (path, sr, ch, sw)
    a = array.array("h"); a.frombytes(raw)
    if ch == 2:
        a = a[0::2]
    return a

def convert(a, secs):
    b = a[0::2]                                  # 44100 -> 22050 隔样本抽取
    n = min(len(b), int(round(secs * SR)))
    b = b[:n]
    peak = max(max(b), -min(b)) or 1
    g = SWING / peak                             # 归一：峰值摆幅 -> 112（静音位 128 上下）
    out = bytearray(len(b))
    fin  = min(80, len(b) // 4)                  # 淡入防爆音头
    fout = min(600, len(b) // 3)                 # 淡尾归静音位防咔哒
    L = len(b)
    for i, v in enumerate(b):
        s = v * g
        if i < fin:
            s *= i / fin
        if i >= L - fout:
            s *= (L - 1 - i) / fout
        out[i] = max(0, min(255, int(round(CENTER + s))))
    return out

def header(n):
    h = bytearray(44)
    h[0:4]  = b"RIFF"
    h[4:8]  = struct.pack("<I", 36 + n)
    h[8:12] = b"WAVE"
    h[12:16]= b"fmt "
    h[16:20]= struct.pack("<I", 16)
    h[20:22]= struct.pack("<H", 1)               # PCM
    h[22:24]= struct.pack("<H", 1)               # mono
    h[24:28]= struct.pack("<I", SR)
    h[28:32]= struct.pack("<I", SR)              # byteRate（1 字节/样本）
    h[32:34]= struct.pack("<H", 1)               # blockAlign
    h[34:36]= struct.pack("<H", 8)               # bits
    h[36:40]= b"data"
    h[40:44]= struct.pack("<I", n)
    return h

def main():
    lines = []
    lines.append("; ============================================================")
    lines.append("; sfxdata.inc —— CC0 音效样本静态数据（会话43，tools/gen_sfx43.py 生成）")
    lines.append("; 来源：Juhani Junkala《The Essential Retro Video Game Sound Effects")
    lines.append("; Collection [512 sounds]》，opengameart.org，CC0/公共领域，无需署名。")
    lines.append("; 格式：44 字节 WAV 头 + 22050Hz 8-bit 无符号 PCM（静音位 128），与")
    lines.append("; sound.asm WrHead/PlaySound SND_MEMORY 约定逐字节一致，可直接播放。")
    lines.append("; 请勿手改；重新生成：python -I tools/gen_sfx43.py")
    lines.append("; ============================================================")
    total = 0
    for sym, rel, secs, use in MAP:
        src = os.path.join(PACK, rel.replace("/", os.sep))
        a = load_mono16(src)
        pcm = convert(a, secs)
        blob = header(len(pcm)) + pcm
        total += len(blob)
        lines.append("")
        lines.append("    align 4")
        lines.append("    ; %s：%s（源 %s，%.3fs -> %d 样本）" % (sym, use, rel, secs, len(pcm)))
        lines.append("    %s db %s" % (sym, ",".join(str(x) for x in blob[:16])))
        for i in range(16, len(blob), 16):
            lines.append("        db %s" % ",".join(str(x) for x in blob[i:i+16]))
        print("%-14s %-58s -> %6d B" % (sym, rel, len(blob)))
    with open(OUT, "w", encoding="utf-8", newline="\r\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %s (%d bytes)" % (OUT, total))

main()
