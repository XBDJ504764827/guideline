/*
	Guideline - Routes
	路线数据管理：按 GOKZ 模式（KZT/SKZ/VNL）分别存储路线、轨迹降采样、来源追踪、缓存路径。
	解析与下载分别由 replayfile.sp / http.sp 负责。

	当前版本只支持主图 course 0（B1/B2 不需要）。
	模式 0=Vanilla(VNL)、1=SimpleKZ(SKZ)、2=KZTimer(KZT)（与 GOKZ_GetCoreOption 一致）。
*/



// =====[ STRUCTS ]=====

enum struct TrackPoint
{
	float origin[3];
	bool isTakeoff; // 起跳帧（flags bit 23）
	bool isTeleport; // 传送帧（flags bit 22）→ 断点
	bool isBreak;  // 断点标记（双层错位/传送/距离断，渲染据此断开连线）
	int tick; // 原始录像 tick 索引
}

// 路线来源
enum
{
	GL_SOURCE_NONE = 0,
	GL_SOURCE_CACHE,   // 插件从 R2 下载的缓存
	GL_SOURCE_LOCAL,   // 服务器本地 GOKZ 录像
	GL_SOURCE_REMOTE   // 从 R2 刚下载
};

enum struct Route
{
	int mode;         // GOKZ 模式（0=VNL 1=SKZ 2=KZT）
	float time;       // 录像成绩（秒）
	int teleports;    // 主图 NUB/PRO
	int tickrate;     // 录像 tickrate
	int source;       // 路线来源（GL_SOURCE_*）
	char playerName[32];
	ArrayList points; // TrackPoint 数组（降采样后）
	bool loaded;
	bool parsing;     // 正在解析中（防止重复触发）
	bool downloading; // 正在下载中（防止重复触发）
}



// =====[ STATE ]=====

// 按模式存储路线（0=VNL, 1=SKZ, 2=KZT），每条路线的 ArrayList 由 Route 结构持有
Route gGL_Routes[3];
int gGL_PendingSource; // 解析完成时的来源标记（http.sp 设置，replayfile 完成时读取）
int gGL_PendingMode;   // 解析完成时的目标模式（http.sp 设置）
int gGL_BuildMode;     // 当前正在构建/渲染的模式（默认 GOKZ 默认模式）



// =====[ PUBLIC ]=====

void GL_OnMapStart_Routes()
{
	GL_ClearAllRoutes();
}

void GL_OnMapEnd_Routes()
{
	GL_ClearAllRoutes();
}

void GL_ClearAllRoutes()
{
	for (int mode = 0; mode < 3; mode++)
	{
		GL_ClearRoute(mode);
	}
	// 同步清空渲染线段缓存（避免旧路线线条残留）
	GL_ClearSegmentCache();
}

void GL_ClearRoute(int mode)
{
	if (mode < 0 || mode > 2) return;

	if (gGL_Routes[mode].points != null)
	{
		delete gGL_Routes[mode].points;
	}
	gGL_Routes[mode].points = null;
	gGL_Routes[mode].loaded = false;
	gGL_Routes[mode].parsing = false;
	gGL_Routes[mode].downloading = false;
	gGL_Routes[mode].time = 0.0;
	gGL_Routes[mode].teleports = 0;
	gGL_Routes[mode].tickrate = 128;
	gGL_Routes[mode].source = GL_SOURCE_NONE;
	gGL_Routes[mode].playerName[0] = '\0';
}

// 获取指定模式的路线（不存在则返回 false）
bool GL_GetRoute(int mode, Route route)
{
	if (mode < 0 || mode > 2)
	{
		return false;
	}
	route = gGL_Routes[mode];
	return true;
}

// 获取指定模式路线是否可用
bool GL_HasRoute(int mode = -1)
{
	if (mode < 0)
	{
		mode = gGL_BuildMode;
	}
	if (mode < 0 || mode > 2)
	{
		return false;
	}
	return gGL_Routes[mode].loaded && gGL_Routes[mode].points != null
		&& gGL_Routes[mode].points.Length >= 2;
}

// 当前路线成绩（供三方对比）：返回指定模式的时间
bool GL_GetCurrentRouteTime(float &time, int mode = -1)
{
	if (mode < 0)
	{
		mode = gGL_BuildMode;
	}
	if (mode < 0 || mode > 2)
	{
		return false;
	}
	if (!gGL_Routes[mode].loaded || gGL_Routes[mode].time <= 0.0)
	{
		return false;
	}
	time = gGL_Routes[mode].time;
	return true;
}

// 设置解析完成时的来源/模式标记（http.sp 在调用 GL_StartParsing 前设置）
void GL_SetPendingSource(int source)
{
	gGL_PendingSource = source;
}

void GL_SetPendingMode(int mode)
{
	gGL_PendingMode = mode;
}

