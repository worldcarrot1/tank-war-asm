; ============================================================
; achv.asm -- 会话40：成就系统引擎
;   四稀有度（普通/稀有/史诗/传奇）+ 图鉴翻阅（ui.asm ST_ACHG）
;   + 解锁弹层条 + 落盘持久化（achv.dat）
; 事件驱动：game.asm 各钩子点 invoke AchvEvent, kind, actor, value, victim
;   actor 闸：联机只记 slot0（对端镜像/中继弹不计本机成就）；
;   单机 botMask 命中槽（人机）不记——屠夫不数 AI 的手数。
;   AK_MATCHST 为清场事件（单场击杀/受伤计数归零），不过 actor 闸。
; 存档 v2：'ACHP' + ver(2) + count(24) + 每条 (prog,own,date)（date=yyyymmdd）；
;   解锁即落盘；读档校验 magic/ver/count，坏档弃读不炸；
;   会话41：旧 v1 档（ver1×23 条 8B 行）自动迁移，缺失日期记 0 不显示。
;   achvUnseen=本次运行新解锁数，主菜单图鉴项挂"(新)"角标，进图鉴清零。
; 自测：T51 直调事件机 + 内存 Pack/Unpack（achvNoSave=1 禁写盘）。
; MASM 围裙（本文件全部绕开）：
;   * [base+index] 双寄存器寻址非法 → 打包/解包用指针自增单基址；
;   * mem-to-mem add 非法 → 先落寄存器；
;   * .if 双内存操作数比较由 MASM 自选寄存器装载（可能正踩 eax 里
;     的表指针）→ kind/param 先入 esi/edi 再纯寄存器比；
;   * 返回 eax 的 proc 绝不能 uses eax（uses 表在 ret 前弹回旧值）。
; ============================================================
.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

public AchvInit
public AchvEvent
public AchvSave
public AchvPack
public AchvUnpack
public AchvClear
public AchvGetProg
public AchvGetOwn
public AchvCountOwned
public AchvGetDate
public achvUnseen
public achvDefs
public achvToastId
public achvToastT
public achvNoSave
public achvMatchKills
public achvMatchHurt

extern netMode :dword               ; ui.asm
extern botMask :dword               ; bot.asm
SndPlay PROTO :DWORD                ; sound.asm

ACH_SIZE equ SIZEOF ACHDEF          ; ACHDEF 在 game.inc；8 dd

