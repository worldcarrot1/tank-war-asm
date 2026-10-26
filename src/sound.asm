; ============================================================
; sound.asm —— 音效 = CC0 采样内嵌 + BGM 程序化八音盒
; 会话43：18 个音效全部换成真实 8-bit/电子采样——Juhani Junkala
; 《The Essential Retro Video Game Sound Effects Collection [512
; sounds]》（opengameart.org，CC0 公共领域，可商用免署名）。
; 由 tools/gen_sfx43.py 转成 22050Hz/8-bit（静音位128）WAV 镜像
; 内嵌于 inc/sfxdata.inc，SndInit 不再运行时生成音效。
; 会话42 的程序化芯片音生成例程（GenPulse/GenSlide* 等）保留，
; BGM 仍走八音盒程序化生成（bgmBuf/bgmBufG，waveOut 独立流）。
; 启动时生成：BGM 整循环样本填 bgmBuf，同时留档
; %TEMP%\tankwar_bgm.wav（仅排障用）；音效生成到内存 buffer
; （PlaySound SND_MEMORY 异步）。
; 会话 26：BGM 改走 waveOut 独立流（PlaySound 只有单一全局
; 通道，任何音效都会把 SND_LOOP 的 BGM 掐死——"退出到主页面
; 音乐突然消失"元凶）；waveOut 流与 PlaySound 音效流并存，
; 由系统混音。音量经 waveOutSetVolume 全局主音量（两路同受）；
; 音效开关 sfxOn（ui.asm）。
; ============================================================
.586
.model flat, stdcall
option casemap:none

include win32.inc

public SndInit
public SndBgmStart
public SndBgmSetTrack
public SndPlay
public SndVolume

PlaySoundA              PROTO stdcall :DWORD,:DWORD,:DWORD
waveOutSetVolume        PROTO stdcall :DWORD,:DWORD
waveOutOpen             PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
waveOutClose            PROTO stdcall :DWORD
waveOutReset            PROTO stdcall :DWORD
waveOutPrepareHeader    PROTO stdcall :DWORD,:DWORD,:DWORD
waveOutWrite            PROTO stdcall :DWORD,:DWORD,:DWORD
GetEnvironmentVariableA PROTO stdcall :DWORD,:DWORD,:DWORD
lstrcatA                PROTO stdcall :DWORD,:DWORD
extern sfxOn            :dword        ; 音效开关（ui.asm）

SND_ASYNC        equ 0001h
SND_NODEFAULT    equ 0002h
SND_MEMORY       equ 0004h
SND_LOOP         equ 0008h
SND_FILENAME     equ 20000h
GENERIC_WRITE    equ 40000000h
CREATE_ALWAYS    equ 2

SR               equ 22050             ; 采样率
AMP_HI           equ 144               ; 方波高电平（0x90，约 60% 满幅）
AMP_LO           equ 48                ; 低电平（0x30）

; 音效编号
SND_SHOT         equ 1
SND_BOOM         equ 2
SND_PICK         equ 3
SND_COUNT        equ 4
SND_SWAP         equ 5
SND_MINE         equ 6                 ; 布雷确认（会话 23 新增）
SND_LASER        equ 7                 ; 激光发射（会话 33 新增）
SND_SHIELD       equ 8                 ; 冰盾发动（会话 39 新增）
SND_SHATTER      equ 9                 ; 冰盾碎裂/到期（会话 39：用户点名"冰碎声"）
SND_GHOSTSND     equ 10                ; 穿墙发动（会话 39 新增）
SND_NITROSND     equ 11                ; 燃油加速发动（会话 39 新增）
SND_WATERSND     equ 12                ; 驭水发动·水花（会话 39 新增）
SND_SWAPFIRE     equ 13                ; 换位弹出手/换位成功嗖声（会话 39 新增）
SND_AIMSND       equ 14                ; 激光一段起瞄双哔（会话 39 新增）
SND_ACH        equ 15                ; 成就解锁号角·普通档（会话 40；会话 41 按品阶分 15..18）
SND_ACH1       equ 16                ; 稀有档（原 C 大调四音）
SND_ACH2       equ 17                ; 史诗档（五音入第二八度）
SND_ACH3       equ 18                ; 传奇档（七音上行+高八度长尾）

