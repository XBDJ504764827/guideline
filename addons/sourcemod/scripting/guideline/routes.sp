/*
	Guideline - Routes
	路线数据管理：当前路线（Route 单例）、轨迹降采样、来源追踪、缓存路径。
	解析与下载分别由 replayfile.sp / http.sp 负责。

	当前版本只支持主图 course 0（B1/B2 不需要）。
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

Route gGL_Route; // 当前地图主图路线（单例，course 0）
int gGL_PendingSource; // 解析完成时的来源标记（http.sp 设置，replayfile 完成时读取）



// =====[ PUBLIC ]=====

void GL_OnMapStart_Routes()
{
	GL_ClearCurrentRoute();
}

void GL_OnMapEnd_Routes()
{
	GL_ClearCurrentRoute();
}

void GL_ClearCurrentRoute()
{
	if (gGL_Route.points != null)
	{
		delete gGL_Route.points;
	}
	gGL_Route.points = null;
	gGL_Route.loaded = false;
	gGL_Route.parsing = false;
	gGL_Route.downloading = false;
	gGL_Route.time = 0.0;
	gGL_Route.teleports = 0;
	gGL_Route.tickrate = 128;
	gGL_Route.source = GL_SOURCE_NONE;
	gGL_Route.playerName[0] = '\0';

	// 同步清空渲染线段缓存（避免旧路线线条残留）
	GL_ClearSegmentCache();
}

// 是否已有一条可用的路线
bool GL_HasRoute()
{
	return gGL_Route.loaded && gGL_Route.points != null && gGL_Route.points.Length >= 2;
}

// 当前路线成绩（供三方对比）
bool GL_GetCurrentRouteTime(float &time)
{
	if (!gGL_Route.loaded || gGL_Route.time <= 0.0)
	{
		return false;
	}
	time = gGL_Route.time;
	return true;
}

// 设置解析完成时的来源标记（http.sp 在调用 GL_StartParsing 前设置）
void GL_SetPendingSource(int source)
{
	gGL_PendingSource = source;
}

// 构建 R2 下载缓存路径：data/gokz-guideline/<map>_pro.replay
void GL_BuildCachePath(char[] buffer, int maxlength)
{
	BuildPath(Path_SM, buffer, maxlength, "data/gokz-guideline/%s_pro.replay", gC_MapName);
}

// 构建 sha256 缓存文件路径（meta 新鲜度比对用）
void GL_BuildCacheShaPath(char[] buffer, int maxlength)
{
	BuildPath(Path_SM, buffer, maxlength, "data/gokz-guideline/%s_pro.sha256", gC_MapName);
}

// 解析完成回调（replayfile.sp 调用）
void GL_RouteFinishParsed(const char[] playerName, float time, int teleports, int tickrate, ArrayList points)
{
	GL_ClearCurrentRoute();

	gGL_Route.time = time;
	strcopy(gGL_Route.playerName, sizeof(gGL_Route.playerName), playerName);
	gGL_Route.teleports = teleports;
	gGL_Route.tickrate = tickrate < 1 ? 128 : tickrate;
	gGL_Route.points = points;
	gGL_Route.loaded = true;
	gGL_Route.parsing = false;
	gGL_Route.downloading = false;
	gGL_Route.source = gGL_PendingSource;

	// 构建渲染线段缓存（分批发送用）
	GL_BuildSegmentCache(points);

	GL_LogDebug("Route parsed: player=\"%s\" time=%.2f teleports=%d points=%d tickrate=%d source=%d",
		playerName, time, teleports, points.Length, tickrate, gGL_Route.source);
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
