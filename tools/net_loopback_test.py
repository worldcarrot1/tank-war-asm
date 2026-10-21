# ============================================================
# net_loopback_test.py -- 会话36 联机回环验收（同机双开）
# 断言链：
#   1) 双实例启动 -> H 行：一方 isFixed=1(28888) 一方临时口
#   2) 握手开局：两端 G 行（sharedSeed/maxRounds/mapIndex）逐字段相等
#   3) 镜像跟随：按 W 驱动"主机窗"（全局异步键：两端自机同动），
#      对端 dump 的镜像列必须从出生点移动并收敛到对方真实位（==）
#      —— 单机无网络时镜像恒驻出生点，故该断言只可能由收包达成
#   4) 开火同步：SPACE 后两端 b1（镜像弹计数）>=1
#   5) 掉线检测：kill 主机 -> 幸存者 T 行 netLost 0->1（<3.5s）
# 纯标准库；任何一步失败 -> 打印两份 dump 尾部并 exit 1。
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
VK_W, VK_SPACE = 0x57, 0x20

class RECT(ctypes.Structure):
    _fields__ = [("L", ctypes.c_long), ("T", ctypes.c_long),
                 ("R", ctypes.c_long), ("B", ctypes.c_long)]

def fail(msg):
    print("FAIL: " + msg)
    for f in (HOSTF, GUESTF):
        print("---- tail " + os.path.basename(f) + " ----")
        try:
            data = open(f, "rb").read().replace(b"\0", b"")
            tail = data.splitlines()[-20:]
            for ln in tail:
                print(ln.decode("ascii", "replace"))
        except Exception as e:
            print("(cannot read: %r)" % e)
    sys.exit(1)

def tok_lines(path, pfx):
    # 行首字母与首值连写（"G15565 11 39" / "T1042 1 ..."），拆首字符再分列
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
    # T tick rx lost pk x0 y0 mx my a0 a1 hp1 sk1 ef1 aim1 b0 b1 m0 m1 pick [rngm ...]
    rows = []
    for c in tok_lines(path, "T"):
        if len(c) < 21:
            continue
        try:
            rows.append([int(v) for v in c[1:21]])
        except ValueError:
            pass
    return rows

def pid_hwnd(pid):
    found = ctypes.c_void_p(0)
    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    def cb(h, l):
        wp = k32.GetCurrentProcessId  # noqa (keep ref)
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

# ---- 清场 ----
subprocess.call(["taskkill", "/F", "/IM", "tankwar.exe"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.5)
for f in (HOSTF, GUESTF):
    if os.path.exists(f):
        os.remove(f)

# ---- 启动双实例（先启者绑 28888 = isFixed=1）----
pA = subprocess.Popen([EXE, "netloop"], cwd=ROOT)
time.sleep(2.0)
pB = subprocess.Popen([EXE, "netloop"], cwd=ROOT)
procs = {pA.pid: pA, pB.pid: pB}

ok = False
try:
    # ---- 1. 握手开局：两端 G 行存在且相等 ----
    got = wait_for(lambda: tok_lines(HOSTF, "G") and tok_lines(GUESTF, "G"), 30)
    if not got:
        fail("no G line within 30s (lobby/handshake did not complete) "
             "host alive=%s guest alive=%s" % (pA.poll(), pB.poll()))
    gH = tok_lines(HOSTF, "G")[-1]
    gG = tok_lines(GUESTF, "G")[-1]
    print("G host  :", " ".join(gH))
    print("G guest :", " ".join(gG))
    if gH[1:] != gG[1:]:
        fail("G lines differ (shared seed/map mismatch)")

    # ---- 2. H 行：端口形态 1 固定 1 临时 ----
    hH = tok_lines(HOSTF, "H")
    hG = tok_lines(GUESTF, "H")
    if not hH or not hG:
        fail("missing H header line")
    fixed = [int(hH[0][1]) == 1, int(hG[0][1]) == 1]
    if sorted(fixed) != [0, 1]:
        fail("expected exactly one isFixed=1 instance, got %r" % fixed)
    print("H ok: host=%s guest=%s" % (" ".join(hH[0]), " ".join(hG[0])))

    # ---- 3. 对局基线：镜像驻对方出生点且 != 自机位 ----
    if not wait_for(lambda: len(parse_t(GUESTF)) > 30, 10):
        fail("no in-match T lines on guest")
    baseH = parse_t(HOSTF)[-1]
    baseG = parse_t(GUESTF)[-1]
    # 列： 0tick 1rx 2lost 3pk 4x0 5y0 6mx 7my 8a0 9a1 10hp1 11sk1 12ef1 13aim1 14b0 15b1 ...
    if baseH[6] == baseH[4] and baseH[7] == baseH[5]:
        fail("host mirror already equals self pos (spawn role broken?)")
    print("baseline: host self=(%d,%d) mirror=(%d,%d)" %
          (baseH[4], baseH[5], baseH[6], baseH[7]))

    # ---- 4. 镜像跟随：驱动"先启动实例"的窗口 ----
    hwndA = pid_hwnd(pA.pid)
    if not hwndA:
        fail("cannot find window for pid %d" % pA.pid)
    focus(hwndA)
    time.sleep(0.3)
    key(VK_W, True)
    time.sleep(1.2)
    key(VK_W, False)
    time.sleep(1.5)   # 松键+包排空，两端位置定格
    rH = parse_t(HOSTF)[-1]
    rG = parse_t(GUESTF)[-1]
    if rH[6] == baseH[6] and rH[7] == baseH[7]:
        fail("host mirror did not move -> peer packets not applied (follow broken)")
    if not (rH[4] == rG[6] and rH[5] == rG[7] and
            rG[4] == rH[6] and rG[5] == rH[7]):
        fail("cross equality broken: host=(%d,%d)/mir(%d,%d) guest=(%d,%d)/mir(%d,%d)"
             % (rH[4], rH[5], rH[6], rH[7], rG[4], rG[5], rG[6], rG[7]))
    print("follow ok: converged host=(%d,%d) guest=(%d,%d)" %
          (rH[4], rH[5], rG[4], rG[5]))

    # ---- 5. 开火同步：两端镜像弹计数 >=1 ----
    key(VK_SPACE, True)
    time.sleep(0.05)
    key(VK_SPACE, False)
    fired = wait_for(lambda: (parse_t(HOSTF) and parse_t(GUESTF) and
                              any(row[15] >= 1 for row in parse_t(HOSTF)[-40:]) and
                              any(row[15] >= 1 for row in parse_t(GUESTF)[-40:])), 4)
    if not fired:
        fail("no mirror bullets (b1) on either end after SPACE")
    print("fire sync ok")

    # ---- 6. 掉线检测：kill A -> B 的 netLost 置 1 ----
    pA.kill()
    pA.wait()
    lost = wait_for(lambda: any(row[2] == 1 for row in parse_t(GUESTF)[-80:]), 3.5)
    if not lost:
        fail("guest did not raise netLost within 3.5s of host kill")
    print("netLost ok")
    ok = True
finally:
    for p in procs.values():
        try:
            p.kill()
            p.wait()
        except Exception:
            pass

if ok:
    print("NET LOOPBACK TEST: PASS")
    sys.exit(0)