.data
    ; ---- 英文文案 ----
    szA01N db "OPENING SHOT", 0
    szA01D db "Fire your first bullet", 0
    szA02N db "FIRST BLOOD", 0
    szA02D db "Get your first kill", 0
    szA03N db "FROST SHELL", 0
    szA03D db "Raise the ice shield", 0
    szA04N db "COLD START", 0
    szA04D db "Burn nitro once", 0
    szA05N db "WATER WALKER", 0
    szA05D db "Use water once", 0
    szA06N db "COLLECTOR", 0
    szA06D db "Pick up 10 items", 0
    szA07N db "BOUNTY HUNTER", 0
    szA07D db "25 kills in total", 0
    szA08N db "ICE GUARD", 0
    szA08D db "Block 10 shots with shield", 0
    szA09N db "MINE LAYER", 0
    szA09D db "Lay 10 mines", 0
    szA10N db "GHOST DANCER", 0
    szA10D db "Use phantom 5 times", 0
    szA11N db "PAYBACK", 0
    szA11D db "Kill the rival who got you last", 0
    szA12N db "BEAM ROOKIE", 0
    szA12D db "Fire the laser 5 times", 0
    szA13N db "PENTA STRIKE", 0
    szA13D db "5 kills in one match", 0
    szA14N db "FLAWLESS", 0
    szA14D db "Win a match unhurt", 0
    szA15N db "VETERAN", 0
    szA15D db "Win 20 matches", 0
    szA16N db "SWAP MASTER", 0
    szA16D db "Finish 5 swaps", 0
    szA17N db "MINE LORD", 0
    szA17D db "Kill 5 with mines", 0
    szA18N db "NET ROOKIE", 0
    szA18D db "Win an online match", 0
    szA19N db "BLACK MEDAL", 0
    szA19D db "Beat the black bot", 0
    szA20N db "EIGHTFOLD SLAUGHTER", 0
    szA20D db "8 kills in one match", 0
    szA21N db "THE BUTCHER", 0
    szA21D db "200 kills in total", 0
    szA22N db "BLOWOUT", 0
    szA22D db "Win with zero on the rival", 0
    szA23N db "BULLET SEA", 0
    szA23D db "Fire 1000 shots", 0
    szA24N db "WIND CHASER", 0          ; 会话41：稀有末位增条（氮气 50 次）
    szA24D db "Burn 50 nitro charges", 0

    ; ---- 中文文案（tools/gen_achv_cn.py 生成）----
    CN_ACH01N dw 9996h,5F00h,950Bh,8292h, 0
    CN_ACH01D dw 6253h,51FAh,7B2Ch,4E00h,53D1h,5B50h,5F39h, 0
    CN_ACH02N dw 9996h,6740h, 0
    CN_ACH02D dw 5B8Ch,6210h,7B2Ch,4E00h,6B21h,51FBh,6740h, 0
    CN_ACH03N dw 5BD2h,971Ch,62A4h,4F53h, 0
    CN_ACH03D dw 53D1h,52A8h,4E00h,6B21h,51B0h,76FEh, 0
    CN_ACH04N dw 75BEh,98CEh,8D77h,6B65h, 0
    CN_ACH04D dw 4F7Fh,7528h,4E00h,6B21h,6C2Eh,6C14h, 0
    CN_ACH05N dw 9047h,6C34h,53E0h,6865h, 0
    CN_ACH05D dw 4F7Fh,7528h,4E00h,6B21h,9A6Dh,6C34h, 0
    CN_ACH06N dw 62FEh,8352h,65B0h,624Bh, 0
    CN_ACH06D dw 62FEh,53D6h,5341h,4EF6h,9053h,5177h, 0
    CN_ACH07N dw 8D4Fh,91D1h,730Eh,4EBAh, 0
    CN_ACH07D dw 7D2Fh,8BA1h,51FBh,6740h,4E8Ch,5341h,4E94h,4EBAh, 0
    CN_ACH08N dw 788Eh,51B0h,5B88h,536Bh, 0
    CN_ACH08D dw 51B0h,76FEh,6321h,4E0Bh,5341h,53D1h,5F39h, 0
    CN_ACH09N dw 5E03h,96F7h,80FDh,624Bh, 0
    CN_ACH09D dw 5E03h,4E0Bh,5341h,9897h,5730h,96F7h, 0
    CN_ACH10N dw 5E7Dh,5F71h,884Ch,8005h, 0
    CN_ACH10D dw 5B9Ah,683Ch,865Ah,5F71h,4E94h,6B21h, 0
    CN_ACH11N dw 4EE5h,7259h,8FD8h,7259h, 0
    CN_ACH11D dw 61FBh,6740h,4E0Ah,6B21h,5E26h,8D70h,4F60h,7684h,5BF9h,624Bh, 0
    CN_ACH12N dw 6FC0h,5149h,521Dh,8BD5h, 0
    CN_ACH12D dw 53D1h,5C04h,4E94h,6B21h,6FC0h,5149h, 0
    CN_ACH13N dw 4E94h,8FDEh,7EDDh,4E16h, 0
    CN_ACH13D dw 5355h,573Ah,51FBh,6740h,4E94h,4EBAh, 0
    CN_ACH14N dw 5B8Ch,7F8Eh,593Ah,51A0h, 0
    CN_ACH14D dw 96F6h,53D7h,4F24h,5BB3h,8D62h,4E0Bh,4E00h,573Ah, 0
    CN_ACH15N dw 767Eh,6218h,8001h,5175h, 0
    CN_ACH15D dw 7D2Fh,8BA1h,593Ah,51A0h,4E8Ch,5341h,573Ah, 0
    CN_ACH16N dw 6362h,4F4Dh,5927h,5E08h, 0
    CN_ACH16D dw 6362h,4F4Dh,6210h,4EA4h,4E94h,6B21h, 0
    CN_ACH17N dw 96F7h,72F1h,9886h,4E3Bh, 0
    CN_ACH17D dw 5730h,96F7h,51FBh,6740h,4E94h,4EBAh, 0
    CN_ACH18N dw 7F51h,53CBh,9996h,80DCh, 0
    CN_ACH18D dw 8054h,673Ah,6A21h,5F0Fh,8D62h,4E00h,573Ah, 0
    CN_ACH19N dw 9ED1h,8272h,52CBh,7AE0h, 0
    CN_ACH19D dw 51FBh,8D25h,9ED1h,8272h,4EBAh,673Ah, 0
    CN_ACH20N dw 516Bh,65B9h,5C60h,573Ah, 0
    CN_ACH20D dw 5355h,573Ah,51FBh,6740h,516Bh,4EBAh, 0
    CN_ACH21N dw 5C60h,592Bh, 0
    CN_ACH21D dw 7D2Fh,8BA1h,51FBh,6740h,4E24h,767Eh,4EBAh, 0
    CN_ACH22N dw 78BEh,538Bh,96F6h,5C01h, 0
    CN_ACH22D dw 5BF9h,624Bh,96F6h,5206h,593Ah,51A0h, 0
    CN_ACH23N dw 5F39h,5E55h,5927h,6D77h, 0
    CN_ACH23D dw 7D2Fh,8BA1h,5F00h,706Bh,4E00h,5343h,53D1h, 0
    CN_ACH24N dw 8FFDh,98CEh,8005h, 0                      ; 追风者
    CN_ACH24D dw 7D2Fh,8BA1h,4F7Fh,7528h,4E94h,5341h,6B21h,6C2Eh,6C14h, 0

    ; ---- 成就定义表（顺序即图鉴顺序；ACH_COUNT 须与条数一致）----
    ;        kind, param, goal, rarity, nameEN, nameCN, descEN, descCN
    achvDefs ACHDEF <AK_SHOT, 0, 1, RAR_COM, OFFSET szA01N, OFFSET CN_ACH01N, OFFSET szA01D, OFFSET CN_ACH01D>
    ACHDEF <AK_KILL, WP_ANY, 1, RAR_COM, OFFSET szA02N, OFFSET CN_ACH02N, OFFSET szA02D, OFFSET CN_ACH02D>
    ACHDEF <AK_SKILL, SK_ICE_SHIELD, 1, RAR_COM, OFFSET szA03N, OFFSET CN_ACH03N, OFFSET szA03D, OFFSET CN_ACH03D>
    ACHDEF <AK_SKILL, SK_NITRO, 1, RAR_COM, OFFSET szA04N, OFFSET CN_ACH04N, OFFSET szA04D, OFFSET CN_ACH04D>
    ACHDEF <AK_SKILL, SK_WATER, 1, RAR_COM, OFFSET szA05N, OFFSET CN_ACH05N, OFFSET szA05D, OFFSET CN_ACH05D>
    ACHDEF <AK_PICKUP, 0, 10, RAR_COM, OFFSET szA06N, OFFSET CN_ACH06N, OFFSET szA06D, OFFSET CN_ACH06D>
    ACHDEF <AK_KILL, WP_ANY, 25, RAR_RARE, OFFSET szA07N, OFFSET CN_ACH07N, OFFSET szA07D, OFFSET CN_ACH07D>
    ACHDEF <AK_BLOCK, 0, 10, RAR_RARE, OFFSET szA08N, OFFSET CN_ACH08N, OFFSET szA08D, OFFSET CN_ACH08D>
    ACHDEF <AK_SKILL, SK_MINE, 10, RAR_RARE, OFFSET szA09N, OFFSET CN_ACH09N, OFFSET szA09D, OFFSET CN_ACH09D>
    ACHDEF <AK_SKILL, SK_PHANTOM, 5, RAR_RARE, OFFSET szA10N, OFFSET CN_ACH10N, OFFSET szA10D, OFFSET CN_ACH10D>
    ACHDEF <AK_REVENGE, 0, 1, RAR_RARE, OFFSET szA11N, OFFSET CN_ACH11N, OFFSET szA11D, OFFSET CN_ACH11D>
    ACHDEF <AK_LASER, 0, 5, RAR_RARE, OFFSET szA12N, OFFSET CN_ACH12N, OFFSET szA12D, OFFSET CN_ACH12D>
    ACHDEF <AK_SKILL, SK_NITRO, 50, RAR_RARE, OFFSET szA24N, OFFSET CN_ACH24N, OFFSET szA24D, OFFSET CN_ACH24D>
    ACHDEF <AK_MKILL, 0, 5, RAR_EPIC, OFFSET szA13N, OFFSET CN_ACH13N, OFFSET szA13D, OFFSET CN_ACH13D>
    ACHDEF <AK_FLAWLESS, 0, 1, RAR_EPIC, OFFSET szA14N, OFFSET CN_ACH14N, OFFSET szA14D, OFFSET CN_ACH14D>
    ACHDEF <AK_WIN, WM_ANY, 20, RAR_EPIC, OFFSET szA15N, OFFSET CN_ACH15N, OFFSET szA15D, OFFSET CN_ACH15D>
    ACHDEF <AK_SWAP, 0, 5, RAR_EPIC, OFFSET szA16N, OFFSET CN_ACH16N, OFFSET szA16D, OFFSET CN_ACH16D>
    ACHDEF <AK_KILL, WP_MINE, 5, RAR_EPIC, OFFSET szA17N, OFFSET CN_ACH17N, OFFSET szA17D, OFFSET CN_ACH17D>
    ACHDEF <AK_WIN, WM_NET, 1, RAR_EPIC, OFFSET szA18N, OFFSET CN_ACH18N, OFFSET szA18D, OFFSET CN_ACH18D>
    ACHDEF <AK_WIN, WM_BOT, 1, RAR_LEG, OFFSET szA19N, OFFSET CN_ACH19N, OFFSET szA19D, OFFSET CN_ACH19D>
    ACHDEF <AK_MKILL, 0, 8, RAR_LEG, OFFSET szA20N, OFFSET CN_ACH20N, OFFSET szA20D, OFFSET CN_ACH20D>
    ACHDEF <AK_KILL, WP_ANY, 200, RAR_LEG, OFFSET szA21N, OFFSET CN_ACH21N, OFFSET szA21D, OFFSET CN_ACH21D>
    ACHDEF <AK_SHUTOUT, 0, 1, RAR_LEG, OFFSET szA22N, OFFSET CN_ACH22N, OFFSET szA22D, OFFSET CN_ACH22D>
    ACHDEF <AK_SHOT, 0, 1000, RAR_LEG, OFFSET szA23N, OFFSET CN_ACH23N, OFFSET szA23D, OFFSET CN_ACH23D>

    achvProg       dd ACH_COUNT dup (0)   ; 计数类=累计；瞬时类=0/1；单场类=峰值
    achvOwn        dd ACH_COUNT dup (0)   ; 1=已解锁
    achvMatchKills dd 0                  ; 本场击杀（五连/八方判定用）
    achvMatchHurt  dd 0                  ; 本场受伤害次数（完美夺冠用）
    killedBy       dd MAX_PLAYERS dup (-1) ; 击杀台账：槽 X 上次被谁带走（以牙还牙）
    achvTimeScr    dd 4 dup (0)            ; SYSTEMTIME 落地暂存（GetLocalTime，会话41）
    achvScrIdx     dd 0                    ; 会话41：API 调用间保 idx（ECX/EDX 对 Win32 call 是易失）
    achvDate       dd ACH_COUNT dup (0)   ; 解锁日期 yyyymmdd（会话41；0=未知/旧档）
    achvUnseen     dd 0                   ; 本次运行新解锁未读（图鉴项角标，会话41）
    achvToastId    dd -1                  ; 弹层成就号（ui 渲染）
    achvToastT     dd 0                   ; 弹层剩余 tick（UiTick 递减）
    achvNoSave     dd 0                   ; 1=selftest 禁写盘
    achvFileBuf    dd (3 + 3*ACH_COUNT + 2) dup (0)   ; 308B >= v2 包体 300B
    szAchvPath     db "achv.dat", 0
    achvWrTmp      dd 0                   ; Read/WriteFile 传输字节数出参

