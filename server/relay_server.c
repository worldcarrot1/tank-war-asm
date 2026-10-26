/* ============================================================
 * relay_server.c -- 会话37 M3.5：坦克大战 UDP 中继服务器
 *
 * 用途：非局域网（跨 NAT / 对称 NAT）双人联机。双方都只与本服务器
 * 单播通信；服务器按"房间号"把两名最早入房成员的报文逐字节透传
 * （'T'/'H'/'W'/'L'/'P' 全量转发，游戏协议零改动），仅 'J' 包由
 * 服务器自己消化（注册/续租/配对状态应答）。
 *
 * 用法：  relay_server [port]      默认端口 28900
 * Windows: cl /O2 /W3 /Fe:relay_server.exe server\relay_server.c ws2_32.lib
 * Linux  : gcc -O2 -o relay_server server/relay_server.c
 *
 * 槽位规则：
 *   - 按 (源IP,源端口) 认人；'J' 每约1秒续租一次，10 秒无包回收槽位。
 *   - 同房间按入房先后（joinSeq）取"最早两名"为配对对子；第三人
 *     收 st=2（房间已满），且不与对子互通（转发仅限对子之间）。
 *
 * 会话51 STUN 步A：配对成立时，每次 JOIN 处理后向双方各发一包 'S'(18B)
 *   反射"另一名成员的观测源 addr:port"（即 STUN 语义的映射地址回执）。
 *   cookie 字段回显收件人自己最近一次 JOIN 的 cookie，供客户端认账；
 *   'S' 是服务器专属魔法，转发路径显式排除（客户端不产 'S'，纯防注入）。
 * ============================================================ */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
  #define _WINSOCK_DEPRECATED_NO_WARNINGS   /* inet_ntoa 够用，免 C4996 */
  #define WIN32_LEAN_AND_MEAN
  #include <winsock2.h>
  #include <windows.h>
  #include <ws2tcpip.h>
  #pragma comment(lib, "ws2_32.lib")
  typedef unsigned int u32;
  static u32 now_ms(void) { return (u32)GetTickCount(); }
  static void sleep_ms(unsigned ms) { Sleep(ms); }
  static void sock_init(void) {
      WSADATA wsa;
      if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
          printf("WSAStartup failed\n");
          exit(1);
      }
  }
  static void set_nonblock(SOCKET s) {
      u_long nb = 1;
      ioctlsocket(s, FIONBIO, &nb);
  }
  #define SOCK_T SOCKET
  #define sock_errno() WSAGetLastError()
  #define EWOULDBLOCK_L WSAEWOULDBLOCK
#else
  #include <unistd.h>
  #include <errno.h>
  #include <time.h>
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  #include <fcntl.h>
  typedef unsigned int u32;
  static u32 now_ms(void) {
      struct timespec ts;
      clock_gettime(CLOCK_MONOTONIC, &ts);
      return (u32)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
  }
  static void sleep_ms(unsigned ms) { usleep(ms * 1000u); }
  static void sock_init(void) { }
  static void set_nonblock(int s) { fcntl(s, F_SETFL, O_NONBLOCK); }
  #define SOCK_T int
  #define closesocket close
  #define sock_errno() errno
  #define EWOULDBLOCK_L EAGAIN
#endif

#define DEFAULT_PORT   28900
#define MAX_SLOTS      64
#define SLOT_EXPIRE_MS 10000u      /* 客户端 JOIN 周期约1s，10s 兜底回收 */
#define NET_VER        1
#define JOIN_ST_WAIT   0
#define JOIN_ST_PAIR   1
#define JOIN_ST_FULL   2
#define PKT_BUF        1024

typedef struct {
    int    used;
    struct sockaddr_in addr;       /* 源 IP:端口 即身份 */
    u32    room;
    u32    lastSeen;               /* GetTickCount 口径，回绕安全（无符号差） */
    u32    joinSeq;                /* 全局入房序号：小者更早 */
    u32    cookie;                 /* 会话51：最近一次 JOIN cookie（'S' 回显用） */
} Slot;

static Slot   g_slots[MAX_SLOTS];
static u32    g_joinSeq = 0;
static SOCK_T g_sock = 0;

