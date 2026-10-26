# ============================================================
# relay_loopback_test.py -- 会话37 M3.5 中继服务器回环验收（同机双开+本机中继）
# 链路：A/B 两实例 -> relay_server(127.0.0.1:28900) 房间 4242 配对，
#      T/H/W/L/P 全量经服务器转发（协议零改动）。
# 断言链：
#   1) 服务器日志出现 room=4242 且 st=1（两人配对成功）
#   1b) 会话51 STUN步A：两端大厅 B 行尾三列 stunSeen/stunPort/stunIp 齐全，
#       本端 stunPort==对端 H 行自报监听口（交叉）、stunIp=16777343（环回裸dw）
#   2) 两端 G 行（sharedSeed/maxRounds/mapIndex）逐字段相等（握手经中继成立）
#   3) 镜像跟随：按 W 驱动先启实例，两端交叉等式收敛（状态包经中继生效）
#   4) 开火同步：SPACE 后两端 b1>=1
#   5) RTT：T 行末列 netRttAvg 至少一端 >0（'P' 经中继往返成功）
#   6) 掉线检测：kill A -> B netLost 0->1
# 纯标准库；失败打印两份 dump 尾部 + 服务器日志并 exit 1。
# ============================================================
import ctypes, os, subprocess, sys, time

user32 = ctypes.windll.user32
k32 = ctypes.windll.kernel32
user32.SetProcessDPIAware()

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "tankwar.exe")
SRV = os.path.join(ROOT, "relay_server.exe")
HOSTF = os.path.join(ROOT, "netdump_host.txt")
GUESTF = os.path.join(ROOT, "netdump_guest.txt")
SRVLOG = os.path.join(ROOT, "relay_server_test.log")
TITLE = "Tank War ASM M1 - P1: WASD+SPACE | P2: Arrows+ENTER | R restart"
VK_W, VK_SPACE = 0x57, 0x20
SPEC = "127.0.0.1:28900#4242"

def dump_tail(n=20):
    for f in (HOSTF, GUESTF):
        print("---- tail " + os.path.basename(f) + " ----")
        try:
            data = open(f, "rb").read().replace(b"\0", b"")
            for ln in data.splitlines()[-n:]:
                print(ln.decode("ascii", "replace"))
        except Exception as e:
            print("(cannot read: %r)" % e)
    try:
        print("---- tail relay_server_test.log ----")
        data = open(SRVLOG, "rb").read()
        for ln in data.splitlines()[-n:]:
            print(ln.decode("ascii", "replace"))
    except Exception as e:
        print("(cannot read server log: %r)" % e)

def fail(msg):
    print("FAIL: " + msg)
    dump_tail()
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
    # 与 net_loopback_test 同口径：固定取列 1..20（rtt 为第21列，另行读取）
    rows = []
    for c in tok_lines(path, "T"):
        if len(c) < 21:
            continue
        try:
            rows.append([int(v) for v in c[1:21]])
        except ValueError:
            pass
    return rows

def parse_rtt(path):
    # T 行第 21 值 = netRttAvg（会话37 追加列；旧 20 列行不计）
    vals = []
    for c in tok_lines(path, "T"):
        if len(c) < 22:
            continue
        try:
            vals.append(int(c[21]))
        except ValueError:
            pass
    return vals

def parse_h(path):
    # H 行：H 固定性 cookie port pid -> 取本机自报监听口
    rows = tok_lines(path, "H")
    return rows[-1] if rows else None

def parse_stun_t(path):
    # T 行尾三列（会话51 STUN）：c[22]=stunSeen c[23]=stunPort c[24]=stunIp。
    # 证据取 T 不取 B：后启实例大厅期不足 16 tick 即开局，B 行可能整局为零。
    for c in reversed(tok_lines(path, "T")):
        if len(c) >= 25:
            return c
    return None

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

def srv_log_text():
    try:
        return open(SRVLOG, "rb").read().decode("ascii", "replace")
    except Exception:
        return ""

# ---- 清场（含上一轮可能残留的服务器）----
for im in ("tankwar.exe", "relay_server.exe"):
    subprocess.call(["taskkill", "/F", "/IM", im],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.5)
for f in (HOSTF, GUESTF, SRVLOG):
    if os.path.exists(f):
        os.remove(f)

if not os.path.exists(SRV):
    print("relay_server.exe missing -> build_server.bat")
    r = subprocess.call(["cmd", "/c", "build_server.bat"], cwd=ROOT)
    if r != 0 or not os.path.exists(SRV):
        fail("relay_server build failed")

# ---- 1. 启动中继服务器（stdout 落日志文件供断言）----
srvlog = open(SRVLOG, "wb")
pS = subprocess.Popen([SRV, "28900"], cwd=ROOT, stdout=srvlog,
                      stderr=subprocess.STDOUT)
time.sleep(0.7)
if pS.poll() is not None:
    fail("relay_server exited early (port busy?)")
print("relay server up pid=%d" % pS.pid)

