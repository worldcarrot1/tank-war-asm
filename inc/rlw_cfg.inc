; 自动生成（tools/gen_rlbot_data.py）勿手改：蒸馏网络隐层宽度
; 会话51 run19 预铺：换宽网络重跑 gen 后本文件随之刷新；手改本文件
; 而 rlw.inc 权重未同宽，会在 RLW_* dd 计数上不匹配（ml 直接报）。
RL_HW equ 128