.code

; ------------------------------------------------------------
; AchvIsLocal —— actor 是否本机可记玩家：eax=1/0
; 联机：只有 slot0（对端不写本机成就）；单机：botMask 命中槽不记。
; 负数 actor 无符号比较天然 >= MAX_PLAYERS，一并拒。
; ------------------------------------------------------------
AchvIsLocal proc uses ecx edx, actor: dword
    mov eax, actor
    .if eax >= MAX_PLAYERS
        xor eax, eax
        ret
    .endif
    .if netMode != 0
        .if eax == PLAYER_SELF
            mov eax, 1
        .else
            xor eax, eax
        .endif
        ret
    .endif
    mov edx, botMask
    bt edx, eax
    jc AL_Bot
    mov eax, 1
    ret
AL_Bot:
    xor eax, eax
    ret
AchvIsLocal endp

; ------------------------------------------------------------
; AchvUnlock —— idx 解锁：标记 + 弹层 + 音效 + 落盘（可关）
; uses：SndPlay/AchvSave 会碾 eax/ecx/edx，AEBump 循环计数 ecx 全指望
; 这份保存名单。无返回值，uses eax 无碍。
; ------------------------------------------------------------
AchvUnlock proc uses eax ecx edx, idx: dword
    mov ecx, idx
    .if achvOwn[ecx*4] == 0
        mov edx, 1
        mov achvOwn[ecx*4], edx
        mov achvToastId, ecx
        mov edx, 240
        mov achvToastT, edx
        inc achvUnseen                     ; 会话41：主菜单"(新)"角标计数
        ; 解锁日 yyyymmdd 打包（GetLocalTime；异常时钟也无害，仅显示用）
        ; 教训（会话41 AV 复盘）：ECX/EDX 是 Win32 易失寄存器，时间类 API 走
        ; ntdll 共享数据快路径尤甚——invoke 后不得直接信调用前装载的 ecx/edx。
        mov achvScrIdx, ecx                ; idx 存证，跨 invoke 重载
        invoke GetLocalTime, OFFSET achvTimeScr
        movzx eax, word ptr achvTimeScr        ; wYear @0
        imul eax, eax, 10000
        movzx edx, word ptr achvTimeScr+2      ; wMonth @2
        imul edx, edx, 100
        add eax, edx
        movzx edx, word ptr achvTimeScr+6      ; wDay @6
        add eax, edx
        mov ecx, achvScrIdx
        mov achvDate[ecx*4], eax
        ; 品阶号角：15+rar（普通双叮/稀有四音/史诗五音/传奇七音）
        mov eax, ecx
        imul eax, eax, ACH_SIZE
        add eax, OFFSET achvDefs
        mov edx, (ACHDEF ptr [eax]).rarity
        add edx, 15
        invoke SndPlay, edx
        .if achvNoSave == 0
            call AchvSave
        .endif
    .endif
    ret