static u32 load32(const unsigned char *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}
static void store32(unsigned char *p, u32 v) {
    p[0] = (unsigned char)(v); p[1] = (unsigned char)(v >> 8);
    p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24);
}

/* 回绕安全的"已过期"判定 */
static int expired(const Slot *s, u32 now) {
    return (now - s->lastSeen) >= SLOT_EXPIRE_MS ? 1 : 0;
}

/* 找 (ip,port) 完全相同的槽位；无则 -1 */
static int find_slot(const struct sockaddr_in *a) {
    int i;
    for (i = 0; i < MAX_SLOTS; i++)
        if (g_slots[i].used &&
            g_slots[i].addr.sin_addr.s_addr == a->sin_addr.s_addr &&
            g_slots[i].addr.sin_port == a->sin_port)
            return i;
    return -1;
}

/* 房间 r 的"最早两名"：输出自成员与配对对子（-1=无）
 * selfIdx = 已在槽位中的下标；返回 me 是否在 top2 里。 */
static int room_top2(u32 room, int selfIdx, int *out1, int *out2) {
    int i, n1 = -1, n2 = -1;
    for (i = 0; i < MAX_SLOTS; i++) {
        if (!g_slots[i].used || g_slots[i].room != room) continue;
        if (n1 < 0 || g_slots[i].joinSeq < g_slots[n1].joinSeq) {
            n2 = n1; n1 = i;
        } else if (n2 < 0 || g_slots[i].joinSeq < g_slots[n2].joinSeq) {
            n2 = i;
        }
    }
    *out1 = n1; *out2 = n2;
    return (selfIdx == n1 || selfIdx == n2) ? 1 : 0;
}

/* 会话51 STUN 步A：向 me 反射 peer 的观测源端点（'S' 18B，布局见 game.inc）
 * room 用 LE（与 'J' ack 同口径）；IP/端口裸字节（网络序）原样拷贝 */
static void send_stun(const Slot *me, const Slot *peer) {
    unsigned char s[18];
    s[0] = 'S'; s[1] = NET_VER; s[2] = 0; s[3] = 0;
    memcpy(s + 4,  &peer->addr.sin_addr.s_addr, 4);
    memcpy(s + 8,  &peer->addr.sin_port, 2);
    store32(s + 10, me->room);
    store32(s + 14, me->cookie);
    sendto(g_sock, (const char *)s, 18, 0,
           (struct sockaddr *)&me->addr, sizeof(me->addr));
}

/* 'J' join：注册/续租并回 16B ack {'J',1,ver,st,room,0,0} */
static void handle_join(const struct sockaddr_in *from, const unsigned char *pkt, int len) {
    u32 room = load32(pkt + 4);
    u32 now  = now_ms();
    int idx  = find_slot(from);
    int n1 = -1, n2 = -1, inTop, st;
    unsigned char ack[16];

    if (len < 16 || room == 0) return;                 /* 非法 JOIN 忽略 */

    if (idx < 0) {
        int i;
        for (i = 0; i < MAX_SLOTS; i++)
            if (!g_slots[i].used) { idx = i; break; }
        if (idx < 0) {                                 /* 槽位满：直接回 FULL */
            st = JOIN_ST_FULL;
            goto SEND_ACK;
        }
        memset(&g_slots[idx], 0, sizeof(Slot));
        g_slots[idx].used = 1;
        g_slots[idx].addr = *from;
        g_slots[idx].room = room;
        g_slots[idx].joinSeq = ++g_joinSeq;
    } else if (g_slots[idx].room != room) {
        g_slots[idx].room = room;                      /* 换房 = 重新排队 */
        g_slots[idx].joinSeq = ++g_joinSeq;
    }
    g_slots[idx].lastSeen = now;
    g_slots[idx].cookie = load32(pkt + 8);             /* 会话51：常新（'S' 回显用） */

    inTop = room_top2(room, idx, &n1, &n2);
    st = !inTop ? JOIN_ST_FULL
       : (n2 >= 0 ? JOIN_ST_PAIR : JOIN_ST_WAIT);       /* 对子齐了才 PAIR */

SEND_ACK:
    ack[0] = 'J'; ack[1] = 1; ack[2] = NET_VER; ack[3] = (unsigned char)st;
    store32(ack + 4, room);
    store32(ack + 8, 0);                                /* cookie 恒 0 */
    store32(ack + 12, 0);
    sendto(g_sock, (const char *)ack, 16, 0, (struct sockaddr *)from, sizeof(*from));
    if (st == JOIN_ST_PAIR && idx >= 0) {
        int pn = (idx == n1) ? n2 : n1;                 /* 会话51：双向反射观测点 */
        if (pn >= 0) {
            send_stun(&g_slots[idx], &g_slots[pn]);     /* 给本人：对端公网端点 */
            send_stun(&g_slots[pn], &g_slots[idx]);     /* 给对端：本人公网端点 */
        }
    }
    printf("[%6u] JOIN %s:%u room=%u st=%d\n",
           now, inet_ntoa(from->sin_addr), ntohs(from->sin_port), room, st);
    fflush(stdout);
}

