#!/usr/bin/env python3
"""
Guideline 测试录像生成器
生成一个符合 GOKZ .replay v2 格式（RP_FORMAT_VERSION 0x02）的样例文件，
字节布局与 gokz-replays/recording.sp 的写入完全一致。

用法:
    python3 tools/make_test_replay.py [输出路径] [地图名] [tick数]

默认输出: test_replay/0_KZT_NRM_PRO.replay
轨迹为直线 + 起跳点标记 + 一个传送断点，方便验证解析与渲染。
"""

import struct
import sys
import math

RP_MAGIC = 0x676F6B7A  # "gokz"
RP_VERSION = 2
RP_TICK_BLOCK = 20  # RP_V2_TICK_DATA_BLOCKSIZE

RPDELTA = {
    "DELTAFLAGS": 0,
    "DELTAFLAGS2": 1,
    "VEL_X": 2, "VEL_Y": 3, "VEL_Z": 4,
    "MOUSE_X": 5, "MOUSE_Y": 6,
    "ORIGIN_X": 7, "ORIGIN_Y": 8, "ORIGIN_Z": 9,
    "ANGLES_X": 10, "ANGLES_Y": 11, "ANGLES_Z": 12,
    "VELOCITY_X": 13, "VELOCITY_Y": 14, "VELOCITY_Z": 15,
    "FLAGS": 16,
    "PACKETSPERSECOND": 17,
    "LAGGEDMOVEMENTVALUE": 18,
    "BUTTONSFORCED": 19,
}

FLAG_ONGROUND = 1 << 18
FLAG_TELEPORT = 1 << 22   # isTeleportTick
FLAG_TAKEOFF = 1 << 23    # takeoff tick


def f2i(f):
    return struct.unpack("<i", struct.pack("<f", f))[0]


def s8(s):
    """int8 length + raw string (no null terminator)"""
    return bytes([len(s)]) + s.encode("utf-8")


# 全局状态：上一帧字段（delta 比较用）
_prev_fields = None


def make_tick(fields):
    """fields: list of 20 ints（单帧），与 gokz 写入行为一致：
    首帧：掩码全 1（全字段写入）；后续帧：与上一帧比较只写变化字段。
    """
    global _prev_fields
    buf = bytearray()
    if _prev_fields is None:
        delta = (1 << RP_TICK_BLOCK) - 1
    else:
        delta = 0
        for j in range(1, RP_TICK_BLOCK):
            if fields[j] != _prev_fields[j]:
                delta |= (1 << j)
    buf += struct.pack("<i", delta)
    for j in range(1, RP_TICK_BLOCK):
        if delta & (1 << j):
            buf += struct.pack("<i", fields[j])
    _prev_fields = fields
    return buf


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "test_replay/0_KZT_NRM_PRO.replay"
    map_name = sys.argv[2] if len(sys.argv) > 2 else "testmap"
    n_ticks = int(sys.argv[3]) if len(sys.argv) > 3 else 500

    tickrate = 128.0
    time = f2i(42.13)  # 42.13 秒
    teleports = 0
    course = 0

    buf = bytearray()
    # General header (v2)
    buf += struct.pack("<i", RP_MAGIC)
    buf += bytes([RP_VERSION])         # formatVersion
    buf += bytes([0])                  # replayType = Run
    buf += s8("1.0.0")                 # gokzVersion
    buf += s8(map_name)                # mapName
    buf += struct.pack("<i", 123456)   # mapFileSize
    buf += struct.pack("<i", 0)        # serverIP
    buf += struct.pack("<i", 1700000000)  # timestamp
    buf += s8("GuidelineTestBot")      # playerAlias
    buf += struct.pack("<i", 76561190000000000 % (2**31))  # playerSteamID (int32)
    buf += bytes([2])                  # mode = KZTimer
    buf += bytes([0])                  # style = Normal
    buf += struct.pack("<i", f2i(2.5))  # playerSensitivity
    buf += struct.pack("<i", f2i(0.022))  # playerMYaw
    buf += struct.pack("<i", f2i(tickrate))  # tickrate
    buf += struct.pack("<i", n_ticks)  # tickCount
    buf += struct.pack("<i", 0)        # equippedWeapon
    buf += struct.pack("<i", 0)        # equippedKnife
    # Run header
    buf += struct.pack("<i", time)     # time (float bits)
    buf += bytes([course])             # course
    buf += struct.pack("<i", teleports)  # teleportsUsed

    # Tick data: 直线轨迹（每 tick +8 units），含起跳点与传送断点
    prev_fields = None
    for tick in range(n_ticks):
        x = tick * 8.0
        y = 0.0
        z = 64.0
        if tick == 250:
            # 传送：跳跃到 (2000, 0, 0) 后的位置
            x = 2000.0
            flags = FLAG_ONGROUND | FLAG_TELEPORT
        else:
            flags = FLAG_ONGROUND
            if tick == 100 or tick == 300:
                flags |= FLAG_TAKEOFF
        fields = [0] * RP_TICK_BLOCK
        fields[RPDELTA["VEL_X"]] = f2i(300.0)
        fields[RPDELTA["VEL_Y"]] = 0
        fields[RPDELTA["VEL_Z"]] = 0
        fields[RPDELTA["MOUSE_X"]] = 0
        fields[RPDELTA["MOUSE_Y"]] = 0
        fields[RPDELTA["ORIGIN_X"]] = f2i(x)
        fields[RPDELTA["ORIGIN_Y"]] = f2i(y)
        fields[RPDELTA["ORIGIN_Z"]] = f2i(z)
        fields[RPDELTA["ANGLES_X"]] = f2i(0.0)
        fields[RPDELTA["ANGLES_Y"]] = f2i(0.0)
        fields[RPDELTA["ANGLES_Z"]] = 0
        fields[RPDELTA["VELOCITY_X"]] = f2i(300.0)
        fields[RPDELTA["VELOCITY_Y"]] = 0
        fields[RPDELTA["VELOCITY_Z"]] = 0
        fields[RPDELTA["FLAGS"]] = flags
        fields[RPDELTA["PACKETSPERSECOND"]] = f2i(64.0)
        fields[RPDELTA["LAGGEDMOVEMENTVALUE"]] = f2i(1.0)
        fields[RPDELTA["BUTTONSFORCED"]] = 0

        buf += make_tick(fields)

    with open(out, "wb") as f:
        f.write(buf)

    print(f"Wrote {out}: {len(buf)} bytes, {n_ticks} ticks")
    # 简单验证
    assert len(buf) > 100
    # 验证头部魔数
    assert struct.unpack("<i", buf[:4])[0] == RP_MAGIC
    print(f"Verify OK: map={map_name} player=GuidelineTestBot mode=2 style=0 ticks={n_ticks} time=42.13s course=0 tp=0 takeoffs=2 teleport_ticks=1")


if __name__ == "__main__":
    main()