NOTE_SHOT        equ 2646              ; 0.12s
; 击败音（会话 26 重制）：PvZ 小丑盒子"开箱"质感 = 盒盖弹开短滑音
; + 八音盒上行颤音 14 音 + 落盖噪声尾巴。总长 BK_POP+BK_PING*BK_NC+BK_POOF
BK_POP           equ 220               ; 0.010s 弹开
BK_PING          equ 480               ; 0.022s 每音
BK_NC            equ 14                ; 音数
BK_POOF          equ 640               ; 0.029s 落盖噪声
NOTE_BOOM        equ BK_POP + BK_PING*BK_NC + BK_POOF   ; 7580 ≈ 0.34s
NOTE_HALF        equ 1652              ; 0.075s
NOTE_CNT         equ 2205              ; 0.10s
NOTE_THIRD       equ 1101              ; 0.05s
NOTE_LASR        equ 3969              ; 0.18s 激光啸（会话 33）

.data
    align 4
    bgmPath     db 260 dup (0)
    tagBgm      db "\tankwar_bgm.wav", 0
    envTag      db "TEMP", 0
    ; 音效内存镜像（44 字节 WAV 头 + PCM）——会话43：18 个音效全部改为
    ; 内嵌 CC0 采样静态表（inc/sfxdata.inc，Juhani Junkala 512 音效包，
    ; 44100/16bit 源 2:1 降采样到 22050/8bit 静音位128 摆幅±112，含淡入淡出
    ; 防爆音咔哒）。生成脚本 tools/gen_sfx43.py，重生成后无需动本文件。
    ; BGM（bgmBuf/bgmBufG）仍为程序化八音盒，运行时生成不变。
    include sfxdata.inc
    hdrBuf      db 44 dup (0)       ; BGM 文件头
    rngSt       dd 12345            ; 噪声 LCG
    tmpAcc      dd 0                ; 滑频相位累积
    phFl        dd 0                ; 方波电平
    wrBytes     dd 0
    hFile       dd 0
    ; 会话 28：主页主题"连奏化"（玩家反馈断断续续）——64 拍全连通
    ; 无休止（旧版每拍尾衰减到 0 + 大量 0 休止造成空洞；配合 GenAdd
    ; 包络托底 35%），级进+琶音交替上行下折；低音轨维持 8 分根音
    bgmMel      dd 440, 523, 659, 880, 659, 880, 1046, 880
                dd 659, 523, 659, 880, 1046, 880, 659, 523
                dd 440, 523, 698, 880, 698, 523, 440, 523
                dd 698, 880, 1046, 880, 698, 523, 440, 349
                dd 523, 659, 784, 1046, 784, 659, 523, 659
                dd 784, 1046, 1318, 1046, 784, 659, 523, 587
                dd 587, 784, 988, 784, 587, 494, 392, 494
                dd 587, 784, 988, 1175, 988, 784, 587, 494
    bgmBass     dd 110, 0, 110, 0, 110, 0, 110, 0, 110, 0, 110, 0, 110, 0, 110, 0
                dd 87, 0, 87, 0, 87, 0, 87, 0, 87, 0, 87, 0, 87, 0, 87, 0
                dd 131, 0, 131, 0, 131, 0, 131, 0, 131, 0, 131, 0, 131, 0, 131, 0
                dd 98, 0, 98, 0, 98, 0, 98, 0, 98, 0, 98, 0, 98, 0, 98, 0
    bgmN        = 64
    ; 会话 29 对战轨：玩家嫌旧 32 音跑动主题"太吵"，改轻音乐——
    ; 16 音 ×0.3s ×2 遍（与主页轨等长 9.6s），C-G-Am-F 五声级进、
    ; 中低声区，正弦波叠加（GenSoft，抛物线半周近似），旋律摆幅 28 /
    ; 低音摆幅 12（主页方波轨是 44/16），整体更静更柔
    gameMel     dd 330, 392, 392, 440, 440, 330, 349, 294
                dd 523, 392, 494, 392, 440, 330, 349, 262
    gameBass    dd 131, 98, 110, 87, 131, 98, 110, 87
    gameN       = 16                  ; 旋律音数/遍
    gameBassN   = 8                   ; 低音根数/遍（每根盖两旋律音）
    gameReps    = 2
