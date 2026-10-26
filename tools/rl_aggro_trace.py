# -*- coding: utf-8 -*-
# ============================================================
# rl_aggro_trace.py —— 会话50：botAggro 无效根因诊断
# 场景=槽0 罚站（act 全 0），槽1 启发式 bot；rlhost 管道模式经
# RLHOST_EXTRA="bottrace" 落逐 tick CSV（main.asm 本会话新增扫描）。
# 对 OFF/ON 两遍分别统计开火链各闸通过率：
#   patrol（无真目标）/ los（视线）/ 瞄准误差分档（≤4 旧闸、
#   4..12 激进新增窗、>12）/ evOwn（躲己弹）/ fireCd / inFire 实写。
# 结论指向：卡点究竟是误差闸（开关本该生效=注入断）还是
# los/patrol 等上游闸（开关天生无效=要换杠杆）。
# ============================================================
import os, sys, csv, math, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ["RLHOST_EXTRA"] = "bottrace"        # TankEnv 在 __init__ 里读
from rl_env import TankEnv                      # noqa: E402

CSV = os.path.join(HERE, "..", "tankwar_bottrace.csv")
IDLE = (0, 0, 0, 0, 0, 0)


def ang_err(a, b):
    d = (a - b) % 360.0
    return min(d, 360.0 - d)


def run(aggro, out_csv, ticks=2000, seed=1234, mode="idle"):
    if os.path.exists(CSV):
        os.remove(CSV)
    env = TankEnv()
    env.reset(seed=seed, aggro=aggro)
    import random
    rnd = random.Random(777)
    s = None
    act = IDLE
    for i in range(ticks):
        if mode != "idle" and i % 8 == 0:   # 随机游走：8t 一段换向（近似游走 NN）
            act = tuple(rnd.randint(0, 1) for _ in range(6))[:4] + (0, 0)
        s = env.step(act, rep=1)
        if s["matchOver"]:
            break
    env.close()
    if os.path.exists(CSV):
        shutil.move(CSV, out_csv)
    else:
        print("!! 无 CSV 产出（bottrace 未生效？）")
    return s


def flips(path, slot):
    """bottrace CSV 中指定槽 alive 1→0 翻转次数（死亡数）。"""
    if not os.path.exists(path):
        return -1, -1
    rows = [r for r in csv.DictReader(open(path)) if int(r["slot"]) == slot]
    n = 0
    prev = None
    for r in rows:
        a = int(r["alive"])
        if prev is not None and prev != 0 and a == 0:
            n += 1
        prev = a
    return n, len(rows)


def analyze(path, tag):
    if not os.path.exists(path):
        return
    with open(path, newline="") as f:
        rows = [r for r in csv.DictReader(f) if int(r["slot"]) == 1]
    n = len(rows)
    if not n:
        print(f"[{tag}] 无 slot1 行")
        return
    patrol = los = evown = fcd = 0
    e_le4 = e_412 = e_gt12 = e_loser = 0
    fire = 0
    dsum = 0.0
    aim_raw = []
    for r in rows:
        p = int(r["patrol"]); l = int(r["los"]); eo = int(r["evOwn"])
        fc = int(r["fireCd"]); inf = int(r["inFire"])
        x = float(r["x"]); y = float(r["y"])
        tx = float(r["tgtX"]); ty = float(r["tgtY"])
        dsum += math.hypot(tx - x, ty - y)
        if p: patrol += 1
        if l: los += 1
        if eo: evown += 1
        if fc: fcd += 1
        if inf: fire += 1
        if l and not p and not eo and not fc:
            aim = float(r["aimA"]); aim_raw.append(aim)
            # 引擎 y 轴方向未定：两种符号取较小误差（防假 >12°）
            w1 = math.degrees(math.atan2(ty - y, tx - x)) % 360.0
            w2 = math.degrees(math.atan2(-(ty - y), tx - x)) % 360.0
            e = min(ang_err(aim, w1), ang_err(aim, w2))
            if e <= 4: e_le4 += 1
            elif e <= 12: e_412 += 1
            else: e_gt12 += 1
    clear = los + patrol  # 仅参考
    print(f"[{tag}] tick={n} 平均距靶={dsum/n:.0f}px  inFire={fire}"
          f"({1000.0*fire/n:.1f}/千t)")
    print(f"  闸拒率: patrol={100.0*patrol/n:.1f}% los=0(无视线)="
          f"{100.0*(n-los)/n:.1f}% evOwn={100.0*evown/n:.1f}%"
          f" fireCd>0={100.0*fcd/n:.1f}%")
    tot = e_le4 + e_412 + e_gt12
    if tot:
        print(f"  净闸内(los且无patrol/evOwn/fireCd)误差: ≤4°={e_le4}"
              f"({100.0*e_le4/tot:.1f}%) 4..12°={e_412}"
              f"({100.0*e_412/tot:.1f}%) >12°={e_gt12}"
              f"({100.0*e_gt12/tot:.1f}%)")
    if aim_raw:
        print(f"  aimA 范围: min={min(aim_raw):.0f} max={max(aim_raw):.0f}"
              f"（判断是否度数刻度）")
    return fire, n


def analyze2(path, tag):
    """汇总一行：开火率/靶死/bot死（含 gate 摘要）。"""
    if not os.path.exists(path):
        return
    rows = [r for r in csv.DictReader(open(path)) if int(r["slot"]) == 1]
    n = len(rows)
    fire = sum(1 for r in rows if int(r["inFire"]))
    egod, _ = flips(path, 0)
    botd, _ = flips(path, 1)
    los = sum(1 for r in rows if int(r["los"]))
    print(f"[{tag}] t={n} inFire={fire}({1000.0*fire/max(n,1):.1f}/千t)"
          f" los_tick={100.0*los/max(n,1):.0f}% 靶死={egod}"
          f"({1000.0*egod/max(n,1):.2f}/千t) bot死={botd}")


if __name__ == "__main__":
    base = os.path.join(HERE, "..")
    jobs = [("idle_off", False, "idle", os.path.join(base, "aggro_idle_off.csv")),
            ("idle_on ", True,  "idle", os.path.join(base, "aggro_idle_on.csv")),
            ("walk_off", False, "walk", os.path.join(base, "aggro_walk_off.csv")),
            ("walk_on ", True,  "walk", os.path.join(base, "aggro_walk_on.csv"))]
    for tag, ag, mode, out in jobs:
        run(ag, out, ticks=2500, mode=mode)
        analyze2(out, tag)