AchvUnlock endp

; ------------------------------------------------------------
; AEBump —— 扫描匹配 kind 且 param 兼容的未解锁成就：
;   addv != 0：prog += addv（计数类）
;   addv == 0：prog = max(prog, setv)（瞬时标记/单场峰值）
; 过 goal 线即 AchvUnlock。param 兼容：def.param == -1（WP_ANY 通配）
; 或 def.param == paramVal。AK_WIN 的"专项档+通用档"由 AchvEvent 调
; 两次完成（WM_ANY=0 不是 -1，通配不误伤，两拨各中各的行不双计）。
; 围裙：kind/paramVal 先入 esi/edi——.if 内存对内存会被 MASM 塞进
; 寄存器，而 eax 正驮着表项指针。
; ------------------------------------------------------------
AEBump proc uses eax ecx edx esi edi, paramVal: dword, addv: dword, setv: dword, kindv: dword
    mov esi, kindv
    mov edi, paramVal
    xor ecx, ecx
AEB_Loop:
    .if ecx >= ACH_COUNT
        ret
    .endif
    mov eax, ecx
    imul eax, eax, ACH_SIZE
    add eax, OFFSET achvDefs
    mov edx, (ACHDEF ptr [eax]).kind
    .if edx == esi
        .if achvOwn[ecx*4] == 0
            mov edx, (ACHDEF ptr [eax]).param
            .if edx == -1
                jmp AEB_Do
            .endif
            .if edx == edi