NOTE_SAMP       equ 3307              ; 一拍 0.15s @ 22050
GAME_SAMP       equ NOTE_SAMP*2       ; 会话 29 轻音乐半速：一音 0.3s
BGM_TOTAL       equ bgmN*NOTE_SAMP    ; 211648 字节

; ---- 会话 26：BGM 独立 waveOut 流（与 PlaySound 音效混音并存）----
WAVE_MAPPER     equ 0FFFFFFFFh
WHDR_BEGINLOOP  equ 0004h
WHDR_ENDLOOP    equ 0008h

.data
    align 4
    bgmBuf      db BGM_TOTAL dup (?)  ; 主页主题（双轨合成）waveOut 缓冲
    bgmBufG     db BGM_TOTAL dup (?)  ; 会话 29 对战轨（轻音乐 16 音正弦×2）
    bgmDev      dd 0                  ; HWAVEOUT
    bgmLive     dd 0                  ; 1=独立流已在播
    bgmTrk      dd -1                 ; 当前曲目：-1 未开流 / 0 主页 / 1 对战
    bgmHdr      dd 0                  ; WAVEHDR(x86, 32B)：lpData /
            dd 0, 0, 0                ;  dwBufferLength / dwBytesRecorded /
            dd 0, 0, 0, 0             ;  dwUser / dwFlags / dwLoops /
                                      ;  lpNext / reserved
    bgmHdrG     dd 0                  ; 对战轨 WAVEHDR（同布局）
            dd 0, 0, 0
            dd 0, 0, 0, 0
    bgmFmt      dw 1                  ; WAVEFORMATEX(18B)：wFormatTag=PCM
            dw 1                      ;  nChannels=mono
            dd SR                     ;  nSamplesPerSec
            dd SR                     ;  nAvgBytesPerSec（8bit 单声道）
            dw 1                      ;  nBlockAlign
            dw 8                      ;  wBitsPerSample
            dw 0                      ;  cbSize
    ; 八音盒音高表：C6 起上行折返颤音（摇晃开盖的叮当感，14 音）
    bkFreq      dd 1046, 1175, 1318, 1175, 1318, 1568, 1318
                dd 1568, 1760, 1568, 1760, 2093, 1760, 2093

.code

; ------------------------------------------------------------
; WrHead -- 在 pBuf 写 44 字节 PCM WAV 头
; 入参：pBuf, dataSize
; ------------------------------------------------------------
WrHead proc uses edi pBuf: dword, dataSize: dword
    mov edi, pBuf
    mov dword ptr [edi], 'FFIR'          ; "RIFF"（小端反序）
    mov eax, dataSize
    add eax, 36
    mov dword ptr [edi+4], eax
    mov dword ptr [edi+8], 'EVAW'        ; "WAVE"
    mov dword ptr [edi+12], ' tmf'       ; "fmt "
    mov dword ptr [edi+16], 16
    mov word ptr  [edi+20], 1            ; PCM
    mov word ptr  [edi+22], 1            ; mono
    mov dword ptr [edi+24], SR
    mov dword ptr [edi+28], SR           ; byteRate（1 byte/sample）
    mov word ptr  [edi+32], 1            ; blockAlign
    mov word ptr  [edi+34], 8            ; bits
    mov dword ptr [edi+36], 'atad'       ; "data"
    mov eax, dataSize
    mov dword ptr [edi+40], eax
    ret
WrHead endp

; ------------------------------------------------------------
; DecayTail -- pBuf+nSamp 末尾 tail 样本线性衰减（防爆音）
; ------------------------------------------------------------
DecayTail proc uses ebx ecx edx esi pBuf: dword, nSamp: dword, tail: dword
    mov esi, pBuf
    add esi, nSamp                ; 指向结尾
    mov ecx, tail
DT_Loop:
    .if ecx <= 0
        ret
    .endif
    mov eax, ecx
    imul eax, eax, 256
    xor edx, edx
    mov ebx, tail
    div ebx                       ; eax = k*256/tail
    mov ebx, esi
    sub ebx, ecx
    movzx edx, byte ptr [ebx]
    mul edx                       ; eax = sample*k*256/tail
    shr eax, 8
    mov ebx, esi
    sub ebx, ecx
    mov [ebx], al
    dec ecx
    jmp DT_Loop
DecayTail endp

