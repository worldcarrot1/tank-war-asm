# -*- coding: utf-8 -*-
"""会话43：探测 CC0 音效包候选 WAV 的参数（采样率/声道/位深/时长/峰值/RMS/过零率）。
只读数据文件；从项目根运行：python -I tools/sfxprobe43.py
"""
import wave, struct, array, os

P = os.path.join("dl", "sfx", "retro512",
                 "The Essential Retro Video Game Sound Effects Collection [512 sounds] By Juhani Junkala")

CAND = [
    # 开炮
    "Weapons/Cannon/sfx_wpn_cannon1.wav", "Weapons/Cannon/sfx_wpn_cannon2.wav",
    "Weapons/Cannon/sfx_wpn_cannon3.wav", "Weapons/Cannon/sfx_wpn_cannon4.wav",
    "Weapons/Single Shot Sounds/sfx_weapon_singleshot1.wav",
    "Weapons/Single Shot Sounds/sfx_weapon_singleshot3.wav",
    "Weapons/Single Shot Sounds/sfx_weapon_singleshot9.wav",
    "Weapons/Single Shot Sounds/sfx_weapon_singleshot14.wav",
    # 爆炸
    "Explosions/Shortest/sfx_exp_shortest_hard1.wav",
    "Explosions/Short/sfx_exp_short_hard1.wav",
    "Explosions/Short/sfx_exp_short_hard7.wav",
    "Explosions/Short/sfx_exp_short_soft3.wav",
    "Explosions/Medium Length/sfx_exp_medium1.wav",
    "Explosions/Medium Length/sfx_exp_medium4.wav",
    "Explosions/Medium Length/sfx_exp_medium9.wav",
    "Explosions/Clusters/sfx_exp_cluster1.wav",
    "Explosions/Clusters/sfx_exp_cluster4.wav",
    "Explosions/Odd/sfx_exp_odd2.wav",
    # 激光
    "Weapons/Lasers/sfx_wpn_laser1.wav", "Weapons/Lasers/sfx_wpn_laser2.wav",
    "Weapons/Lasers/sfx_wpn_laser3.wav", "Weapons/Lasers/sfx_wpn_laser5.wav",
    "Weapons/Lasers/sfx_wpn_laser7.wav", "Weapons/Lasers/sfx_wpn_laser9.wav",
    "Weapons/Lasers/sfx_wpn_laser12.wav",
    # 拾取/金币
    "General Sounds/Coins/sfx_coin_single1.wav", "General Sounds/Coins/sfx_coin_single2.wav",
    "General Sounds/Coins/sfx_coin_double1.wav", "General Sounds/Coins/sfx_coin_double2.wav",
    "General Sounds/Coins/sfx_coin_cluster2.wav",
    # 按钮/哔声
    "General Sounds/Buttons/sfx_sounds_button1.wav", "General Sounds/Buttons/sfx_sounds_button2.wav",
    "General Sounds/Buttons/sfx_sounds_button3.wav", "General Sounds/Buttons/sfx_sounds_button7.wav",
    "General Sounds/Buttons/sfx_sounds_button13.wav",
    "General Sounds/High Pitched Sounds/sfx_sounds_high1.wav",
    "General Sounds/High Pitched Sounds/sfx_sounds_high2.wav",
    "General Sounds/High Pitched Sounds/sfx_sounds_high4.wav",
    "General Sounds/High Pitched Sounds/sfx_sounds_high6.wav",
    # 成就号角
    "General Sounds/Fanfares/sfx_sounds_fanfare1.wav",
    "General Sounds/Fanfares/sfx_sounds_fanfare2.wav",
    "General Sounds/Fanfares/sfx_sounds_fanfare3.wav",
    # 负面/碎裂
    "General Sounds/Negative Sounds/sfx_sounds_negative1.wav",
    "General Sounds/Negative Sounds/sfx_sounds_damage2.wav",
    "General Sounds/Negative Sounds/sfx_sounds_error4.wav",
    # 冲击（布雷/护盾/穿墙等可候选）
    "General Sounds/Impacts/sfx_sounds_impact1.wav",
    "General Sounds/Impacts/sfx_sounds_impact3.wav",
    "General Sounds/Impacts/sfx_sounds_impact7.wav",
    "General Sounds/Impacts/sfx_sounds_impact9.wav",
    "General Sounds/Impacts/sfx_sounds_impact13.wav",
    "General Sounds/Impacts/sfx_sounds_impact15.wav",
    # 怪异（水/隐身/加速/嗖 可候选）
    "General Sounds/Weird Sounds/sfx_sound_bling.wav",
    "General Sounds/Weird Sounds/sfx_sound_poweron.wav",
    "General Sounds/Weird Sounds/sfx_sound_vaporizing.wav",
    "General Sounds/Weird Sounds/sfx_sound_depressurizing.wav",
    "General Sounds/Weird Sounds/sfx_sound_mechanicalnoise1.wav",
    "General Sounds/Weird Sounds/sfx_sound_mechanicalnoise4.wav",
    "General Sounds/Weird Sounds/sfx_sound_nagger1.wav",
    "General Sounds/Weird Sounds/sfx_sound_shutdown1.wav",
    "General Sounds/Weird Sounds/sfx_sound_refereewhistle.wav",
]

def probe(path):
    with wave.open(path, "rb") as w:
        sr, ch, sw, nf = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(nf)
    if sw == 2:
        a = array.array("h"); a.frombytes(raw)
    elif sw == 1:
        a = array.array("b"); a.frombytes(raw)
    else:
        return None
    if ch == 2:
        a = a[0::2]
    peak = max(abs(min(a)), max(a))
    mx = float(max(1, peak))
    rms = (sum((v / mx) ** 2 for v in a) / len(a)) ** 0.5
    # 过零率≈主频指示（2*zc/sr 为 Hz 量级）
    zc = sum(1 for i in range(1, len(a)) if (a[i-1] < 0) != (a[i] < 0))
    dur = nf / sr
    return sr, ch, sw * 8, dur, peak, rms, 2.0 * zc / dur

for rel in CAND:
    fp = os.path.join(P, rel.replace("/", os.sep))
    if not os.path.exists(fp):
        print("MISSING", rel); continue
    r = probe(fp)
    if r is None:
        print("SKIP  ", rel); continue
    sr, ch, bits, dur, peak, rms, zcr = r
    print("%-58s sr=%6d ch=%d bits=%2d dur=%6.3fs peak=%5d rms=%5.3f zcHz~=%5.0f" %
          (rel, sr, ch, bits, dur, peak, rms, zcr))
