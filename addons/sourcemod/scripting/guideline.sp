/*
	Guideline
	---------------------------------------------
	CS:GO GOKZ 路线指引插件：从「插件缓存 / 服务器本地 GOKZ 录像 / R2 存储」三方
	中选取最快（time 最小）的主图路线录像，解析玩家轨迹并以 GOKZ JumpBeam
	同款激光束（laserbeam.vmt、宽度 0.25、圆角平滑）绘制整条路线。

	【路线来源优先级（按成绩 time 对比，最快者胜）】
	  1. 插件自己从 R2 下载并存下的缓存（data/gokz-guideline/）
	  2. 服务器本地 GOKZ 录像（data/gokz-replays/_runs/<map>/，玩家在本服跑出的录像）
	  3. R2 存储（https://cngokzreplay.iquankz.cn，配合 stratosphere 生产端）
	检查时机：地图加载时自动检查 + !routerefresh 手动强制刷新。

	【键名约定（与 stratosphere 完全对齐）】
	  R2:  {base}/wr/<vnl|skz|kzt>/<地图名>/<pro|tp>.replay
	  本地: data/gokz-replays/_runs/<地图名>/<course>_<MODE>_<STYLE>_<TIMETYPE>.replay
	  - 只处理 course 0（主图）；B1/B2 忽略
	  - 传送点（flags bit 22）跳过不连线，避免线条穿地图

	【显示规则】
	  !gl        每个玩家独立开关，只显示给本人，不影响他人
	  !gl 开启后路线常驻显示（定时重发光束，GOKZ JumpBeam 同款视觉）
	  - 线条：TE_SetupBeamPoints + materials/sprites/laserbeam.vmt
	          宽度 0.25 / 0.25、FadeLength 10、Amplitude 0、速度 0（与 JumpBeam 一致）
	  - 颜色：紫色（默认 148 0 211 110，可配置）
	  - 拐角：Chaikin 角切割平滑（默认 1 次迭代），形成与 JumpBeam 一致的自然圆弧

	【Worker 协议（与 stratosphere 一致）】
	  GET {url}/wr/{mode}/{map}/{type}.replay?meta=1
	    Headers: X-API-Key: <gokz_guideline_api_key>
	    响应 JSON: { exists, time_ms, sha256, size }
	  GET {url}/wr/{mode}/{map}/{type}.replay   → 录像二进制

	依赖：SourceMod 1.11、SteamWorks 扩展（无则禁用 R2 下载）、gokz-core、
	      gokz-replays（仅要求本地 _runs 目录格式；不依赖其 API）。
*/

#include <sourcemod>
#include <sdktools>
#include <clientprefs>

#include <gokz/core>

#undef REQUIRE_PLUGIN
#include <gokz/replays>
#define REQUIRE_PLUGIN

#undef REQUIRE_EXTENSIONS
#include <SteamWorks>

#include <autoexecconfig>

#include <guideline/version>

#pragma newdecls required
#pragma semicolon 1



public Plugin myinfo =
{
	name = "Guideline",
	author = "XBDJ",
	description = "GOKZ jump map route guide driven by fastest replay (cache / local / R2)",
	version = GL_VERSION,
	url = ""
};



// =====[ GLOBAL STATE ]=====

bool gB_SteamWorksOK;
char gC_MapName[64]; // 当前地图名（小写，与 gokz-replays 的 _runs 目录命名一致）
int gI_BeamModel;    // laserbeam 激光束模型索引（OnMapStart 预缓存）
Handle gH_RenderTimer;

// 模块 include 顺序 = 依赖顺序：被依赖的模块在前
#include "guideline/convars.sp"
#include "guideline/helpers.sp"
#include "guideline/state.sp"
#include "guideline/replayfile.sp"
#include "guideline/localreplay.sp"
#include "guideline/routes.sp"
#include "guideline/render.sp"
#include "guideline/http.sp"
#include "guideline/commands.sp"



// =====[ PLUGIN EVENTS ]=====

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("guideline");
	return APLRes_Success;
}

public void OnPluginStart()
{
	GL_CreateConVars();
	GL_CreateCookies();
	GL_RegisterCommands();

	// 渲染定时器：路线常驻重发（与 JumpBeam 的生命周期配合）
	GL_RestartRenderTimer();
}

// —— from gokz-replays ——
// 玩家跑出破纪录录像被永久保存（tempReplay=false）时，
// 本服最快录像可能更新 → 自动触发一次路线检查（仅 course 0）
public Action GOKZ_RP_OnReplaySaved(int client, int replayType,
	const char[] map, int course, int timeType, float time,
	const char[] filePath, bool tempReplay)
{
	// 永远放行，不干扰 gokz-replays 的本地保存与临时文件清理
	if (replayType != ReplayType_Run || tempReplay || course != 0)
	{
		return Plugin_Continue;
	}

	// 地图必须匹配（避免上一张图延迟触发的 forward 干扰当前路线）
	char currentMap[64];
	GetCurrentMap(currentMap, sizeof(currentMap));
	GL_ToLower(currentMap, sizeof(currentMap));
	if (!StrEqual(currentMap, map, false))
	{
		return Plugin_Continue;
	}

	// 如果当前路线已加载，且新录像比当前路线更快 → 重新检查
	float currentTime = 0.0;
	bool hasRoute = GL_GetCurrentRouteTime(currentTime);
	if (GL_GetEnabled() && (!hasRoute || time < currentTime))
	{
		GL_LogDebug("New faster record saved (%.2fs, was %.2fs) -> recheck route", time, currentTime);
		GL_CheckRoutes(GL_STRATEGY_AUTO, GetClientUserId(client));
	}

	return Plugin_Continue;
}

public void OnAllPluginsLoaded()
{
	gB_SteamWorksOK = (GetExtensionFileStatus("SteamWorks.ext") > 0);
	if (!gB_SteamWorksOK)
	{
		LogError("[guideline] SteamWorks extension not loaded; R2 route downloads are disabled.");
	}

	// 有玩家在服上的热加载场景：立即为已开启 !gl 的玩家加载路线
	for (int client = 1; client <= MaxClients; client++)
	{
		if (GL_IsValidClient(client) && GL_IsOpen(client))
		{
			GL_EnsureRouteForClient(client);
		}
	}
}

public void OnMapStart()
{
	GetCurrentMap(gC_MapName, sizeof(gC_MapName));
	GL_ToLower(gC_MapName, sizeof(gC_MapName));

	gI_BeamModel = PrecacheModel("materials/sprites/laserbeam.vmt", true);

	GL_OnMapStart_Routes();
	GL_OnMapStart_Render();

	// 换图自动检查（延迟 3 秒，避开服务器高峰）
	if (GL_GetAutoCheck() && GL_GetEnabled())
	{
		CreateTimer(3.0, GL_Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnMapEnd()
{
	GL_OnMapEnd_Routes();
}

public void OnClientCookiesCached(int client)
{
	GL_OnClientCookiesCached(client);
}

public void OnClientDisconnect(int client)
{
	GL_OnClientDisconnect(client);
}

public void OnPluginEnd()
{
	if (gH_RenderTimer != null)
	{
		KillTimer(gH_RenderTimer);
		gH_RenderTimer = null;
	}
	GL_OnMapEnd_Routes();
	GL_AbortParsing();
}



// =====[ TIMERS ]=====

public Action GL_Timer_AutoCheck(Handle timer)
{
	GL_CheckRoutes(GL_STRATEGY_AUTO);
	return Plugin_Stop;
}