; ------------------------------------------------------------
; GenSquare -- 方波写 pBuf（pBuf, freq, nSamp, tail）
; ------------------------------------------------------------
GenSquare proc uses ebx ecx edx esi pBuf: dword, freq: dword, nSamp: dword, tail: dword
    mov esi, pBuf
    xor ecx, ecx
GS_Loop:
    mov eax, ecx
    mul freq                      ; eax = i*freq（edx 破坏）
    shr eax, 1
    xor edx, edx
    mov ebx, SR
    div ebx
    and eax, 1                    ; 相位方波
    .if eax == 0
        mov byte ptr [esi], AMP_HI
    .else
        mov byte ptr [esi], AMP_LO
    .endif
    inc esi
    inc ecx
    .if ecx < nSamp
        jmp GS_Loop
    .endif
    .if tail != 0
        invoke DecayTail, pBuf, nSamp, tail
    .endif
    ret
GenSquare endp

; ------------------------------------------------------------
; GenSlide -- 频率滑动方波（pBuf, f0, f1, nSamp）
; ------------------------------------------------------------
GenSlide proc uses ebx ecx edx esi pBuf: dword, f0: dword, f1: dword, nSamp: dword
    mov tmpAcc, 0
    mov phFl, 0
    mov esi, pBuf
    xor ecx, ecx
GL_Loop:
    ; f = f0 + (f1-f0)*i/nSamp
    mov eax, f1
    sub eax, f0
    imul eax, ecx
    xor edx, edx
    push ebx
    mov ebx, nSamp
    div ebx
    pop ebx
    add eax, f0
    add tmpAcc, eax               ; 相位累积
    mov eax, tmpAcc
    .if eax >= SR
        sub tmpAcc, SR
        xor phFl, 1               ; 半周期翻转
    .endif
    mov al, AMP_LO
    .if phFl == 0
        mov al, AMP_HI
    .endif
    mov [esi], al
    inc esi
    inc ecx
    .if ecx < nSamp
        jmp GL_Loop
    .endif
    ret
GenSlide endp

; ------------------------------------------------------------
; GenSlideSoft -- 线性滑频正弦绝对写（会话 30 开炮音去刺耳：方波谐波
; 是"刺耳"元凶，改抛物线近似正弦）。每样本相位步进从 (f0<<16)/SR 线性
; 插值到 (f1<<16)/SR；低 16 位=周期内相位；byte = 96 ± amp*近似sin
; ------------------------------------------------------------
GenSlideSoft proc uses ebx ecx edx esi edi pBuf: dword, f0: dword, f1: dword, nSamp: dword
local ph: dword, stepA: dword, dstep: dword
    mov ph, 0
    mov eax, f0
    shl eax, 16
    xor edx, edx
    mov ebx, SR
    div ebx
    mov stepA, eax                  ; 起始每样本相位步进
    mov eax, f1
    shl eax, 16
    xor edx, edx
    mov ebx, SR
    div ebx
    sub eax, stepA
    mov dstep, eax                  ; 步进差（可为负，滑频斜率）
    mov esi, pBuf
    xor ecx, ecx
GLS_Loop:
    mov eax, dstep
    imul eax, ecx
    cdq
    idiv nSamp
    add eax, stepA
    add ph, eax
    mov eax, ph
    and eax, 0FFFFh                 ; p = 周期内相位
    mov edx, 65536
    sub edx, eax
    cmp eax, 32768
    jbe GLS_NoMir
    mov eax, edx
GLS_NoMir:
    mov edx, 32768
    sub edx, eax
    imul eax, edx                   ; u*(32768-u)
    shr eax, 14                     ; ≤16384
    imul eax, 56                    ; 满幅 ±56（96±56=40..152，对齐方波响度）
    shr eax, 14
    mov edx, ph
    and edx, 0FFFFh
    cmp edx, 32768
    jae GLS_Neg
    mov edx, 96
    add edx, eax
    mov [esi], dl
    jmp GLS_N
GLS_Neg:
    mov edx, 96
    sub edx, eax
    mov [esi], dl
GLS_N:
    inc esi
    inc ecx
    cmp ecx, nSamp
    jb GLS_Loop
    ret
GenSlideSoft endp

; ------------------------------------------------------------
; GenNoise -- 白噪声爆炸（pBuf, nSamp），幅度线性衰减
; ------------------------------------------------------------
GenNoise proc uses ebx ecx edx esi pBuf: dword, nSamp: dword
    mov esi, pBuf
    xor ecx, ecx
