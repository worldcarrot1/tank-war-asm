; ============================================================
; ui.asm —— 界面状态机：主菜单 / 人数选择 / 按键设置 / 联机大厅
; 键盘操作（边沿检测防连发，导航键固定不受自定义键位影响）：
;   主菜单: ↑↓ 选择, Enter 确认, 鼠标悬停+左键点击
;   人数选择: ←→ 调整 2..4, Enter 开始, Esc 返回
;     下方按当前人数显示键位容器（2 人 2 个 .. 4 人 4 个）：
;     鼠标点击某键位 -> 闪烁等待 -> 按新键完成改键（冲突则拒绝），
;     容器区右下角"重置按键"按钮恢复默认；键盘操作全部保留
;   设置: ↑↓ 选择动作, Enter 进入重绑 -> 按任意键完成, Esc 返回
;   联机: 自动 UDP 广播发现对手(端口 28888), Enter 与发现的对手开战
;   对局中: Esc 回主菜单
; 联机说明：双方都进"LAN PLAY"页 -> 互相广播发现 -> 各自按 Enter 开战。
;   对局内本机驱动 slot0，对方坦克经 UDP 状态同步显示（net.asm）。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

public gameState
public numPlayers
public netMode
public menuFont
public fontSmall
public fontBig
public langFlag
public playerName
public pauseMode
public pauseSel
public countT
public volumeLvl
public sfxOn
public themeNight
public clickEvt
public clickPX
public clickPY
public UiInit
public UiTick
public UiRender
public UiTextZ
public UiForcePlay2
public UiForceNumSel
public UiForceBotMatch             ; 会话38：黑色人机挑战局入口
public UiSyncBotName               ; 会话38：槽1显示名同步（net.asm 退人机用）

extern hWnd      :dword
extern hdcBack   :dword
extern keyTable  :dword
extern maxRounds :dword
extern matchOver :dword
extern brushPickBg :dword        ; gfx：图标深色底
extern brushIcon   :dword        ; gfx：图标白填充
extern penIcon     :dword        ; gfx：图标白笔
extern penOld2     :dword        ; gfx：笔恢复
extern brushMortar :dword        ; gfx：深色描边
extern brushBg     :dword        ; gfx：页面底色
extern brushSteel  :dword        ; gfx：钢墙
extern brushBrick  :dword        ; gfx：砖红（爆炸/血条）
extern brushP1     :dword        ; gfx：P1 车体色
extern brushP2     :dword        ; gfx：P2 车体色
extern brushBullet :dword        ; gfx：子弹
extern brushIce    :dword        ; gfx：冰面（演示/护盾）
extern brushWater  :dword        ; gfx：水面（演示）
extern brushDirt   :dword        ; gfx：泥地（演示）
extern brushDirtDark :dword      ; gfx：泥地纹理（演示）
extern brushWave   :dword        ; gfx：水波纹（演示）
extern brushStreak :dword        ; gfx：冰高光（演示）
DrawTank PROTO :DWORD,:DWORD,:DWORD,:DWORD
DrawPickupIcon PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
GameInit  PROTO
InitKeyDefaults PROTO
GfxRender PROTO
NetInit   PROTO
NetFlush  PROTO
NetShutdown PROTO
AchvCountOwned PROTO                  ; achv.asm 会话40：已收集数（图鉴页眉）
AchvGetDate    PROTO :DWORD           ; achv.asm 会话41：解锁日期 yyyymmdd
AchvGetProg    PROTO :DWORD           ; achv.asm 会话40：单条进度查询
AchvGetOwn     PROTO :DWORD           ; achv.asm 会话40：单条解锁查询
extern achvDefs       :byte           ; 定义表基址（ACHDEF 形状，按 ACH_SIZE 步行）
extern achvToastId    :dword          ; 解锁弹层成就号（-1 无）
extern achvToastT     :dword          ; 解锁弹层剩余 tick
extern achvMatchKills :dword          ; 本场击杀（单场类行现值显示）
extern achvUnseen     :dword          ; 会话41：本次运行新解锁未读（菜单角标）
SndVolume PROTO :DWORD
SndPlay   PROTO :DWORD
SndBgmSetTrack PROTO :DWORD
extern peerAddr  :sockaddr_in
extern peerKnown :dword
extern hSock     :dword
; ---- 会话36：联机大厅 FSM / 掉线 / 手输直连接口 ----
NetEnterLan   PROTO
NetLobbyTick  PROTO
NetLobbyState PROTO
NetCanStart   PROTO
NetSetStart   PROTO
NetEnterMatch PROTO
NetSetManual  PROTO :DWORD
; ---- 会话37 M3.5：中继服务器联机 + RTT 显示 ----
NetSetServer    PROTO :DWORD
NetResetTargets PROTO
extern relayMode   :dword
extern relayRoom   :dword
extern relaySt     :dword
; ---- 会话51 STUN步A（net.asm）----
extern stunIp      :dword
extern stunPort    :dword
extern stunSeen    :dword
extern netRttAvg   :dword
extern netRttOk    :dword
extern netLost     :dword
extern ownPort     :dword
extern isFixedPort :dword
extern netDumpOn   :dword
extern botMask     :dword          ; bot.asm（会话39：bit i=槽i黑色人机）
public netPaused
public onlineBanT                  ; 会话39：联机禁用技提示 toast（game 置位、本模块渲染递减）
public UiOnChar
public UiForceLanAuto
public UiForceRelayAuto

; win32.inc 未收录的鼠标 API 原型与常量
VK_LBUTTON     equ 001h
VK_BACK        equ 008h
GetCursorPos   PROTO stdcall :DWORD
ScreenToClient PROTO stdcall :DWORD,:DWORD

; ---- 人数选择页键位容器布局（客户区 992x640，6 行/人）----
KBBOX_X0   equ 28                  ; 首个容器左缘
KBBOX_DX   equ 240                 ; 容器水平间距（宽 216 + 缝 24）
KBBOX_W    equ 216                 ; 容器宽
KBBOX_H    equ 228                 ; 容器高（头 40 + 6 行*30 + 底 8）
KBBOX_Y    equ 322                 ; 容器顶部 y
KBROW_Y0   equ 40                  ; 容器顶 -> 首行偏移
KBROW_DH   equ 30                  ; 行高
RST_X      equ 745                 ; 重置按钮区（容器区右下角）
RST_Y      equ 556
RST_W      equ 210
RST_H      equ 30

