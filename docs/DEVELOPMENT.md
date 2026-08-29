# Guideline 开发文档

> CS:GO GOKZ 路线指引插件 —— 从「插件缓存 / 服务器本地 GOKZ 录像 / R2 存储」三方择优选取最快主图路线录像，解析玩家轨迹并绘制 JumpBeam 同款紫色路线。

- 插件名：`guideline`
- 最终产物：**一个** `guideline.smx`
- 代码结构：模仿 `~/gokz-top-plugins`（单入口 `.sp` + 同名模块目录 + `include/` 依赖）
- 生命周期管理：模仿 `~/gokz/gokz-core.sp`（入口文件集中接收 SourceMod/GOKZ 事件，转发给各模块）
- R2 交互：参考 `~/cngokz-plugins/stratosphere`（SteamWorks HTTP + X-API-Key 鉴权）

---

## 1. 项目概述

### 1.1 解决什么问题

玩家在跳图（KZ 图）时不知道下一步怎么走。Guideline 自动挑选**当前地图最快的路线录像**（来源优先级见下），解析出玩家轨迹并整图绘制，玩家 `!gl` 开启后看到紫色线条跟随走。

### 1.2 路线来源优先级（按录像 header 里的 time 对比，最快者胜）

| 优先级 | 来源 | 目录/键名 |
|---|---|---|
| 1 | 插件下载缓存 | `addons/sourcemod/data/gokz-guideline/<map>_pro.replay` |
| 2 | 服务器本地 GOKZ 录像 | `addons/sourcemod/data/gokz-replays/_runs/<map>/`（course 0） |
| 3 | R2 存储 | `{base}/wr/{<vnl|skz|kzt>}/<map>/<pro|tp>.replay` |

检查时机：换图 3 秒后自动 + `!routerefresh` 手动强制刷新 +
**本服破纪录保存新录像时自动触发一次检查**（GOKZ_RP_OnReplaySaved，
仅在 course 0 且比当前路线快时生效，不干扰上游保存流程）。

### 1.3 显示规则

- `!gl` 每玩家独立开关（Cookie `gokz-guideline-enabled` 持久化），只发给本人
- 不依赖计时状态：开启后常驻显示（定时重发，refresh_interval=2.0s < beam_lifetime=4.0s）
- 线条参数与 GOKZ JumpBeam 完全一致：`laserbeam.vmt`、Width=0.25、FadeLength=10、Amplitude=0、Speed=0
- 颜色默认紫色 `148 0 211 110`；Chaikin 平滑 1 次迭代
- 传送点（flags bit 22）断开不连线

### 1.4 核心约束

| 约束 | 说明 |
|---|---|
| 单一 SMX | 所有模块编译进一个 `guideline.smx` |
| 依赖最少 | 运行时：SourceMod 1.11、SteamWorks（R2 下载）、gokz-core；不依赖数据库 |
| 异步下载 | R2 下载用 SteamWorks 回调，绝不阻塞主线程 |
| 解析不卡服 | 大录像分帧解析（CreateTimer 分批，默认 5000 帧/批） |
| 只支持主图 | course 0；B1/B2 忽略 |

---

## 2. 目录结构

```
guideline/                          # 项目根（= 本仓库）
├── README.md
├── docs/
│   └── DEVELOPMENT.md              # 本文档
├── addons/
│   └── sourcemod/
│       ├── scripting/
│       │   ├── guideline.sp        # 唯一入口：myinfo / 事件集中转发 / include 所有模块
│       │   ├── guideline/          # 模块目录（均被 guideline.sp include）
│       │   │   ├── convars.sp      # ConVar 创建与读取封装 + Cookie
│       │   │   ├── helpers.sp      # 字符串/客户端/日志/距离工具
│       │   │   ├── state.sp        # 玩家 !gl 开关状态（Cookie 镜像）
│       │   │   ├── replayfile.sp   # .replay 二进制解析（v1/v2）+ 读时间
│       │   │   ├── localreplay.sp  # 扫描本服 _runs 目录找最快录像
│       │   │   ├── routes.sp       # 路线数据管理：降采样、缓存路径、来源
│       │   │   ├── render.sp       # beam 渲染（JumpBeam 同款参数）
│       │   │   ├── http.sp         # SteamWorks HTTP：meta 两阶段下载 + 三方对比
│       │   │   └── commands.sp     # !gl / !routerefresh 命令
│       │   └── include/
│       │       └── guideline/version.inc  # 版本号（CI 自动 bump）
│       └── translations/           # （可选，本插件暂无多语言）
│       └── plugins/                # 构建产物（gitignore）
├── cfg/
│   └── sourcemod/gokz/gokz-guideline.cfg  # 配置模板
├── build.sh                        # 本地编译脚本
└── .github/workflows/
    ├── pr-check.yml                # PR 编译检查 + 测试包 artifact
    └── release.yml                 # push main：bump 版本 + Release
```

### 2.1 模块加载方式

```pawn
#include "guideline/convars.sp"
#include "guideline/helpers.sp"
#include "guideline/state.sp"
#include "guideline/replayfile.sp"
#include "guideline/localreplay.sp"
#include "guideline/routes.sp"
#include "guideline/render.sp"
#include "guideline/http.sp"
#include "guideline/commands.sp"
```

