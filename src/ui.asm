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
SndVolume PROTO :DWORD
SndPlay   PROTO :DWORD
extern peerAddr  :sockaddr_in
extern peerKnown :dword
extern hSock     :dword

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
    uiBuf       db 96 dup (0)
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
    szNumT      db "SELECT PLAYERS", 0
    szNumL      db "<<", 0
    szNumR      db ">>", 0
    szRounds    db "ROUNDS", 0
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
    szReb2      db "PRESS ANY KEY (EN IME! ESC=CANCEL)", 0
    szSetT      db "KEY SETTINGS", 0
    szSetH      db "ENTER: REBIND   ESC: BACK", 0
    szRebind    db " <- PRESS ANY KEY", 0
    szLanT      db "LAN PLAY", 0
    szLanB      db "BROADCASTING ON UDP PORT 28888 ...", 0
    szLanN      db "SEARCHING FOR PEERS ...", 0
    szLanF      db "PEER FOUND:", 0
    szLanS      db "CLICK/ENTER: START MATCH   ESC: BACK", 0
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
    CN_LANG dw 8bedh,8a00h,0ff1ah,4e2dh,6587h, 0
    CN_NUMT dw 9009h,62e9h,73a9h,5bb6h,6570h,91cfh, 0
    CN_ROUNDS dw 5c40h,6570h, 0                                          ; 局数
    CN_HINT dw 56deh,8f66h,0ff1ah,786eh,8ba4h,0020h,0020h,0020h,0020h,0045h,0073h,0063h,0ff1ah,8fd4h,56deh, 0
    CN_NAMEHINT dw 70B9h,51FBh,540Dh,5B57h,53EFh,6539h,540Dh, 0   ; 点击名字可改名
    CN_NAMEEDIT dw 8F93h,5165h,540Dh,5B57h,56DEh,8F66h,786Eh,8BA4h, 0 ; 输入名字回车确认
    CN_VOL2     dw 97F3h,91CFh, 0                              ; 音量
    CN_SFX      dw 97F3h,6548h, 0                              ; 音效
    CN_ON2      dw 5F00h, 0                                    ; 开
    CN_OFF2     dw 5173h, 0                                    ; 关
    CN_NIGHT    dw 6DF1h,591Ch,6A21h,5F0Fh, 0                  ; 深夜模式
    CN_RESET dw 91cdh,7f6eh,6240h,6709h,66f4h,6539h,6309h,952eh, 0        ; 重置所有更改按键
    CN_REB2 dw 8bf7h,6309h,4efbh,610fh,952eh,0FF08h,5148h,5207h,82f1h,6587h,8f93h,5165h,6cd5h,0FF09h, 0 ; 请按任意键（先切英文输入法）
    CN_KEYS dw 952eh,4f4dh, 0                                            ; 键位
    CN_SETT     dw 06E38h,0620Fh,08BBEh,07F6Eh, 0
    CN_SETH dw 56deh,8f66h,0ff1ah,6539h,952eh,0020h,0020h,0020h,0020h,0045h,0073h,0063h,0ff1ah,8fd4h,56deh, 0
    CN_REBIND dw 0020h,003ch,002dh,0020h,8bf7h,6309h,4efbh,610fh,952eh, 0
    CN_LANT dw 8054h,673ah,5bf9h,6218h,0ff08h,5c40h,57dfh,7f51h,0ff09h, 0
    CN_LANB dw 6b63h,5728h,901ah,8fc7h,0020h,0055h,0044h,0050h,0020h,7aefh,53e3h,0020h,0032h,0038h,0038h,0038h,0038h,0020h,5e7fh,64adh,0020h,002eh,002eh,002eh, 0
    CN_LANN dw 6b63h,5728h,641ch,7d22h,5bf9h,624bh,0020h,002eh,002eh,002eh, 0
    CN_LANF dw 5df2h,53d1h,73b0h,5bf9h,624bh,003ah, 0
    CN_LANS dw 70B9h,51FBh,6216h,56DEh,8F66h,0FF1Ah,5F00h,59CBh,6BD4h,8D5Bh,0020h,0045h,0073h,0063h,0FF1Ah,8FD4h,56DEh, 0
    colDark     dd 00232323h
    colGray     dd 00606060h
    colHi       dd 0000C06000h
    colFound    dd 0000A000h
    hdcWin2     dd 0