.data
    gameState   dd ST_MENU
    langFlag    dd 1                   ; 0=英文 1=中文（默认中文）
    numPlayers  dd 2
    netMode     dd 0                   ; 1 = 联机对局（主循环调用 NetFlush）
    menuSel     dd 0
    numSel      dd 2
    numBot      dd 0                 ; 会话39：人数页人机补位数（0..numSel-1，占高档槽）
    prevBotMask dd 0                 ; 会话39：上次同步的 botMask（改名恢复判据）
    roundsSel   dd 11                  ; 人数页可调的比赛局数（11..51 奇数）
    playerName  db "P1", 0, 13 dup (0), "P2", 0, 13 dup (0)
                db "P3", 0, 13 dup (0), "P4", 0, 13 dup (0)   ; 每人 16 字节
    editSlot    dd -1                  ; 正在改名的容器槽位（-1=无）
    pauseMode   dd 0                   ; 0=无 1=暂停菜单 2=继续倒计时
    pauseSel    dd 0                   ; 暂停菜单选中项 0继续 1音量 2音效 3退出
    countT      dd 0                   ; 倒计时剩余 tick
    volumeLvl   dd 70                  ; 主音量 0..100
    sfxOn       dd 1                   ; 音效开关
    themeNight  dd 0                   ; 深夜模式（主页面黑风）
    prevUp      dd 0
    prevDown    dd 0
    prevLeft    dd 0
    prevRight   dd 0
    prevEnter   dd 0
    prevEsc     dd 0
    prevK1      dd 0                ; 会话41：图鉴 1..4/Home/End 跳页
    prevK2      dd 0
    prevK3      dd 0
    prevK4      dd 0
    prevKHome   dd 0
    prevKEnd    dd 0
    prevAny     dd 0
    prevLBtn    dd 0                   ; 鼠标左键上帧状态（边沿检测）
    mousePt     POINT <>               ; 鼠标客户区坐标（GetCursorPos+ScreenToClient）
    mouseX      dd 0
    mouseY      dd 0
    rebindSlot  dd -1                  ; 人数页改键：正在等待新键的槽位（slot*KEY_PER+动作），-1=无
    rebindCool  dd 0                   ; 改键进入等待的防误捕冷却 tick
    clickEvt    dd 0                   ; 1=本帧有待处理的鼠标点击（WndProc 置位）
    clickPX     dd 0                   ; 点击客户区坐标（消息 lParam）
    clickPY     dd 0
    blinkTick   dd 0                   ; 改键闪烁计数
    discTimer   dd 0
    discBuf     db "TWNET01"
    discFrom    sockaddr_in <>
    discLen     dd SIZEOF sockaddr_in
    recvTmp     db 64 dup (0)
    peerIpBuf   db 20 dup (0)
    peerIpLen   dd 0
    stunBuf     db 32 dup (0)          ; 会话51 STUN步A："STUN a.b.c.d:port" 显示缓冲
    ; ---- 会话36：大厅手输 IP + 掉线冻结 ----
    ipEditMode  dd 0                   ; 1=Tab 聚焦编辑行（Enter 走连接不走开局）
    ipBuf       db 32 dup (0)
    ipLen       dd 0
    manualErr   dd 0                   ; 1=ParseIp 失败红字提示
    directOn    dd 0                   ; 1=已切手动直连模式
    lanAuto     dd 0                   ; netloop：每 tick 自动 SetStart 并开局
    netPaused   dd 0                   ; 1=掉线冻结玩法但继续收包（main 主循环读取）
    onlineBanT  dd 0                   ; 会话39：联机禁用技按压提示倒计时（渲染递减，2s 自隐）
    prevTab     dd 0
    lanSt       dd 0                   ; NetLobbyState 位图（渲染用）
    lanBtnCol   dd 0                   ; 开始按钮色（FrameRect 毁 edx 兜底）
    uiBuf       db 96 dup (0)
    nsTmp       db 16 dup (0)            ; NumStr 逆序暂存（会话36）
    menuBrush   dd ?
    menuFont    dd ?
    fontSmall   dd ?                   ; 键位容器用小字体（18px）
    fontBig     dd ?                   ; 倒计时大数字（72px）
    boxBrush    dd ?                   ; 容器边框画刷（深灰）
    brushNight  dd ?                   ; 深夜模式背景刷（近黑）
    boxBrushN   dd ?                   ; 深夜模式容器边框（浅灰）
    boxCur      dd ?                   ; 当帧生效的边框刷
    fontOld     dd ?
    bcastAddr   sockaddr_in <>
    oneVal      dd 1
    aTab        dd aUp, aDn, aLt, aRt, aFire, aUse

    ; ---- 技能说明页数据（9 技能：名/描述，中英双语）----
    skillPage   dd 0                   ; 当前页 0..SKILL_COUNT-1
    demoT       dd 0                   ; 玩法演示动画 tick
    demoPage    dd 0                   ; 玩法演示页 0..5
    szPlus1     db "+1", 0
    szScore0    db "P1 0 : 0 P2", 0
    szScore1    db "P1 1 : 0 P2", 0
    szDemT      db "GAMEPLAY", 0
    CN_DEMOMENU dw 073A9h,06CD5h,06F14h,0793Ah, 0
    CN_DEMOT    dw 073A9h,06CD5h,06F14h,0793Ah, 0
    szKO        db "K.O.", 0
    dDemoEn     dd dDE0, dDE1, dDE2, dDE3, dDE4, dDE5
    dDemoCn     dd kDD0, kDD1, kDD2, kDD3, kDD4, kDD5
    dDE0        db "DRIVE: W/S fwd-back, A/D rotate; aim = body facing", 0
    dDE1        db "FIRE: each hit drains 1 HP; 3 HP and out", 0
    dDE2        db "BOUNCE: bullets ricochet off walls (up to 10)", 0
    dDE3        db "TERRAIN: mud slows, ice slides, water blocks", 0
    dDE4        db "SKILLS: a box spawns every 10s; skill key fires it", 0
    dDE5        db "SCORE: last survivor +1; most wins takes the match", 0
    kDD0        dw 9A7Eh,9A76h,0FF1Ah,0057h,002Fh,0053h,524Dh,8FDBh,540Eh,9000h,0FF0Ch,0041h,002Fh,0044h,5DE6h,53F3h,65CBh,8F6Ch,0FF1Bh,70AEh,5F39h,671Dh,70AEh,53E3h,65B9h,5411h,98DEh, 0
    ; 驾驶：W/S 前进后退、A/D 左右旋转；炮弹朝炮口方向飞
    ;（原"移动：方向键或WASD；出生朝向…"文案随会话 19 操控改版更新）
    kDD1        dw 05C04h,051FBh,0FF1Ah,0547Dh,04E2Dh,05373h,06DD8h,06C70h,0FF08h,04E00h,06EF4h,08840h,0FF09h, 0
    kDD2        dw 053CDh,05F39h,0FF1Ah,05B50h,05F39h,0649Eh,05899h,04F1Ah,053CDh,05F39h,0FF08h,06700h,0591Ah,00020h,00031h,00030h,00020h,06B21h,0FF09h,0FF0Ch,053EFh,04EE5h,07ED5h,0540Eh,0653Bh,051FBh, 0
    kDD3        dw 05730h,05F62h,0FF1Ah,06CE5h,05730h,051CFh,0901Fh,03001h,051B0h,09762h,06ED1h,0884Ch,03001h,06C34h,09762h,0963Bh,06321h,0FF08h,09A6Dh,06C34h,0672Fh,053EFh,0901Ah,08FC7h,0FF09h, 0
    kDD4        dw 06280h,080FDh,0FF1Ah,05730h,056FEh,06BCFh,00020h,00031h,00030h,00020h,079D2h,05237h,04E00h,04E2Ah,06280h,080FDh,07BB1h,0FF0Ch,06309h,06280h,080FDh,0952Eh,053D1h,052A8h, 0
    kDD5        dw 05F97h,05206h,0FF1Ah,056DEh,05408h,06700h,0540Eh,05B58h,06D3Bh,08005h,00020h,0002Bh,00031h,00020h,05206h,0FF1Bh,05C40h,06570h,06253h,06EE1h,0603Bh,05206h,06700h,09AD8h,08005h,083B7h,080DCh, 0
    skNmEn      dd sKN1,sKN2,sKN3,sKN4,sKN5,sKN6,sKN7,sKN8,sKN9
    skNmCn      dd kCN1,kCN2,kCN3,kCN4,kCN5,kCN6,kCN7,kCN8,kCN9
    skDsEn      dd sKD1,sKD2,sKD3,sKD4,sKD5,sKD6,sKD7,sKD8,sKD9
    skDsCn      dd kCD1,kCD2,kCD3,kCD4,kCD5,kCD6,kCD7,kCD8,kCD9
    sKN1        db "ICE SHIELD", 0
    sKD1        db "7s shield: immune to bullets, freezes 2x2 tiles nearby", 0
    sKN2        db "LASER", 0
    sKD2        db "hold dashed preview; press again, fires after 1.3s", 0
    sKN3        db "BOUNCE LASER", 0
    sKD3        db "live bounce preview; press again, 1.3s then hits path", 0
    sKN4        db "GHOST", 0
    sKD4        db "drive through walls up to 3 times within 4s", 0
    sKN5        db "MINE", 0
    sKD5        db "plant a mine at your feet, arms in 2s (you can trigger it too)", 0
    sKN6        db "NITRO", 0
    sKD6        db "+50% speed for 5s, stacks with terrain", 0
    sKN7        db "SWAP", 0
    sKD7        db "after firing, swap positions with your flying bullet", 0
    sKN8        db "WATER WALK", 0
    sKD8        db "drive on water for 6s", 0
    sKN9        db "PHANTOM", 0
    sKD9        db "leave 2 decoys, body immune 6s; a bullet hitting a decoy hurts you", 0
    kCN1        dw 051B0h,076FEh, 0
    kCD1        dw 089E6h,053D1h,0540Eh,00020h,00037h,00020h,079D2h,062A4h,076FEh,073AFh,07ED5h,0FF0Ch,0671Fh,095F4h,0514Dh,075ABh,05B50h,05F39h,04F24h,05BB3h,0FF0Ch,05E76h,05728h,08EABh,08FB9h,094FAh,05F00h,00020h,00032h,00078h,00032h,00020h,051B0h,09762h, 0
    kCN2        dw 06FC0h,05149h,070AEh, 0
    kCD2        dw 09884h,089C8h,0865Ah,07EBFh,08DEFh,05F84h,0FF0Ch,0518Dh,06309h,00020h,00031h,0002Eh,00033h,00073h,00020h,0540Eh,053D1h,05C04h,07A7Fh,05899h,06FC0h,05149h, 0
    kCN3        dw 053CDh,05C04h,06FC0h,05149h, 0
    kCD3        dw 06301h,07EEDh,09884h,089C8h,053CDh,05F39h,08DEFh,05F84h,0FF0Ch,0518Dh,06309h,00020h,00031h,0002Eh,00033h,00073h,00020h,0540Eh,05168h,08DEFh,05F84h,04F24h,05BB3h, 0
    kCN4        dw 07A7Fh,05899h,0672Fh, 0
    kCD4        dw 00034h,00020h,079D2h,05185h,053EFh,07A7Fh,08D8Ah,05899h,04F53h,0884Ch,09A76h,0FF0Ch,06700h,0591Ah,07A7Fh,08D8Ah,00020h,00033h,00020h,06B21h, 0
    kCN5        dw 05730h,096F7h, 0
    kCD5        dw 05728h,0811Ah,04E0Bh,057CBh,096F7h,0FF0Ch,00032h,00020h,079D2h,0540Eh,0751Fh,06548h,0FF08h,081EAh,05DF1h,078BEh,04E0Ah,04E5Fh,04F1Ah,070B8h,0FF09h, 0
    kCN6        dw 071C3h,06CB9h,052A0h,0901Fh, 0
    kCD6        dw 00035h,00020h,079D2h,05185h,079FBh,052A8h,0901Fh,05EA6h,00020h,0002Bh,00035h,00030h,00025h,0FF0Ch,053EFh,04E0Eh,051B0h,09762h,0002Fh,06CE5h,05730h,06548h,0679Ch,053E0h,052A0h, 0
    kCN7        dw 06362h,04F4Dh,0672Fh, 0
    kCD7        dw 05F00h,0706Bh,0540Eh,06309h,06280h,080FDh,0952Eh,0FF0Ch,04E0Eh,098DEh,0884Ch,04E2Dh,07684h,05B50h,05F39h,04EA4h,06362h,04F4Dh,07F6Eh, 0
    kCN8        dw 09A6Dh,06C34h,0672Fh, 0
    kCD8        dw 00036h,00020h,079D2h,05185h,053EFh,05728h,06C34h,09762h,04E0Ah,0884Ch,09A76h, 0
    kCN9        dw 05B9Ah,0683Ch,0672Fh, 0
    kCD9        dw 0539Fh,05730h,07559h,04E0Bh,00020h,00032h,00020h,053EAh,0865Ah,05F71h,0FF0Ch,0672Ch,04F53h,0514Dh,04F24h,00020h,00036h,00020h,079D2h,0FF1Bh,05B50h,05F39h,06253h,04E2Dh,0865Ah,05F71h,04F1Ah,08BA9h,0672Ch,04F53h,06389h,08840h, 0
    szSkT       db "SKILLS", 0
    szItemSk    db "SKILL GUIDE", 0
    CN_SKT      dw 06280h,080FDh,08BF4h,0660Eh, 0
    CN_SKILLMENU dw 06280h,080FDh,08BF4h,0660Eh, 0
    szSkHint    db "ESC: BACK   <- ->: PAGE", 0
    CN_SKHINT   dw 00045h,00073h,00063h,0FF1Ah,08FD4h,056DEh,00020h,00020h,05DE6h,053F3h,065B9h,05411h,0952Eh,0FF1Ah,07FFBh,09875h, 0
    szSkPage    db " / %d", 0

    aUp         db "FWD", 0          ; 会话 19: 四方向驾驶 -> 前进/后退/转左/转右
    aDn         db "BACK", 0
    aLt         db "TURN-L", 0
    aRt         db "TURN-R", 0
    aFire       db "FIRE", 0
    aUse        db "SKILL", 0
    ; 中文动作名：等长指针表（每项独立 0 结尾，按下标索引）
    cUpW        dw 524Dh, 8FDBh, 0   ; 前进
    cDnW        dw 540Eh, 9000h, 0   ; 后退
    cLtW        dw 5DE6h, 8F6Ch, 0   ; 左转
    cRtW        dw 53F3h, 8F6Ch, 0   ; 右转
    cFireW      dw 5F00h, 706Bh, 0      ; 开火
    cUseW       dw 4F7Fh, 7528h, 0      ; 使用（技能）
    cnActT      dd cUpW, cDnW, cLtW, cRtW, cFireW, cUseW
    vkUpN       db "UP", 0
    vkDnN       db "DOWN", 0
    vkLtN       db "LEFT", 0
    vkRtN       db "RIGHT", 0
    vkSpN       db "SPACE", 0
    vkEnN       db "ENTER", 0
    vkRsN       db "RSH", 0
    vkLsN       db "LSH", 0
    szTitle     db "TANK WAR v1.2", 0
    szKeysLbl   db "KEYS (CLICK A KEY TO CHANGE)", 0
    szItem1     db "START GAME", 0
    szItem2     db "SETTINGS", 0
    szItem3     db "LAN PLAY", 0
    szItem4     db "EXIT", 0
    szItemBot   db "BLACK BOT DUEL", 0      ; 会话38：黑色人机挑战局
    szItemAch   db "ACHIEVEMENTS", 0        ; 会话40：成就图鉴入口
    szItemAchNew db "ACHIEVEMENTS *(NEW)", 0 ; 会话41：有新解锁未读时的变体
    szAchT      db "ACHIEVEMENT CODEX", 0
    szAchProg   db "COLLECTED", 0
    szToastAch  db "ACHIEVEMENT UNLOCKED", 0
    szRar0      db "COMMON", 0
    szRar1      db "RARE", 0
    szRar2      db "EPIC", 0
    szRar3      db "LEGEND", 0
    szDoneEN    db "DONE", 0
    szLockEN    db "LOCKED", 0
    szBotNm     db "BLACK BOT", 0
    szPDfl      db "P", 0            ; 会话39：恢复默认名前缀（后随槽号+1）
    szNumT      db "SELECT PLAYERS", 0
    szNumL      db "<<", 0
    szNumR      db ">>", 0
    szRounds    db "ROUNDS", 0
    szBots      db "BOTS", 0
    szHint      db "ENTER: CONFIRM   ESC: BACK", 0
    szNameHint  db "CLICK NAME TO RENAME", 0
    szNameEdit  db "TYPE A NAME, ENTER TO OK", 0
    szVol2      db "VOLUME", 0
    szSfx2      db "SOUND FX", 0
    szOn2       db "ON", 0
    szOff2      db "OFF", 0
    szNight     db "NIGHT MODE", 0
    szSetHint   db "MOUSE OR KEYS BOTH OK   ESC: BACK", 0
    CN_SETHINT  dw 09F20h,06807h,0952Eh,076D8h,07686h,053EFh,00020h,00020h,00045h,0073h,0063h,0FF1Ah,08FD4h,056DEh, 0
    CN_BACKBTN  dw 08FD4h,056DEh, 0                            ; 返回
    CN_STARTBTN dw 05F00h,059CBh,06BD4h,08D5Bh, 0              ; 开始对局
    szReset     db "RESET ALL KEYS", 0
    szReb2      db "BLINK: CLICK 2ND ROW=SWAP / PRESS KEY / ESC", 0
    szSetT      db "KEY SETTINGS", 0
    szSetH      db "ENTER: REBIND   ESC: BACK", 0
    szRebind    db " <- PRESS ANY KEY", 0
    szLanT      db "LAN PLAY", 0
    szLanB      db "BROADCASTING ON UDP PORT 28888 ...", 0
    szLanN      db "SEARCHING FOR PEERS ...", 0
    szLanF      db "PEER FOUND:", 0
    szLanS      db "CLICK/ENTER: START MATCH   ESC: BACK", 0
    ; ---- 会话36：大厅四态/端口/手输/掉线 ----
    szLanW      db "WAITING PEER ENTER ...", 0
    szLanR      db "STARTING ...", 0
    szLanBoth   db "PRESS ENTER: START MATCH (BOTH SIDES)", 0
    szPort      db "LOCAL PORT:", 0
    szManual    db "TAB: IP[:PORT] OR SRV:PORT#ROOM, ENTER", 0
    szDirect    db "DIRECT MODE:", 0
    szBad       db "INVALID ADDRESS", 0
    szLostEN    db "CONNECTION LOST - WAITING RECONNECT", 0
    szBanEN     db "SKILL NOT AVAILABLE ONLINE", 0
    szTempEN    db "TEMP - SHARE FOR MANUAL", 0
    szStartBtn  db "START MATCH", 0
    szBackBtn   db "BACK", 0
    szFont      db "Arial", 0
    wBuf        dd 64 dup (0)           ; 设置行宽字符缓冲
    szLangEN    db "LANGUAGE: ENGLISH", 0
    cnActW      dw 4E0Ah, 0             ; 上
                dw 4E0Bh, 0             ; 下
                dw 5DE6h, 0             ; 左
                dw 53F3h, 0             ; 右
                dw 5F00h, 706Bh, 0      ; 开火
    CN_START dw 5f00h,59cbh,6e38h,620fh, 0
    CN_SET dw 8bbeh,7f6eh, 0
    CN_LAN dw 8054h,673ah,5bf9h,6218h, 0
    CN_EXIT dw 9000h,51fah, 0
    CN_BOT  dw 6311h,6218h,9ED1h,8272h,4EBAh,673Ah, 0     ; 挑战黑色人机
    CN_LANG dw 8bedh,8a00h,0ff1ah,4e2dh,6587h, 0
    CN_NUMT dw 9009h,62e9h,73a9h,5bb6h,6570h,91cfh, 0
    CN_ROUNDS dw 5c40h,6570h, 0                                          ; 局数
    CN_BOTS   dw 4EBAh,673Ah, 0                                          ; 人机（会话39）
    CN_HINT dw 56deh,8f66h,0ff1ah,786eh,8ba4h,0020h,0020h,0020h,0020h,0045h,0073h,0063h,0ff1ah,8fd4h,56deh, 0
    CN_NAMEHINT dw 70B9h,51FBh,540Dh,5B57h,53EFh,6539h,540Dh, 0   ; 点击名字可改名
    CN_NAMEEDIT dw 8F93h,5165h,540Dh,5B57h,56DEh,8F66h,786Eh,8BA4h, 0 ; 输入名字回车确认
    CN_VOL2     dw 97F3h,91CFh, 0                              ; 音量
    CN_SFX      dw 97F3h,6548h, 0                              ; 音效
    CN_ON2      dw 5F00h, 0                                    ; 开
    CN_OFF2     dw 5173h, 0                                    ; 关
    CN_NIGHT    dw 6DF1h,591Ch,6A21h,5F0Fh, 0                  ; 深夜模式
    CN_RESET dw 91cdh,7f6eh,6240h,6709h,66f4h,6539h,6309h,952eh, 0        ; 重置所有更改按键
    CN_REB2 dw 95EAh,70C1h,4E2Dh,0FF1Ah,70B9h,53E6h,4E00h,884Ch,3Dh,4E92h,6362h,0FF0Ch,6309h,65B0h,952Eh,3Dh,7ED1h,5B9Ah,0FF0Ch,45h,73h,63h,3Dh,53D6h,6D88h, 0 ; 闪烁中：点另一行=互换，按新键=绑定，Esc=取消
    CN_KEYS dw 952eh,4f4dh, 0                                            ; 键位
    CN_SETT     dw 06E38h,0620Fh,08BBEh,07F6Eh, 0
    CN_SETH dw 56deh,8f66h,0ff1ah,6539h,952eh,0020h,0020h,0020h,0020h,0045h,0073h,0063h,0ff1ah,8fd4h,56deh, 0
    CN_REBIND dw 0020h,003ch,002dh,0020h,8bf7h,6309h,4efbh,610fh,952eh, 0
    CN_LANT dw 8054h,673ah,5bf9h,6218h,0ff08h,5c40h,57dfh,7f51h,0ff09h, 0
    CN_LANB dw 6b63h,5728h,901ah,8fc7h,0020h,0055h,0044h,0050h,0020h,7aefh,53e3h,0020h,0032h,0038h,0038h,0038h,0038h,0020h,5e7fh,64adh,0020h,002eh,002eh,002eh, 0
    CN_LANN dw 6b63h,5728h,641ch,7d22h,5bf9h,624bh,0020h,002eh,002eh,002eh, 0
    CN_LANF dw 5df2h,53d1h,73b0h,5bf9h,624bh,003ah, 0
    CN_LANS dw 70B9h,51FBh,6216h,56DEh,8F66h,0FF1Ah,5F00h,59CBh,6BD4h,8D5Bh,0020h,0045h,0073h,0063h,0FF1Ah,8FD4h,56DEh, 0
    CN_LANW dw 7B49h,5F85h,5BF9h,65B9h,6309h,0020h,0045h,006Eh,0074h,0065h,0072h,0020h,002Eh,002Eh,002Eh, 0
    CN_LANR dw 5373h,5C06h,5F00h,59CBh,002Eh,002Eh,002Eh, 0
    CN_LANBOTH dw 53CCh,65B9h,6309h,0020h,0045h,006Eh,0074h,0065h,0072h,0020h,5F00h,59CBh, 0
    CN_PORT dw 672Ch,673Ah,7AEFh,53E3h,003Ah, 0
    CN_MANUAL dw 6309h,0054h,0061h,0062h,8F93h,5BF9h,65B9h,0049h,0050h,0020h,6216h,0020h,670Dh,52A1h,5668h,003Ah,7AEFh,53E3h,0023h,623Fh,95F4h,0020h,56DEh,8F66h,8FDEh,63A5h, 0
    CN_DIRECT dw 76F4h,8FDEh,6A21h,5F0Fh,003Ah, 0
    CN_BAD dw 5730h,5740h,65E0h,6548h, 0
    CN_LOST dw 8FDEh,63A5h,4E22h,5931h,0FF0Ch,7B49h,5F85h,91CDh,8FDEh,002Eh,002Eh,002Eh, 0
    CN_NETBAN dw 8054h,673Ah,6A21h,5F0Fh,4E0Dh,652Fh,6301h,8BE5h,6280h,80FDh,0 ; 联机模式不支持该技能
    ; ---- 会话40：成就图鉴文案（码点同 tools/gen_achv_cn.py）----
    CN_ACHGALT dw 6210h,5C31h,56FEh,9274h, 0        ; 成就图鉴（菜单项与页眉共用）
    CN_ACHPROG dw 6536h,96C6h,8FDBh,5EA6h, 0        ; 收集进度
    CN_ACHTOA  dw 6210h,5C31h,89E3h,9501h, 0        ; 成就解锁
    CN_ACHRAR0 dw 666Eh,901Ah, 0                    ; 普通
    CN_ACHRAR1 dw 7A00h,6709h, 0                    ; 稀有
    CN_ACHRAR2 dw 53F2h,8BD7h, 0                    ; 史诗
    CN_ACHRAR3 dw 4F20h,5947h, 0                    ; 传奇
    CN_ACHOWN  dw 5DF2h,8FBEh,6210h, 0              ; 已达成
    CN_ACHLOCK dw 672Ah,8FBEh,6210h, 0              ; 未达成
    CN_ACHGALTW dw 0FF08h,65B0h,0FF09h,6210h,5C31h,56FEh,9274h, 0 ; （新）成就图鉴
    rarEn   dd OFFSET szRar0, OFFSET szRar1, OFFSET szRar2, OFFSET szRar3
    rarCn   dd OFFSET CN_ACHRAR0, OFFSET CN_ACHRAR1, OFFSET CN_ACHRAR2, OFFSET CN_ACHRAR3
    rarCol  dd 00808080h, 00D08020h, 00C040C0h, 0020D0FFh  ; 灰/蓝/紫/金（0x00BBGGRR）
    rarGoal dd 6, 7, 6, 5                              ; 会话41：各品阶条数（随 def 表增删同步！）
    rarCnt  dd 0, 0, 0, 0                              ; 会话41：本次扫描各品阶已点亮
    rarBr   dd 0, 0, 0, 0                              ; 会话41：品阶色笔刷（弹层描边，UiInit 建）
    rarIdx  dd 0                                       ; 会话41：建刷循环计数（跨 invoke 安全）
    galPage dd 0                                       ; 图鉴当前页
    CN_TEMP dw 4E34h,65F6h,7AEFh,53E3h,0FF0Ch,624Bh,7ED9h,5BF9h,65B9h, 0
    ; ---- 会话37 M3.5：中继房间状态 / RTT 延迟 ----
    szRelay     db "RELAY:", 0
    szRelayWait db "WAITING PEER JOIN ...", 0
    szRelayPair db "PAIRED ON SERVER", 0
    szRelayFull db "ROOM FULL - PICK ANOTHER", 0
    CN_RELAY    dw 4E2Dh,7EE7h,003Ah, 0                        ; 中继:
    CN_RELAYW   dw 7B49h,5F85h,961Fh,53CBh,52A0h,5165h,002Eh,002Eh,002Eh, 0 ; 等待队友加入...
    CN_RELAYP   dw 5DF2h,914Dh,5BF9h,0FF08h,670Dh,52A1h,5668h,8FDEh,63A5h,0FF09h, 0 ; 已配对（服务器连接）
    CN_RELAYF   dw 623Fh,95F4h,5DF2h,6EE1h,0FF0Ch,6362h,53ECh,65B0h,623Fh,95F4h, 0 ; 房间已满，换一个新房间
    colErr      dd 000000CDh
    colDark     dd 00232323h
    colGray     dd 00606060h
    colHi       dd 0000C06000h
    colFound    dd 0000A000h
    hdcWin2     dd 0
    ; ---- 会话45：成就图鉴图标表（game-icons.net，CC BY 3.0，署名见 README
    ;      「成就图标」条；重生成 tools/pick45.py + tools/raster45.py）----
    include achvicons.inc

.code

; ------------------------------------------------------------
; 会话45：图鉴图标渲染 —— achvicons.inc 24x24 四级覆盖字节，
; 按品阶色点亮。AchvShade=各分量 k/256 缩放（k 作 256 分母整数）。
; AchvIcoBlit：pIdx 0..27（0..23 成就算条，24..27 品阶徽章），
; pCol=满色（级3），级2≈0.62 满色、级1≈0.30 满色、级0 透明；
; 逐行同色跨段合并减少 FillRect。笔刷即建即销（每调用 3 枚，可忽）。
; ------------------------------------------------------------
AchvShade proc uses ebx, pCol:DWORD, pK:DWORD
    local r0:DWORD, g0:DWORD, b0:DWORD
    mov eax, pCol
    and eax, 0FFh
    imul eax, pK
    shr eax, 8
    mov r0, eax
    mov eax, pCol
    shr eax, 8
    and eax, 0FFh
    imul eax, pK
    shr eax, 8
    mov g0, eax
    mov eax, pCol
    shr eax, 16
    and eax, 0FFh
    imul eax, pK
    shr eax, 8
    mov b0, eax
    shl eax, 16
    mov ebx, g0
    shl ebx, 8
    or eax, ebx
    or eax, r0
    ret
AchvShade endp