AEB_Do:
                .if addv != 0
                    mov eax, addv
                    add achvProg[ecx*4], eax
                .else
                    mov eax, setv
                    cmp achvProg[ecx*4], eax
                    jge AEB_Goal
                    mov achvProg[ecx*4], eax
                .endif
AEB_Goal:
                mov eax, ecx
                imul eax, eax, ACH_SIZE
                add eax, OFFSET achvDefs
                mov edx, (ACHDEF ptr [eax]).goal
                cmp achvProg[ecx*4], edx
                jl AEB_Next
                invoke AchvUnlock, ecx
            .endif
        .endif
    .endif
AEB_Next:
    inc ecx
    jmp AEB_Loop
AEBump endp

; ------------------------------------------------------------
; AchvEvent —— 成就事件入口（pushad/popad：钩子点散布对局热路径，
; 开火/伤害/拾取循环里的寄存器一个都不能丢）
; 入：kind, actor, value；除 AK_MATCHST 外一律先过 actor 闸
; ------------------------------------------------------------
AchvEvent proc kind: dword, actor: dword, value: dword, vict: dword
    mov eax, kind
    .if eax == AK_MATCHST
        mov achvMatchKills, 0
        mov achvMatchHurt, 0
        mov eax, MAX_PLAYERS             ; 击杀台账复位为哨兵（永不等真槽位）
        mov killedBy[0], eax             ; MAX_PLAYERS=4 四条硬写（game.inc 改值须同步）
        mov killedBy[4], eax
        mov killedBy[8], eax
        mov killedBy[12], eax
        ret
    .endif
    pushad
    mov ebx, kind
    mov esi, vict
    mov edi, actor
    .if ebx == AK_KILL                   ; 台账先记再过闸：联机被对端/人机带走也留痕，
        .if edi < MAX_PLAYERS && esi < MAX_PLAYERS   ;   复仇一击才能对上"上次带走我的人"
            mov eax, edi
            mov killedBy[esi*4], eax
        .endif
    .endif
    invoke AchvIsLocal, edi
    .if eax != 0
        .if ebx == AK_SHOT
            invoke AEBump, 0, 1, 0, AK_SHOT
        .elseif ebx == AK_PICKUP
            invoke AEBump, 0, 1, 0, AK_PICKUP
        .elseif ebx == AK_BLOCK
            invoke AEBump, 0, 1, 0, AK_BLOCK
        .elseif ebx == AK_SWAP
            invoke AEBump, 0, 1, 0, AK_SWAP
        .elseif ebx == AK_LASER
            invoke AEBump, 0, 1, 0, AK_LASER
        .elseif ebx == AK_SKILL
            invoke AEBump, value, 1, 0, AK_SKILL
        .elseif ebx == AK_KILL
            inc achvMatchKills
            mov eax, killedBy[edi*4]
            .if eax == esi               ; 本受害者恰是上次带走我的凶手
                invoke AEBump, 0, 0, 1, AK_REVENGE
            .endif
            invoke AEBump, value, 1, 0, AK_KILL
            mov eax, achvMatchKills
            invoke AEBump, 0, 0, eax, AK_MKILL
        .elseif ebx == AK_HURT
            inc achvMatchHurt
        .elseif ebx == AK_WIN
            ; mode：联机=WM_NET；单机有 bot 在场=WM_BOT；其余 WM_ANY。
            ; 先拨专项档再拨通用档。
            mov ecx, WM_ANY
            .if netMode != 0
                mov ecx, WM_NET
            .else
                mov eax, botMask
                .if eax != 0
                    mov ecx, WM_BOT
                .endif
            .endif
            .if ecx != WM_ANY
                invoke AEBump, ecx, 1, 0, AK_WIN
            .endif
            invoke AEBump, WM_ANY, 1, 0, AK_WIN
            .if achvMatchHurt == 0
                invoke AEBump, 0, 0, 1, AK_FLAWLESS
            .endif
            .if value == 0
                invoke AEBump, 0, 0, 1, AK_SHUTOUT
            .endif
        .endif
    .endif
    popad
    ret
