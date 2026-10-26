# -*- coding: utf-8 -*-
# ============================================================
# gen_rlbot_data.py —— 会话47 Phase3 蒸馏：npz → inc/rlw.inc
# 把 run14 冠军网络（90→128→128→36，tanh×2，obsv1 编码）逐位无损
# 落成 MASM 数据段：float32 按 uint32 hex 输出（不经十进制，杜绝
# 文本往返误差）。三个权重矩阵一律转置为 [out][in] 行主序——asm 侧
# 内层循环顺序读。tanh 用 4097 点线性插值表（x∈[-8,8]，步长恰为
# 2^-11，表值 float32；最大误差 ~1e-6，远小于 argmax 决策裕度）。
# 自检：生成后反读本文件逐位对拍 npz，不一致即报错退出。
# 用法：python -I tools/gen_rlbot_data.py [npz] [--out inc/rlw.inc]
#       信标常量经环境变量 RL_BKM / RL_BKT / RL_BTHR 传入（调参回写）。
# ============================================================
import os, sys, struct, hashlib
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "rl_policy_14champ.bak.npz")
OUT = os.path.join(ROOT, "inc", "rlw.inc")
argv = sys.argv[1:]
if argv and not argv[0].startswith("-"):
    SRC = argv[0] if os.path.isabs(argv[0]) else os.path.join(ROOT, argv[0])
if "--out" in argv:
    OUT = argv[argv.index("--out") + 1]

p = dict(np.load(SRC))
if "obsv2" in p:
    sys.exit("错误：该 npz 带 obsv2 标记（v2 编码），蒸馏只支持 obsv1（run14 冠军谱系）")
MD5 = hashlib.md5(open(SRC, "rb").read()).hexdigest()


def bits(v):
    """float32 → uint32 hex 位模式。"""
    return struct.unpack("<I", struct.pack("<f", np.float32(v)))[0]


def hx(u):
    """uint32 → MASM 十六进制字面量（ml 不认 0x 前缀；首字符防字母）。"""
    return "0%08Xh" % (u & 0xFFFFFFFF)


# tanh 表：4097 点，x∈[-8,8]，step=2^-11（二进制精确）
TANH_N = 4097
TANH_LO = -8.0
TANH_STEP = 16.0 / (TANH_N - 1)
assert TANH_STEP == 0.00390625
tanh_tab = [float(np.tanh(TANH_LO + i * TANH_STEP)) for i in range(TANH_N)]

# 观测构建常量：与 tools/rl_train.py build_obs 逐式对应（分母不整除二进制
# 的用 float 精确位模式，asm 一律 fmul  reciprocal，不做整数除法）
consts = [
    ("RLC_INV_W",    1.0 / 992.0),    # (v-x)/W，W=MAP_W
    ("RLC_INV_H",    1.0 / 608.0),    # H=ROWS*CELL
    ("RLC_INV_30",   1.0 / 30.0),     # fireCd/30 封顶1
    ("RLC_INV_8",    1.0 / 8.0),      # skill/8 封顶1、pickupType/8
    ("RLC_INV_3",    1.0 / 3.0),      # lives/3、score/3
    ("RLC_INV_6",    1.0 / 6.0),      # map 字节/6
    ("RLC_INV_FP",   1.0 / 176947.0), # 子弹 16.16 定点速度归一
    ("RLC_INV_1024", 1.0 / 1024.0),   # cosTBL/sinTBL 标度
    ("RLC_EMA_A",    1.0 / 16.0),     # 敌向 EMA 步长
    ("RLC_EMA_1MA",  1.0 - 1.0 / 16.0),
    ("RLC_ONE",      1.0),
    # ---- tanh 查表算术（idx=(x+8)*256，step=2^-8，4096 封顶）----
    ("RLC_P8",       8.0),
    ("RLC_256",      256.0),
    # ---- 信标叠加层（与 tools/rl_beacon_probe.py 一一对应）----
    ("RLC_BKM",      float(os.environ.get("RL_BKM", "1.2"))),
    ("RLC_BKT",      float(os.environ.get("RL_BKT", "0.6"))),
    ("RLC_BW1",      1.0),            # d<200px 带权
    ("RLC_BW2",      0.6),            # 200..400
    ("RLC_BW3",      0.3),            # 400..700
]

mats = []
l1 = np.asarray(p["l1w"], dtype=np.float32)          # (90,H) row=in
l2 = np.asarray(p["l2w"], dtype=np.float32)
pw = np.asarray(p["pw"], dtype=np.float32)            # (H,36)
# 会话51 run19 预铺：隐层宽度从 npz 形状反推（H=128 时产物与旧版逐字节
# 一致；换宽网络时 asm 侧经 inc/rlw_cfg.inc 的 RL_HW 同步）。
H = int(l1.shape[1])
assert l2.shape == (H, H) and pw.shape == (H, 36), \
    "层宽不一致: l1=%r l2=%r pw=%r" % (l1.shape, l2.shape, pw.shape)