AchvIcoBlit proc uses ebx esi edi ecx edx, pX:DWORD, pY:DWORD, pIdx:DWORD, pCol:DWORD
    local rc:RECT, br1:DWORD, br2:DWORD, br3:DWORD, iy:DWORD, ix:DWORD
    invoke AchvShade, pCol, 77
    invoke CreateSolidBrush, eax
    mov br1, eax
    invoke AchvShade, pCol, 158
    invoke CreateSolidBrush, eax
    mov br2, eax
    invoke CreateSolidBrush, pCol
    mov br3, eax
    mov eax, pIdx
    imul eax, eax, 576
    lea esi, achvIconTab
    add esi, eax
    mov iy, 0
AIB_Y:
    mov ix, 0
AIB_X:
    mov eax, iy
    imul eax, 24
    add eax, ix
    movzx ecx, byte ptr [esi+eax]
    test ecx, ecx
    jz AIB_STEP
    mov edx, ix
AIB_SP:
    inc edx
    cmp edx, 24
    jae AIB_SPD
    mov eax, iy
    imul eax, 24
    add eax, edx
    movzx eax, byte ptr [esi+eax]
    cmp eax, ecx
    je AIB_SP
AIB_SPD:
    mov ebx, edx                       ; 段尾（FillRect 会毁 edx）
    mov eax, pX
    add eax, ix
    mov rc.left, eax
    mov eax, pX
    add eax, edx
    mov rc.right, eax
    mov eax, pY
    add eax, iy
    mov rc.top, eax
    inc eax
    mov rc.bottom, eax
    mov eax, ecx                       ; 级别选刷
    .if eax == 1
        mov eax, br1
    .elseif eax == 2
        mov eax, br2
    .else
        mov eax, br3
    .endif
    invoke FillRect, hdcBack, addr rc, eax
    mov ix, ebx
    jmp AIB_NEXT
AIB_STEP:
    inc ix
AIB_NEXT:
    mov eax, ix
    cmp eax, 24
    jb AIB_X
    inc iy
    mov eax, iy
    cmp eax, 24
    jb AIB_Y
    invoke DeleteObject, br1
    invoke DeleteObject, br2
    invoke DeleteObject, br3
    ret
AchvIcoBlit endp

; ------------------------------------------------------------
; UiInit
; ------------------------------------------------------------
UiInit proc
    invoke CreateSolidBrush, 00D2D2D2h
    mov menuBrush, eax
    invoke CreateSolidBrush, 00141414h       ; 深夜模式背景（近黑）
    mov brushNight, eax
    invoke CreateSolidBrush, 00232323h
    mov boxBrush, eax
    invoke CreateSolidBrush, 00A0A0A0h       ; 深夜模式容器边框（浅灰）
    mov boxBrushN, eax
    ; ---- 会话41：弹层品阶色描边笔刷（rarCol 四色各建一刷）----
    mov rarIdx, 0
UI_RarBr:
    mov ecx, rarIdx
    .if ecx >= 4
        jmp UI_RarBrDone
    .endif
    mov edx, rarCol[ecx*4]
    invoke CreateSolidBrush, edx
    mov ecx, rarIdx
    mov rarBr[ecx*4], eax
    inc rarIdx
    jmp UI_RarBr
UI_RarBrDone:
    ; （会话 27 主页坦克三色刷+描边笔已随会话 28 下架移除）
    invoke CreateFontA, 30, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov menuFont, eax
    invoke CreateFontA, 18, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov fontSmall, eax
    invoke CreateFontA, 72, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov fontBig, eax
    ; 键位默认值只在启动时设一次（GameInit 不再重置，
    ; 否则人数页改的自定义键位每局开局都会被洗掉）
    invoke InitKeyDefaults
    ret
UiInit endp

; ------------------------------------------------------------
; UiForcePlay2 -- 命令行 "tankwar play2"：跳过菜单直接 2P 对局
; （自动化截图验收用，避免菜单按键注入受启动期环境停顿影响）
; ------------------------------------------------------------
UiForcePlay2 proc
    mov botMask, 0                 ; 会话39：常规对练不带人机
    mov numPlayers, 2
    invoke GameInit
    mov netMode, 0
    mov gameState, ST_PLAY
    ret
UiForcePlay2 endp

; ------------------------------------------------------------
; UiSyncBotName -- 会话39：按 botMask 同步 4 槽容器标题（playerName 每槽 16B）
;   槽在掩码内        -> "BLACK BOT"（第2台起带序号 "BLACK BOT 2/3/4"）
;   不在掩码但上次在  -> 恢复默认 "P1..P4"（延续会话38 的槽1行为）
;   其余槽不动        -> 保留玩家自定义名（联机退人机后改名不丢）
; ------------------------------------------------------------
UiSyncBotName proc uses esi edi ecx ebx edx
    xor ebx, ebx
USN_L:
    mov edi, ebx
    imul edi, edi, 16
    add edi, offset playerName
    mov eax, botMask
    bt eax, ebx
    jnc USN_Out
    ; 人机槽：名 = "BLACK BOT" + 序号（序号=本槽以下人机数+1，随槽位升序）
    mov esi, ebx
    xor edx, edx
USN_Pc:
    dec esi
    js USN_PcDone
    bt botMask, esi
    jnc USN_Pc
    inc edx
    jmp USN_Pc
USN_PcDone:
    inc edx
    mov dword ptr [edi], 0
    mov dword ptr [edi+4], 0
    mov dword ptr [edi+8], 0
    mov dword ptr [edi+12], 0
    xor ecx, ecx
    lea esi, szBotNm
USN_Cp:
    cmp byte ptr [esi+ecx], 0
    je USN_CpDone
    mov al, [esi+ecx]
    mov [edi+ecx], al
    inc ecx
    cmp ecx, 12
    jb USN_Cp
USN_CpDone:
    cmp edx, 1
    jbe USN_Nul
    mov byte ptr [edi+ecx], ' '
    inc ecx
    add dl, '0'
    mov [edi+ecx], dl
USN_Nul:
    mov byte ptr [edi+ecx], 0
    jmp USN_Next
USN_Out:
    ; 非人机槽：仅当上次是人机时恢复默认名，否则保留自定义名
    mov eax, prevBotMask
    bt eax, ebx
    jnc USN_Next
    mov dword ptr [edi], 0
    mov dword ptr [edi+4], 0
    mov dword ptr [edi+8], 0
    mov dword ptr [edi+12], 0
    mov byte ptr [edi], 'P'
    mov eax, ebx
    add eax, '1'
    mov byte ptr [edi+1], al
USN_Next:
    inc ebx
    cmp ebx, MAX_PLAYERS
    jb USN_L
    mov eax, botMask
    mov prevBotMask, eax
    ret
UiSyncBotName endp

; ------------------------------------------------------------
; UiApplyBots -- 会话39：把人数页 numBot 落地为 botMask+容器名
;   人占低槽、人机补高槽：mask = ((1<<K)-1) << (N-K)，K≤N-1（至少留1真人）
;   菜单期调用安全：GameUpdate 不跑，BotThink 无从触发
; ------------------------------------------------------------
UiApplyBots proc
    mov eax, numSel
    dec eax
    .if numBot > eax
        mov numBot, eax
    .endif
    mov ecx, numBot
    mov edx, numSel
    sub edx, ecx                      ; 移位量 N-K
    mov eax, 1
    shl eax, cl
    dec eax                           ; 低 K 位 1
    mov ecx, edx
    shl eax, cl                       ; 抬到高 K 槽
    mov botMask, eax
    invoke UiSyncBotName
    ret
UiApplyBots endp

; ------------------------------------------------------------
; UiForceBotMatch -- 会话38/39：直开黑色人机挑战局（菜单项 / "tankwar bot"）
;   双人 BO3 + 1 台人机补位（等同 numsel 页 numSel=2、numBot=1）；
;   botMask 必须在 GameInit 之前落地——ResetTanks 依据它给人机槽三命。
; ------------------------------------------------------------
UiForceBotMatch proc
    mov numSel, 2
    mov numBot, 1
    invoke UiApplyBots
    mov numPlayers, 2
    mov maxRounds, 3
    invoke GameInit
    mov netMode, 0
    mov gameState, ST_PLAY
    ret
UiForceBotMatch endp

; ------------------------------------------------------------
; UiForceNumSel -- 命令行 "tankwar numsel"：直入人数选择页
; （无注入截图验收键位容器用）
; ------------------------------------------------------------
UiForceNumSel proc
    mov numSel, 2
    mov rebindSlot, -1
    mov gameState, ST_NUMSEL
    ret
UiForceNumSel endp

; ------------------------------------------------------------
; UiForceLanAuto -- 命令行 "tankwar netloop"：直入大厅 + 自动开局
; 同机双开回环验收专用（tools/net_loopback_test.py）：开转储、进大厅、
; 每 tick 自动 NetSetStart，NetCanStart 一真立即 NetEnterMatch。
; 双方对称执行 -> 握手/种子协商走的全是真实代码路径。
; ------------------------------------------------------------
UiForceLanAuto proc
    mov netDumpOn, 1
    mov numPlayers, 2
    mov lanAuto, 1
    mov gameState, ST_LAN
    invoke NetEnterLan
    ret
UiForceLanAuto endp

; ------------------------------------------------------------
; UiForceRelayAuto -- 会话37 "tankwar netrelay <ip[:port]#room>"：
; 直入大厅 + 自动设定中继目标 + 自动开局（中继回环验收专用，
; tools/relay_loopback_test.py 双实例同房间连接自建服务器全链路）
; ------------------------------------------------------------
UiForceRelayAuto proc pBuf: dword
    invoke UiForceLanAuto
    invoke NetSetServer, pBuf
    mov directOn, eax
    ret
UiForceRelayAuto endp

; ------------------------------------------------------------
; NumStr -- 无符号十进制转字符串（0 结尾），返回 eax=字符数
; ------------------------------------------------------------
NumStr proc uses ebx ecx edx esi value: dword, pBuf: dword
    mov esi, pBuf
    mov eax, value
    .if eax == 0
        mov byte ptr [esi], '0'
        mov byte ptr [esi+1], 0
        mov eax, 1
        ret
    .endif
    xor ecx, ecx
NS_Dig:
    .if eax == 0
        jmp NS_Out
    .endif
    xor edx, edx
    mov ebx, 10
    div ebx
    add dl, '0'
    mov nsTmp[ecx], dl
    inc ecx
    jmp NS_Dig
NS_Out:
    xor eax, eax
NS_Wr:
    .if eax >= ecx
        mov byte ptr [esi+eax], 0
        ret
    .endif
    mov edx, ecx
    sub edx, eax
    dec edx
    movzx edx, byte ptr nsTmp[edx]
    mov byte ptr [esi+eax], dl
    inc eax
    jmp NS_Wr
NumStr endp

; ------------------------------------------------------------
; UiOnChar -- WndProc WM_CHAR 转发（main.asm 每字符调用）
; 仅 ST_LAN 且 Tab 聚焦编辑行时生效；放行 0-9 . : 退格 回车；
; 其余（含中文输入法合成字符）一律吞掉不响应，改键页不参与。
; ------------------------------------------------------------
UiOnChar proc wCh: dword
    .if gameState != ST_LAN
        ret
    .endif
    .if ipEditMode == 0
        ret
    .endif
    mov eax, wCh
    .if eax == 8                          ; Backspace
        .if ipLen > 0
            dec ipLen
            mov ecx, ipLen
            mov byte ptr ipBuf[ecx], 0
        .endif
        ret
    .endif
    .if eax == 13                         ; Enter -> 解析并直连
        mov ecx, ipLen
        mov byte ptr ipBuf[ecx], 0
        ; 会话37：串中含 '#' = 中继服务器模式 "ip[:port]#房间"，否则纯手动直连
        xor edx, edx
        mov eax, 0
    UOC_Hash:
        movzx ecx, byte ptr ipBuf[edx]
        .if ecx == 0
            jmp UOC_HashDone
        .endif
        .if ecx == '#'
            mov eax, 1
            jmp UOC_HashDone
        .endif
        inc edx
        jmp UOC_Hash
    UOC_HashDone:
        .if eax != 0
            invoke NetSetServer, addr ipBuf
        .else
            invoke NetSetManual, addr ipBuf
        .endif
        .if eax == 0
            mov manualErr, 1
        .else
            mov manualErr, 0
            mov directOn, 1
        .endif
        ret
    .endif
    .if eax < '0'
        .if eax != '#'                    ; 会话37：'#'(0x23) 放行（房间号分隔符）
            ret
        .endif
    .endif
    .if eax > '9' && eax != '.' && eax != ':' && eax != '#'
        ret
    .endif
    mov ecx, ipLen
    .if ecx >= 28
        ret
    .endif
    mov byte ptr ipBuf[ecx], al
    inc ecx
    mov byte ptr ipBuf[ecx], 0
    mov ipLen, ecx
    ret
UiOnChar endp

; ------------------------------------------------------------
; UiTextZ -- 输出 0 结尾字符串
; ------------------------------------------------------------
UiTextZ proc uses esi ecx hdc: dword, x: dword, y: dword, pStr: dword, color: dword
    invoke SetBkMode, hdc, TRANSPARENT
    invoke SetTextColor, hdc, color
    mov esi, pStr
    xor ecx, ecx
UTZ_Len:
    cmp byte ptr [esi+ecx], 0
    je UTZ_Out
    inc ecx
    jmp UTZ_Len
UTZ_Out:
    invoke TextOutA, hdc, x, y, pStr, ecx
    ret
UiTextZ endp

; ------------------------------------------------------------
; UiTextW -- 输出 UTF-16 字符串（自动求长）
; ------------------------------------------------------------
UiTextW proc uses esi ecx hdc: dword, x: dword, y: dword, pStr: dword, color: dword
    invoke SetBkMode, hdc, TRANSPARENT
    invoke SetTextColor, hdc, color
    mov esi, pStr
    xor ecx, ecx
UTW_Len:
    cmp word ptr [esi+ecx*2], 0
    je UTW_Out
    inc ecx
    jmp UTW_Len
UTW_Out:
    invoke TextOutW, hdc, x, y, pStr, ecx
    ret
UiTextW endp

; PickLang -- 按语言返回字符串指针：eax = pEn 或 pCn
PickLang proc pEn: dword, pCn: dword
    mov eax, pEn
    .if langFlag != 0
        mov eax, pCn
    .endif
    ret
PickLang endp

; ------------------------------------------------------------
; MenuActivate -- 主菜单当前项（menuSel）的激活动作
; 键盘 Enter 与鼠标左键点击共用，保证两种操作行为一致
; ------------------------------------------------------------
; ------------------------------------------------------------
; MenuActivate -- 主菜单当前项（menuSel）的激活动作
; 键盘 Enter 与鼠标左键点击共用，保证两种操作行为一致
; 会话42：删除第2项"挑战黑色人机"（用户要求撤出主界面）——人机仍可由
; 命令行 tankwar bot 与人数选择页补位进入，UiForceBotMatch 本身保留。
; ------------------------------------------------------------
MenuActivate proc
    .if menuSel == 0
        mov rebindSlot, -1          ; 进入人数页清改键状态
        mov gameState, ST_NUMSEL
    .elseif menuSel == 1
        mov demoPage, 0
        mov demoT, 0
        mov gameState, ST_DEMO
    .elseif menuSel == 2
        mov skillPage, 0
        mov gameState, ST_SKILL
    .elseif menuSel == 3
        mov gameState, ST_SET
    .elseif menuSel == 4
        mov gameState, ST_LAN
        mov discTimer, 0
        mov ipEditMode, 0
        mov manualErr, 0
        mov lanAuto, 0
        invoke NetResetTargets            ; 会话37：重进大厅清手动/中继目标（回广播发现）
        invoke NetEnterLan              ; 会话36：socket 常驻不再重建/关断
        mov ipLen, 0
        mov byte ptr ipBuf[0], 0
        mov directOn, 0
    .elseif menuSel == 5
        mov galPage, 0               ; 会话40：成就图鉴（每次进页回首页）
        mov achvUnseen, 0            ; 会话41：进图鉴=已读，菜单"(新)"角标熄灭
        mov gameState, ST_ACHG
    .elseif menuSel == 6
        invoke PostQuitMessage, NULL
    .else
        xor langFlag, 1              ; 语言切换
    .endif
    ret
MenuActivate endp

; UiTextL -- 语言感知文本输出（EN=UiTextZ / CN=UiTextW）
UiTextL proc hdc: dword, x: dword, y: dword, pEn: dword, pCn: dword, color: dword
    .if langFlag == 0
        invoke UiTextZ, hdc, x, y, pEn, color
    .else
        invoke UiTextW, hdc, x, y, pCn, color
    .endif
    ret
UiTextL endp

; ------------------------------------------------------------
; KeyEdge -- 按键边沿检测
; ------------------------------------------------------------
KeyEdge proc vk: dword, pPrev: dword
    invoke GetAsyncKeyState, vk
    and eax, 8000h
    .if eax != 0
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov ecx, pPrev
    mov edx, [ecx]
    mov [ecx], eax
    .if eax != 0 && edx == 0
        mov eax, 1
    .else
        mov eax, 0
    .endif
    ret
KeyEdge endp

; ------------------------------------------------------------
; StrCopy -- 复制 len 字节
; ------------------------------------------------------------
StrCopy proc uses esi edi ecx pSrc: dword, pDst: dword, len: dword
    mov esi, pSrc
    mov edi, pDst
    mov ecx, len
    rep movsb
    ret
StrCopy endp