GN_Loop:
    ; LCG 噪声 64..255
    mov eax, rngSt
    imul eax, eax, 1103515245
    add eax, 12345
    mov rngSt, eax
    xor edx, edx
    mov ebx, 192
    div ebx
    add eax, 64
    mov ebx, eax                  ; ebx = raw
    ; 包络 e = (nSamp-i)*256/nSamp
    mov eax, nSamp
    sub eax, ecx
    imul eax, eax, 256
    xor edx, edx
    push ebx
    mov ebx, nSamp
    div ebx
    pop ebx
    mul ebx                       ; eax = raw * e
    shr eax, 8
    mov [esi], al
    inc esi
    inc ecx
    .if ecx < nSamp
        jmp GN_Loop
    .endif
    ret
GenNoise endp

; ------------------------------------------------------------
; GenAdd -- 方波叠加进 pBuf（会话 27 双轨合成；会话 28 包络托底）：
; 摆幅从 delta 线性衰减到 ~35%（旧版衰减到 0，一拍一坑听着断续），
; 读取现值加/减摆幅，钳位 8..240。静音中心 96。
; 钳位用 jl/jle 显式带符号跳转（.if reg<8 会按无符号编译的陷阱）。
; 入参：pBuf, freq, nSamp, delta
; ------------------------------------------------------------
GenAdd proc uses ebx esi edi edx pBuf: dword, freq: dword, nSamp: dword, delta: dword
    local hiAcc: dword, stepAcc: dword
    mov eax, delta
    imul eax, eax, 256
    mov hiAcc, eax                    ; 包络起点（定点 8 位）
    imul eax, delta, 89               ; 托底 ≈ delta*34.8%*256/256
    mov edx, eax
    mov eax, hiAcc
    sub eax, edx                      ; delta*167
    xor edx, edx
    mov ebx, nSamp
    div ebx
    mov stepAcc, eax                  ; 每样本递减步长（定点 8 位）
    mov esi, pBuf
    xor ecx, ecx                      ; i（ecx 自由：非协议寄存器）
GA_Loop:
    mov eax, ecx                      ; 相位 = ((i*freq)/2/SR) & 1
    mul freq
    shr eax, 1
    xor edx, edx
    mov ebx, SR
    div ebx
    and eax, 1
    mov edi, eax                      ; 相位位（edi 已 uses 保存）
    mov eax, ecx                      ; 摆幅 d = (hi - i*step)>>8
    imul eax, stepAcc
    mov ebx, hiAcc
    sub ebx, eax
    shr ebx, 8
    movzx edx, byte ptr [esi]
    test edi, edi
    jz GA_Lo
    add edx, ebx
    jmp GA_Clamp
GA_Lo:
    sub edx, ebx
GA_Clamp:
    cmp edx, 8
    jge GA_C1
    mov edx, 8
GA_C1:
    cmp edx, 240
    jle GA_C2
    mov edx, 240
GA_C2:
    mov [esi], dl
    inc esi
    inc ecx
    cmp ecx, nSamp
    jb GA_Loop
    ret
GenAdd endp

; GenSoft -- 正弦叠加写 pBuf（会话 29 轻音乐轨）：相位 16.16 定点步进
; step=(freq<<16)/SR，抛物线半周近似 sin（u*(32768-u)>>14 峰 16384，
; 再按 amp/16384 缩放），叠加进既有字节；amp 小（≤28）、基准 96，
; 结果恒在 8..240 安全区无需钳位
GenSoft proc uses ecx edx esi edi pBuf: dword, freq: dword, nSamp: dword, amp: dword
local ph: dword
    mov ph, 0
    mov eax, freq
    shl eax, 16
    xor edx, edx
    mov ecx, SR
    div ecx                           ; eax = 每样本相位步进
    mov edi, eax
    mov esi, pBuf
    mov ecx, nSamp
GS_L1:
    mov eax, ph
    add eax, edi
    mov ph, eax
    and eax, 0FFFFh                   ; p=周期内相位（16.16 低 16 位）
    push eax
    mov edx, 65536
    sub edx, eax
    cmp eax, 32768
    jbe GS_NoMir
    mov eax, edx                      ; 镜像回 0..32768
