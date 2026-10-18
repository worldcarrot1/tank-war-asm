; ============================================================
; sound.asm —— 程序化 8-bit 电子音（上世纪芯片音风格）
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
public SndPlay
public SndVolume

PlaySoundA              PROTO stdcall :DWORD,:DWORD,:DWORD
waveOutSetVolume        PROTO stdcall :DWORD,:DWORD
waveOutOpen             PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
waveOutClose            PROTO stdcall :DWORD
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

.data
    align 4
    bgmPath     db 260 dup (0)
    tagBgm      db "\tankwar_bgm.wav", 0
    envTag      db "TEMP", 0
    ; 音效内存镜像（44 字节 WAV 头 + PCM）
    sndShotBuf  db 2760 dup (?)     ; 头+0.12s
    sndBoomBuf  db 8800 dup (?)     ; 头+0.34s（八音盒开箱音，会话 26）
    sndPickBuf  db 3460 dup (?)     ; 头+0.15s
    sndCntBuf   db 2360 dup (?)     ; 头+0.10s
    sndSwapBuf  db 3460 dup (?)     ; 头+0.15s
    sndMineBuf  db 2300 dup (?)     ; 头+2*0.05s（布雷闷双响，会话 23）
    hdrBuf      db 44 dup (0)       ; BGM 文件头
    rngSt       dd 12345            ; 噪声 LCG
    tmpAcc      dd 0                ; 滑频相位累积
    phFl        dd 0                ; 方波电平
    wrBytes     dd 0
    hFile       dd 0
    ; 会话 27：双轨 64 拍 BGM（用户反馈"旋律太单调"）——主旋律
    ; Am/F/C/G 四乐句带切分休止、八度大跳与最高音点缀，低音轨以
    ; 8 分音符根音行进（Am→F→C→G），两轨方波线性叠加（GenAdd）。
    ; 0=休止。循环尺寸不变：64 拍 × NOTE_SAMP = 211648 字节 9.6s
    bgmMel      dd 440, 659, 880, 659, 0, 1046, 880, 0
                dd 523, 659, 880, 1046, 880, 659, 523, 0
                dd 698, 523, 440, 523, 0, 698, 880, 0
                dd 1046, 880, 698, 523, 440, 0, 349, 0
                dd 523, 659, 784, 1046, 784, 659, 0, 523
                dd 659, 784, 1046, 1318, 1046, 784, 659, 0
                dd 392, 494, 587, 784, 587, 494, 0, 392
                dd 494, 587, 784, 988, 784, 587, 494, 392
    bgmBass     dd 110, 0, 110, 0, 110, 0, 110, 0, 110, 0, 110, 0, 110, 0, 110, 0
                dd 87, 0, 87, 0, 87, 0, 87, 0, 87, 0, 87, 0, 87, 0, 87, 0
                dd 131, 0, 131, 0, 131, 0, 131, 0, 131, 0, 131, 0, 131, 0, 131, 0
                dd 98, 0, 98, 0, 98, 0, 98, 0, 98, 0, 98, 0, 98, 0, 98, 0
    bgmN        = 64
NOTE_SAMP       equ 3307              ; 一拍 0.15s @ 22050
BGM_TOTAL       equ bgmN*NOTE_SAMP    ; 211648 字节

; ---- 会话 26：BGM 独立 waveOut 流（与 PlaySound 音效混音并存）----
WAVE_MAPPER     equ 0FFFFFFFFh
WHDR_BEGINLOOP  equ 0004h
WHDR_ENDLOOP    equ 0008h

.data
    align 4
    bgmBuf      db BGM_TOTAL dup (?)  ; 全循环 8bit 单声道样本（waveOut 缓冲）
    bgmDev      dd 0                  ; HWAVEOUT
    bgmLive     dd 0                  ; 1=独立流已在播
    bgmHdr      dd 0                  ; WAVEHDR(x86, 32B)：lpData /
            dd 0, 0, 0                ;  dwBufferLength / dwBytesRecorded /
            dd 0, 0, 0, 0             ;  dwUser / dwFlags / dwLoops /
                                      ;  lpNext / reserved
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
; GenAdd -- 方波叠加进 pBuf（会话 27 双轨合成）：读取现值加/减
; 包络（线性衰减到 0），钳位 8..240。静音中心 96。
; 钳位用 jl/jle 显式带符号跳转（.if reg<8 会按无符号编译的陷阱）。
; 入参：pBuf, freq, nSamp, delta
; ------------------------------------------------------------
GenAdd proc uses ebx esi edx pBuf: dword, freq: dword, nSamp: dword, delta: dword
    local accSpd: dword
    mov eax, delta
    shl eax, 8
    xor edx, edx
    mov ebx, nSamp
    div ebx
    mov accSpd, eax                   ; 定点 8 位包络步长
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
    mov bl, al                        ; bl=相位（SR 已用完）
    mov eax, nSamp                    ; 摆幅 d = (n-i)*accSpd>>8
    sub eax, ecx
    imul eax, accSpd
    shr eax, 8
    movzx edx, byte ptr [esi]
    test bl, bl
    jz GA_Lo
    add edx, eax
    jmp GA_Clamp
