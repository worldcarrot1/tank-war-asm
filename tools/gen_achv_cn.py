#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""会话40：成就系统中文文案 -> MASM dw 码点行生成（tools/gen_achv_cn.py）。
用法: python -I tools/gen_achv_cn.py > tools/achv_cn.txt 后人工拼入 achv.asm / ui.asm"""

def dwline(label, text):
    body = ",".join(f"{ord(c):04X}h" for c in text)
    return f"    {label} dw {body}, 0"

# (名, 描述) —— 顺序即图鉴顺序：普通6 / 稀有7 / 史诗6 / 传奇5
# 会话41：追风者为第13条（稀有末位），achv.asm 中手工命名 CN_ACH24N/CN_ACH24D，
# 生成器按序输出的是 CN_ACH13N/D，取用该两行时记得改标签名。
ACH = [
 ("首开锋芒", "打出第一发子弹"),
 ("首杀", "完成第一次击杀"),
 ("寒霜护体", "发动一次冰盾"),
 ("疾风起步", "使用一次氮气"),
 ("遇水叠桥", "使用一次驭水"),
 ("拾荒新手", "拾取十件道具"),
 ("赏金猎人", "累计击杀二十五人"),
 ("碎冰守卫", "冰盾挡下十发弹"),
 ("布雷能手", "布下十颗地雷"),
 ("幽影行者", "定格虚影五次"),
 ("以牙还牙", "击杀上次带走你的对手"),
 ("激光初试", "发射五次激光"),
 ("追风者", "累计使用五十次氮气"),
 ("五连绝世", "单场击杀五人"),
 ("完美夺冠", "零受伤害赢下一场"),
 ("百战老兵", "累计夺冠二十场"),
 ("换位大师", "换位成交五次"),
 ("雷狱领主", "地雷击杀五人"),
 ("网友首胜", "联机模式赢一场"),
 ("黑色勋章", "击败黑色人机"),
 ("八方屠场", "单场击杀八人"),
 ("屠夫", "累计击杀两百人"),
 ("碾压零封", "对手零分夺冠"),
 ("弹幕大海", "累计开火一千发"),
]
for i, (n, d) in enumerate(ACH, 1):
    print(dwline(f"CN_ACH{i:02d}N", n))
    print(dwline(f"CN_ACH{i:02d}D", d))
print()
for lab, t in [("CN_ACHRAR0", "普通"), ("CN_ACHRAR1", "稀有"), ("CN_ACHRAR2", "史诗"),
               ("CN_ACHRAR3", "传奇"), ("CN_ACHOWN", "已达成"), ("CN_ACHLOCK", "未达成"),
               ("CN_ACHGALT", "成就图鉴"), ("CN_ACHGALC", "收集进度"),
               ("CN_ACHTOAST", "成就解锁"), ("CN_MENUACH", "成就图鉴"),
               ("CN_ACHGALTW", "（新）成就图鉴")]:  # 会话41：菜单未读角标变体
    print(dwline(lab, t))
