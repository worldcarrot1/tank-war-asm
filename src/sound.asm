; ============================================================
; sound.asm —— 程序化 8-bit 电子音（上世纪芯片音风格）
; 启动时生成：BGM 循环 WAV 写 %TEMP%\tankwar_bgm.wav
; （PlaySound 文件循环播放）；音效生成到内存 buffer
; （PlaySound SND_MEMORY 异步）。音量经 waveOutSetVolume
; 全局主音量；音效开关 sfxOn（ui.asm）。
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

NOTE_SHOT        equ 2646              ; 0.12s
NOTE_BOOM        equ 8599              ; 0.39s
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
    sndBoomBuf  db 8800 dup (?)     ; 头+0.39s
    sndPickBuf  db 3460 dup (?)     ; 头+0.15s
    sndCntBuf   db 2360 dup (?)     ; 头+0.10s
    sndSwapBuf  db 3460 dup (?)     ; 头+0.15s
    tmpBuf      db 4096 dup (?)     ; BGM 逐音符工作区
    hdrBuf      db 44 dup (0)       ; BGM 文件头
    rngSt       dd 12345            ; 噪声 LCG
    tmpAcc      dd 0                ; 滑频相位累积
    phFl        dd 0                ; 方波电平
    wrBytes     dd 0
    hFile       dd 0
    ; 自创 16 音循环旋律（A 小调琶音风）
    melody      dd 440, 523, 659, 880, 784, 659, 523, 587
                dd 440, 523, 659, 587, 523, 440, 392, 440
NOTE_SAMP       equ 3307              ; 0.15s @ 22050
BGM_REPS        equ 4                 ; 4 遍 = 4.8s 循环

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
; SndInit -- 启动时生成 BGM 文件与全部音效
; ------------------------------------------------------------
SndInit proc uses ebx esi edi
    ; ---- BGM 文件 ----
    invoke GetEnvironmentVariableA, offset envTag, offset bgmPath, 240
    invoke lstrcatA, offset bgmPath, offset tagBgm
    invoke WrHead, offset hdrBuf, BGM_REPS*16*NOTE_SAMP
    invoke CreateFileA, offset bgmPath, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, 0, 0
    mov hFile, eax
    .if eax == -1
        ret                       ; 打不开（无 TEMP）：跳过 BGM
    .endif
    invoke WriteFile, hFile, offset hdrBuf, 44, addr wrBytes, 0
    xor ebx, ebx
BG_Rep:
    xor esi, esi
BG_Note:
    mov eax, melody[esi*4]
    invoke GenSquare, offset tmpBuf, eax, NOTE_SAMP, 300
    invoke WriteFile, hFile, offset tmpBuf, NOTE_SAMP, addr wrBytes, 0
    inc esi
    .if esi < 16
        jmp BG_Note
    .endif
    inc ebx
    .if ebx < BGM_REPS
        jmp BG_Rep
    .endif
    invoke CloseHandle, hFile
    ; ---- 开炮：下滑方波 0.12s ----
    invoke GenSlide, offset sndShotBuf+44, 900, 280, NOTE_SHOT
    invoke DecayTail, offset sndShotBuf+44, NOTE_SHOT, 200
    invoke WrHead, offset sndShotBuf, NOTE_SHOT
    ; ---- 爆炸：噪声 0.39s（小丑盒爆裂感：衰减 + 随机裂音）----
    invoke GenNoise, offset sndBoomBuf+44, NOTE_BOOM
    invoke WrHead, offset sndBoomBuf, NOTE_BOOM
    ; ---- 拾取：上升双音 E5->A5 ----
    invoke GenSquare, offset sndPickBuf+44, 659, NOTE_HALF, 80
    invoke GenSquare, offset sndPickBuf+44+NOTE_HALF, 880, NOTE_HALF, 240
    invoke WrHead, offset sndPickBuf, NOTE_HALF*2
    ; ---- 倒计时哔 ----
    invoke GenSquare, offset sndCntBuf+44, 880, NOTE_CNT, 320
    invoke WrHead, offset sndCntBuf, NOTE_CNT
    ; ---- 虚影/换位：三连琶音 C5-G5-C6 ----
    invoke GenSquare, offset sndSwapBuf+44, 523, NOTE_THIRD, 60
    invoke GenSquare, offset sndSwapBuf+44+NOTE_THIRD, 784, NOTE_THIRD, 60
    invoke GenSquare, offset sndSwapBuf+44+NOTE_THIRD*2, 1046, NOTE_THIRD, 300
    invoke WrHead, offset sndSwapBuf, NOTE_THIRD*3
    ret
SndInit endp

; ------------------------------------------------------------
; SndBgmStart -- 循环播放背景音乐
; ------------------------------------------------------------
SndBgmStart proc
    invoke PlaySoundA, offset bgmPath, 0, SND_FILENAME or SND_ASYNC or SND_LOOP
    ret
SndBgmStart endp

; ------------------------------------------------------------
; SndPlay -- 播放音效（id: 1开炮 2爆炸 3拾取 4倒计时 5虚影）
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