// 构建 R2/本地缓存路径：data/gokz-guideline/<map>_<mode>_pro.replay
void GL_BuildCachePath(char[] buffer, int maxlength, int mode = -1)
{
	if (mode < 0) mode = gGL_BuildMode;
	char modeStr[8];
	GL_GetModeShortName(mode, modeStr, sizeof(modeStr));
	BuildPath(Path_SM, buffer, maxlength, "data/gokz-guideline/%s_%s_pro.replay", gC_MapName, modeStr);
}

// 构建 sha256 缓存文件路径（meta 新鲜度比对用）
void GL_BuildCacheShaPath(char[] buffer, int maxlength, int mode = -1)
{
	if (mode < 0) mode = gGL_BuildMode;
	char modeStr[8];
	GL_GetModeShortName(mode, modeStr, sizeof(modeStr));
	BuildPath(Path_SM, buffer, maxlength, "data/gokz-guideline/%s_%s_pro.sha256", gC_MapName, modeStr);
}

// 模式短名（与 stratosphere 键名一致：vnl/skz/kzt）
void GL_GetModeShortName(int mode, char[] buffer, int maxlength)
{
	switch (mode)
	{
		case 0: strcopy(buffer, maxlength, "vnl");
		case 1: strcopy(buffer, maxlength, "skz");
		default: strcopy(buffer, maxlength, "kzt");
	}
}

// 解析完成回调（replayfile.sp 调用）
void GL_RouteFinishParsed(const char[] playerName, float time, int teleports, int tickrate, ArrayList points)
{
	int mode = gGL_PendingMode;
	if (mode < 0 || mode > 2)
	{
		mode = gGL_BuildMode;
	}

	GL_ClearRoute(mode);

	gGL_Routes[mode].mode = mode;
	gGL_Routes[mode].time = time;
	strcopy(gGL_Routes[mode].playerName, sizeof(Route::playerName), playerName);
	gGL_Routes[mode].teleports = teleports;
	gGL_Routes[mode].tickrate = tickrate < 1 ? 128 : tickrate;
	gGL_Routes[mode].points = points;
	gGL_Routes[mode].loaded = true;
	gGL_Routes[mode].parsing = false;
	gGL_Routes[mode].downloading = false;
	gGL_Routes[mode].source = gGL_PendingSource;

	// 若该模式是当前构建模式，构建渲染线段缓存
	if (mode == gGL_BuildMode)
	{
		GL_BuildSegmentCache(points);
	}

	// 来源名（日志用）
	static const char GL_SourceNames[4][8] = { "none", "cache", "local", "remote" };
	GL_LogDebug("Route parsed: mode=%d player=\"%s\" time=%.2f teleports=%d points=%d tickrate=%d source=%s",
		mode, playerName, time, teleports, points.Length, tickrate, GL_SourceNames[gGL_PendingSource]);
}



// =====[ DOWNSAMPLE ]=====

// 轨迹降采样：距离抽稀 + 起跳点/传送点强制保留 + 断点处理
ArrayList GL_Downsample(ArrayList raw)
{
	ArrayList result = new ArrayList(sizeof(TrackPoint));

	if (raw == null || raw.Length == 0)
	{
		return result;
	}

	float sampleDist = GL_GetSampleDist();
	float breakDist = GL_GetBreakDist();
	float verticalBreakDist = GL_GetVerticalBreakDist();

	TrackPoint last;
	raw.GetArray(0, last);
	result.PushArray(last);
	float lastOrigin[3];
	lastOrigin = last.origin;

	for (int i = 1; i < raw.Length; i++)
	{
		TrackPoint tp;
		raw.GetArray(i, tp);

		// 使用 3D 距离：双层地图上层/下层水平距离近但垂直距离大，
		// 水平距离会错误合并上下层点；3D 距离可正确区分
		float dist = GL_Distance3D(tp.origin, lastOrigin);

		// 断点：保留（标记断开，绘制时跳过连线）
		// 双层场景：水平距离近但垂直距离突变（> verticalBreakDist）也视为断点
		float vertDelta = FloatAbs(tp.origin[2] - lastOrigin[2]);
		bool verticalBreak = vertDelta > verticalBreakDist
			&& GL_HorizontalDistance(tp.origin, lastOrigin) < 64.0;
		if (dist > breakDist || verticalBreak || tp.isTeleport)
		{
			tp.isBreak = true;
			result.PushArray(tp);
			lastOrigin = tp.origin;
			continue;
		}

		// 起跳点/传送点强制保留；其余按距离抽稀
		if (tp.isTakeoff || dist >= sampleDist)
		{
			result.PushArray(tp);
			lastOrigin = tp.origin;
		}
	}

	// 确保终点被保留
	TrackPoint finalPoint;
	raw.GetArray(raw.Length - 1, finalPoint);
	TrackPoint lastResult;
	result.GetArray(result.Length - 1, lastResult);
	if (GL_Distance3D(finalPoint.origin, lastResult.origin) > 0.1)
	{
		result.PushArray(finalPoint);
	}

	return result;
}