GS_NoMir:
    mov edx, 32768
    sub edx, eax
    imul eax, edx                     ; u*(32768-u) ≤ 2.68e8
    shr eax, 14                       ; ≤16384
    imul eax, amp
    shr eax, 14                       ; ≤amp
    pop edx                           ; p（定符号）
    cmp edx, 32768
    jae GS_Neg
    movzx edx, byte ptr [esi]
    add edx, eax
    mov [esi], dl
    jmp GS_Done
GS_Neg:
    movzx edx, byte ptr [esi]
    sub edx, eax
    mov [esi], dl
GS_Done:
    inc esi
    dec ecx
    jnz GS_L1
    ret
GenSoft endp

; ------------------------------------------------------------
; GenPulse -- 占空比脉冲波绝对写（会话42 8-bit 化主力音色）：
; duty ∈ 1..3（周期 4 分法，1=25% 高电平）。25%/12.5% 占空是 NES 2A03
; /Game Boy 主音色的灵魂——比 50% 方波更"尖亮金属感"，一听即回 80 年代。
; 入参：pBuf, freq, nSamp, tail, duty
; ------------------------------------------------------------
GenPulse proc uses ebx ecx edx esi pBuf: dword, freq: dword, nSamp: dword, tail: dword, duty: dword
    mov esi, pBuf
    xor ecx, ecx
GP_Loop:
    mov eax, ecx
    imul eax, eax, 4
    mov ebx, freq
    imul eax, ebx                 ; 会话42 陷阱：ml 拒三操作数 imul reg,reg,reg（A2070），
    mov ebx, SR                   ; 改两操作数；积 <3.1e8 高位 edx 恒 0，直接 div
    div ebx                       ; edx = 4 分法相位余数 0..3
    cmp edx, duty                 ; 余数 < duty -> 高电平
    cmp edx, duty                   ; 相位余数 < duty -> 高电平
    jb GP_Hi
    mov byte ptr [esi], AMP_LO
    jmp GP_N
GP_Hi:
    mov byte ptr [esi], AMP_HI
GP_N:
    inc esi
    inc ecx
    .if ecx < nSamp
        jmp GP_Loop
    .endif
    .if tail != 0
        invoke DecayTail, pBuf, nSamp, tail
    .endif
    ret
GenPulse endp


; ------------------------------------------------------------
; GenTick -- 白噪声混入（会话42 8-bit 电子镲头）：每样本
; new=(原值+噪声32..159)/2，在音色头部叠 50% 宽带"嚓"感打击层
; ------------------------------------------------------------
GenTick proc uses ebx ecx edx esi pBuf: dword, nSamp: dword
    mov esi, pBuf
    xor ecx, ecx
GT_Loop:
    mov eax, rngSt
    imul eax, eax, 1103515245
    add eax, 12345
    mov rngSt, eax
    xor edx, edx
    mov ebx, 128
    div ebx
    add eax, 32
    mov ebx, eax
    movzx edx, byte ptr [esi]
    add edx, ebx
    shr edx, 1
    mov [esi], dl
    inc esi
    inc ecx
    .if ecx < nSamp
        jmp GT_Loop
    .endif
    ret
GenTick endp
; ------------------------------------------------------------
; SndInit -- 启动时生成 BGM 文件与全部音效
; ------------------------------------------------------------
SndInit proc uses ebx esi edi
    ; ---- BGM：逐音符填 bgmBuf（waveOut 独立流数据），并留档一份
    ;      %TEMP%\tankwar_bgm.wav 供排障。旧版 CreateFile 失败会直接
    ;      ret，把全部音效生成一起跳过（隐形静音 bug）；现文件仅为
    ;      留档，失败不再影响任何音频。 ----
    invoke GetEnvironmentVariableA, offset envTag, offset bgmPath, 240
    invoke lstrcatA, offset bgmPath, offset tagBgm
    invoke CreateFileA, offset bgmPath, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, 0, 0
    mov hFile, eax
    invoke WrHead, offset hdrBuf, BGM_TOTAL
    ; ---- 双轨合成（会话 27）：先整轨铺 96（8bit 无符号静音中心），
    ;      再逐拍把旋律轨(摆幅44)与低音轨(摆幅16)叠加进 bgmBuf ----
    mov edi, OFFSET bgmBuf
    mov eax, 060606060h
    mov ecx, BGM_TOTAL/4
    cld
    rep stosd
    xor ebx, ebx