; ------------------------------------------------------------
; VkName -- VK 码 -> 名称（写 uiBuf，返回 eax = 长度）
; ------------------------------------------------------------
VkName proc uses ebx ecx edx edi vk: dword, pDst: dword
    mov edi, pDst
    mov eax, vk
    .if eax == VK_UP
        mov word ptr [edi], 'PU'            ; "UP"
        mov eax, 2
    .elseif eax == VK_DOWN
        invoke StrCopy, offset vkDnN, edi, 4
        mov eax, 4
    .elseif eax == VK_LEFT
        invoke StrCopy, offset vkLtN, edi, 4
        mov eax, 4
    .elseif eax == VK_RIGHT
        invoke StrCopy, offset vkRtN, edi, 5
        mov eax, 5
    .elseif eax == VK_SPACE
        invoke StrCopy, offset vkSpN, edi, 5
        mov eax, 5
    .elseif eax == VK_RETURN
        invoke StrCopy, offset vkEnN, edi, 5
        mov eax, 5
    .elseif eax == VK_RSHIFT
        invoke StrCopy, offset vkRsN, edi, 4
        mov eax, 4
    .elseif eax == VK_LSHIFT
        invoke StrCopy, offset vkLsN, edi, 4
        mov eax, 4
    .elseif (eax >= 'A' && eax <= 'Z') || (eax >= '0' && eax <= '9')
        mov [edi], al
        mov eax, 1
    .else
        mov byte ptr [edi], '0'
        mov byte ptr [edi+1], 'x'
        mov ecx, eax
        shr ecx, 4
        mov dl, cl
        .if dl < 10
            add dl, '0'
        .else
            add dl, '0'-10+7
        .endif
        mov [edi+2], dl
        mov ecx, eax
        and ecx, 0Fh
        mov dl, cl
        .if dl < 10
            add dl, '0'
        .else
            add dl, '0'-10+7
        .endif
        mov [edi+3], dl
        mov eax, 4
    .endif
    ret
VkName endp

; ------------------------------------------------------------
; IpToStr -- sin_addr 网络序 4 字节 -> "a.b.c.d"
; 返回 eax = 长度
; ------------------------------------------------------------
IpToStr proc uses ebx ecx edx esi edi pAddr: dword, pBuf: dword
    mov esi, pAddr
    mov edi, pBuf
    xor ecx, ecx
IPS_Seg:
    .if ecx >= 4
        jmp IPS_Done
    .endif
    .if ecx > 0
        mov byte ptr [edi], '.'
        inc edi
    .endif
    movzx eax, byte ptr [esi+ecx]
    xor edx, edx
    mov ebx, 100
    div ebx
    mov dh, 0                        ; 已写高位标志
    .if al > 0
        add al, '0'
        mov [edi], al
        inc edi
        mov dh, 1
    .endif
    mov eax, edx
    xor edx, edx
    mov ebx, 10
    div ebx
    .if al > 0 || dh != 0
        add al, '0'
        mov [edi], al
        inc edi
    .endif
    add dl, '0'
    mov [edi], dl
    inc edi
    inc ecx
    jmp IPS_Seg
IPS_Done:
    mov eax, edi
    sub eax, pBuf
    ret
IpToStr endp

; ------------------------------------------------------------
; UiStunStr -- 会话51 STUN步A：拼 "STUN a.b.c.d:port" 到 stunBuf
;   （大厅中继模式对端观测端点显示；IpToStr 返回值=点分串长度，直接定位冒号）
; ------------------------------------------------------------
UiStunStr proc uses ebx ecx edx esi edi
    mov byte ptr stunBuf[0], 'S'
    mov byte ptr stunBuf[1], 'T'
    mov byte ptr stunBuf[2], 'U'
    mov byte ptr stunBuf[3], 'N'
    mov byte ptr stunBuf[4], ' '
    invoke IpToStr, addr stunIp, offset stunBuf+5
    lea esi, stunBuf+5
    add esi, eax
    mov byte ptr [esi], ':'
    inc esi
    invoke NumStr, stunPort, esi
    ret
UiStunStr endp

; ------------------------------------------------------------
; NumSelHitTest -- 人数页鼠标命中测试
; 返回 eax: 0..19 = 键位槽位（slot*KEY_PER+动作），-2 = 重置按钮，
;           -3-slot = 容器标题（点击改名），-1 = 无
; ------------------------------------------------------------
NumSelHitTest proc uses ebx esi
    ; 重置按钮（容器区右下角）
    mov eax, mouseX
    .if eax >= RST_X && eax < RST_X+RST_W && mouseY >= RST_Y && mouseY < RST_Y+RST_H
        mov eax, -2
        ret
    .endif
    xor ebx, ebx                     ; 容器序号
NHT_Box:
    .if ebx >= numSel
        mov eax, -1
        ret
    .endif
    mov eax, ebx
    imul eax, eax, KBBOX_DX
    add eax, KBBOX_X0
    mov ecx, eax                     ; ecx = 容器左缘
    add eax, KBBOX_W
    .if mouseX >= ecx && mouseX < eax
        ; 容器标题区（P1..P4，y KBBOX_Y+4 .. +30）-> 改名
        mov eax, mouseY
        .if eax >= KBBOX_Y+4 && eax < KBBOX_Y+30
            mov eax, -3
            sub eax, ebx             ; -3-slot
            ret
        .endif
        mov edx, KBBOX_Y + KBROW_Y0  ; 首行顶部
        xor esi, esi
NHT_Row:
        .if esi >= KEY_PER
            jmp NHT_Next
        .endif
        mov eax, edx
        add eax, KBROW_DH - 4        ; 行命中高度 26px
        .if mouseY >= edx && mouseY < eax
            mov eax, ebx
            imul eax, eax, KEY_PER
            add eax, esi             ; slot*KEY_PER + 动作
            ret
        .endif
        add edx, KBROW_DH
        inc esi
        jmp NHT_Row
    .endif
NHT_Next:
    inc ebx
    jmp NHT_Box
NumSelHitTest endp

; ------------------------------------------------------------
; UT_QuitToMenu -- 从暂停/对局退出到主菜单（联机时断开重置）
; ------------------------------------------------------------
UT_QuitToMenu proc
    mov pauseMode, 0
    mov matchOver, 0
    mov gameState, ST_MENU
    .if netMode != 0
        mov netMode, 0                  ; 会话36：socket 常驻；清对端回大厅态
        mov netPaused, 0
        mov lanAuto, 0
        invoke NetEnterLan
    .endif
    ret
UT_QuitToMenu endp

; ------------------------------------------------------------
; UiTick -- 每逻辑 tick 调用
; ------------------------------------------------------------
UiTick proc uses ebx esi edi
    local upE:dword, dnE:dword, ltE:dword, rtE:dword
    local enE:dword, esE:dword, scanVk:dword
    local tabE:dword
    local lbE:dword

    ; 会话41 根因修复：弹层倒计时移到过程头。原先在过程尾，而 ST_PLAY 分支
    ; 末尾的 jmp UT_Done 恒跳过它 → 对局中 toastT 冻结在 240，滑入 dy 恒=96，
    ; 横幅永久停在屏外顶端（对局内解锁弹层从会话40起从未显示的真相）。
    .if achvToastT != 0
        dec achvToastT
    .endif

    ; ---- 鼠标采样 ----
    ; hover 位置用 GetCursorPos（尽力而为，多屏 DPI 下仅作视觉提示）；
    ; 点击判定用 WndProc 的 WM_LBUTTONDOWN 消息坐标（DPI/多屏恒正确）
    invoke GetCursorPos, addr mousePt
    invoke ScreenToClient, hWnd, addr mousePt
    mov eax, mousePt.x
    mov mouseX, eax
    mov eax, mousePt.y
    mov mouseY, eax
    mov eax, clickEvt
    mov lbE, eax
    mov clickEvt, 0
    .if lbE != 0
        mov eax, clickPX
        mov mouseX, eax
        mov eax, clickPY
        mov mouseY, eax
    .endif

    invoke KeyEdge, VK_UP, addr prevUp
    mov upE, eax
    invoke KeyEdge, VK_DOWN, addr prevDown
    mov dnE, eax
    invoke KeyEdge, VK_LEFT, addr prevLeft
    mov ltE, eax
    invoke KeyEdge, VK_RIGHT, addr prevRight
    mov rtE, eax
    invoke KeyEdge, VK_RETURN, addr prevEnter
    mov enE, eax
    invoke KeyEdge, VK_ESCAPE, addr prevEsc
    mov esE, eax
    invoke KeyEdge, VK_TAB, addr prevTab       ; 会话36：大厅编辑焦点
    mov tabE, eax

    ; ---- 会话 28：BGM 分页——对局用旧主题，其余页面用主页新主题
    ;      （同轨直返，零开销）----
    mov eax, gameState
    .if eax == ST_PLAY
        invoke SndBgmSetTrack, 1
    .else
        invoke SndBgmSetTrack, 0
    .endif

    ; ---------- 对局中：Esc 暂停 / 比赛结束回菜单 ----------
    .if gameState == ST_PLAY
        ; 会话36：掉线冻结——玩法停摆但收包继续（main 主循环读 netPaused），
        ; 对端任何一包到达即 netLost 自愈、冻结自动解除
        mov eax, netMode
        .if eax != 0
            mov ecx, netLost
            mov netPaused, ecx
        .else
            mov netPaused, 0
        .endif
        ; 倒计时（pauseMode==2）：到 0 恢复对局；每秒哔一声
        mov eax, pauseMode
        .if eax == 2
            dec countT
            .if countT == 180 || countT == 120 || countT == 60
                invoke SndPlay, 4
            .endif
            .if countT == 0
                mov pauseMode, 0
            .endif
            jmp UT_Done
        .endif
        ; 暂停菜单（pauseMode==1）—— 直接用已采样的边沿变量
        .if eax == 1
            .if upE != 0
                dec pauseSel
                cmp pauseSel, 0
                jge PS_UpOk
                mov pauseSel, 3            ; 环绕（勿写 < 0：无符号恒假）
PS_UpOk:
            .endif
            .if dnE != 0
                inc pauseSel
                .if pauseSel > 3
                    mov pauseSel, 0
                .endif
            .endif
            ; 音量：暂停中 ←→ 直接调节
            .if ltE != 0
                sub volumeLvl, 5
                cmp volumeLvl, 0
                jge PS_VlOk
                mov volumeLvl, 0
PS_VlOk:
                invoke SndVolume, volumeLvl
            .endif
            .if rtE != 0
                add volumeLvl, 5
                .if volumeLvl > 100
                    mov volumeLvl, 100
                .endif
                invoke SndVolume, volumeLvl
            .endif
            .if enE != 0
                .if pauseSel == 0
                    mov pauseMode, 2           ; 继续 -> 3s 倒计时
                    mov countT, 180
                .elseif pauseSel == 2
                    xor sfxOn, 1               ; 音效开关
                .elseif pauseSel == 3
                    call UT_QuitToMenu
                .else
                    mov pauseMode, 2           ; 选中音量行回车 = 直接继续
                    mov countT, 180
                .endif
            .endif
            .if lbE != 0
                ; 菜单项区域：x 420..600，项 y 300+idx*44 .. +38
                mov eax, mouseX
                .if eax >= 420 && eax < 600
                    mov eax, mouseY
                    sub eax, 300
                    .if eax >= 0
                        xor edx, edx
                        mov ecx, 44
                        div ecx                ; eax = 项号
                        .if eax <= 3
                            mov pauseSel, eax
                            .if eax == 0 || eax == 1
                                mov pauseMode, 2
                                mov countT, 180
                            .elseif eax == 2
                                xor sfxOn, 1
                            .else
                                call UT_QuitToMenu
                            .endif
                        .endif
                    .endif
                .endif
            .endif
            jmp UT_Done
        .endif
        ; 打满局数：Enter/Esc/鼠标点击回主菜单（用采样变量；会话 23 加鼠标）
        mov eax, matchOver
        .if eax != 0
            .if enE != 0 || esE != 0 || lbE != 0
                mov matchOver, 0
                mov gameState, ST_MENU
            .endif
            jmp UT_Done
        .endif
        ; Esc -> 暂停
        .if esE != 0
            mov pauseMode, 1
            mov pauseSel, 0
        .endif
        jmp UT_Done
    .endif

    ; ---------- 主菜单 ----------
    .if gameState == ST_MENU
        .if dnE != 0
            inc menuSel
            .if menuSel > 7          ; 会话42：8 项（删"挑战黑色人机"）
                mov menuSel, 0
            .endif
        .endif
        .if upE != 0
            .if menuSel == 0
                mov menuSel, 7
            .else
                dec menuSel
            .endif
        .endif
        .if enE != 0
            invoke MenuActivate
        .endif
        ; ---- 鼠标：悬停高亮 + 左键点击激活 ----
        ; 菜单 8 项渲染矩形：x 440..660，y = 190+i*46 .. +34（与 UiRender UM_Items 同几何）
        ; 鼠标坐标需在窗口客户区内才参与 hover（多屏 DPI 下 GetCursorPos 可能返回界外乱值）
        mov eax, mouseX
        .if eax < 0 || eax >= WND_W
            jmp UT_MMouseDone
        .endif
        mov eax, mouseY
        .if eax < 0 || eax >= WND_H
            jmp UT_MMouseDone
        .endif
        xor ebx, ebx                   ; 会话 23 修复：循环计数器必须显式清零
                                       ; （UiTick 虽 uses ebx，入口值=调用方残留，
                                       ;  >=7 时整段 hover 静默跳过）
UT_MMouse:
        .if ebx >= 8                   ; 会话42：8 项全部可点
            jmp UT_MMouseDone
        .endif
        mov eax, ebx
        imul eax, eax, 46
        add eax, 190
        mov ecx, eax                     ; ecx = 项顶部 y
        add eax, 34                      ; eax = 项底部 y
        .if mouseY >= ecx && mouseY < eax && mouseX >= 440 && mouseX < 660
            mov eax, ebx
            mov menuSel, eax             ; 悬停即选中（高亮联动）
            .if lbE != 0
                invoke MenuActivate      ; 点击激活
                jmp UT_MMouseDone        ; 状态可能已切换
            .endif
        .endif
        inc ebx
        jmp UT_MMouse
UT_MMouseDone:

    ; ---------- 人数选择 ----------
    .elseif gameState == ST_NUMSEL
        ; ---- 玩家名编辑：点击容器标题进入；字符输入；Enter/Esc 确认 ----
        ; （Enter 用采样变量 enE——KeyEdge 边沿已被开头采样消费，二次调用恒 0）
        .if editSlot != -1
            inc blinkTick
            .if enE != 0
                mov editSlot, -1
            .else
                invoke GetAsyncKeyState, VK_ESCAPE
                and eax, 8000h
                .if eax != 0
                    mov editSlot, -1
                .else
                    invoke GetAsyncKeyState, VK_BACK
                    and eax, 1
                    .if eax != 0
                        ; 删尾字符
                        mov eax, editSlot
                        imul eax, eax, 16
                        add eax, offset playerName
                        mov edi, eax
                        xor ecx, ecx
UTN_BLen:
                        cmp byte ptr [edi+ecx], 0
                        je UTN_BCut
                        inc ecx
                        .if ecx < 14
                            jmp UTN_BLen
                        .endif
UTN_BCut:
                        .if ecx > 0
                            mov byte ptr [edi+ecx-1], 0
                        .endif
                    .endif
                    ; 可打印字符 0x20..0x5A（空格/数字/大写字母），0x1 边沿位
                    mov scanVk, 20h
UTN_Scan:
                    mov eax, scanVk
                    .if eax >= 5Bh
                        jmp UTN_ScanDone
                    .endif
                    invoke GetAsyncKeyState, eax
                    and eax, 1
                    .if eax != 0
                        mov eax, editSlot
                        imul eax, eax, 16
                        add eax, offset playerName
                        mov edi, eax
                        xor ecx, ecx
UTN_Len:
                        cmp byte ptr [edi+ecx], 0
                        je UTN_Append
                        inc ecx
                        .if ecx < 14
                            jmp UTN_Len
                        .endif
UTN_Append:
                        .if ecx < 12
                            mov edx, scanVk
                            mov [edi+ecx], dl
                            mov byte ptr [edi+ecx+1], 0
                        .endif
                    .endif
                    inc scanVk
                    jmp UTN_Scan
UTN_ScanDone:
                .endif
            .endif
            ; ---- 会话 23：改名中支持鼠标收尾（原先只能键盘 Enter/Esc，
            ;      纯鼠标用户点名字进改名后被困在编辑态） ----
            .if lbE != 0
                invoke NumSelHitTest
                test eax, eax
                js NE_EdNeg
                mov editSlot, -1             ; 点键位行：提交改名并进入改键等待
                mov rebindSlot, eax
                mov rebindCool, 3
                jmp UT_Done
NE_EdNeg:
                .if eax == -1
                    mov editSlot, -1         ; 点空白 = 提交改名
                    jmp UT_Done
                .elseif eax == -2
                    mov editSlot, -1         ; 点重置 = 提交改名并重置键位
                    invoke InitKeyDefaults
                    jmp UT_Done
                .else
                    neg eax                  ; 点其他容器标题 = 切换编辑目标
                    sub eax, 3
                    mov editSlot, eax
                .endif
            .endif
            jmp UT_Done              ; 编辑改名中：屏蔽本页其他操作
        .endif
        ; 人数变少时改键目标可能指向已隐藏的容器 -> 清理
        mov eax, numSel
        imul eax, eax, KEY_PER
        .if rebindSlot >= eax
            mov rebindSlot, -1
        .endif
        .if rebindSlot != -1
            ; ---- 改键等待：目标键位闪烁，再点一个键位行=互换完成（会话 29
            ;      全鼠标流程）；按任意裸键亦可（占用则互换，会话 26），Esc 取消 ----
            inc blinkTick
            .if esE != 0
                mov rebindSlot, -1
            .else
                ; 改键扫描：0x8000 电平（0x1 边沿位在焦点切换时不可靠），
                ; 范围 0x08..0x5A / 0x60..0x80 / 0xA0..0xA5 —— 会话34 把旧上界
                ; 0x87 收到 0x80：0x85 起中文输入法常报"按下"（VK_PROCESSKEY
                ; 幻影），点击行后冷却 3 tick 的首次扫描就误绑 0x85 并静默
                ; 退出等待态——"先闪烁再点第二行互换"因此永远等不到，用户只能
                ; 按住新键+鼠标抢在幻影前捕获才改成功。0x81..0x9F 为未分配/
                ; IME 区整体排除；Esc=取消专用；进入等待后 3 tick 冷却
                ; （rebindCool）防点击残键误捕获
                .if rebindCool > 0
                    dec rebindCool
                    jmp UT_Scan2Done
                .endif
                mov scanVk, 08h