procs = {pS.pid: pS}
ok = False
try:
    # ---- 2. 双实例进中继房间（先启者绑 28888 = host dump）----
    pA = subprocess.Popen([EXE, "netrelay", SPEC], cwd=ROOT)
    time.sleep(2.0)
    pB = subprocess.Popen([EXE, "netrelay", SPEC], cwd=ROOT)
    procs[pA.pid] = pA
    procs[pB.pid] = pB

    paired = wait_for(lambda: "room=4242 st=1" in srv_log_text(), 20)
    if not paired:
        fail("server never reported room=4242 paired (st=1)")
    print("server: room 4242 PAIRED")

    # ---- 1b. STUN 步A：'S' 反射两端采信 + 端口/环回 IP 交叉对账（T 行尾列）----
    if not wait_for(lambda: (lambda bH, bG: bH and bG and bH[22] == "1" and
                             bG[22] == "1")(parse_stun_t(HOSTF),
                                           parse_stun_t(GUESTF)), 25):
        fail("no STUN 'S' accepted on both ends (T tail stunSeen never 1)")
    bH, bG = parse_stun_t(HOSTF), parse_stun_t(GUESTF)
    hH, hG = parse_h(HOSTF), parse_h(GUESTF)
    if not (hH and hG):
        fail("missing H line (own reported port unavailable)")
    ownH, ownG = hH[3], hG[3]
    if bH[23] != ownG or bG[23] != ownH:
        fail("STUN port cross mismatch: host_saw=%s guest_own=%s "
             "guest_saw=%s host_own=%s" % (bH[23], ownG, bG[23], ownH))
    if bH[24] != "16777343" or bG[24] != "16777343":
        fail("STUN ip != loopback raw dword 16777343: host=%s guest=%s"
             % (bH[24], bG[24]))
    print("stun ok: host sees 127.0.0.1:%s, guest sees 127.0.0.1:%s" %
          (bH[23], bG[23]))

    # ---- 3. 握手开局：两端 G 行存在且相等 ----
    got = wait_for(lambda: tok_lines(HOSTF, "G") and tok_lines(GUESTF, "G"), 40)
    if not got:
        fail("no G line within 40s (relay handshake did not complete) "
             "A alive=%s B alive=%s" % (pA.poll(), pB.poll()))
    gH = tok_lines(HOSTF, "G")[-1]
    gG = tok_lines(GUESTF, "G")[-1]
    print("G host  :", " ".join(gH))
    print("G guest :", " ".join(gG))
    if gH[1:] != gG[1:]:
        fail("G lines differ (shared seed/map mismatch via relay)")

    # ---- 4. 对局基线 + 镜像跟随（W 驱动先启实例）----
    if not wait_for(lambda: len(parse_t(GUESTF)) > 30, 10):
        fail("no in-match T lines on guest")
    baseH = parse_t(HOSTF)[-1]
    if baseH[6] == baseH[4] and baseH[7] == baseH[5]:
        fail("host mirror already equals self pos (spawn role broken?)")
    hwndA = pid_hwnd(pA.pid)
    if not hwndA:
        fail("cannot find window for pid %d" % pA.pid)
    focus(hwndA)
    time.sleep(0.3)
    key(VK_W, True)
    time.sleep(1.2)
    key(VK_W, False)
    time.sleep(1.5)
    rH = parse_t(HOSTF)[-1]
    rG = parse_t(GUESTF)[-1]
    if rH[6] == baseH[6] and rH[7] == baseH[7]:
        fail("host mirror did not move -> relay forwarding broken")
    if not (rH[4] == rG[6] and rH[5] == rG[7] and
            rG[4] == rH[6] and rG[5] == rH[7]):
        fail("cross equality broken: host=(%d,%d)/mir(%d,%d) guest=(%d,%d)/mir(%d,%d)"
             % (rH[4], rH[5], rH[6], rH[7], rG[4], rG[5], rG[6], rG[7]))
    print("follow ok via relay: host=(%d,%d) guest=(%d,%d)" %
          (rH[4], rH[5], rG[4], rG[5]))

    # ---- 5. 开火同步 ----
    key(VK_SPACE, True)
    time.sleep(0.05)
    key(VK_SPACE, False)
    fired = wait_for(lambda: (parse_t(HOSTF) and parse_t(GUESTF) and
                              any(row[15] >= 1 for row in parse_t(HOSTF)[-40:]) and
                              any(row[15] >= 1 for row in parse_t(GUESTF)[-40:])), 4)
    if not fired:
        fail("no mirror bullets (b1) on either end after SPACE (via relay)")
    print("fire sync ok")

    # ---- 6. RTT：'P' 经服务器对转，至少一端 netRttAvg>0 ----
    rtted = wait_for(lambda: (parse_rtt(HOSTF) and max(parse_rtt(HOSTF)) > 0) or
                                (parse_rtt(GUESTF) and max(parse_rtt(GUESTF)) > 0), 8)
    if not rtted:
        fail("no RTT sample (T col21 >0) on either end")
    print("rtt ok: host_max=%s guest_max=%s" %
          (max(parse_rtt(HOSTF) or [0]), max(parse_rtt(GUESTF) or [0])))

    # ---- 7. 掉线检测：kill A -> B netLost 置 1 ----
    pA.kill()
    pA.wait()
    lost = wait_for(lambda: any(row[2] == 1 for row in parse_t(GUESTF)[-80:]), 3.5)
    if not lost:
        fail("guest did not raise netLost within 3.5s of host kill (relay)")
    print("netLost ok")
    ok = True
finally:
    for p in procs.values():
        try:
            p.kill()
            p.wait()
        except Exception:
            pass
    try:
        srvlog.close()
    except Exception:
        pass

if ok:
    print("RELAY LOOPBACK TEST: PASS")
    sys.exit(0)