.code

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
    mov numPlayers, 2
    invoke GameInit
    mov netMode, 0
    mov gameState, ST_PLAY
    ret
UiForcePlay2 endp

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
        invoke NetShutdown
        invoke NetInit
        mov peerKnown, 0
        mov discTimer, 0
        invoke setsockopt, hSock, SOL_SOCKET, SO_BROADCAST,
               addr oneVal, 4
    .elseif menuSel == 5
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
        invoke NetShutdown
        mov netMode, 0
        invoke NetInit
        mov peerKnown, 0
    .endif
    ret
UT_QuitToMenu endp

; ------------------------------------------------------------
; UiTick -- 每逻辑 tick 调用
; ------------------------------------------------------------
UiTick proc uses ebx esi edi
    local upE:dword, dnE:dword, ltE:dword, rtE:dword
    local enE:dword, esE:dword, scanVk:dword
    local lbE:dword

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

    ; ---------- 对局中：Esc 暂停 / 比赛结束回菜单 ----------
    .if gameState == ST_PLAY
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
        inc demoT                        ; 会话 25：主页装饰动画时钟（gTick 仅对局
                                         ; 推进，菜单里必须自带表针；演示页 mod 480
                                         ; 取值，多走无副作用）
        .if dnE != 0
            inc menuSel
            .if menuSel > 6
                mov menuSel, 0
            .endif
        .endif
        .if upE != 0
            .if menuSel == 0
                mov menuSel, 6
            .else
                dec menuSel
            .endif
        .endif
        .if enE != 0
            invoke MenuActivate
        .endif
        ; ---- 鼠标：悬停高亮 + 左键点击激活 ----
        ; 菜单 7 项渲染矩形：x 440..660，y = 190+i*46 .. +34（与 UiRender UM_Items 同几何）
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
        .if ebx >= 7                   ; 会话 23 修复：7 项（含语言切换）全部可点
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
            ; ---- 改键等待：目标键位闪烁，按新键完成（冲突拒绝），Esc 取消 ----
            inc blinkTick
            .if esE != 0
                mov rebindSlot, -1
            .else
                ; 改键扫描：0x8000 电平（0x1 边沿位在焦点切换时不可靠），
                ; 范围收窄 0x08..0x5A / 0x60..0x87 / 0xA0..0xA5 —— 排除
                ; 鼠标键、Win/IME 保留区（0x85 误绑问题），Esc=取消专用；
                ; 进入等待后 3 tick 冷却（rebindCool）防点击残键误捕获
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
                .if eax > 87h && eax < 0A0h    ; 保留/IME 区跳过
                    jmp UT_Scan2Next
                .endif
                invoke GetAsyncKeyState, eax
                and eax, 8000h
                .if eax != 0
                    ; 冲突校验：不得与其他任何槽位的键相同
                    mov edx, scanVk
                    xor ebx, ebx
UT_Conf:
                    .if ebx >= MAX_PLAYERS*KEY_PER
                        ; 无冲突：写入并结束等待
                        mov eax, rebindSlot
                        mov keyTable[eax*4], edx
                        mov rebindSlot, -1
                        jmp UT_Scan2Done
                    .endif
                    .if ebx != rebindSlot
                        mov eax, keyTable[ebx*4]
                        .if eax == edx
                            jmp UT_Scan2Done     ; 冲突：保持闪烁等待换键
                        .endif
                    .endif
                    inc ebx
                    jmp UT_Conf
                .endif
UT_Scan2Next:
                inc scanVk
                jmp UT_Scan2
UT_Scan2Done:
            .endif
            ; 等待中允许点击其他键位行切换目标 / 点重置按钮
            .if lbE != 0
                invoke NumSelHitTest
                test eax, eax
                js UTW_Next                ; 负值（重置/标题）不走切换
                .if eax != rebindSlot
                    mov rebindSlot, eax
                    mov rebindCool, 3      ; 切换目标：冷却防残键误捕
                .endif