UT_Scan2:
                mov eax, scanVk
                .if eax > 0A5h
                    jmp UT_Scan2Done
                .endif
                .if eax == 1Bh                 ; Esc = 取消专用，不捕获
                    jmp UT_Scan2Next
                .endif
                .if eax > 5Ah && eax < 60h     ; Win 键区跳过
                    jmp UT_Scan2Next
                .endif
                .if eax >= 80h && eax < 0A0h   ; 未分配/IME 区跳过（会话34：0x85 幻影键）
                    jmp UT_Scan2Next
                .endif
                invoke GetAsyncKeyState, eax
                and eax, 8000h
                .if eax != 0
                    ; 会话 26：目标键若已被别的槽位占用 -> 本槽旧键与占用槽
                    ; 互换（旧版"冲突拒绝"把隐藏玩家 3/4 的默认键也算冲突，
                    ; 点了行再按键毫无反应——"无法修改按键"元凶）
                    mov edx, scanVk
                    xor ebx, ebx
UT_Conf:
                    .if ebx >= MAX_PLAYERS*KEY_PER
                        jmp UT_Grab
                    .endif
                    .if ebx != rebindSlot
                        mov eax, keyTable[ebx*4]
                        .if eax == edx
                            mov eax, rebindSlot
                            mov ecx, keyTable[eax*4]
                            mov keyTable[ebx*4], ecx
                            mov keyTable[eax*4], edx
                            mov rebindSlot, -1
                            jmp UT_Scan2Done
                        .endif
                    .endif
                    inc ebx
                    jmp UT_Conf
UT_Grab:
                    mov eax, rebindSlot
                    mov keyTable[eax*4], edx
                    mov rebindSlot, -1
                    jmp UT_Scan2Done
                .endif
UT_Scan2Next:
                inc scanVk
                jmp UT_Scan2
UT_Scan2Done:
            .endif
            ; 会话 29 全鼠标改键：等待中**再点另一个键位行 = 两槽互换
            ; 键位**（即"闪烁后点击新键位完成更改"）；点同行 = 取消闪烁；
            ; 键盘扫描仍保留，供绑到页面上没有的任意裸键
            .if lbE != 0
                invoke NumSelHitTest
                test eax, eax
                js UTW_Next                ; 负值（重置/标题）不走互换
                .if eax == rebindSlot
                    mov rebindSlot, -1     ; 再点同一行 = 取消
                .else
                    mov ecx, eax           ; ecx=被点行 B
                    mov eax, rebindSlot    ; eax=闪烁行 A
                    mov edx, keyTable[eax*4]
                    mov ebx, keyTable[ecx*4]
                    mov keyTable[eax*4], ebx   ; A 得到 B 的键
                    mov keyTable[ecx*4], edx   ; B 得到 A 的旧键（互换）
                    mov rebindSlot, -1
                .endif
UTW_Next:
                .if eax == -2
                    invoke InitKeyDefaults
                    mov rebindSlot, -1
                .elseif eax == -1
                    ; 会话34：闪烁中点空白改为忽略（旧"点空白=取消"在行带
                    ; 边缘极易误触，用户以为"点了没反应"；取消走 Esc/再点同行）
                .endif
            .endif
        .else
            ; ---- 常规键盘操作（保留） ----
            .if rtE != 0
                inc numSel
                .if numSel > 4
                    mov numSel, 2
                .endif
                invoke UiApplyBots           ; 会话39：人数变了，钳制并刷新补位
            .endif
            .if ltE != 0
                dec numSel
                .if numSel < 2
                    mov numSel, 4
                .endif
                invoke UiApplyBots
            .endif
            .if enE != 0
                mov eax, numSel
                mov numPlayers, eax
                mov eax, roundsSel
                mov maxRounds, eax
                invoke UiApplyBots           ; 会话39：人机补位随 numBot 落地/清零
                invoke GameInit
                mov netMode, 0
                mov gameState, ST_PLAY
            .endif
            .if esE != 0
                mov gameState, ST_MENU
            .endif
            ; ---- 鼠标：键位容器改键 / 重置 / << >> 调人数与局数 / 数字区开始 ----
            .if lbE != 0
                invoke NumSelHitTest
                test eax, eax
                js NHT_NegRet              ; 负值：重置/改名（勿写 >= 0：恒真）
                mov rebindSlot, eax        ; 点击键位 -> 闪烁等待新键
                mov rebindCool, 3          ; 冷却防点击残键误捕
                jmp NHT_Done
NHT_NegRet:
                .if eax == -2
                    invoke InitKeyDefaults ; 重置所有更改按键
                    mov rebindSlot, -1
                .elseif eax == -1
                    jmp NHT_Done2          ; 无命中 -> 落到 << >> / 开始区域
                .else
                    neg eax                ; -3-slot -> slot
                    sub eax, 3
                    mov editSlot, eax      ; 点击容器标题 -> 改名
                .endif
                jmp NHT_Done
NHT_Done2:
                ; PLAYERS << 400..460, y190..242
                mov eax, mouseX
                .if eax >= 400 && eax < 460 && mouseY >= 190 && mouseY < 242
                    dec numSel
                    .if numSel < 2
                        mov numSel, 4
                    .endif
                    invoke UiApplyBots       ; 会话39：人数变了，钳制并刷新补位
                ; PLAYERS >> 535..600, y190..242
                .elseif eax >= 535 && eax < 600 && mouseY >= 190 && mouseY < 242
                    inc numSel
                    .if numSel > 4
                        mov numSel, 2
                    .endif
                    invoke UiApplyBots
                ; ROUNDS << 400..460, y252..304
                .elseif eax >= 400 && eax < 460 && mouseY >= 252 && mouseY < 304
                    sub roundsSel, 2
                    .if roundsSel < ROUNDS_MIN
                        mov roundsSel, ROUNDS_MAX
                    .endif
                ; ROUNDS >> 535..600, y252..304
                .elseif eax >= 535 && eax < 600 && mouseY >= 252 && mouseY < 304
                    add roundsSel, 2
                    .if roundsSel > ROUNDS_MAX
                        mov roundsSel, ROUNDS_MIN
                    .endif
                ; 人数数字区 465..530, y180..242 -> 确认开始
                .elseif eax >= 465 && eax < 530 && mouseY >= 180 && mouseY < 242
                    mov eax, numSel
                    mov numPlayers, eax
                    mov eax, roundsSel
                    mov maxRounds, eax
                    invoke UiApplyBots       ; 会话39：人机补位随 numBot 落地/清零
                    invoke GameInit
                    mov netMode, 0
                    mov gameState, ST_PLAY
                ; BOTS << 700..760, y252..304（会话39：人机补位减量）
                .elseif eax >= 700 && eax < 760 && mouseY >= 252 && mouseY < 304
                    .if numBot > 0
                        dec numBot
                    .endif
                    invoke UiApplyBots
                ; BOTS >> 850..910, y252..304（会话39：增量，上限 numSel-1 留至少1真人）
                .elseif eax >= 850 && eax < 910 && mouseY >= 252 && mouseY < 304
                    mov ecx, numSel
                    dec ecx
                    .if numBot < ecx
                        inc numBot
                    .endif
                    invoke UiApplyBots
                .endif
NHT_Done:
            .endif
        .endif

    ; ---------- 按键设置 ----------
    .elseif gameState == ST_SET
        ; ---- 音量（←→）/ 音效 / 深夜模式 快捷设置 ----
        .if ltE != 0
            sub volumeLvl, 5
            cmp volumeLvl, 0
            jge SS_Vl1
            mov volumeLvl, 0
SS_Vl1:
            invoke SndVolume, volumeLvl
        .endif
        .if rtE != 0
            add volumeLvl, 5
            .if volumeLvl > 100
                mov volumeLvl, 100
            .endif
            invoke SndVolume, volumeLvl
        .endif
        ; 会话 23 修复：旧版外层守卫带着音量条专属的 y186..222，
        ; 导致 sfx/深夜/<<>>/返回 全部点击区永远打不通；
        ; 改为 lbE 判一次，各区域自带 y 带。
        .if lbE != 0
            mov eax, mouseX
            .if eax >= 412 && eax <= 612 && mouseY >= 186 && mouseY < 222
                sub eax, 412
                mov ecx, 200
                .if eax > 200
                    mov eax, 200
                .endif
                imul eax, eax, 100
                xor edx, edx
                div ecx
                mov volumeLvl, eax
                invoke SndVolume, eax
            .endif
            mov eax, mouseX
            .if eax >= 330 && eax < 400 && mouseY >= 186 && mouseY < 222
                sub volumeLvl, 10
                cmp volumeLvl, 0
                jge SS_Vl2
                mov volumeLvl, 0
SS_Vl2:
                invoke SndVolume, volumeLvl
            .endif
            mov eax, mouseY
            .if eax >= 288 && eax < 324
                mov eax, mouseX
                .if eax >= 480 && eax < 604
                    xor sfxOn, 1
                .endif
            .elseif eax >= 388 && eax < 424
                mov eax, mouseX
                .if eax >= 480 && eax < 604
                    xor themeNight, 1
                .endif
            .endif
            ; 会话 23 补：>> 音量按钮（<< 已有，>> 此前漏接）
            mov eax, mouseX
            .if eax >= 616 && eax < 680 && mouseY >= 186 && mouseY < 222
                add volumeLvl, 10
                .if volumeLvl > 100
                    mov volumeLvl, 100
                .endif
                invoke SndVolume, volumeLvl
            .endif
            ; 会话 23 补：返回按钮（与 Esc 等价）
            mov eax, mouseX
            .if eax >= 440 && eax < 560 && mouseY >= 462 && mouseY < 498
                mov gameState, ST_MENU
                jmp UT_Done
            .endif
        .endif
        .if esE != 0
            mov gameState, ST_MENU
        .endif
        ; （会话 23 删除：本页不渲染键位行，旧 setSel↑↓/Enter 隐形改键块
        ;   会在设置页误吞按键、悄悄改写 keyTable —— "键位页面有问题"元凶）

    ; ---------- 联机大厅（会话36：net.asm FSM 全面接线） ----------
    .elseif gameState == ST_LAN
        invoke NetLobbyTick
        invoke NetLobbyState
        mov lanSt, eax
        .if peerKnown != 0
            invoke IpToStr, addr peerAddr.sin_addr, offset peerIpBuf
            mov peerIpLen, eax
        .endif
        ; netloop：每 tick 自动按下开始（双方对称即自动双 Enter 开局）
        .if lanAuto != 0
            invoke NetSetStart
        .endif
        ; 我按开始（Enter 或点开始按钮 400..600 y410..450）；编辑聚焦时屏蔽
        .if ipEditMode == 0
            .if enE != 0
                invoke NetSetStart
            .endif
            .if lbE != 0 && mouseX >= 400 && mouseX < 600
                .if mouseY >= 410 && mouseY < 450
                    invoke NetSetStart
                .endif
            .endif
        .endif
        ; 双 Enter + 握手齐 -> NetEnterMatch（同种子同图同出生点）
        invoke NetCanStart
        .if eax != 0
            invoke NetEnterMatch
            mov lanAuto, 0
            mov ipEditMode, 0
            mov gameState, ST_PLAY
        .endif
        ; Tab 切换手输编辑焦点
        .if tabE != 0
            xor ipEditMode, 1
            mov manualErr, 0
        .endif
        ; 点击手输行（x350..650 y316..346）聚焦编辑
        .if lbE != 0 && mouseX >= 350 && mouseX < 650
            .if mouseY >= 316 && mouseY < 346
                mov ipEditMode, 1
            .endif
        .endif
        ; 返回按钮（400..600 y460..500）
        .if lbE != 0 && mouseX >= 400 && mouseX < 600
            .if mouseY >= 460 && mouseY < 500
                invoke NetEnterLan
                mov gameState, ST_MENU
            .endif
        .endif
        ; Esc：编辑中先退编辑；否则清握手状态回主菜单
        .if esE != 0
            .if ipEditMode != 0
                mov ipEditMode, 0
            .else
                invoke NetEnterLan
                mov gameState, ST_MENU
            .endif
        .endif

    ; ---------- 技能说明页：左右翻页 ----------
    .elseif gameState == ST_SKILL
        .if ltE != 0
            .if skillPage > 0
                dec skillPage
            .endif
        .endif
        .if rtE != 0
            mov eax, skillPage
            .if eax < SKILL_COUNT-1
                inc skillPage
            .endif
        .endif
        .if esE != 0
            mov gameState, ST_MENU
        .endif
        .if lbE != 0
            ; 左箭头 130..210, 260..340 / 右箭头 778..858 / 返回 440..560, 516..552
            mov eax, mouseY
            .if eax >= 516 && eax < 552
                mov eax, mouseX
                .if eax >= 440 && eax < 560
                    mov gameState, ST_MENU
                .endif
            .elseif eax >= 260 && eax < 340
                mov eax, mouseX
                .if eax >= 130 && eax < 210
                    .if skillPage > 0
                        dec skillPage
                    .endif
                .elseif eax >= 778 && eax < 858
                    mov eax, skillPage
                    .if eax < SKILL_COUNT-1
                        inc skillPage
                    .endif
                .endif
            .endif
        .endif
    ; ---------- 玩法演示页：6 段动画翻页 ----------
    .elseif gameState == ST_DEMO
        inc demoT
        .if ltE != 0
            .if demoPage > 0
                dec demoPage
            .endif
        .endif
        .if rtE != 0
            mov eax, demoPage
            .if eax < 5
                inc demoPage
            .endif
        .endif
        .if esE != 0
            mov gameState, ST_MENU
        .endif
        .if lbE != 0
            ; 会话 23：←→ 翻页之外补鼠标（左右箭头同技能页 + 返回按钮）
            mov eax, mouseY
            .if eax >= 516 && eax < 552
                mov eax, mouseX
                .if eax >= 440 && eax < 560
                    mov gameState, ST_MENU
                .endif
            .elseif eax >= 260 && eax < 340
                mov eax, mouseX
                .if eax >= 130 && eax < 210 && demoPage > 0
                    dec demoPage
                .elseif eax >= 778 && eax < 858 && demoPage < 5
                    inc demoPage
                .endif
            .endif
        .endif
    ; ---------- 会话40：成就图鉴页（←→/箭头钮翻页，Esc/返回钮退页） ----------
    .elseif gameState == ST_ACHG
        .if ltE != 0
            .if galPage > 0
                dec galPage
            .endif
        .endif
        .if rtE != 0
            mov eax, galPage
            .if eax < ACH_PAGES-1
                inc galPage
            .endif
        .endif
        .if esE != 0
            mov gameState, ST_MENU
        .endif
        invoke KeyEdge, VK_1, addr prevK1      ; 会话41：数字键直接跳页（24 条恰 4 整页）
        .if eax != 0
            mov galPage, 0
        .endif
        invoke KeyEdge, VK_2, addr prevK2
        .if eax != 0
            mov galPage, 1
        .endif
        invoke KeyEdge, VK_3, addr prevK3
        .if eax != 0
            mov galPage, 2
        .endif
        invoke KeyEdge, VK_4, addr prevK4
        .if eax != 0
            mov galPage, 3
        .endif
        invoke KeyEdge, VK_HOME, addr prevKHome
        .if eax != 0
            mov galPage, 0
        .endif
        invoke KeyEdge, VK_END, addr prevKEnd
        .if eax != 0
            mov galPage, ACH_PAGES-1
        .endif
        .if lbE != 0
            ; 几何与技能页一致：返回 440..560,516..552 / 箭头 130..210,778..858,260..340
            mov eax, mouseY
            .if eax >= 516 && eax < 552
                mov eax, mouseX
                .if eax >= 440 && eax < 560
                    mov gameState, ST_MENU
                .endif
            .elseif eax >= 260 && eax < 340
                mov eax, mouseX
                .if eax >= 86 && eax < 130
                    .if galPage > 0
                        dec galPage
                    .endif
                .elseif eax >= 858 && eax < 902
                    mov eax, galPage
                    .if eax < ACH_PAGES-1
                        inc galPage
                    .endif
                .endif
            .endif
        .endif
    .endif
UT_Done:
    ret
UiTick endp

; ------------------------------------------------------------
; UiRender -- 按状态绘制；对局中委托 GfxRender
; ------------------------------------------------------------
UiRender proc uses ebx esi edi
    local rc:RECT
    local boxRc:RECT
    local rowY:dword
    local txtLen:dword
    local klen:dword
    local rowCol:dword
    local slotIdx:dword
    local demoPh:dword
    local demoPt:dword
    local demoP1x:dword
    local demoP1y:dword
    local demoDir:dword
    local achIdx:dword, achDefP:dword, achOwnF:dword, achProgV:dword, achGoalV:dword
    local achRarV:dword, achCol:dword, achNmCol:dword, achY2:dword, achYt:dword
    local achOwnN:dword
    local achEnP:dword, achCnP:dword, achDsEnP:dword, achDsCnP:dword
    local achRarEnP:dword, achRarCnP:dword
    local achDtV:dword, achDtY:dword, achDtM:dword, achDtD:dword
    local achBr:dword, achDy:dword, achShow:dword, achBx:dword, achBi:dword
    local achTx:dword, achIcoY:dword, achIcoCol:dword, achChip:dword, achBrush:dword
    local achDx:dword                 ; 会话46：图鉴行首英文偏移（COMMON 比中文宽，挡 chip）

    mov rc.left, 0
    mov rc.top, 0
    mov rc.right, WND_W
    mov rc.bottom, WND_H
    ; 深夜模式：背景近黑 + 文字浅色重映射
    mov eax, themeNight
    .if eax != 0
        invoke FillRect, hdcBack, addr rc, brushNight
        mov colDark, 00D0D0D0h
        mov colGray, 00808080h
        mov colHi,   0000E0E0h
        mov eax, boxBrushN
        mov boxCur, eax
    .else
        invoke FillRect, hdcBack, addr rc, menuBrush
        mov colDark, 00232323h
        mov colGray, 00606060h
        mov colHi,   0000C06000h
        mov eax, boxBrush
        mov boxCur, eax
    .endif
    invoke SelectObject, hdcBack, menuFont
    mov fontOld, eax

    .if gameState == ST_PLAY
        invoke GfxRender
        ; 会话36：掉线横幅（netPaused 冻结期间玩法不动，收包继续）
        mov eax, netMode
        .if eax != 0
            mov ecx, netLost
            .if ecx != 0
                mov boxRc.left, 240
                mov boxRc.top, 258
                mov boxRc.right, 752
                mov boxRc.bottom, 334
                invoke FrameRect, hdcBack, addr boxRc, boxCur
                invoke UiTextL, hdcBack, 264, 268, offset szLostEN, offset CN_LOST, colErr
            .endif
            ; 会话39：B 档禁用技（换位/虚影）按压提示条，掉线横幅正下方，2s 自隐
            mov ecx, onlineBanT
            .if ecx != 0
                dec onlineBanT
                mov boxRc.left, 240
                mov boxRc.top, 344
                mov boxRc.right, 752
                mov boxRc.bottom, 400
                invoke FrameRect, hdcBack, addr boxRc, boxCur
                invoke UiTextL, hdcBack, 264, 354, offset szBanEN, offset CN_NETBAN, colErr
            .endif
        .endif
        jmp UR_Toast   ; 会话40：对局画面也要过弹层
    .endif

    ; ---------- 主菜单 ----------
    .if gameState == ST_MENU
        ; 会话 28：主页暂不放任何大图/装饰（会话 27 黄色大坦克被嫌丑，
        ; 先下架留纯净底；渲染资源与坐标表已一并移除）
        invoke UiTextZ, hdcBack, 385, 90, offset szTitle, colDark
        mov ebx, 0