事件集中转发：入口 `.sp` 的 `OnPluginStart` / `OnMapStart` / `OnClientCookiesCached` 等转发给各模块的 `GL_*` 函数。

---

## 3. 数据流

```
换图 OnMapStart
  └─ 3 秒后 GL_Timer_AutoCheck → GL_CheckRoutes(AUTO)
       ├─ GL_MetaStart → SteamWorks GET {url}?meta=1（遍历 pro→tp→模式）
       │     └─ OnMetaComplete：
       │          ├─ 404 → 下一组合 | 全部 404 → FinishWithLocalOrCache
       │          ├─ 200 → 三方对比（本地 time / 缓存 time / 远程 time_ms）
       │          │     ├─ 远程最快 & sha 不同 → StartDownload（写缓存）
       │          │     └─ 本地/缓存最快 → GL_StartParsing
       │          └─ 网络失败 → FinishWithLocalOrCache
       └─ GL_StartParsing（分帧）
             └─ FinishParsing → GL_Downsample → GL_RouteFinishParsed
                   └─ gGL_Route.loaded = true
                        └─ 渲染定时器 GL_Timer_Render 每 2s 给开启 !gl 的玩家画线
```

---

## 4. 三方对比算法（http.sp OnMetaComplete）

```
localTime  = GL_FindFastestLocalReplay()  （读 header time，0 表示无）
cacheTime  = GL_GetCurrentRouteTime()     （当前已加载路线的 time）
remoteTime = meta JSON 的 time_ms / 1000

bestSource = min(localTime, cacheTime, remoteTime)
- remote 最快：sha 与缓存一致 → 直接解析缓存；否则下载 body 覆盖缓存
- local 最快：不下载，直接解析本地录像
- cache 最快：直接解析缓存
- 全无：聊天提示"未找到本图路线"
```

---

## 5. R2 协议（与 stratosphere 完全一致）

```
GET {base}/wr/{mode}/{map}/{type}.replay?meta=1
  Headers: X-API-Key: <key>
  → 200 {"exists":true,"time_ms":42130,"sha256":"...","size":6188}
GET {base}/wr/{mode}/{map}/{type}.replay
  Headers: X-API-Key: <key>
  → 200 二进制录像（响应头 x-sha256）
  → 404 无录像

mode = vnl|skz|kzt（遍历顺序：服务器默认模式 → 其余两种）
type = pro|tp（pro 优先，404 回退 tp）
map  = 服务器当前地图（小写 URLEncode）
```

---

## 6. 录像格式要点（replayfile.sp）

- v2：`GeneralHeader`（魔数 0x676F6B7A / 版本 2 / replayType=0(Run) / ... / tickrate / tickCount / ...）+ `RunHeader`（time float / course / teleportsUsed）+ delta 压缩 tick 数据
- v1：旧格式，固定 7 int32/tick
- tick 数据关注字段：`ORIGIN_X/Y/Z`（索引 7/8/9）、`FLAGS`（索引 16，bit 22=传送、bit 23=起跳）
- delta 压缩：每 tick 一个 int32 位掩码，置位字段才写值；首 tick 全置位
- 解析采用「文件流 + 分帧定时器」，避免一次读入大录像卡服（上限 8MB / 100 万 tick）

---

## 7. 关键 ConVar

| ConVar | 默认 | 说明 |
|---|---|---|
| gokz_guideline_enabled | 1 | 总开关 |
| gokz_guideline_url | https://cngokzreplay.iquankz.cn | R2 基础 URL |
| gokz_guideline_api_key | (空) | X-API-Key 鉴权 |
| gokz_guideline_auto_check | 1 | 换图自动检查 |
| gokz_guideline_color | 148 0 211 110 | 紫色线条 |
| gokz_guideline_beam_lifetime | 4.0 | 与 JumpBeam 一致 |
| gokz_guideline_beam_width | 0.25 | 与 JumpBeam 一致 |
| gokz_guideline_refresh_interval | 2.0 | 重发间隔（< lifetime） |
| gokz_guideline_smooth / smooth_points | 1 / 1 | Chaikin 平滑 |
| gokz_guideline_sample_dist | 32.0 | 降采样距离（3D）|
| gokz_guideline_break_dist | 1000.0 | 断点判定（3D 距离）|
| gokz_guideline_vertical_break_dist | 300.0 | 双层断点（水平 <64 且垂直 >300 断开）|

---

## 8. CI 自动化

- **pr-check.yml**：PR → main 时编译（STRICT 警告即错误）+ 上传测试包 artifact（`guideline-TEST-PR{N}-v{V}-{sha}.zip`）
- **release.yml**：push main 时自动 bump patch 版本号（`chore: bump version to vX.Y.Z [skip ci]` 提交避免循环触发）→ 编译 → 打 tag → 创建 GitHub Release（附件 `guideline-vX.Y.Z.zip`）

版本号维护在 `addons/sourcemod/scripting/include/guideline/version.inc` 的 `GL_VERSION` / `GL_VERSION_MAJOR/MINOR/PATCH`。

## 9. 测试工具

`tools/make_test_replay.py` 可生成符合 v2 格式的测试录像（直线轨迹 + 起跳点 + 传送断点）：

```sh
python3 tools/make_test_replay.py /tmp/test.replay testmap 500
```

验证方式：把生成文件放入 `data/gokz-guideline/<真实地图名>_pro.replay`，换图后 `!gl` 应看到紫色直线 + 断点。