GA_Lo:
    sub edx, eax
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
    .if hFile != -1
        invoke WriteFile, hFile, offset hdrBuf, 44, addr wrBytes, 0
        invoke WriteFile, hFile, offset bgmBuf, BGM_TOTAL, addr wrBytes, 0
        invoke CloseHandle, hFile
    .endif
    ; ---- 会话 23 电子音重制 ----
    ; 开炮：尖锐"pew"下滑方波 1500->140Hz，0.12s（旧 900->280 太闷）
    invoke GenSlide, offset sndShotBuf+44, 1500, 140, NOTE_SHOT
    invoke DecayTail, offset sndShotBuf+44, NOTE_SHOT, 200
    invoke WrHead, offset sndShotBuf, NOTE_SHOT
    ; 爆炸（坦克击败音，会话 26 重制）：PvZ 小丑僵尸"小丑盒子打开"
    ; 音效 = 八音盒上行折返颤音 14 音（方波+快速衰减的拨弦叮当感），
    ; 前置盒盖弹开短滑音 900->300Hz，尾部落盖噪声。旧版通长纯噪声
    ; 爆裂（会话 24"复原"）被指太吵杂，改音乐盒质感。
    invoke GenSlide, offset sndBoomBuf+44, 900, 300, BK_POP
    mov edi, OFFSET sndBoomBuf+44+BK_POP
    xor esi, esi
BK_Ping:
    mov eax, bkFreq[esi*4]
    invoke GenSquare, edi, eax, BK_PING, 380
    add edi, BK_PING
    inc esi
    .if esi < BK_NC
        jmp BK_Ping
    .endif
    invoke GenNoise, edi, BK_POOF
    invoke WrHead, offset sndBoomBuf, NOTE_BOOM
    ; 拾取：明亮上行大三琶音 A5->E6->A6（芯片过关感）
    invoke GenSquare, offset sndPickBuf+44, 880, NOTE_THIRD, 60
    invoke GenSquare, offset sndPickBuf+44+NOTE_THIRD, 1318, NOTE_THIRD, 60
    invoke GenSquare, offset sndPickBuf+44+NOTE_THIRD*2, 1760, NOTE_THIRD, 300
    invoke WrHead, offset sndPickBuf, NOTE_THIRD*3
    ; ---- 倒计时哔 ----
    invoke GenSquare, offset sndCntBuf+44, 880, NOTE_CNT, 320
    invoke WrHead, offset sndCntBuf, NOTE_CNT
    ; 虚影/换位：下行琶音 A6->E6->A5（与拾取上行形成"得到/失去"对照）
    invoke GenSquare, offset sndSwapBuf+44, 1760, NOTE_THIRD, 60
    invoke GenSquare, offset sndSwapBuf+44+NOTE_THIRD, 1318, NOTE_THIRD, 60
    invoke GenSquare, offset sndSwapBuf+44+NOTE_THIRD*2, 880, NOTE_THIRD, 300
    invoke WrHead, offset sndSwapBuf, NOTE_THIRD*3
    ; 布雷：两声低鸣 220->165Hz（闷双响，提示"脚下有雷"）
    invoke GenSquare, offset sndMineBuf+44, 220, NOTE_THIRD, 60
    invoke GenSquare, offset sndMineBuf+44+NOTE_THIRD, 165, NOTE_THIRD, 400
    invoke WrHead, offset sndMineBuf, NOTE_THIRD*2
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
    invoke waveOutWrite, bgmDev, addr bgmHdr, 32
    .if eax == 0
        mov bgmLive, 1
    .else
        invoke waveOutClose, bgmDev
        mov bgmDev, 0
    .endif
    ret
SndBgmStart endp

; ------------------------------------------------------------
; SndPlay -- 播放音效（id: 1开炮 2爆炸 3拾取 4倒计时 5虚影/换位 6布雷）
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