UM_Items:
        .if ebx == menuSel
            mov edx, colHi
        .else
            mov edx, colGray
        .endif
        mov eax, ebx
        imul eax, eax, 46
        add eax, 190
        mov rowY, eax
        push ebx
        mov eax, ebx
        .if eax == 0
            invoke UiTextL, hdcBack, 436, rowY, offset szItem1, offset CN_START, edx
        .elseif eax == 1
            invoke UiTextL, hdcBack, 436, rowY, offset szDemT, offset CN_DEMOMENU, edx
        .elseif eax == 2
            invoke UiTextL, hdcBack, 436, rowY, offset szItemSk, offset CN_SKILLMENU, edx
        .elseif eax == 3
            invoke UiTextL, hdcBack, 436, rowY, offset szItem2, offset CN_SET, edx
        .elseif eax == 4
            invoke UiTextL, hdcBack, 440, rowY, offset szItem3, offset CN_LAN, edx
        .elseif eax == 5
            mov ecx, offset szItemAch
            mov eax, offset CN_ACHGALT
            .if achvUnseen != 0      ; 会话41：本次运行有新解锁未读 -> "(新)"变体
                mov ecx, offset szItemAchNew
                mov eax, offset CN_ACHGALTW
            .endif
            invoke UiTextL, hdcBack, 436, rowY, ecx, eax, edx
        .elseif eax == 6
            invoke UiTextL, hdcBack, 436, rowY, offset szItem4, offset CN_EXIT, edx
        .else
            invoke UiTextL, hdcBack, 436, rowY, offset szLangEN, offset CN_LANG, edx
        .endif
        pop ebx
        inc ebx
        .if ebx < 8                  ; 会话42：删人机项后 8 项
            jmp UM_Items
        .endif

    ; ---------- 人数选择 ----------
    .elseif gameState == ST_NUMSEL
        invoke UiTextL, hdcBack, 420, 150, offset szNumT, offset CN_NUMT, colDark
        ; PLAYERS 行（y 190..242）
        invoke UiTextZ, hdcBack, 410, 200, offset szNumL, colDark
        invoke UiTextZ, hdcBack, 545, 200, offset szNumR, colDark
        lea edi, uiBuf
        mov eax, numSel
        add eax, '0'
        mov [edi], al
        mov byte ptr [edi+1], 0
        invoke UiTextZ, hdcBack, 485, 192, offset uiBuf, 000000D0h
        ; ROUNDS 行（y 252..304）
        ; 会话46：英文 "ROUNDS"（30px 字体 6 字符 ≈83px）从 322 画会压上 410 的 «，
        ; 改按语言取起点（中文 局数 不动）；<< 与点击热区(400..460)保持原位。
        mov eax, 322
        .if langFlag == 0
            mov eax, 296
        .endif
        invoke UiTextL, hdcBack, eax, 262, offset szRounds, offset CN_ROUNDS, colDark
        invoke UiTextZ, hdcBack, 410, 262, offset szNumL, colDark
        invoke UiTextZ, hdcBack, 545, 262, offset szNumR, colDark
        lea edi, uiBuf
        mov eax, roundsSel
        xor edx, edx
        mov ecx, 10
        div ecx                          ; eax=十位 edx=个位
        add eax, '0'
        add edx, '0'
        mov [edi], al
        mov [edi+1], dl
        mov byte ptr [edi+2], 0
        invoke UiTextZ, hdcBack, 480, 254, offset uiBuf, 000000D0h
        ; BOTS 行（会话39：黑色人机补位数；与 ROUNDS 同带右半，<< 700..760 / >> 850..910）
        invoke UiTextL, hdcBack, 620, 262, offset szBots, offset CN_BOTS, colDark
        invoke UiTextZ, hdcBack, 710, 262, offset szNumL, colDark
        invoke UiTextZ, hdcBack, 855, 262, offset szNumR, colDark
        lea edi, uiBuf
        mov eax, numBot
        add eax, '0'
        mov [edi], al
        mov byte ptr [edi+1], 0
        invoke UiTextZ, hdcBack, 790, 254, offset uiBuf, 000000D0h

        ; ---- 键位容器（小字体）：按当前选择的人数显示 2..4 个 ----
        invoke SelectObject, hdcBack, fontSmall
        invoke UiTextL, hdcBack, 30, 306, offset szKeysLbl, offset CN_KEYS, colGray
        xor ebx, ebx
NS_Box:
        .if ebx >= numSel
            jmp NS_BoxDone
        .endif
        ; 容器边框
        mov eax, ebx
        imul eax, eax, KBBOX_DX
        add eax, KBBOX_X0
        mov boxRc.left, eax
        add eax, KBBOX_W
        mov boxRc.right, eax
        mov eax, KBBOX_Y
        mov boxRc.top, eax
        add eax, KBBOX_H
        mov boxRc.bottom, eax
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        ; 容器标题：玩家名（可点击改名；编辑中光标 '_' 闪烁）
        mov eax, ebx
        imul eax, eax, 16
        add eax, offset playerName
        lea edi, uiBuf
        xor ecx, ecx
NT_Copy:
        mov dl, [eax+ecx]
        .if dl == 0
            jmp NT_Copied
        .endif
        mov [edi+ecx], dl
        inc ecx
        .if ecx < 14
            jmp NT_Copy
        .endif
NT_Copied:
        .if ebx == editSlot
            mov eax, blinkTick
            shr eax, 3
            and eax, 1
            .if eax != 0
                mov byte ptr [edi+ecx], '_'
                inc ecx
            .endif
        .endif
        mov byte ptr [edi+ecx], 0
        invoke UiTextZ, hdcBack, boxRc.left, KBBOX_Y+8, offset uiBuf, colDark
        ; 每人 6 键（KEY_PER）：0前进 1后退 2左转 3右转 4开火 5技能（会话 23 修正旧注"5 行"）
        mov rowY, KBBOX_Y + KBROW_Y0
        xor esi, esi                     ; 动作 0..5
NS_Row:
        .if esi >= KEY_PER
            inc ebx
            jmp NS_Box
        .endif
        mov eax, ebx
        imul eax, eax, KEY_PER
        add eax, esi
        mov slotIdx, eax
        ; 颜色：改键中的槽位闪烁；悬停高亮；其余灰
        mov eax, slotIdx
        .if eax == rebindSlot
            mov eax, blinkTick
            shr eax, 3
            and eax, 1
            .if eax != 0
                mov eax, colHi
                mov rowCol, eax
            .else
                mov eax, colDark
                mov rowCol, eax
            .endif
        .else
            mov eax, boxRc.left
            add eax, 8
            mov ecx, boxRc.right
            sub ecx, 8
            mov edi, rowY
            mov edx, edi
            add edx, KBROW_DH - 4
            .if mouseX >= eax && mouseX < ecx && mouseY >= edi && mouseY < edx
                mov eax, colHi
                mov rowCol, eax
            .else
                mov eax, colGray
                mov rowCol, eax
            .endif
        .endif
        ; 动作名（语言感知）
        mov eax, esi
        mov edx, aTab[eax*4]             ; 英文动作名指针
        mov eax, esi
        mov ecx, cnActT[eax*4]           ; 中文动作名指针
        invoke UiTextL, hdcBack, boxRc.left, rowY, edx, ecx, rowCol
        ; 键名（VkName -> uiBuf）
        mov eax, slotIdx
        mov eax, keyTable[eax*4]
        invoke VkName, eax, offset uiBuf
        mov byte ptr uiBuf[eax], 0
        mov eax, boxRc.left
        add eax, 120
        invoke UiTextZ, hdcBack, eax, rowY, offset uiBuf, rowCol
        add rowY, KBROW_DH
        inc esi
        jmp NS_Row
NS_BoxDone:
        ; ---- 重置按钮（容器区右下角）----
        mov eax, mouseX
        .if eax >= RST_X && eax < RST_X+RST_W && mouseY >= RST_Y && mouseY < RST_Y+RST_H
            mov edx, colHi
        .else
            mov edx, colDark
        .endif
        mov boxRc.left, RST_X-10
        mov boxRc.top, RST_Y-4
        mov boxRc.right, RST_X+RST_W+8
        mov boxRc.bottom, RST_Y+RST_H+4
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke UiTextL, hdcBack, RST_X, RST_Y, offset szReset, offset CN_RESET, edx
        ; ---- 底部提示：改键等待时显示引导，否则显示操作提示 ----
        .if rebindSlot != -1
            invoke UiTextL, hdcBack, 360, 600, offset szReb2, offset CN_REB2, colHi
        .elseif editSlot != -1
            invoke UiTextL, hdcBack, 350, 600, offset szNameEdit, offset CN_NAMEEDIT, colHi
        .else
            invoke UiTextL, hdcBack, 330, 600, offset szHint, offset CN_HINT, colGray
            invoke UiTextL, hdcBack, 620, 600, offset szNameHint, offset CN_NAMEHINT, colGray
        .endif
        invoke SelectObject, hdcBack, menuFont

    ; ---------- 按键设置 ----------
    .elseif gameState == ST_SET
        invoke UiTextL, hdcBack, 420, 36, offset szSetT, offset CN_SETT, colDark
        ; ---- 快捷设置行（小字体，y 96）：音量 / 音效 / 深夜模式 ----
        invoke SelectObject, hdcBack, fontSmall
        ; 音量行（y 196）：标签 + << 按钮 + 进度条 + >> 按钮 + 数值
        invoke UiTextL, hdcBack, 250, 196, offset szVol2, offset CN_VOL2, colDark
        invoke UiTextZ, hdcBack, 356, 190, offset szNumL, colDark
        mov boxRc.left, 410
        mov boxRc.top, 191
        mov boxRc.right, 614
        mov boxRc.bottom, 217
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        mov eax, volumeLvl
        .if eax > 0
            imul eax, eax, 2
            add eax, 412
            mov boxRc.left, 412
            mov boxRc.top, 194
            mov boxRc.right, eax
            mov boxRc.bottom, 214
            mov edx, boxBrush
            mov eax, themeNight
            .if eax != 0
                mov edx, boxBrushN
            .endif
            invoke FillRect, hdcBack, addr boxRc, edx
        .endif
        invoke UiTextZ, hdcBack, 626, 190, offset szNumR, colDark
        lea edi, uiBuf
        mov eax, volumeLvl
        xor edx, edx
        mov ecx, 10
        div ecx
        add al, '0'
        add dl, '0'
        mov [edi], al
        mov [edi+1], dl
        mov byte ptr [edi+2], '%'
        mov byte ptr [edi+3], 0
        invoke UiTextZ, hdcBack, 668, 196, offset uiBuf, colDark
        ; 音效开关行（y 300）
        invoke UiTextL, hdcBack, 250, 296, offset szSfx2, offset CN_SFX, colDark
        mov boxRc.left, 480
        mov boxRc.top, 288
        mov boxRc.right, 604
        mov boxRc.bottom, 324
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        mov eax, sfxOn
        .if eax != 0
            invoke UiTextL, hdcBack, 516, 296, offset szOn2, offset CN_ON2, colDark
        .else
            invoke UiTextL, hdcBack, 516, 296, offset szOff2, offset CN_OFF2, colDark
        .endif
        ; 深夜模式行（y 400）
        invoke UiTextL, hdcBack, 250, 396, offset szNight, offset CN_NIGHT, colDark
        mov boxRc.left, 480
        mov boxRc.top, 388
        mov boxRc.right, 604
        mov boxRc.bottom, 424
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        mov eax, themeNight
        .if eax != 0
            invoke UiTextL, hdcBack, 494, 396, offset szOn2, offset CN_ON2, colDark
        .else
            invoke UiTextL, hdcBack, 494, 396, offset szOff2, offset CN_OFF2, colDark
        .endif
        ; 会话 23：返回按钮（点击 = Esc 等价），绘制在点击区 440..560, 462..498
        mov boxRc.left, 440
        mov boxRc.top, 462
        mov boxRc.right, 560
        mov boxRc.bottom, 498
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke UiTextL, hdcBack, 474, 470, offset szBackBtn, offset CN_BACKBTN, colDark
        invoke UiTextL, hdcBack, 360, 560, offset szSetHint, offset CN_SETHINT, colGray
        invoke SelectObject, hdcBack, menuFont

    ; ---------- 联机大厅（会话36：四态 + 端口 + 手输编辑行） ----------
    .elseif gameState == ST_LAN
        invoke UiTextL, hdcBack, 440, 130, offset szLanT, offset CN_LANT, colDark
        ; 本机监听端口行（B1 退避时展示临时端口，供跨网手输分享）
        invoke UiTextL, hdcBack, 350, 196, offset szPort, offset CN_PORT, colGray
        mov eax, ownPort
        invoke NumStr, eax, offset uiBuf
        invoke UiTextZ, hdcBack, 512, 196, offset uiBuf, colDark
        .if isFixedPort == 0
            invoke SelectObject, hdcBack, fontSmall
            invoke UiTextL, hdcBack, 596, 202, offset szTempEN, offset CN_TEMP, colErr
            invoke SelectObject, hdcBack, menuFont
        .endif
        ; 对端发现状态（会话37 M3.5：中继模式此行改显房间号+配对状态）
        mov eax, lanSt
        and eax, 1
        .if relayMode != 0
            invoke UiTextL, hdcBack, 350, 240, offset szRelay, offset CN_RELAY, colGray
            mov eax, relayRoom
            invoke NumStr, eax, offset uiBuf
            invoke UiTextZ, hdcBack, 440, 240, offset uiBuf, colDark
            ; 状态词（小字 y264）：已配对绿 / 等待灰 / 房间已满红（relaySt 2=FULL 1=PAIR）
            ; 注意：SelectObject 毁 EAX/ECX/EDX（volatile），必须先换字体再暂存参数
            invoke SelectObject, hdcBack, fontSmall
            mov eax, peerKnown
            .if eax != 0
                mov eax, offset szRelayPair
                mov edx, offset CN_RELAYP
                mov ecx, colFound
            .else
                mov eax, relaySt
                .if eax == 2
                    mov eax, offset szRelayFull
                    mov edx, offset CN_RELAYF
                    mov ecx, colErr
                .elseif eax == 1
                    mov eax, offset szRelayPair
                    mov edx, offset CN_RELAYP
                    mov ecx, colFound
                .else
                    mov eax, offset szRelayWait
                    mov edx, offset CN_RELAYW
                    mov ecx, colGray
                .endif
            .endif
            invoke UiTextL, hdcBack, 350, 264, eax, edx, ecx
            invoke SelectObject, hdcBack, menuFont
            ; 会话51 STUN步A：收到服务器 'S' 反射后显示对端公网观测点（小字 y282）。
            ; 手输该行地址可试直连（步B 自动升级前的可见化能力）。
            .if stunSeen != 0
                call UiStunStr
                invoke SelectObject, hdcBack, fontSmall
                invoke UiTextZ, hdcBack, 350, 282, offset stunBuf, colGray
                invoke SelectObject, hdcBack, menuFont
            .endif
        .elseif eax != 0
            invoke UiTextL, hdcBack, 350, 240, offset szLanF, offset CN_LANF, colFound
            invoke UiTextZ, hdcBack, 530, 240, offset peerIpBuf, colFound
        .elseif directOn != 0
            invoke UiTextL, hdcBack, 350, 240, offset szDirect, offset CN_DIRECT, colGray
            invoke UiTextZ, hdcBack, 500, 240, offset ipBuf, colGray
        .else
            invoke UiTextL, hdcBack, 350, 240, offset szLanN, offset CN_LANN, colGray
        .endif
        ; RTT 延迟读数（会话37：NET_PING 有回包时右对齐小字）
        .if netRttOk != 0
            invoke SelectObject, hdcBack, fontSmall
            mov byte ptr uiBuf[0], 'R'
            mov byte ptr uiBuf[1], 'T'
            mov byte ptr uiBuf[2], 'T'
            mov byte ptr uiBuf[3], ' '
            invoke NumStr, netRttAvg, offset uiBuf+4
            mov ecx, eax
            mov byte ptr uiBuf[ecx+4], ' '
            mov byte ptr uiBuf[ecx+5], 'm'
            mov byte ptr uiBuf[ecx+6], 's'
            mov byte ptr uiBuf[ecx+7], 0
            invoke UiTextZ, hdcBack, 800, 242, offset uiBuf, colGray
            invoke SelectObject, hdcBack, menuFont
        .endif
        ; 开始流程四态（HELLO 齐后：按 Enter / 等待对方 / 即将开始）
        mov eax, lanSt
        and eax, 2
        .if eax != 0
            mov eax, lanSt
            and eax, 0Ch
            .if eax == 0Ch
                invoke UiTextL, hdcBack, 350, 280, offset szLanR, offset CN_LANR, colHi
            .elseif eax == 4
                invoke UiTextL, hdcBack, 350, 280, offset szLanW, offset CN_LANW, colGray
            .else
                invoke UiTextL, hdcBack, 350, 280, offset szLanBoth, offset CN_LANBOTH, colDark
            .endif
        .endif
        ; 手输直连提示 + 编辑框（Tab 聚焦；仅放行 0-9 . : 退格回车）
        invoke SelectObject, hdcBack, fontSmall
        invoke UiTextL, hdcBack, 350, 300, offset szManual, offset CN_MANUAL, colGray
        invoke SelectObject, hdcBack, menuFont
        mov edx, colDark
        .if manualErr != 0
            mov edx, colErr
        .endif
        mov boxRc.left, 350
        mov boxRc.top, 316
        mov boxRc.right, 650
        mov boxRc.bottom, 346
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        .if manualErr != 0
            mov edx, colErr
        .else
            mov edx, colDark
        .endif
        invoke SelectObject, hdcBack, fontSmall
        mov ecx, ipLen
        .if ipEditMode != 0
            mov byte ptr ipBuf[ecx], '_'
            mov byte ptr ipBuf[ecx+1], 0
        .endif
        invoke UiTextZ, hdcBack, 358, 322, offset ipBuf, edx
        .if ipEditMode != 0
            mov byte ptr ipBuf[ecx], 0
        .endif
        invoke SelectObject, hdcBack, menuFont
        .if manualErr != 0
            invoke UiTextL, hdcBack, 660, 322, offset szBad, offset CN_BAD, colErr
        .endif
        ; 按钮组（开始 400..600 y410..450 / 返回 y460..500，与点击区一致）
        invoke SelectObject, hdcBack, fontSmall
        mov edx, colGray
        invoke NetCanStart
        .if eax != 0
            mov edx, colHi
        .else
            mov eax, lanSt
            and eax, 1
            .if eax != 0
                mov edx, colDark
            .endif
        .endif
        mov lanBtnCol, edx                 ; FrameRect 可能毁 edx，落存再取
        mov boxRc.left, 400
        mov boxRc.top, 410
        mov boxRc.right, 600
        mov boxRc.bottom, 450
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        mov edx, lanBtnCol
        invoke UiTextL, hdcBack, 446, 422, offset szStartBtn, offset CN_STARTBTN, edx
        mov boxRc.top, 460
        mov boxRc.bottom, 500
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke UiTextL, hdcBack, 474, 472, offset szBackBtn, offset CN_BACKBTN, colDark
        invoke SelectObject, hdcBack, menuFont

    ; ---------- 技能说明页 ----------
    .elseif gameState == ST_SKILL
        invoke UiTextL, hdcBack, 430, 60, offset szSkT, offset CN_SKT, colDark
        ; 外框容器
        mov boxRc.left, 130
        mov boxRc.top, 140
        mov boxRc.right, 858
        mov boxRc.bottom, 490
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        ; 左右箭头（边界置灰）
        invoke SelectObject, hdcBack, fontSmall
        mov edx, colDark
        .if skillPage == 0
            mov edx, colGray
        .endif
        invoke UiTextZ, hdcBack, 155, 285, offset szNumL, edx
        mov edx, colDark
        mov eax, skillPage
        .if eax >= SKILL_COUNT-1
            mov edx, colGray
        .endif
        invoke UiTextZ, hdcBack, 815, 285, offset szNumR, edx
        ; 图标：深色底 + 放大 3 倍特性图形（60x60 内 54px 图形）
        mov boxRc.left, 220
        mov boxRc.top, 240
        mov boxRc.right, 280
        mov boxRc.bottom, 300
        invoke FillRect, hdcBack, addr boxRc, brushPickBg
        invoke FrameRect, hdcBack, addr boxRc, brushMortar
        invoke SelectObject, hdcBack, penIcon
        mov penOld2, eax
        mov eax, skillPage
        inc eax
        invoke DrawPickupIcon, hdcBack, 223, 243, eax, 3
        invoke SelectObject, hdcBack, penOld2
        invoke SelectObject, hdcBack, menuFont
        ; 技能名（大字）+ 描述（小字，双语表查当前页）
        mov eax, skillPage
        mov edx, skNmEn[eax*4]
        mov eax, skillPage
        mov ecx, skNmCn[eax*4]
        invoke UiTextL, hdcBack, 320, 240, edx, ecx, colDark
        invoke SelectObject, hdcBack, fontSmall
        mov eax, skillPage
        mov edx, skDsEn[eax*4]
        mov eax, skillPage
        mov ecx, skDsCn[eax*4]
        invoke UiTextL, hdcBack, 230, 330, edx, ecx, colGray
        invoke SelectObject, hdcBack, menuFont
        ; 页码 "n / 9"
        lea edi, uiBuf
        mov eax, skillPage
        inc eax
        add al, '0'
        mov [edi], al
        mov byte ptr [edi+1], ' '
        mov byte ptr [edi+2], '/'
        mov byte ptr [edi+3], ' '
        mov byte ptr [edi+4], '0'+SKILL_COUNT
        mov byte ptr [edi+5], 0
        invoke UiTextZ, hdcBack, 470, 410, offset uiBuf, colDark
        ; 会话 23：返回按钮（点击区 440..560, 516..552）
        mov boxRc.left, 440
        mov boxRc.top, 516
        mov boxRc.right, 560
        mov boxRc.bottom, 552
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke UiTextL, hdcBack, 474, 524, offset szBackBtn, offset CN_BACKBTN, colDark
        ; 底部提示
        invoke UiTextL, hdcBack, 360, 560, offset szSetHint, offset CN_SETHINT, colGray

    ; ---------- 会话40：成就图鉴（6 行/页 × 4 页，随意翻阅） ----------
    .elseif gameState == ST_ACHG
        invoke AchvCountOwned
        mov achOwnN, eax
        mov edx, colDark
        .if eax == ACH_COUNT             ; 会话41：全收集 -> 金色标题
            mov edx, 0020D0FFh
        .endif
        invoke UiTextL, hdcBack, 430, 60, offset szAchT, offset CN_ACHGALT, edx
        invoke SelectObject, hdcBack, fontSmall
        ; 页眉：COLLECTED n/24（左） + 品阶徽章行（y=121） + 页码 p/P（右）
        ; 会话46：进度行 y104→88——18px 字高与徽章行（121）压字同带，中英都叠
        invoke UiTextL, hdcBack, 150, 88, offset szAchProg, offset CN_ACHPROG, colGray
        lea edi, uiBuf
        invoke NumStr, achOwnN, edi
        add edi, eax
        mov byte ptr [edi], '/'
        inc edi
        invoke NumStr, ACH_COUNT, edi
        invoke UiTextZ, hdcBack, 250, 88, offset uiBuf, colDark
        ; ---- 会话41：品阶徽章 普通n/6 稀有n/7 史诗n/6 传奇n/5 ----
        mov rarCnt[0], 0
        mov rarCnt[4], 0
        mov rarCnt[8], 0
        mov rarCnt[12], 0
        mov achBi, 0