BG_Beat:
    mov eax, ebx
    imul eax, eax, NOTE_SAMP
    mov edx, OFFSET bgmBuf
    add edx, eax
    mov eax, bgmMel[ebx*4]
    .if eax != 0
        invoke GenAdd, edx, eax, NOTE_SAMP, 44
    .endif
    mov eax, ebx
    imul eax, eax, NOTE_SAMP
    mov edx, OFFSET bgmBuf
    add edx, eax
    mov eax, bgmBass[ebx*4]
    .if eax != 0
        invoke GenAdd, edx, eax, NOTE_SAMP, 16
    .endif
    inc ebx
    .if ebx < bgmN
        jmp BG_Beat
    .endif
    ; ---- 对战轨（会话 29 轻音乐）：整轨铺 96 后正弦叠加旋律(±28)与
    ;      低音(±12)——16 音 ×0.3s ×2 遍=9.6s，与主页轨等长；
    ;      旧会话 28 方波跑动主题被指"太吵"，整段替换 ----
    mov edi, OFFSET bgmBufG
    mov eax, 060606060h
    mov ecx, BGM_TOTAL/4
    cld
    rep stosd
    xor ebx, ebx
BG2_Rep:
    xor esi, esi
BG2_Note:
    mov eax, ebx
    imul eax, eax, gameN
    add eax, esi
    imul eax, eax, GAME_SAMP
    mov edx, OFFSET bgmBufG
    add edx, eax
    mov eax, gameMel[esi*4]
    invoke GenSoft, edx, eax, GAME_SAMP, 28
    inc esi
    .if esi < gameN
        jmp BG2_Note
    .endif
    xor esi, esi
BG2_Bass:
    mov eax, ebx
    imul eax, eax, gameBassN
    add eax, esi
    imul eax, eax, GAME_SAMP*2
    mov edx, OFFSET bgmBufG
    add edx, eax
    mov eax, gameBass[esi*4]
    invoke GenSoft, edx, eax, GAME_SAMP*2, 12
    inc esi
    .if esi < gameBassN
        jmp BG2_Bass
    .endif
    inc ebx
    .if ebx < gameReps
        jmp BG2_Rep
    .endif
    .if hFile != -1
        invoke WriteFile, hFile, offset hdrBuf, 44, addr wrBytes, 0
        invoke WriteFile, hFile, offset bgmBuf, BGM_TOTAL, addr wrBytes, 0
        invoke CloseHandle, hFile
    .endif
    ; ---- 会话43：18 个音效不再运行时生成——inc/sfxdata.inc 已内嵌 CC0 采样
    ; 静态表（44B WAV 头+PCM，22050Hz/8bit/静音位128/摆幅±112，源为 Juhani
    ; Junkala《512 Retro SFX》CC0 包，tools/gen_sfx43.py 转换生成）。
    ; Gen*/bkFreq/NOTE_* 保留：BGM 八音盒与后续备用音色仍可用。
    ret
SndInit endp

; ------------------------------------------------------------
; SndBgmStart -- 循环播放背景音乐（会话 26：waveOut 独立流）
; PlaySound 只有一条全局通道：任何 SND_MEMORY 音效都会掐死它的
; SND_LOOP BGM 且不再恢复——正是"退出到主页面音乐突然消失"的
; 根因。改 waveOutOpen+Prepare+Write 一条独立流（dwLoops=-1 +
; BEGINLOOP|ENDLOOP 无限循环），与 PlaySound 音效各自成流、系统
; 混音；主音量 waveOutSetVolume(0,..) 对两路同时生效。幂等。
; ------------------------------------------------------------
SndBgmStart proc
    mov eax, bgmLive
    .if eax != 0
        ret
    .endif
    invoke waveOutOpen, addr bgmDev, WAVE_MAPPER, addr bgmFmt, 0, 0, 0
    .if eax != 0
        ret                             ; 无声卡/占用：静默跳过 BGM
    .endif
    mov eax, OFFSET bgmBuf
    mov bgmHdr, eax                     ; lpData
    mov bgmHdr+4, BGM_TOTAL             ; dwBufferLength
    mov bgmHdr+16, 0                    ; dwFlags 先清零再 Prepare
    mov bgmHdr+20, -1                   ; dwLoops=-1 → 无限循环
    invoke waveOutPrepareHeader, bgmDev, addr bgmHdr, 32
    .if eax != 0
        invoke waveOutClose, bgmDev
        mov bgmDev, 0
        ret
    .endif
    or bgmHdr+16, WHDR_BEGINLOOP or WHDR_ENDLOOP
    ; ---- 会话 28：对战轨头同样布局预备（主页/对战双曲目分页）----
    mov eax, OFFSET bgmBufG
    mov bgmHdrG, eax
    mov bgmHdrG+4, BGM_TOTAL
    mov bgmHdrG+16, 0
    mov bgmHdrG+20, -1
    invoke waveOutPrepareHeader, bgmDev, addr bgmHdrG, 32
    .if eax != 0
        invoke waveOutClose, bgmDev
        mov bgmDev, 0
        ret
    .endif
    or bgmHdrG+16, WHDR_BEGINLOOP or WHDR_ENDLOOP
    invoke waveOutWrite, bgmDev, addr bgmHdr, 32   ; 先播主页主题
    .if eax == 0
        mov bgmLive, 1
        mov bgmTrk, 0
    .else
        invoke waveOutClose, bgmDev
        mov bgmDev, 0
    .endif
    ret