AchvEvent endp

; ------------------------------------------------------------
; AchvPack v2 —— 'ACHP'+ver(2)+count+每条(prog,own,date)（会话41）
; 出：eax=字节数（返回 eax 故 uses 名单绝不带 eax）。
; 指针自增单基址寻址（[edi+edx] 双寄存器非法）。
; ------------------------------------------------------------
AchvPack proc uses ecx edx edi, pBuf: dword
    mov edi, pBuf
    mov dword ptr [edi], 'ACHP'
    mov dword ptr [edi+4], 2
    mov dword ptr [edi+8], ACH_COUNT
    add edi, 12
    xor ecx, ecx
AP_Loop:
    .if ecx >= ACH_COUNT
        mov eax, 12 + ACH_COUNT*12
        ret
    .endif
    mov eax, achvProg[ecx*4]
    mov [edi], eax
    mov eax, achvOwn[ecx*4]
    mov [edi+4], eax
    mov eax, achvDate[ecx*4]
    mov [edi+8], eax
    add edi, 12
    inc ecx
    jmp AP_Loop
AchvPack endp

; ------------------------------------------------------------
; AchvUnpack —— 校验并回灌；坏档返回 0 且零写入（半包/篡改免疫）。
; own 一律归一化 0/1（脏档大数不污染图鉴渲染分支）。
; 会话41：ver2=全量 12B 行；ver1×(ACH_COUNT-1)=旧 23 条 8B 行档迁移，
;   旧行 0..11 原位、12..22 后移一格回填 prog/own，插入行 idx12 从零起步、
;   全表 date 置 0（迁移不造假日期）。
; 出：eax=1 成功 / 0 拒绝
; ------------------------------------------------------------
AchvUnpack proc uses ecx edx esi, pBuf: dword
    mov esi, pBuf
    cmp dword ptr [esi], 'ACHP'
    jne AU_Bad
    cmp dword ptr [esi+8], ACH_COUNT
    jne AU_TryV1
    cmp dword ptr [esi+4], 2
    jne AU_Bad
    add esi, 12
    xor ecx, ecx