UA_Scan:
        mov eax, achBi
        .if eax >= ACH_COUNT
            jmp UA_ScanDone
        .endif
        imul eax, eax, ACH_SIZE
        add eax, OFFSET achvDefs
        mov ecx, (ACHDEF ptr [eax]).rarity
        mov achRarV, ecx
        invoke AchvGetOwn, achBi
        .if eax != 0
            mov ecx, achRarV
            inc rarCnt[ecx*4]
        .endif
        inc achBi
        jmp UA_Scan
UA_ScanDone:
        mov esi, 0
UA_Badges:
        .if esi >= 4
            jmp UA_BEnd
        .endif
        mov eax, esi
        imul eax, eax, 180
        add eax, 150
        mov achBx, eax
        mov edx, rarEn[esi*4]
        mov ecx, rarCn[esi*4]
        mov ebx, rarCol[esi*4]
        ; ---- 会话45：品阶徽标 24px（achvIconTab 24+品阶），文字右移 30 ----
        mov eax, esi
        add eax, 24
        invoke AchvIcoBlit, achBx, 112, eax, ebx
        mov eax, achBx
        add eax, 30
        mov achTx, eax
        invoke UiTextL, hdcBack, achTx, 121, edx, ecx, ebx
        mov eax, rarCnt[esi*4]
        mov ecx, rarGoal[esi*4]
        lea edi, uiBuf
        invoke NumStr, eax, edi
        add edi, eax
        mov byte ptr [edi], '/'
        inc edi
        invoke NumStr, ecx, edi
        mov eax, achBx
        add eax, 100
        .if langFlag == 0            ; 会话46：COMMON/LEGEND 词宽 ~67 顶到计数，英文再右移 20
            add eax, 20
        .endif
        invoke UiTextZ, hdcBack, eax, 121, offset uiBuf, colDark
        inc esi
        jmp UA_Badges
UA_BEnd:
        mov eax, galPage
        inc eax
        lea edi, uiBuf
        invoke NumStr, eax, edi
        add edi, eax
        mov byte ptr [edi], '/'
        inc edi
        invoke NumStr, ACH_PAGES, edi
        invoke UiTextZ, hdcBack, 838, 88, offset uiBuf, colDark   ; 会话45：徽章行加宽后页码右移；会话46：随进度行上移 y88
        ; 外框 + 左右箭头（边界置灰，与技能页同几何）
        mov boxRc.left, 130
        mov boxRc.top, 140
        mov boxRc.right, 858
        mov boxRc.bottom, 490
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke SelectObject, hdcBack, fontSmall
        mov edx, colDark
        .if galPage == 0
            mov edx, colGray
        .endif
        invoke UiTextZ, hdcBack, 108, 285, offset szNumL, edx
        mov edx, colDark
        mov eax, galPage
        .if eax >= ACH_PAGES-1
            mov edx, colGray
        .endif
        invoke UiTextZ, hdcBack, 880, 285, offset szNumR, edx
        ; ---- 逐行：稀有度签(彩) / 名称(点亮=彩 未点亮=灰) / 状态 / 描述 / 进度 ----
        ; 会话46：英文品阶词（COMMON/LEGEND 6 字符 ×9px ≈ 54）会顶穿 x180 的
        ; chip 与图标，故英文下 chip/图标/名称/描述整体右移 36；中文不动。
        mov achDx, 0
        .if langFlag == 0
            mov achDx, 44             ; 实测 COMMON 末尾 217px，chip 起点留到 224
        .endif
        mov ebx, 0
UA_Rows:
        mov eax, galPage
        imul eax, eax, ACH_ROW_PG
        add eax, ebx
        .if eax >= ACH_COUNT
            jmp UA_End
        .endif
        mov achIdx, eax
        mov eax, ebx
        imul eax, eax, 56
        add eax, 152
        mov rowY, eax
        add eax, 7
        mov achYt, eax
        mov eax, rowY
        add eax, 26
        mov achY2, eax
        mov eax, achIdx
        imul eax, eax, ACH_SIZE
        add eax, OFFSET achvDefs
        mov achDefP, eax
        invoke AchvGetOwn, achIdx
        mov achOwnF, eax
        invoke AchvGetProg, achIdx
        mov achProgV, eax
        mov eax, achDefP
        mov ecx, (ACHDEF ptr [eax]).kind
        .if ecx == AK_MKILL            ; 单场类：显示"历史峰值 vs 本场现值"较大者
            mov eax, achvMatchKills
            .if achProgV < eax
                mov achProgV, eax
            .endif
        .endif
        mov eax, achDefP
        mov ecx, (ACHDEF ptr [eax]).goal
        mov achGoalV, ecx
        mov eax, achDefP
        mov ecx, (ACHDEF ptr [eax]).rarity
        mov achRarV, ecx
        mov edx, rarCol[ecx*4]
        mov achCol, edx
        mov eax, achRarV
        mov ecx, rarEn[eax*4]
        mov achRarEnP, ecx
        mov eax, achRarV
        mov ecx, rarCn[eax*4]
        mov achRarCnP, ecx
        mov eax, achDefP
        mov ecx, (ACHDEF ptr [eax]).pNameEn
        mov achEnP, ecx
        mov eax, achDefP
        mov ecx, (ACHDEF ptr [eax]).pNameCn
        mov achCnP, ecx
        mov eax, achDefP
        mov ecx, (ACHDEF ptr [eax]).pDescEn
        mov achDsEnP, ecx
        mov eax, achDefP
        mov ecx, (ACHDEF ptr [eax]).pDescCn
        mov achDsCnP, ecx
        invoke SelectObject, hdcBack, fontSmall
        invoke UiTextL, hdcBack, 150, achYt, achRarEnP, achRarCnP, achCol
        ; ---- 会话45：行首 24px 图标 + 底色 chip（x180..212，品阶签与名称之间）----
        ; 已解锁：chip=品阶色 27% 深底、图标=品阶色；未解锁：chip=主题中性底、图标=colGray
        mov eax, themeNight
        .if eax != 0
            mov eax, 002E2E2Eh
        .else
            mov eax, 0000BEBEBEh
        .endif
        mov achChip, eax
        .if achOwnF != 0
            invoke AchvShade, achCol, 70
            mov achChip, eax
            mov eax, achCol
        .else
            mov eax, colGray
        .endif
        mov achIcoCol, eax
        mov eax, 180
        add eax, achDx
        mov boxRc.left, eax
        mov eax, 212
        add eax, achDx
        mov boxRc.right, eax
        mov eax, rowY
        add eax, 2
        mov boxRc.top, eax
        mov eax, rowY
        add eax, 34
        mov boxRc.bottom, eax
        invoke CreateSolidBrush, achChip
        mov achBrush, eax
        invoke FillRect, hdcBack, addr boxRc, achBrush
        invoke DeleteObject, achBrush
        mov eax, rowY
        add eax, 6
        mov achIcoY, eax
        mov ecx, achIdx
        mov eax, 184
        add eax, achDx
        invoke AchvIcoBlit, eax, achIcoY, ecx, achIcoCol
        .if achOwnF != 0
            mov eax, achCol
            mov achNmCol, eax
        .else
            mov eax, colGray
            mov achNmCol, eax
        .endif
        invoke SelectObject, hdcBack, menuFont
        mov eax, 220
        add eax, achDx
        invoke UiTextL, hdcBack, eax, rowY, achEnP, achCnP, achNmCol
        invoke SelectObject, hdcBack, fontSmall
        .if achOwnF != 0
            invoke UiTextL, hdcBack, 770, achYt, offset szDoneEN, offset CN_ACHOWN, colHi
            ; 会话41：达成日期 2026-10-22（旧档迁移=0 不显示）
            invoke AchvGetDate, achIdx
            .if eax != 0
                mov achDtV, eax
                xor edx, edx
                mov ecx, 100
                div ecx                      ; eax=yyyymm edx=dd
                mov achDtD, edx
                xor edx, edx
                mov ecx, 100
                div ecx                      ; eax=yyyy edx=mm
                mov achDtM, edx
                mov achDtY, eax
                lea edi, uiBuf
                invoke NumStr, achDtY, edi   ; NumStr 存 edi：游标续写安全
                add edi, eax
                mov byte ptr [edi], '-'
                inc edi
                mov eax, achDtM
                .if eax < 10
                    mov byte ptr [edi], '0'
                    inc edi
                .endif
                invoke NumStr, achDtM, edi
                add edi, eax
                mov byte ptr [edi], '-'
                inc edi
                mov eax, achDtD
                .if eax < 10
                    mov byte ptr [edi], '0'
                    inc edi
                .endif
                invoke NumStr, achDtD, edi
                invoke UiTextZ, hdcBack, 770, achY2, offset uiBuf, colGray
            .endif
        .else
            invoke UiTextL, hdcBack, 770, achYt, offset szLockEN, offset CN_ACHLOCK, colGray
        .endif
        mov eax, 220
        add eax, achDx
        invoke UiTextL, hdcBack, eax, achY2, achDsEnP, achDsCnP, colGray
        .if achOwnF == 0
            .if achGoalV > 1           ; 计数类才显示 n/m；瞬时类(目标1)不剧透
                lea edi, uiBuf
                invoke NumStr, achProgV, edi
                add edi, eax
                mov byte ptr [edi], '/'
                inc edi
                invoke NumStr, achGoalV, edi
                invoke UiTextZ, hdcBack, 700, achY2, offset uiBuf, colGray
            .endif
        .endif
        inc ebx
        .if ebx < ACH_ROW_PG
            jmp UA_Rows
        .endif