UTW_Next:
                .if eax == -2
                    invoke InitKeyDefaults
                    mov rebindSlot, -1
                .endif
            .endif
        .else
            ; ---- 常规键盘操作（保留） ----
            .if rtE != 0
                inc numSel
                .if numSel > 4
                    mov numSel, 2
                .endif
            .endif
            .if ltE != 0
                dec numSel
                .if numSel < 2
                    mov numSel, 4
                .endif
            .endif
            .if enE != 0
                mov eax, numSel
                mov numPlayers, eax
                mov eax, roundsSel
                mov maxRounds, eax
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
                ; PLAYERS >> 535..600, y190..242
                .elseif eax >= 535 && eax < 600 && mouseY >= 190 && mouseY < 242
                    inc numSel
                    .if numSel > 4
                        mov numSel, 2
                    .endif
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
                    invoke GameInit
                    mov netMode, 0
                    mov gameState, ST_PLAY
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

    ; ---------- 联机大厅 ----------
    .elseif gameState == ST_LAN
        inc discTimer
        .if discTimer >= 30
            mov discTimer, 0
            mov bcastAddr.sin_family, AF_INET
            invoke htons, 28888
            mov bcastAddr.sin_port, ax
            mov bcastAddr.sin_addr, INADDR_BROADCAST
            invoke sendto, hSock, offset discBuf, 7, 0,
                   addr bcastAddr, SIZEOF sockaddr_in
        .endif
        mov discLen, SIZEOF sockaddr_in
        invoke recvfrom, hSock, offset recvTmp, 64, 0,
               addr discFrom, addr discLen
        .if eax >= 7
            mov eax, dword ptr recvTmp[0]
            .if eax == 454E5754h               ; "TWNE" (小端)
                cmp byte ptr recvTmp[4], 'T'   ; "T01" 的 'T'
                .if ZERO?
                    invoke StrCopy, addr discFrom, addr peerAddr, 16
                    mov peerKnown, 1
                    invoke IpToStr, addr peerAddr.sin_addr, offset peerIpBuf
                    mov peerIpLen, eax
                .endif
            .endif
        .endif
        ; 会话 23：开始对局 / 返回按钮可点（开始 400..600 y410..450，返回 y460..500）
        .if lbE != 0 && mouseX >= 400 && mouseX < 600 && peerKnown != 0
            .if mouseY >= 410 && mouseY < 450
                jmp UT_LanStart
            .endif
        .endif
        .if enE != 0 && peerKnown != 0
UT_LanStart:
            mov numPlayers, 2
            invoke GameInit
            mov netMode, 1
            mov gameState, ST_PLAY
        .endif
        .if lbE != 0 && mouseX >= 400 && mouseX < 600
            .if mouseY >= 460 && mouseY < 500
                jmp UT_LanBack
            .endif
        .endif
        .if esE != 0
UT_LanBack:
            invoke NetShutdown
            mov peerKnown, 0
            mov gameState, ST_MENU
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
    .endif
UT_Done:
    ret
UiTick endp

; ------------------------------------------------------------
; UiRender -- 按状态绘制；对局中委托 GfxRender
; ------------------------------------------------------------
; 会话 25 主页装饰宏：18px 深色拾取底 + 描边 + 白图标（限 UiRender
; 内使用，依赖局部 boxRc；pen 选换模式与演示页 2068..2073 一致）
UMIconBox macro px, py, tp
    mov boxRc.left, px
    mov boxRc.top, py
    mov boxRc.right, px+18
    mov boxRc.bottom, py+18
    invoke FillRect, hdcBack, addr boxRc, brushPickBg
    invoke FrameRect, hdcBack, addr boxRc, brushMortar
    invoke SelectObject, hdcBack, penIcon
    mov penOld2, eax
    invoke DrawPickupIcon, hdcBack, px+2, py+2, tp, 1
    invoke SelectObject, hdcBack, penOld2
endm

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
        jmp UR_Done
    .endif

    ; ---------- 主菜单 ----------
    .if gameState == ST_MENU
        ; ==== 会话 25 主页装饰（demoT 驱动；全部避开菜单文字区
        ;      x380..680/y80..510 与点击/悬停带 x440..660）====
        ; -- 左侧地形样本：钢墙 L 角 + 砖墙三连 + 水/冰/泥样块 --
        mov boxRc.left, 40
        mov boxRc.top, 148
        mov boxRc.right, 176
        mov boxRc.bottom, 162
        invoke FillRect, hdcBack, addr boxRc, brushSteel
        mov boxRc.left, 40
        mov boxRc.top, 148
        mov boxRc.right, 54
        mov boxRc.bottom, 268
        invoke FillRect, hdcBack, addr boxRc, brushSteel
        mov ebx, 0
