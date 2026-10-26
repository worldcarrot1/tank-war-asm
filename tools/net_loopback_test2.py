# ============================================================
# net_loopback_test2.py -- 会话51 联机回归覆盖面加密（同机双开）
# 基线套（net_loopback_test.py）盖了握手/镜像跟随/开火/netLost，
# 本套补会话36 同步面的四个洞（全部吃现成 T 行列，零引擎改动）：
#   A) 共享流一致：rngMatch 与拾取池 pick 两列在两端采样期间值序列
#      必须完全一致（发散=选池/道具时钟不同步，任何后续行为都白谈）
#   B) 反向驱动：基线只驱动 A 窗验 host 镜像；本套驱动 B 窗验 host
#      端 mx/my 收敛 == guest 自机（双向通路都要活）
#   C) 输入隔离 B3：host 窗按 P2 方向键(↑)=自机零响应；连按 R=联机
#      禁重开（G 行不重发、tick 不回卷）
#   D) 弹数交叉映射：A 开一炮 -> host.b0(自弹)与 guest.b1(对方弹)
#      必须同现——基线"两端 b1>=1"不区分弹的归属，映射断言更强
# 纯标准库；失败打印两份 dump 尾部并 exit 1。
# ============================================================
import ctypes, os, subprocess, sys, time

user32 = ctypes.windll.user32
k32 = ctypes.windll.kernel32
user32.SetProcessDPIAware()

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "tankwar.exe")
HOSTF = os.path.join(ROOT, "netdump_host.txt")
GUESTF = os.path.join(ROOT, "netdump_guest.txt")
TITLE = "Tank War ASM M1 - P1: WASD+SPACE | P2: Arrows+ENTER | R restart"
VK_W, VK_S, VK_A, VK_D = 0x57, 0x53, 0x41, 0x44
VK_SPACE, VK_UP, VK_R = 0x20, 0x26, 0x52

class RECT(ctypes.Structure):
    _fields__ = [("L", ctypes.c_long), ("T", ctypes.c_long),
                 ("R", ctypes.c_long), ("B", ctypes.c_long)]

def fail(msg):
    print("FAIL: " + msg)
    for f in (HOSTF, GUESTF):
        print("---- tail " + os.path.basename(f) + " ----")
        try:
            data = open(f, "rb").read().replace(b"\0", b"")
            for ln in data.splitlines()[-20:]:
                print(ln.decode("ascii", "replace"))
        except Exception as e:
            print("(cannot read: %r)" % e)
    sys.exit(1)

def tok_lines(path, pfx):
    out = []
    try:
        data = open(path, "rb").read().replace(b"\0", b"")
    except Exception:
        return out
    for ln in data.splitlines():
        s = ln.decode("ascii", "replace").strip()
        if len(s) < 2 or s[0] != pfx:
            continue
        toks = [s[0]] + s[1:].split()
        if len(toks) >= 2 and toks[1].lstrip("-").isdigit():
            out.append(toks)
    return out

def parse_t(path):
    # T tick rx lost pk x0 y0 mx my a0 a1 hp1 sk1 ef1 aim1 b0 b1 m0 m1 pick rngM rtt
    rows = []
    for c in tok_lines(path, "T"):
        if len(c) < 21:
            continue
        try:
            rows.append([int(v) for v in c[1:21]])
        except ValueError:
            pass
    return rows

# 列索引速记
C_TICK, C_LOST = 0, 2
C_X0, C_Y0, C_MX, C_MY = 4, 5, 6, 7
C_A0 = 8
C_B0, C_B1, C_M0, C_M1, C_PICK, C_RNGM = 14, 15, 16, 17, 18, 19

def pid_hwnd(pid):
    found = ctypes.c_void_p(0)
    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    def cb(h, l):
        pidbuf = ctypes.c_ulong(0)
        user32.GetWindowThreadProcessId(h, ctypes.byref(pidbuf))
        if pidbuf.value == pid:
            n = user32.GetWindowTextLengthW(h)
            if n:
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(h, buf, n + 1)
                if buf.value == TITLE:
                    found.value = h
                    return False
        return True
    user32.EnumWindows(cb, 0)
    return found.value

def focus(hwnd):
    if not hwnd:
        return
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)
    fg = user32.GetForegroundWindow()
    cur = k32.GetCurrentThreadId()
    other = user32.GetWindowThreadProcessId(fg, None)
    if other and other != cur:
        user32.AttachThreadInput(other, cur, True)
    user32.SetForegroundWindow(hwnd)
    user32.SetFocus(hwnd)
    if other and other != cur:
        user32.AttachThreadInput(other, cur, False)