UA_End:
        ; 返回按钮 + 底部提示（与技能页同几何）
        invoke SelectObject, hdcBack, menuFont
        mov boxRc.left, 440
        mov boxRc.top, 516
        mov boxRc.right, 560
        mov boxRc.bottom, 552
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke UiTextL, hdcBack, 474, 524, offset szBackBtn, offset CN_BACKBTN, colDark
        invoke UiTextL, hdcBack, 360, 560, offset szSetHint, offset CN_SETHINT, colGray

    ; ---------- 玩法演示页：6 段动画 ----------
    .elseif gameState == ST_DEMO
        invoke UiTextL, hdcBack, 430, 60, offset szDemT, offset CN_DEMOT, colDark
        mov boxRc.left, 130
        mov boxRc.top, 140
        mov boxRc.right, 858
        mov boxRc.bottom, 490
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke SelectObject, hdcBack, fontSmall
        mov edx, colDark
        .if demoPage == 0
            mov edx, colGray
        .endif
        invoke UiTextZ, hdcBack, 155, 285, offset szNumL, edx
        mov edx, colDark
        mov eax, demoPage
        .if eax >= 5
            mov edx, colGray
        .endif
        invoke UiTextZ, hdcBack, 815, 285, offset szNumR, edx
        invoke SelectObject, hdcBack, menuFont
        mov eax, demoT
        xor edx, edx
        mov ecx, 480
        div ecx
        mov eax, edx
        xor edx, edx
        mov ecx, 120
        div ecx
        mov demoPh, eax
        mov demoPt, edx
        invoke SelectObject, hdcBack, brushMortar
        mov boxRc.left, 150
        mov boxRc.top, 362
        mov boxRc.right, 838
        mov boxRc.bottom, 366
        invoke FillRect, hdcBack, addr boxRc, brushMortar
        mov eax, demoPage
        .if eax == 0
            mov eax, demoPh
            .if eax == 0
                mov eax, demoPt
                imul eax, eax, 2
                add eax, 250
                mov demoP1x, eax
                mov demoP1y, 300
                mov demoDir, DIR_RIGHT
            .elseif eax == 1
                mov demoP1x, 490
                mov eax, demoPt
                add eax, 300
                mov demoP1y, eax
                mov demoDir, DIR_DOWN
            .elseif eax == 2
                mov eax, demoPt
                imul eax, eax, 2
                mov ecx, eax
                mov eax, 490
                sub eax, ecx
                mov demoP1x, eax
                mov demoP1y, 420
                mov demoDir, DIR_LEFT
            .else
                mov demoP1x, 250
                mov eax, 420
                sub eax, demoPt
                mov demoP1y, eax
                mov demoDir, DIR_UP
            .endif
            invoke SelectObject, hdcBack, brushP1
            invoke DrawTank, hdcBack, demoP1x, demoP1y, demoDir
            invoke SelectObject, hdcBack, menuFont
        .elseif eax == 1
            ; 会话 24 重排：旧动画弹速 4px/tick 且"三回合各射一发"与真实
            ; 弹速/一命制脱节。现在 0~1 拍一发 2.7px/tick 的弹飞到 P2 车头
            ; 即被吸收，第 2 拍起 P2 淘汰闪烁 + 爆裂圈 + KO（一命制，首发定胜负）
            invoke SelectObject, hdcBack, brushP1
            invoke DrawTank, hdcBack, 200, 330, DIR_RIGHT
            mov eax, demoPh
            .if eax < 2
                invoke SelectObject, hdcBack, brushP2
                invoke DrawTank, hdcBack, 650, 330, DIR_LEFT
            .else
                mov eax, demoT
                and eax, 8
                .if eax == 0
                    invoke SelectObject, hdcBack, brushP2
                    invoke DrawTank, hdcBack, 650, 330, DIR_LEFT
                .endif
                mov eax, demoPt
                .if eax < 40
                    mov eax, demoT
                    and eax, 4
                    .if eax == 0
                        invoke SelectObject, hdcBack, brushBrick
                        invoke Ellipse, hdcBack, 635, 315, 690, 370
                    .endif
                .endif
                invoke UiTextZ, hdcBack, 640, 260, offset szKO, 0000E0E0h
            .endif
            ; 子弹：x = 230 + floor(tt*27/10)（2.7px/tick），越过 648 视为命中
            mov eax, demoPh
            .if eax < 2
                imul eax, eax, 120
                add eax, demoPt
                imul eax, eax, 27
                mov ecx, 10
                xor edx, edx
                div ecx
                add eax, 230
                .if eax <= 648
                    mov boxRc.left, eax
                    add eax, 8
                    mov boxRc.right, eax
                    mov boxRc.top, 336
                    mov boxRc.bottom, 344
                    invoke FillRect, hdcBack, addr boxRc, brushBullet
                .endif
            .endif
            ; P2 血条：一滴血（第一发即淘汰）
            mov eax, demoPh
            .if eax == 0
                mov boxRc.left, 640
                mov boxRc.top, 296
                mov boxRc.right, 660
                mov boxRc.bottom, 304
                invoke FillRect, hdcBack, addr boxRc, brushBrick
            .endif
            invoke SelectObject, hdcBack, menuFont
        .elseif eax == 2
            invoke SelectObject, hdcBack, brushSteel
            mov boxRc.left, 596
            mov boxRc.top, 240
            mov boxRc.right, 604
            mov boxRc.bottom, 440
            invoke FillRect, hdcBack, addr boxRc, brushSteel
            invoke SelectObject, hdcBack, brushP1
            invoke DrawTank, hdcBack, 200, 330, DIR_RIGHT
            mov eax, demoT
            xor edx, edx
            mov ecx, 480
            div ecx
            mov eax, edx
            ; 会话 24 重排：弹真实速度 2.7px/tick —— 128 tick 走完
            ; 230->572（贴墙），挤压两拍后同速折返，回到炮口停住
            ; （折返段减法会出负：钳位用有符号 jge，勿写 .if <（无符号恒假））
            .if eax < 128
                imul eax, eax, 27
                xor edx, edx
                mov ecx, 10
                div ecx
                add eax, 230
                mov demoP1x, eax
            .elseif eax < 132
                mov demoP1x, 575              ; 贴墙挤压拍（爆裂圈同窗显示）
            .else
                sub eax, 132
                imul eax, eax, 27
                xor edx, edx
                mov ecx, 10
                div ecx
                mov ecx, eax
                mov eax, 575
                sub eax, ecx
                cmp eax, 230
                jge T2P2Keep
                mov eax, 230
T2P2Keep:
                mov demoP1x, eax
            .endif
            mov eax, demoT
            xor edx, edx
            mov ecx, 480
            div ecx
            mov eax, edx
            .if eax >= 124 && eax < 142
                invoke SelectObject, hdcBack, brushBrick
                invoke Ellipse, hdcBack, 580, 316, 620, 356
            .endif
            invoke SelectObject, hdcBack, brushBullet
            mov eax, demoP1x
            mov boxRc.left, eax
            mov boxRc.top, 336
            mov eax, demoP1x
            add eax, 8
            mov boxRc.right, eax
            mov boxRc.bottom, 344
            invoke FillRect, hdcBack, addr boxRc, brushBullet
            invoke SelectObject, hdcBack, menuFont
        .elseif eax == 3
            ; 地形演示（会话 18 重做）：坦克行驶在地形带正中（原悬浮在带上方
            ; 且恒速直线，看不出任何地形效果）。纹理与 game.asm 地面层同款
            ; 泥地（150..320）：棕褐底 + 两道深棕纹理
            mov boxRc.left, 150
            mov boxRc.top, 350
            mov boxRc.right, 320
            mov boxRc.bottom, 372
            invoke FillRect, hdcBack, addr boxRc, brushDirt
            mov boxRc.left, 154
            mov boxRc.right, 310
            mov boxRc.top, 357
            mov boxRc.bottom, 359
            invoke FillRect, hdcBack, addr boxRc, brushDirtDark
            mov boxRc.left, 160
            mov boxRc.right, 316
            mov boxRc.top, 369
            mov boxRc.bottom, 371
            invoke FillRect, hdcBack, addr boxRc, brushDirtDark
            ; 冰面（320..490）：浅蓝底 + 两道错位白高光
            mov boxRc.left, 320
            mov boxRc.right, 490
            mov boxRc.top, 350
            mov boxRc.bottom, 372
            invoke FillRect, hdcBack, addr boxRc, brushIce
            mov boxRc.left, 324
            mov boxRc.right, 480
            mov boxRc.top, 356
            mov boxRc.bottom, 358
            invoke FillRect, hdcBack, addr boxRc, brushStreak
            mov boxRc.left, 330
            mov boxRc.right, 486
            mov boxRc.top, 368
            mov boxRc.bottom, 370
            invoke FillRect, hdcBack, addr boxRc, brushStreak
            ; 水面（490..660）：深蓝底 + 两道浅蓝波纹
            mov boxRc.left, 490
            mov boxRc.right, 660
            mov boxRc.top, 350
            mov boxRc.bottom, 372
            invoke FillRect, hdcBack, addr boxRc, brushWater
            mov boxRc.left, 494
            mov boxRc.right, 656
            mov boxRc.top, 358
            mov boxRc.bottom, 360
            invoke FillRect, hdcBack, addr boxRc, brushWave
            mov boxRc.left, 500
            mov boxRc.right, 650
            mov boxRc.top, 368
            mov boxRc.bottom, 370
            invoke FillRect, hdcBack, addr boxRc, brushWave
            ; 空地（660..838）：留白透出页面底色（深夜模式不铺死色）
            ; 运动时间轴：480 tick 循环，tt = demoPh*120 + demoPt
            ; （会话 23 降速重时：地面 2/3 交替均速 2.5px/tick，用 5/2 定点；
            ;   泥地 1px/tick 不变，仍与真速一致）
            mov eax, demoPh
            imul eax, eax, 120
            add eax, demoPt
            .if eax < 170                 ; 泥地：1px/tick 陷住爬行，走满 170px 带宽
                add eax, 150
                mov demoP1x, eax
            .elseif eax < 228             ; 出泥上冰：均速 2.5px/tick 滑行（58 tick 滑到水缘）
                sub eax, 170
                imul eax, eax, 5
                shr eax, 1
                add eax, 320
                mov demoP1x, eax
            .elseif eax < 232             ; 冰尽头：余势缓停（1px/tick）
                sub eax, 227
                add eax, 462
                mov demoP1x, eax
            .elseif eax < 292             ; 水面阻挡：冰缘原地小幅顶撞
                shr eax, 2
                and eax, 1
                shl eax, 1
                add eax, 465
                mov demoP1x, eax
            .elseif eax < 362             ; 驭水术生效：均速 2.5px/tick 穿水而过
                sub eax, 292
                imul eax, eax, 5
                shr eax, 1
                add eax, 465
                mov demoP1x, eax
            .elseif eax < 410             ; 开阔地：正常速推进
                sub eax, 362
                imul eax, eax, 5
                shr eax, 1
                add eax, 637
                mov demoP1x, eax
            .else                         ; 循环末停住，回卷重演
                mov demoP1x, 754
            .endif
            ; 驭水徽章：坦克中心骑在水面上（x 478..648）时框浅色外圈
            mov eax, demoP1x
            .if eax >= 478 && eax <= 648
                mov boxRc.left, eax
                sub boxRc.left, 3
                mov boxRc.right, eax
                add boxRc.right, TANK_SIZE + 3
                mov boxRc.top, 345
                mov boxRc.bottom, 345 + TANK_SIZE + 6
                invoke FrameRect, hdcBack, addr boxRc, brushIce
            .endif
            invoke SelectObject, hdcBack, brushP1
            invoke DrawTank, hdcBack, demoP1x, 348, DIR_RIGHT
            invoke SelectObject, hdcBack, menuFont
        .elseif eax == 4
            mov eax, demoPh
            .if eax == 0
                mov eax, demoPt
                imul eax, eax, 2
                add eax, 180
                mov demoP1x, eax
                mov boxRc.left, 460
                mov boxRc.top, 326
                mov boxRc.right, 478
                mov boxRc.bottom, 344
                invoke FillRect, hdcBack, addr boxRc, brushPickBg
                invoke FrameRect, hdcBack, addr boxRc, brushMortar
                invoke SelectObject, hdcBack, penIcon
                mov penOld2, eax
                invoke DrawPickupIcon, hdcBack, 462, 328, SK_ICE_SHIELD, 1
                invoke SelectObject, hdcBack, penOld2
            .else
                mov demoP1x, 420
                invoke SelectObject, hdcBack, brushIce
                mov eax, demoP1x
                mov boxRc.left, eax
                sub boxRc.left, 6
                mov boxRc.top, 324
                mov eax, demoP1x
                add eax, TANK_SIZE+6
                mov boxRc.right, eax
                mov boxRc.bottom, 356
                invoke FrameRect, hdcBack, addr boxRc, brushIce
            .endif
            invoke SelectObject, hdcBack, brushP1
            invoke DrawTank, hdcBack, demoP1x, 330, DIR_RIGHT
            invoke SelectObject, hdcBack, menuFont
        .else
            invoke SelectObject, hdcBack, brushP1
            invoke DrawTank, hdcBack, 250, 330, DIR_RIGHT
            mov eax, demoPh
            .if eax < 2
                invoke SelectObject, hdcBack, brushP2
                invoke DrawTank, hdcBack, 650, 330, DIR_LEFT
            .else
                mov eax, demoT
                and eax, 8
                .if eax == 0
                    invoke SelectObject, hdcBack, brushP2
                    invoke DrawTank, hdcBack, 650, 330, DIR_LEFT
                .endif
                invoke SelectObject, hdcBack, menuFont
                mov eax, 300
                sub eax, demoPt
                .if eax < 240
                    mov eax, 240
                .endif
                invoke UiTextZ, hdcBack, 655, eax, offset szPlus1, 0000E0E0h
            .endif
            invoke SelectObject, hdcBack, menuFont
            mov eax, demoPh
            .if eax >= 2
                invoke UiTextZ, hdcBack, 420, 180, offset szScore1, colDark
            .else
                invoke UiTextZ, hdcBack, 420, 180, offset szScore0, colDark
            .endif
        .endif
        invoke SelectObject, hdcBack, menuFont
        invoke SelectObject, hdcBack, fontSmall
        mov eax, demoPage
        mov edx, dDemoEn[eax*4]
        mov eax, demoPage
        mov ecx, dDemoCn[eax*4]
        invoke UiTextL, hdcBack, 230, 420, edx, ecx, colGray
        invoke SelectObject, hdcBack, menuFont
        lea edi, uiBuf
        mov eax, demoPage
        inc eax
        add al, '0'
        mov [edi], al
        mov byte ptr [edi+1], ' '
        mov byte ptr [edi+2], '/'
        mov byte ptr [edi+3], ' '
        mov byte ptr [edi+4], '6'
        mov byte ptr [edi+5], 0
        invoke UiTextZ, hdcBack, 470, 165, offset uiBuf, colDark
        ; 会话 23：返回按钮（点击区 440..560, 516..552）
        mov boxRc.left, 440
        mov boxRc.top, 516
        mov boxRc.right, 560
        mov boxRc.bottom, 552
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke UiTextL, hdcBack, 474, 524, offset szBackBtn, offset CN_BACKBTN, colDark
        invoke UiTextL, hdcBack, 360, 560, offset szSkHint, offset CN_SKHINT, colGray
    .endif

UR_Toast:
    ; ---- 会话40：成就解锁弹层（任意画面置顶横幅 4s；顶部 36..100 不与掉线横幅 258..334 冲突） ----
    ; ---- 会话41：滑入/品阶描边/末段闪烁 + 对局内倒计时修复（见 UiTick 过程头） ----
    mov eax, achvToastT
    .if eax != 0
        mov ecx, achvToastId
        .if ecx < ACH_COUNT            ; 无符号判定：-1（无弹层）天然落选
            mov edx, ecx
            imul edx, edx, ACH_SIZE
            add edx, OFFSET achvDefs
            mov eax, (ACHDEF ptr [edx]).rarity
            mov achRarV, eax
            mov eax, (ACHDEF ptr [edx]).pNameEn
            mov achEnP, eax
            mov eax, (ACHDEF ptr [edx]).pNameCn
            mov achCnP, eax
            mov eax, achRarV
            mov ecx, rarCol[eax*4]
            mov achCol, ecx
            mov ecx, rarEn[eax*4]
            mov achRarEnP, ecx
            mov eax, achRarV
            mov ecx, rarCn[eax*4]
            mov achRarCnP, ecx
            mov eax, achCol
            mov achNmCol, eax
            mov ecx, achRarV
            mov edx, rarBr[ecx*4]
            mov achBr, edx                   ; 会话41：品阶色描边
            ; 会话42：退场改滑出（末 8 tick 原路顶回屏外），替代会话41 的
            ; 末段闪烁——用户实玩反馈"一闪一闪"显廉价，动画首尾对称更体面
            mov eax, 240
            sub eax, achvToastT
            mov achDy, 0
            .if eax < 8
                mov ecx, 8
                sub ecx, eax
                imul ecx, ecx, 12
                mov achDy, ecx
            .else
                mov ecx, achvToastT
                .if ecx < 8
                    mov eax, 8
                    sub eax, ecx
                    imul eax, eax, 12
                    mov achDy, eax
                .endif
            .endif
            mov achShow, 1
            .if achShow != 0
                mov ecx, achDy
                ; 会话45：横幅左延至 252、右延至 740（中心 496 不变），腾出 x260..284 图标位
                mov boxRc.left, 252
                mov boxRc.right, 740
                mov eax, 36
                sub eax, ecx
                mov boxRc.top, eax
                mov eax, 100
                sub eax, ecx
                mov boxRc.bottom, eax
                invoke FillRect, hdcBack, addr boxRc, brushPickBg
                invoke FrameRect, hdcBack, addr boxRc, achBr
                ; ---- 会话45：横幅左侧 24px 成就图标（品阶色），y=52-achDy ----
                mov ecx, achDy
                mov eax, 52
                sub eax, ecx
                mov achIcoY, eax
                mov eax, achvToastId
                invoke AchvIcoBlit, 260, achIcoY, eax, achCol
                mov ecx, achDy
                mov eax, 44
                sub eax, ecx
                mov achYt, eax
                mov ecx, achDy
                mov eax, 64
                sub eax, ecx
                mov achY2, eax
                invoke SelectObject, hdcBack, fontSmall
                invoke UiTextL, hdcBack, 316, achYt, offset szToastAch, offset CN_ACHTOA, colHi
                invoke UiTextL, hdcBack, 600, achYt, achRarEnP, achRarCnP, achCol
                invoke SelectObject, hdcBack, menuFont
                invoke UiTextL, hdcBack, 316, achY2, achEnP, achCnP, achNmCol
            .endif
        .endif
    .endif

UR_Done:
    invoke SelectObject, hdcBack, fontOld
    invoke GetDC, hWnd
    mov hdcWin2, eax
    invoke BitBlt, hdcWin2, 0, 0, WND_W, WND_H, hdcBack, 0, 0, SRCCOPY
    invoke ReleaseDC, hWnd, hdcWin2
    ret
UiRender endp

end