UM_Brick:
        mov eax, ebx
        imul eax, eax, 26
        add eax, 176
        mov boxRc.left, 60
        mov boxRc.top, eax
        mov boxRc.right, 156
        add eax, 18
        mov boxRc.bottom, eax
        invoke FillRect, hdcBack, addr boxRc, brushBrick
        inc ebx
        cmp ebx, 3
        jb UM_Brick
        mov boxRc.left, 60
        mov boxRc.top, 262
        mov boxRc.right, 148
        mov boxRc.bottom, 300
        invoke FillRect, hdcBack, addr boxRc, brushWater
        mov boxRc.left, 68
        mov boxRc.top, 270
        mov boxRc.right, 132
        mov boxRc.bottom, 272
        invoke FillRect, hdcBack, addr boxRc, brushWave
        mov boxRc.left, 80
        mov boxRc.top, 286
        mov boxRc.right, 144
        mov boxRc.bottom, 288
        invoke FillRect, hdcBack, addr boxRc, brushWave
        mov boxRc.left, 160
        mov boxRc.top, 262
        mov boxRc.right, 258
        mov boxRc.bottom, 300
        invoke FillRect, hdcBack, addr boxRc, brushIce
        mov boxRc.left, 168
        mov boxRc.top, 268
        mov boxRc.right, 250
        mov boxRc.bottom, 270
        invoke FillRect, hdcBack, addr boxRc, brushStreak
        mov boxRc.left, 60
        mov boxRc.top, 312
        mov boxRc.right, 258
        mov boxRc.bottom, 372
        invoke FillRect, hdcBack, addr boxRc, brushDirt
        mov boxRc.left, 72
        mov boxRc.top, 320
        mov boxRc.right, 78
        mov boxRc.bottom, 326
        invoke FillRect, hdcBack, addr boxRc, brushDirtDark
        mov boxRc.left, 120
        mov boxRc.top, 344
        mov boxRc.right, 126
        mov boxRc.bottom, 350
        invoke FillRect, hdcBack, addr boxRc, brushDirtDark
        mov boxRc.left, 168
        mov boxRc.top, 326
        mov boxRc.right, 174
        mov boxRc.bottom, 332
        invoke FillRect, hdcBack, addr boxRc, brushDirtDark
        mov boxRc.left, 216
        mov boxRc.top, 348
        mov boxRc.right, 222
        mov boxRc.bottom, 354
        invoke FillRect, hdcBack, addr boxRc, brushDirtDark
        mov boxRc.left, 96
        mov boxRc.top, 356
        mov boxRc.right, 102
        mov boxRc.bottom, 362
        invoke FillRect, hdcBack, addr boxRc, brushDirtDark
        ; -- 样块旁的两枚"场上拾取物" --
        UMIconBox 196, 208, SK_MINE
        UMIconBox 222, 208, SK_NITRO
        ; -- 右侧技能图标列（与 7 项菜单同 y 节拍，镜像在右缘）--
        UMIconBox 930, 190, SK_LASER
        UMIconBox 930, 236, SK_ICE_SHIELD
        UMIconBox 930, 282, SK_GHOST
        UMIconBox 930, 328, SK_MINE
        UMIconBox 930, 374, SK_NITRO
        ; -- 炮塔旋转展示：慢速整圈（demoT 18 秒一圈），秀连续转向引擎 --
        mov eax, demoT
        xor edx, edx
        mov ecx, 360
        div ecx
        mov demoPt, edx
        invoke SelectObject, hdcBack, brushP1
        invoke DrawTank, hdcBack, 795, 300, demoPt
        invoke SelectObject, hdcBack, menuFont
        ; -- 底部巡逻双车道：P1 右行/P2 左行三角波 + 中间乒乓弹 --
        mov boxRc.left, 0
        mov boxRc.top, 644
        mov boxRc.right, WND_W
        mov boxRc.bottom, 646
        invoke FillRect, hdcBack, addr boxRc, brushMortar
        mov eax, demoT
        xor edx, edx
        mov ecx, 480
        div ecx
        mov demoPh, edx
        cmp edx, 240
        jb UM_P1F
        mov eax, 480
        sub eax, demoPh