AU_Loop:
    .if ecx >= ACH_COUNT
        mov eax, 1
        ret
    .endif
    mov eax, [esi]
    mov achvProg[ecx*4], eax
    mov eax, [esi+4]
    .if eax != 0
        mov eax, 1
    .endif
    mov achvOwn[ecx*4], eax
    mov eax, [esi+8]
    mov achvDate[ecx*4], eax
    add esi, 12
    inc ecx
    jmp AU_Loop
AU_TryV1:
    cmp dword ptr [esi+4], 1
    jne AU_Bad
    cmp dword ptr [esi+8], ACH_COUNT-1
    jne AU_Bad
    mov edx, esi
    add edx, 12                        ; edx=旧 8B 行游标
    xor ecx, ecx
AU1_Loop:
    .if ecx >= ACH_COUNT
        mov eax, 1
        ret
    .endif
    .if ecx == 12                      ; 新插行（idx12 追风者）从零起步
        mov achvProg[ecx*4], 0
        mov achvOwn[ecx*4], 0
    .else                              ; 旧行 0..11/12..22 -> 新 0..11/13..23
        mov eax, [edx]
        mov achvProg[ecx*4], eax
        mov eax, [edx+4]
        .if eax != 0
            mov eax, 1
        .endif
        mov achvOwn[ecx*4], eax
        add edx, 8
    .endif
    mov achvDate[ecx*4], 0
    inc ecx
    jmp AU1_Loop
