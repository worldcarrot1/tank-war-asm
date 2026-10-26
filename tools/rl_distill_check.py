# -*- coding: utf-8 -*-
# ============================================================
# rl_distill_check.py —— 会话47 Phase3 蒸馏对拍：
# 解析 exe 侧 rlbotdump 轨迹（664B/记录 = [4I][90f][36f原][36f终]），
# 用 npz 权重在 python 复算同 obs 的前向，与 exe 落盘逐段对：
#   A) RlChoose：argmax(post)==chosen 比例（通道选择器）
#   B) NN 前向：py_forward(obs) vs exe raw logits（含 tanh 表/截断
#      取整/量化三角的全部数值差），argmax 一致率 + 最大逐位差
#   C) 信标层：bonus=post-raw vs 按 obs 重构的期望偏置（同带/同门
#      语义；bkThr<0 时期望全零）
# 用法：python -I tools/rl_distill_check.py [trace.bin] [npz]
#      常量默认与 inc/rlw.inc 同源（RL_BKM=1.2 RL_BKT=0.6 THR=1）。
# ============================================================
import os, sys, struct
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRACE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "rlbot_trace.bin")
NPZ = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "rl_policy_14champ.bak.npz")
BKM = float(os.environ.get("RL_BKM", "1.2"))
BKT = float(os.environ.get("RL_BKT", "0.6"))
BTHR = int(os.environ.get("RL_BTHR", "1"))
REC = 16 + 90 * 4 + 36 * 4 * 2
f32 = np.float32

p = dict(np.load(NPZ))
if "obsv2" in p:
    sys.exit("错误：npz 带 obsv2 标记，影子复算只支持 obsv1")
L1W = p["l1w"].astype(np.float32)   # (90,128) in-major（python 原形状）
L1B = p["l1b"].astype(np.float32)
L2W = p["l2w"].astype(np.float32)
L2B = p["l2b"].astype(np.float32)
PW = p["pw"].astype(np.float32)
PB = p["pb"].astype(np.float32)


def fwd(o):
    h1 = np.tanh(o @ L1W + L1B)
    h2 = np.tanh(h1 @ L2W + L2B)
    return (h2 @ PW + PB).astype(np.float32)


def beacon_from_obs(o, bkthr):
    """按 asm 同构算术从 obs 重构期望 logits 偏置（float32）。
    仅当 bkThr>=0（exe 已过全部前门）才有非零可能。"""
    b = np.zeros(36, dtype=np.float32)
    if bkthr < 0:
        return b
    alive = o[4]
    if alive == 0.0:
        return b
    dx = o[83] * 992.0
    dy = o[84] * 608.0
    d2 = dx * dx + dy * dy
    if d2 < 1600.0 or d2 > 490000.0:
        return b
    d = np.sqrt(d2)
    w = f32(1.0) if d2 < 40000.0 else (f32(0.6) if d2 < 160000.0 else f32(0.3))
    s, c = o[2], o[3]                       # sinTBL/cosTBL x1024（与 exe 同源）
    dotN = (c * dx + s * dy) / d
    crsN = (c * dy - s * dx) / d
    for mv in range(3):
        mvs = dotN if mv == 0 else (-dotN if mv == 1 else f32(0.0))
        for tn in range(3):
            tns = (-crsN if tn == 0 else (crsN if tn == 1 else f32(0.0)))
            v = w * (BKM * mvs + BKT * tns)
            b[mv * 12 + tn * 4: mv * 12 + tn * 4 + 4] = v
    return b


def main():
    data = open(TRACE, "rb").read()
    n = len(data) // REC
    if len(data) % REC:
        sys.exit("轨迹长度 %d 不是 %d 的整数倍（尾部截断?）" % (len(data), REC))
    print("记录数 %d" % n)
    choose_ok = nn_am_ok = chain_am_ok = 0
    gate_hist = {}
    raw_maxdiff = 0.0
    bonus_maxdiff = 0.0
    act_hist = np.zeros(36, dtype=np.int64)
    first_bad = None
    for i in range(n):
        slot, tick, chosen, bkthr = struct.unpack_from("<4i", data, i * REC)
        o = np.frombuffer(data, "float32", 90, i * REC + 16)
        raw = np.frombuffer(data, "float32", 36, i * REC + 16 + 360)
        post = np.frombuffer(data, "float32", 36, i * REC + 16 + 360 + 144)
        gate_hist[bkthr if bkthr >= 0 else ("off" if bkthr == -3 else "gate")] = \
            gate_hist.get(bkthr if bkthr >= 0 else ("off" if bkthr == -3 else "gate"), 0) + 1
        act_hist[chosen] += 1
        if int(post.argmax()) == chosen:
            choose_ok += 1
        elif first_bad is None:
            first_bad = (i, tick, chosen, post.argmax(), float(post.max()))
        z = fwd(o.astype(np.float32))
        if int(z.argmax()) == int(raw.argmax()):
            nn_am_ok += 1
        raw_maxdiff = max(raw_maxdiff, float(np.abs(z - raw).max()))
        bexp = beacon_from_obs(o, bkthr)
        bex = post - raw
        bonus_maxdiff = max(bonus_maxdiff, float(np.abs(bexp - bex).max()))
        if int((z + bexp).astype(np.float32).argmax()) == chosen:
            chain_am_ok += 1
    print("A) RlChoose   argmax(post)==chosen : %d/%d = %.3f%%" % (choose_ok, n, 100.0 * choose_ok / n))
    print("B) NN 前向    argmax 一致          : %d/%d = %.3f%%   max|Δraw|=%.3g"
          % (nn_am_ok, n, 100.0 * nn_am_ok / n, raw_maxdiff))
    print("C) 全链(py重构) argmax==exe chosen : %d/%d = %.3f%%   max|Δbonus|=%.3g"
          % (chain_am_ok, n, 100.0 * chain_am_ok / n, bonus_maxdiff))
    print("门状态分布:", gate_hist)
    mv = act_hist.reshape(3, 12).sum(1)
    f = act_hist.reshape(9, 2, 2)
    print("动作分布: 前进/倒车/停=%d/%d/%d  开火=%d 技能=%d" %
          (mv[0], mv[1], mv[2], f[:, 1, :].sum(), f[:, :, 1].sum()))
    if first_bad:
        print("首个 choose 不一致: rec=%d tick=%d chosen=%d argmax=%d" % first_bad)


if __name__ == "__main__":
    main()