UM_P1F:
        mov demoPt, eax
        imul eax, eax, 3
        add eax, 40
        mov demoP1x, eax
        mov ecx, 0
        cmp demoPh, 240
        jb UM_P1D
        mov ecx, 180
UM_P1D:
        mov demoDir, ecx
        invoke SelectObject, hdcBack, brushP1
        invoke DrawTank, hdcBack, demoP1x, 578, demoDir
        invoke SelectObject, hdcBack, menuFont
        mov eax, demoT
        add eax, 240
        xor edx, edx
        mov ecx, 480
        div ecx
        mov demoPh, edx
        cmp edx, 240
        jb UM_P2F
        mov eax, 480
        sub eax, demoPh
UM_P2F:
        mov demoPt, eax
        imul eax, eax, 3
        mov ecx, 912
        sub ecx, eax
        mov demoP1x, ecx
        mov ecx, 180
        cmp demoPh, 240
        jb UM_P2D
        xor ecx, ecx
UM_P2D:
        mov demoDir, ecx
        invoke SelectObject, hdcBack, brushP2
        invoke DrawTank, hdcBack, demoP1x, 616, demoDir
        invoke SelectObject, hdcBack, menuFont
        ; 乒乓弹：两车道之间 y602..610，300..660 折返（半周期 120 tick）
        mov eax, demoT
        xor edx, edx
        mov ecx, 240
        div ecx
        mov demoPh, edx
        cmp edx, 120
        jb UM_BF
        mov eax, 240
        sub eax, demoPh
UM_BF:
        imul eax, eax, 3
        add eax, 300
        mov boxRc.left, eax
        add eax, 8
        mov boxRc.right, eax
        mov boxRc.top, 602
        mov boxRc.bottom, 610
        invoke FillRect, hdcBack, addr boxRc, brushBullet
        ; ==== 装饰结束：标题与 7 项菜单压在装饰上层 ====
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
            invoke UiTextL, hdcBack, 436, rowY, offset szItem4, offset CN_EXIT, edx
        .else
            invoke UiTextL, hdcBack, 436, rowY, offset szLangEN, offset CN_LANG, edx
        .endif
        pop ebx
        inc ebx
        .if ebx < 7
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
        invoke UiTextL, hdcBack, 322, 262, offset szRounds, offset CN_ROUNDS, colDark
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

    ; ---------- 联机大厅 ----------
    .elseif gameState == ST_LAN
        invoke UiTextL, hdcBack, 440, 130, offset szLanT, offset CN_LANT, colDark
        invoke UiTextL, hdcBack, 350, 220, offset szLanB, offset CN_LANB, colGray
        .if peerKnown != 0
            invoke UiTextL, hdcBack, 350, 280, offset szLanF, offset CN_LANF, colFound
            invoke UiTextZ, hdcBack, 530, 280, offset peerIpBuf, colFound
        .else
            invoke UiTextL, hdcBack, 350, 280, offset szLanN, offset CN_LANN, colGray
        .endif
        invoke UiTextL, hdcBack, 350, 360, offset szLanS, offset CN_LANS, colDark
        ; 会话 23：按钮组（开始 400..600 y410..450 / 返回 y460..500，与点击区一致）
        invoke SelectObject, hdcBack, fontSmall
        mov edx, colGray
        .if peerKnown != 0
            mov edx, colHi
        .endif
        mov boxRc.left, 400
        mov boxRc.top, 410
        mov boxRc.right, 600
        mov boxRc.bottom, 450
        invoke FrameRect, hdcBack, addr boxRc, boxCur
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

UR_Done:
    invoke SelectObject, hdcBack, fontOld
    invoke GetDC, hWnd
    mov hdcWin2, eax
    invoke BitBlt, hdcWin2, 0, 0, WND_W, WND_H, hdcBack, 0, 0, SRCCOPY
    invoke ReleaseDC, hWnd, hdcWin2
    ret
UiRender endp

end