mats = [("RLW_L1", l1.T.ravel(), H, 90, "L1 转置后 [out=%d][in=90]" % H),
        ("RLW_L2", l2.T.ravel(), H, H, "L2 [out=%d][in=%d]" % (H, H)),
        ("RLW_P",  pw.T.ravel(), 36, H,  "P  [out=36][in=%d]" % H)]
vecs = [("RLB_1", np.asarray(p["l1b"], dtype=np.float32).ravel()),
        ("RLB_2", np.asarray(p["l2b"], dtype=np.float32).ravel()),
        ("RLB_P", np.asarray(p["pb"], dtype=np.float32).ravel())]

lines = [
    "; ============================================================",
    "; rlw.inc —— 自动生成，勿手改（tools/gen_rlbot_data.py）",
    "; 来源 %s  md5 %s" % (os.path.basename(SRC), MD5),
    "; 网络 obsv1：90->%d(tanh)->%d(tanh)->36  贪心 argmax" % (H, H),
    "; 权重 float32 位模式 dd（[out][in] 行主序；0…h 字面量，ml 不认 0x）",
    "; tanh 4097 点插值表；常量倒数 RLC_*",
    "; 生成时间见 git；改常量走 RL_BKM/RL_BKT 环境变量重跑脚本",
    "; ============================================================",
    "ifndef RLW_INC_DEFINED",
    "RLW_INC_DEFINED equ 1",
    "",
    "RL_TANH_N   equ %d" % TANH_N,
    "RL_TANH_STEP equ 0.00390625",
    "RL_B_THREAT equ %d" % int(os.environ.get("RL_BTHR", "1")),
    "align 4",
]
emitted = {}      # name -> list[uint32]，反读对拍用


def emit_array(name, flat):
    hexvals = []
    for i in range(0, len(flat), 16):
        chunk = flat[i:i + 16]
        hexs = [hx(v if isinstance(v, int) else bits(v)) for v in chunk]
        hexvals += [int(h[1:-1], 16) for h in hexs]
        if i == 0:
            lines.append("%s dd %s" % (name, ", ".join(hexs)))
        else:
            lines.append("      dd " + ", ".join(hexs))
    emitted[name] = hexvals


for name, flat, nr, nc, cmt in mats:
    assert flat.size == nr * nc, (name, flat.size)
    lines.append("; " + cmt)
    emit_array(name, flat)
    lines.append("")
for name, flat in vecs:
    emit_array(name, flat)
    lines.append("")
lines.append("; tanh(x) 线性插值表：idx=(x+8)*1024*2? 步长 2^-11 -> i=(x-RLC_NEG8)/step")
emit_array("RL_TANH", tanh_tab)
lines.append("")
for name, v in consts:
    lines.append("  %-12s dd 0%08Xh   ; %.9g" % (name, bits(v), v))
lines.append("RLC_NEG8 dd 0%08Xh   ; -8.0" % bits(-8.0))
lines.append("")
lines.append("endif")
open(OUT, "w").write("\n".join(lines) + "\n")
# rlbot.asm 的 rlH1/rlH2 dd RL_HW dup(?) 与 RlForward 各 stride 用此宽度；
# cfg 单独成文件令其在 .data 之前可被 include（rlw.inc 含 dd 只能在 .data 内）。
OUT_CFG = os.path.join(ROOT, "inc", "rlw_cfg.inc")
open(OUT_CFG, "w").write(
    "; 自动生成（tools/gen_rlbot_data.py）勿手改：蒸馏网络隐层宽度\n"
    "RL_HW equ %d\n" % H)

# ---- 反读对拍：从生成的 .inc 逐行抠 dd，重建三矩阵+表头若干元素 ----
txt = open(OUT).read()
import re
def read_back(name):
    m = re.search(r"^%s dd (.*)\n((?:      dd .*\n)*)" % name, txt, re.M)
    body = m.group(1) + "\n" + m.group(2)
    vals = [int(h, 16) for h in re.findall(r"0([0-9A-Fa-f]{8})h", body)]
    return vals

ok = True
for name, flat, nr, nc, cmt in mats:
    rb = read_back(name)
    want = [bits(v) for v in flat]
    if rb != want:
        ok = False
        print("MISMATCH", name, len(rb), len(want))
rb = read_back("RL_TANH")
if rb[0] != bits(np.tanh(-8.0)) or rb[-1] != bits(np.tanh(8.0)) or len(rb) != TANH_N:
    ok = False
    print("MISMATCH RL_TANH", len(rb))
if not ok:
    sys.exit("自检失败")
print("OK -> %s  (%d 行, %d dd 权重值, md5 %s)" %
      (OUT, len(lines), sum(len(v) for v in emitted.values()), MD5))