AU_Bad:
    xor eax, eax
    ret
AchvUnpack endp

; ------------------------------------------------------------
; AchvSave —— 全量落盘（CREATE_ALWAYS 整写；失败静默）
; ------------------------------------------------------------
AchvSave proc uses eax ecx edx esi
    .if achvNoSave != 0
        ret
    .endif
    invoke AchvPack, OFFSET achvFileBuf
    mov esi, eax
    invoke CreateFileA, OFFSET szAchvPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .if eax != INVALID_HANDLE_VALUE
        push eax
        invoke WriteFile, eax, OFFSET achvFileBuf, esi, OFFSET achvWrTmp, NULL
        pop ecx
        invoke CloseHandle, ecx
    .endif
    ret
AchvSave endp

; ------------------------------------------------------------
; AchvInit —— 启动读档（无档=首次游玩，静默零态；坏档弃读）。
; 短读时数组尾部还是全零 achvFileBuf 旧值，own=0 不产生假解锁。
; ------------------------------------------------------------
AchvInit proc uses eax ecx edx esi
    invoke CreateFileA, OFFSET szAchvPath, GENERIC_READ, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL
    .if eax != INVALID_HANDLE_VALUE
        push eax
        invoke ReadFile, eax, OFFSET achvFileBuf, 12 + ACH_COUNT*12, OFFSET achvWrTmp, NULL
        pop ecx
        invoke CloseHandle, ecx
        invoke AchvUnpack, OFFSET achvFileBuf
    .endif
    ret
AchvInit endp

; ------------------------------------------------------------
; 自测/图鉴查询助手（内存直读，越界返回 0；负数无符号天然越界）
; ------------------------------------------------------------
AchvGetProg proc idx: dword
    mov eax, idx
    .if eax >= ACH_COUNT
        xor eax, eax
        ret
    .endif
    mov eax, achvProg[eax*4]
    ret
AchvGetProg endp

AchvGetOwn proc idx: dword
    mov eax, idx
    .if eax >= ACH_COUNT
        xor eax, eax
        ret
    .endif
    mov eax, achvOwn[eax*4]
    ret
AchvGetOwn endp

; AchvGetDate —— 会话41：解锁日期 yyyymmdd（未解锁/旧档迁移=0）
AchvGetDate proc idx: dword
    mov eax, idx
    .if eax >= ACH_COUNT
        xor eax, eax
        ret
    .endif
    mov eax, achvDate[eax*4]
    ret
AchvGetDate endp

AchvCountOwned proc uses edx
    xor edx, edx
    xor ecx, ecx
ACO_Loop:
    .if ecx >= ACH_COUNT
        mov eax, edx
        ret
    .endif
    .if achvOwn[ecx*4] != 0
        inc edx
    .endif
    inc ecx
    jmp ACO_Loop
AchvCountOwned endp

AchvClear proc
    mov achvUnseen, 0                  ; 会话41：清库连未读角标一起清
    xor ecx, ecx
ACl_Loop:
    .if ecx >= ACH_COUNT
        ret
    .endif
    mov achvProg[ecx*4], 0
    mov achvOwn[ecx*4], 0
    mov achvDate[ecx*4], 0
    inc ecx
    jmp ACl_Loop
AchvClear endp

end
