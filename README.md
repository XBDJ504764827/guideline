# Guideline

CS:GO GOKZ 路线指引插件：从**插件缓存 / 服务器本地 GOKZ 录像 / R2 存储**三方中选取最快（time 最小）的主图路线录像，解析玩家轨迹并以 **GOKZ JumpBeam 同款激光束**（紫色、0.25 宽、Chaikin 圆角平滑）绘制玩家**附近**的路线，帮助玩家跟随路线完成地图。

与 [stratosphere](https://github.com/XBDJ504764827/stratosphere) 是一对：**stratosphere 负责把服务器纪录录像上传到 R2（生产者）**，**guideline 负责按成绩择优下载并绘制路线（消费者）**。

## 特性

- 🏆 **三方择优**：插件下载缓存 → 本服 GOKZ 录像 → R2 存储，按录像 header 中的成绩 **time** 对比，**最快者胜**（本服有人跑出更快成绩即用本地，无需下载）
- 📂 **本地录像按 header 归类**：不解析文件名，直接读录像 header 里的 course/mode，因此 `0_0_VNL_NRM_NUB.replay`、`365313220_0_KZT_NRM_PRO.replay` 或被改名的文件都能正确配对到对应模式
- 🔑 **键名对齐 stratosphere**：`wr/{map}/0_0_{MODE}_NRM_{PRO|NUB}.replay`，R2 地址 `https://cngokzreplay.iquankz.cn` + `X-API-Key` 密钥
- 📥 **两阶段下载省流量**：`?meta=1` 先查 sha256/time_ms 比对缓存，一致则不下载 body
- 💜 **JumpBeam 同款线条**：`laserbeam.vmt`、宽度 0.25、FadeLength 10、Amplitude 0、速度 0，默认紫色（148 0 211 110）；Chaikin 角切割平滑，拐角自然圆弧
- ⚡ **附近窗口渲染**：只绘制玩家周围窗口内的路线段，开销与路线总长无关；约 20 条/秒/人
  （旧版全图轮转约 1067 条/秒/人，降低约 50 倍），热路径零临时分配
- 🧵 **保形简化**：把近似共线的短段合并成长段（Chaikin 的价值只在拐角），
  发送量再降约 8.7 倍而线条形变 ≤2 units（玩家模型宽 32 units，肉眼不可见）
- 🔇 **传送点断开**：录像 flags bit 22（teleport）处不连线，避免线条穿地图（已确认：坐标实际走过、捷径/绕路如实显示、传送跳过）
- 🚀 **`!gl` 开关**：每个玩家独立，只显示给本人；需手动开启，换图/重连后默认关闭
- ♿ **多模式支持**：KZT/SKZ/VNL 三种模式的路线独立加载，玩家切换 GOKZ 模式时自动显示对应模式路线
- 🔄 **自动检查**：换图时自动检查一次 + 本服破纪录自动重查 + `!routerefresh` 手动强制刷新（管理员）
- 🧱 模块化代码结构（单入口 .sp + 模块目录，最终只编译一个 guideline.smx）
- ⚙️ CI 自动化：PR 编译检查 + 测试包 artifact；合并 main 自动 bump 版本号并发布 Release

## 目录结构

```
addons/sourcemod/scripting/guideline.sp   # 唯一入口
addons/sourcemod/scripting/guideline/     # 模块目录
addons/sourcemod/scripting/include/guideline/version.inc  # 版本号（CI 自动更新）
cfg/sourcemod/gokz/gokz-guideline.cfg     # 配置模板（运行时 autoexecconfig 生成）
docs/DEVELOPMENT.md                       # 开发文档
build.sh                                  # 编译脚本
.github/workflows/pr-check.yml            # PR：编译检查 + 测试包
.github/workflows/release.yml             # push main：自动 bump 版本 + Release
```

## 编译

```sh
./build.sh setup   # 首次：下载 SourceMod 1.11 + GOKZ includes 到 .sm111/ .deps/
./build.sh         # 编译 → addons/sourcemod/plugins/guideline.smx
STRICT=1 ./build.sh  # 警告即错误（CI 用）
```

## 安装

1. 下载 `Releases` 中 `guideline-vX.Y.Z.zip`（或 PR 测试包 `guideline-TEST-PR{N}.zip`）。
2. 将 `addons/`、`cfg/` 合并进 CS:GO 服务器根目录。
3. 在 `cfg/sourcemod/gokz/gokz-guideline.cfg` 中填写：
   - `gokz_guideline_url`：`https://cngokzreplay.iquankz.cn`（默认已填）
   - `gokz_guideline_api_key`：与 stratosphere 上传 Worker 约定的密钥
4. 重启服务器或 `sm plugins load guideline`。

## 命令

- `!gl` — 开关路线显示（每玩家独立，只显示给本人）
- `!routerefresh` — 强制刷新本图路线（管理员，ADMFLAG_GENERIC）

## 依赖

- SourceMod 1.11
- SteamWorks 扩展（R2 下载必需；无则只能用本地录像）
- GOKZ + gokz-core
- **stratosphere（配套上传插件）**：R2 中的录像由它生产，键名约定一致（`wr/{map}/0_0_{MODE}_NRM_{TYPE}.replay`）

## 与 stratosphere 的配合

```
打破服务器纪录 → stratosphere 上传 wr/{map}/0_0_{MODE}_NRM_{TYPE}.replay
→ guideline 换图/手动检查时三方对比（缓存/本地/R2）→ 最快录像解析 → 玩家 !gl 看到附近路线
```

## 性能说明

渲染采用「附近窗口 + 窗口内滚动续期 + 保形简化」，与旧版「全图分批轮转」相比：

| | 旧版（全图轮转） | 现在 |
|---|---|---|
| 每玩家发送量 | 约 1067 条/秒 | 约 20 条/秒（窗口 + 共线合并） |
| 与路线总长的关系 | 总长越长，全图刷新周期越长 | 无关，只与窗口半径有关 |
| 热路径临时分配 | 每个 tick 分配扫描数组（约 32KB） | 无 |
| 附近段查找 | 全局扫描 + 插入排序 O(n²) | 进度游标局部搜索 O(±数百) |
| 颜色解析 | 每 tick 每玩家解析字符串 | 缓存，仅 ConVar 变更时刷新 |
| 玩家静止时 | 照常全量重发 | 只做最低额度续期 |

**保形简化**是最大的一档收益：Chaikin 平滑的价值只在拐角（把折线切成圆弧），
直线段被切成 8u 碎片纯属浪费，而发送量正比于 1/平均段长。
简化把近似共线的短段合并（拐角因中间点偏离超限而自然保留），
平均段长从 8u 升到约 70u，段数降为 1/6~1/9，实测发送量降低约 8.7 倍。
形变上限由 `gokz_guideline_simplify_tol` 控制（默认 2 units，玩家模型宽 32 units）。

性能旋钮：`gokz_guideline_near_dist`（窗口半径，默认 1500）与
`gokz_guideline_beam_lifetime`（默认 4.0s）都与发送量成反比；
`gokz_guideline_simplify_tol` 提高可进一步降低发送量（代价是线条更"直"）。
发送量低于 `beam_lifetime` 所需的自动值时线条会闪烁，`gokz_guideline_batch_size` 只作为兜底硬顶。