/* 非 'J' 包：已知槽位 -> 刷新租约 + 若在对子中则透传给另一名 */
static void handle_forward(const struct sockaddr_in *from, const unsigned char *pkt, int len) {
    int idx = find_slot(from);
    int n1, n2, partner;
    if (idx < 0) return;                                /* 未注册来源一律丢弃 */
    g_slots[idx].lastSeen = now_ms();
    if (!room_top2(g_slots[idx].room, idx, &n1, &n2)) {
        return;                                          /* 第三人/孤儿成员不转发 */
    }
    partner = (idx == n1) ? n2 : n1;
    if (partner < 0) return;                             /* 还没配对 */
    if (sendto(g_sock, (const char *)pkt, len, 0,
               (struct sockaddr *)&g_slots[partner].addr,
               sizeof(g_slots[partner].addr)) < 0) {
        printf("[warn] forward to partner failed err=%d\n", sock_errno());
    }
}

static void reap_expired(void) {
    u32 now = now_ms();
    int i;
    for (i = 0; i < MAX_SLOTS; i++) {
        if (g_slots[i].used && expired(&g_slots[i], now)) {
            printf("[%6u] EXPIRE slot %d %s:%u room=%u\n",
                   now, i, inet_ntoa(g_slots[i].addr.sin_addr),
                   ntohs(g_slots[i].addr.sin_port), g_slots[i].room);
            fflush(stdout);
            g_slots[i].used = 0;
        }
    }
}

int main(int argc, char **argv) {
    unsigned short port = DEFAULT_PORT;
    struct sockaddr_in me;
    unsigned char buf[PKT_BUF];
    socklen_t alen;
    int recvLoop;

    if (argc > 1) {
        long p = strtol(argv[1], NULL, 10);
        if (p < 1 || p > 65535) {
            printf("bad port: %s\n", argv[1]);
            return 1;
        }
        port = (unsigned short)p;
    }

    sock_init();
    g_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (g_sock == (SOCK_T)-1) { printf("socket failed\n"); return 1; }
#ifdef SO_REUSEADDR
    { int on = 1; setsockopt(g_sock, SOL_SOCKET, SO_REUSEADDR, (const char *)&on, sizeof(on)); }
#endif
    memset(&me, 0, sizeof(me));
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = htonl(INADDR_ANY);
    me.sin_port = htons(port);
    if (bind(g_sock, (struct sockaddr *)&me, sizeof(me)) < 0) {
        printf("bind :%u failed\n", port);
        return 1;
    }
    set_nonblock(g_sock);
    printf("TankWar relay server listening on UDP :%u (default room gate: 2 earliest joiners)\n", port);
    fflush(stdout);

    for (;;) {
        recvLoop = 0;
        for (;;) {                                       /* 一次唤醒抽干队列 */
            struct sockaddr_in from;
            int n;
            alen = sizeof(from);
            n = recvfrom(g_sock, (char *)buf, sizeof(buf), 0,
                         (struct sockaddr *)&from, &alen);
            if (n < 0) break;
            if (n == 0) continue;
            if (buf[0] == 'J') {
                handle_join(&from, buf, n);
            } else if (buf[0] != 'S') {     /* 会话51：'S' 服务器专属，防注入转发 */
                handle_forward(&from, buf, n);
            }
            if (++recvLoop >= 256) { sleep_ms(1); }      /* 防洪：单轮上限 */
        }
        reap_expired();
        sleep_ms(5);
    }
    return 0;
}