SndBgmStart endp

; ------------------------------------------------------------
; SndBgmSetTrack -- 切换独立流曲目（会话 28：0=主页新主题
; 1=对战旧主题）。waveOutReset 丢弃当前无限循环缓冲后重写另一
; 轨头；同轨/未开流零开销直返。UiTick 每 tick 按 gameState 调用。
; ------------------------------------------------------------
SndBgmSetTrack proc trk: dword
    mov eax, bgmTrk
    .if eax == -1
        ret
    .endif
    .if eax == trk
        ret
    .endif
    invoke waveOutReset, bgmDev
    mov eax, trk
    mov bgmTrk, eax
    .if eax == 1
        invoke waveOutWrite, bgmDev, addr bgmHdrG, 32
    .else
        invoke waveOutWrite, bgmDev, addr bgmHdr, 32
    .endif
    ret
SndBgmSetTrack endp

; ------------------------------------------------------------
; SndPlay -- 播放音效（id: 1开炮 2爆炸 3拾取 4倒计时 5虚影/换位 6布雷
;              7激光发射）
; sfxOn=0 时静默
; ------------------------------------------------------------
SndPlay proc uses ebx id: dword
    mov eax, sfxOn
    .if eax == 0
        ret
    .endif
    mov eax, id
    .if eax == SND_SHOT
        invoke PlaySoundA, offset sndShotBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_BOOM
        invoke PlaySoundA, offset sndBoomBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_PICK
        invoke PlaySoundA, offset sndPickBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_COUNT
        invoke PlaySoundA, offset sndCntBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_SWAP
        invoke PlaySoundA, offset sndSwapBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_MINE
        invoke PlaySoundA, offset sndMineBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_LASER
        invoke PlaySoundA, offset sndLaserBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_SHIELD
        invoke PlaySoundA, offset sndShieldBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_SHATTER
        invoke PlaySoundA, offset sndShatterBuf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_GHOSTSND
        invoke PlaySoundA, offset sndGhostBf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_NITROSND
        invoke PlaySoundA, offset sndNitroBf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_WATERSND
        invoke PlaySoundA, offset sndWaterBf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_SWAPFIRE
        invoke PlaySoundA, offset sndSwapfBf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_AIMSND
        invoke PlaySoundA, offset sndAimBf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_ACH
        invoke PlaySoundA, offset sndAch0Bf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_ACH1
        invoke PlaySoundA, offset sndAchBf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_ACH2
        invoke PlaySoundA, offset sndAch2Bf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .elseif eax == SND_ACH3
        invoke PlaySoundA, offset sndAch3Bf, 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT
    .endif
    ret
SndPlay endp

; ------------------------------------------------------------
; SndVolume -- 主音量（vol 0..100）
; ------------------------------------------------------------
SndVolume proc uses ebx vol: dword
    mov eax, vol
    imul eax, eax, 65535
    xor edx, edx
    mov ebx, 100
    div ebx                       ; eax = 0..65535
    mov ebx, eax
    shl ebx, 16
    or eax, ebx                   ; 左右声道同值
    invoke waveOutSetVolume, 0, eax
    ret
SndVolume endp

end