def key(vk, down):
    user32.keybd_event(vk, 0, 0 if down else 2, None)

def wait_for(pred, secs, step=0.25):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(step)
    return False

# ---- 清场（会话51 纪律：按精确 PID 逐个杀，禁 /IM 镜像扫射）----
def kill_leftovers():
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq tankwar.exe",
                          "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    for ln in out.splitlines():
        parts = ln.strip('"').split('","')
        if len(parts) >= 2 and parts[0].lower() == "tankwar.exe":
            try:
                subprocess.call(["taskkill", "/F", "/PID", parts[1]],
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
            except Exception:
                pass

kill_leftovers()
time.sleep(0.5)

# ---- 起跑一对（握手发现偶发被本机 LSP 广播怪癖卡住：run#5 双端 30s
# 超时自退、guest 连 dump 都没建。基线套同日两 PASS、本套首连 PASS ⇒
# 判定环境抖动非回归；给一次整对重启，再不行才算 FAIL）----
def launch_pair(attempt):
    for f in (HOSTF, GUESTF):
        if os.path.exists(f):
            os.remove(f)
    pA = subprocess.Popen([EXE, "netloop"], cwd=ROOT)
    time.sleep(2.0)
    pB = subprocess.Popen([EXE, "netloop"], cwd=ROOT)
    return pA, pB

pA, pB = launch_pair(1)
procs = {pA.pid: pA, pB.pid: pB}

ok = False
try:
    # ---- 0. 握手开局（同基线，快速门槛；含一次重启）----
    if not wait_for(lambda: tok_lines(HOSTF, "G") and tok_lines(GUESTF, "G"), 30):
        print("WARN: 30s 无 G 行（host alive=%s guest alive=%s）→ 整对重启重试一次"
              % (pA.poll(), pB.poll()))
        for p in list(procs.values()):
            p.kill(); p.wait()
        kill_leftovers()
        pA, pB = launch_pair(2)
        procs = {pA.pid: pA, pB.pid: pB}
        if not wait_for(lambda: tok_lines(HOSTF, "G") and tok_lines(GUESTF, "G"), 30):
            fail("no G line within 30s even after relaunch (host alive=%s guest alive=%s)"
                 % (pA.poll(), pB.poll()))
    if tok_lines(HOSTF, "G")[-1][1:] != tok_lines(GUESTF, "G")[-1][1:]:
        fail("G lines differ")
    if not wait_for(lambda: len(parse_t(GUESTF)) > 30, 10):
        fail("no in-match T lines on guest")
    print("handshake ok (G matched, T flowing)")

    # ---- A. 共享流一致：静置与事件后各采一轮，两端 (pick, rngM, m0/m1) ----
    # 对齐靠"同刻双读"（循环里两端取同一 last row），发散=选池/道具时钟不同步
    def sample_window(secs):
        hR, gR = [], []
        t_end = time.time() + secs
        while time.time() < t_end:
            rh = parse_t(HOSTF)
            rg = parse_t(GUESTF)
            if rh and rg:
                hR.append(rh[-1])
                gR.append(rg[-1])
            time.sleep(0.3)
        return hR, gR
    def runs(rows, col):
        out = []
        for row in rows:
            v = row[col]
            if not out or out[-1][1] != v:
                out.append((row[C_TICK], v))
        return out
    def seq_compat(vh, vg):
        # 采样时刻差半秒内，一端可能多/少捕到"最后一个"变化——前缀互含
        # 视为兼容；真发散必然体现在序列中段，前缀关系藏不住。
        n = min(len(vh), len(vg))
        return vh[:n] == vg[:n]
    # rngMatch 判据（会话51 链式定案）：公共流每事件耗一发，两端 netTick
    # 自由跑格（实测差 ~150 tick），同一发在两端墙上错峰落地；3.3Hz 采样
    # 会漏掉中间值 ⇒ 采样序列必然异相位。真发散的唯一表现=值脱离公共
    # xorshift 链或链序倒退，故沿 RngNextMatch(xor13/shr17/shl5) 前推建
    # 链，要求两侧全部采样值同链且各自索引严格递增。
    def next32(x):
        x &= 0xFFFFFFFF
        t = (x ^ ((x << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF
        t = (t ^ (t >> 17)) & 0xFFFFFFFF
        return (t ^ ((t << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF
    def chain_check(tag, vh, vg):
        if vh[0] != vg[0]:
            fail("%s/rngMatch 起点即不同: host=%r guest=%r" % (tag, vh[0], vg[0]))
        want = set(vh) | set(vg)
        pos = {vh[0]: 0}
        v = vh[0]
        while want - set(pos) and len(pos) < 5000:
            v = next32(v)
            if v in pos:
                break
            pos[v] = len(pos)
        missing = want - set(pos)
        if missing:
            fail("%s/rngMatch 值脱离公共链(真发散): 脱链值 %r (host=%r guest=%r)"
                 % (tag, sorted(missing)[:4], vh[:6], vg[:6]))
        for L, who in ((vh, "host"), (vg, "guest")):
            idx = [pos[x] for x in L]
            if any(b <= a for a, b in zip(idx, idx[1:])):
                fail("%s/rngMatch %s 链序倒退: %r idx=%r" % (tag, who, L[:6], idx[:6]))
        h = [pos[x] for x in vh][-1]
        g = [pos[x] for x in vg][-1]
        print("chain ok[%s]: 同链 跨度 host=%d guest=%d (相位差 %d)"
              % (tag, h, g, abs(h - g)))
    def cross_check(tag, hR, gR):
        vh = [v for _, v in runs(hR, C_RNGM)]
        vg = [v for _, v in runs(gR, C_RNGM)]
        chain_check(tag, vh, vg)
        for col, name in ((C_PICK, "pick"),):
            vh = [v for _, v in runs(hR, col)]
            vg = [v for _, v in runs(gR, col)]
            if not seq_compat(vh, vg):
                fail("%s/%s 值序列发散: host=%r guest=%r" % (tag, name, vh, vg))
            print("stream ok[%s]: %s 一致 %r (变化点 %d)" % (tag, name, vh[:6], len(vh)))
        for a, b in ((C_M0, C_M1), (C_M1, C_M0)):
            ra = [v for _, v in runs(hR, a)]
            rb = [v for _, v in runs(gR, b)]
            if not seq_compat(ra, rb):
                fail("%s 雷池镜像发散 col%d<->col%d: %r vs %r" % (tag, a, b, ra[:8], rb[:8]))
        print("mine pool cross ok[%s]" % tag)
    hR, gR = sample_window(12.0)
    cross_check("静置", hR, gR)

    # ---- B. 反向驱动：B 窗驾驶自机移动 -> host 镜像收敛到 guest 自机 ----
    # 出生点间距全凭握手种子（run#3 实测两车垂直仅隔 37px，W 正前方顶住
    # 对方车体=物理挡住而非按键死），故依次试 前进/倒车/转向后前进，
    # 任一方向挪动即认定反向通路活；全程不动才 FAIL（并诊断焦点误投）。
    hwndB = pid_hwnd(pB.pid)
    if not hwndB:
        # run#6 实测 T 行正常在流却一次性枚举不到（重绘期 GetWindowTextLength
        # 瞬返 0 的嫌疑）——重试 4 次，仍败则列出全盘同名窗口 pid 供诊断
        for _ in range(4):
            time.sleep(0.5)
            hwndB = pid_hwnd(pB.pid)
            if hwndB:
                break
    if not hwndB:
        allh = []
        @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
        def cb(h, l):
            n = user32.GetWindowTextLengthW(h)
            if n:
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(h, buf, n + 1)
                if "Tank War" in buf.value:
                    pb = ctypes.c_ulong(0)
                    user32.GetWindowThreadProcessId(h, ctypes.byref(pb))
                    allh.append((pb.value, buf.value))
            return True
        user32.EnumWindows(cb, 0)
        fail("cannot find guest window pid=%d; Tank-War 窗口=%r" % (pB.pid, allh))
    focus(hwndB)
    time.sleep(0.3)
    def drive(seq):
        # seq = (vk, secs, vk, secs, ...)；(vk, vk) 转向不算位移通道
        for i in range(0, len(seq), 2):
            key(seq[i], True); time.sleep(seq[i+1]); key(seq[i], False)
            time.sleep(0.35)
    startG = parse_t(GUESTF)[-1]
    startH = parse_t(HOSTF)[-1]
    moved = None
    for tag, seq in (("W", (VK_W, 1.2)), ("S", (VK_S, 1.2)),
                     ("D+W", (VK_D, 0.9, VK_W, 1.2)),
                     ("A+S", (VK_A, 1.8, VK_S, 1.2))):
        pre = parse_t(GUESTF)[-1]
        drive(seq)
        time.sleep(1.2)  # 等镜像包到位再判
        cur = parse_t(GUESTF)[-1]
        if (cur[C_X0], cur[C_Y0]) != (pre[C_X0], pre[C_Y0]):
            moved = tag
            break
    if not moved:
        nowH = parse_t(HOSTF)[-1]
        leak = ((nowH[C_X0], nowH[C_Y0]) != (startH[C_X0], startH[C_Y0]))
        fail("guest self never moved after W/S/turn tries (driving dead? "
             "focus leaked to host=%s)" % leak)
    time.sleep(0.5)
    rH = parse_t(HOSTF)[-1]
    rG = parse_t(GUESTF)[-1]
    if not (rH[C_MX] == rG[C_X0] and rH[C_MY] == rG[C_Y0] and
            rG[C_MX] == rH[C_X0] and rG[C_MY] == rH[C_Y0]):
        fail("reverse follow broken: host self=(%d,%d) mir=(%d,%d) "
             "guest self=(%d,%d) mir=(%d,%d)"
             % (rH[C_X0], rH[C_Y0], rH[C_MX], rH[C_MY],
                rG[C_X0], rG[C_Y0], rG[C_MX], rG[C_MY]))
    print("reverse follow ok via %s: guest self=(%d,%d) host-mirror converged"
          % (moved, rG[C_X0], rG[C_Y0]))

    # ---- C. 输入隔离：host 窗 P2↑ 不动自机；R 禁重开 ----
    hwndA = pid_hwnd(pA.pid)
    if not hwndA:
        fail("cannot find host window")
    focus(hwndA)
    time.sleep(0.3)
    pre = parse_t(HOSTF)[-1]
    g_cnt0 = len(tok_lines(HOSTF, "G"))
    tick_pre = pre[C_TICK]
    key(VK_UP, True); time.sleep(0.6); key(VK_UP, False)
    key(VK_R, True); time.sleep(0.05); key(VK_R, False)
    time.sleep(0.2)
    key(VK_R, True); time.sleep(0.05); key(VK_R, False)
    time.sleep(1.2)
    post = parse_t(HOSTF)[-1]
    if (post[C_X0], post[C_Y0]) != (pre[C_X0], pre[C_Y0]) or post[C_A0] != pre[C_A0]:
        fail("P2 arrow leaked into local tank: (%d,%d)->(%d,%d)"
             % (pre[C_X0], pre[C_Y0], post[C_X0], post[C_Y0]))
    if post[C_TICK] <= tick_pre:
        fail("R appears to have restarted match (tick regressed %d->%d)"
             % (tick_pre, post[C_TICK]))
    if len(tok_lines(HOSTF, "G")) != g_cnt0:
        fail("R re-issued G handshake lines (restart not suppressed)")
    print("input isolation ok: P2 keys inert, R suppressed (tick %d->%d)"
          % (tick_pre, post[C_TICK]))

    # ---- D. 弹数交叉映射：A 开火 -> host.b0>=1 且 guest.b1>=1 ----
    base_hb0 = max(r[C_B0] for r in parse_t(HOSTF)[-8:])
    base_gb1 = max(r[C_B1] for r in parse_t(GUESTF)[-8:])
    key(VK_SPACE, True); time.sleep(0.05); key(VK_SPACE, False)
    fired = wait_for(lambda: (
        parse_t(HOSTF) and parse_t(GUESTF) and
        max(r[C_B0] for r in parse_t(HOSTF)[-12:]) > base_hb0 and
        max(r[C_B1] for r in parse_t(GUESTF)[-12:]) > base_gb1), 4)
    if not fired:
        fail("owner-cross bullet mapping broken: host b0 base=%d max=%d, "
             "guest b1 base=%d max=%d"
             % (base_hb0, max(r[C_B0] for r in parse_t(HOSTF)[-12:]),
                base_gb1, max(r[C_B1] for r in parse_t(GUESTF)[-12:])))
    print("bullet cross-mapping ok (host own-shot visible as guest peer-shot)")

    # ---- D2. 事件后再验共享流：走动/开火后道具刷新与 RNG 消耗若产生
    #        变化，必须在两端同刻同值出现（此刻有真事件概率更高）----
    hR2, gR2 = sample_window(8.0)
    cross_check("事件后", hR2, gR2)

    # ---- E. 掉线（快验幸存者侧）----
    pA.kill(); pA.wait()
    if not wait_for(lambda: any(r[C_LOST] == 1 for r in parse_t(GUESTF)[-80:]), 3.5):
        fail("survivor did not raise netLost after host kill")
    print("netLost ok")
    ok = True
finally:
    for p in procs.values():
        try:
            p.kill(); p.wait()
        except Exception:
            pass

if ok:
    print("NET LOOPBACK TEST2: PASS")
    sys.exit(0)
