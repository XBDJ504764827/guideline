/*
	Guideline - ConVars
	配置生成于 cfg/sourcemod/gokz/gokz-guideline.cfg（与其它 GOKZ 配置同目录）。
	首次启动由 autoexecconfig 生成；仓库内保留模板参考。
*/



// =====[ CVARS ]=====

ConVar gCV_Enabled;
ConVar gCV_URL;
ConVar gCV_APIKey;
ConVar gCV_AutoCheck;
ConVar gCV_Debug;
ConVar gCV_Color;
ConVar gCV_BeamLifetime;
ConVar gCV_BeamWidth;
ConVar gCV_RefreshInterval;
ConVar gCV_Smooth;
ConVar gCV_SmoothPoints;
ConVar gCV_SampleDist;
ConVar gCV_BreakDist;
ConVar gCV_VerticalBreakDist;
ConVar gCV_MaxSegments;
ConVar gCV_ParseBatch;
ConVar gCV_MetaTimeout;
ConVar gCV_DownloadTimeout;
ConVar gCV_BatchSize;



// =====[ COOKIE ]=====

Cookie gH_EnabledCookie; // !gl 开关持久化（每个玩家独立）



// =====[ PUBLIC ]=====

void GL_CreateConVars()
{
	AutoExecConfig_SetFile("gokz-guideline", "sourcemod/gokz");
	AutoExecConfig_SetCreateFile(true);
	AutoExecConfig_SetCreateDirectory(true);

	gCV_Enabled = AutoExecConfig_CreateConVar("gokz_guideline_enabled", "1",
		"总开关：是否启用 guideline 路线显示功能（关闭后 !gl 无效）。", _, true, 0.0, true, 1.0);
	gCV_URL = AutoExecConfig_CreateConVar("gokz_guideline_url", "https://cngokzreplay.iquankz.cn",
		"R2 存储基础 URL（域名 + 可选前缀，不含路径参数），插件自动拼接 /wr/<模式>/<地图>/<pro|tp>.replay。");
	gCV_APIKey = AutoExecConfig_CreateConVar("gokz_guideline_api_key", "",
		"R2 鉴权密钥（与 stratosphere 上传 Worker 约定的 X-API-Key）。", FCVAR_PROTECTED);
	gCV_AutoCheck = AutoExecConfig_CreateConVar("gokz_guideline_auto_check", "1",
		"地图加载时是否自动检查并加载最快路线。", _, true, 0.0, true, 1.0);
	gCV_Debug = AutoExecConfig_CreateConVar("gokz_guideline_debug", "0",
		"调试日志开关。", _, true, 0.0, true, 1.0);
	gCV_Color = AutoExecConfig_CreateConVar("gokz_guideline_color", "148 0 211 110",
		"路线线条颜色 \"R G B A\"（0-255）。默认为紫色。");
	gCV_BeamLifetime = AutoExecConfig_CreateConVar("gokz_guideline_beam_lifetime", "4.0",
		"线条存活时间（秒），与 GOKZ JumpBeam 一致。" , _, true, 0.5, true, 10.0);
	gCV_BeamWidth = AutoExecConfig_CreateConVar("gokz_guideline_beam_width", "0.25",
		"线条宽度（与 GOKZ JumpBeam 一致）。", _, true, 0.1, true, 8.0);
	gCV_RefreshInterval = AutoExecConfig_CreateConVar("gokz_guideline_refresh_interval", "0.3",
		"路线发光束的刷新间隔（秒）——分批滚动发送，每周期发一批线段；\n		需保证 路线段数/批大宽 × 间隔 < beam_lifetime 才能整条覆盖。", _, true, 0.1, true, 5.0);
	gCV_Smooth = AutoExecConfig_CreateConVar("gokz_guideline_smooth", "1",
		"路线平滑开关：Chaikin 角切割细分，拐角处切出圆角（与 JumpBeam 视觉一致）。", _, true, 0.0, true, 1.0);
	gCV_SmoothPoints = AutoExecConfig_CreateConVar("gokz_guideline_smooth_points", "1",
		"Chaikin 细分迭代次数（0-3）：越大越圆润，每迭代一次段数约 ×2。", _, true, 0.0, true, 3.0);
	gCV_SampleDist = AutoExecConfig_CreateConVar("gokz_guideline_sample_dist", "32.0",
		"轨迹降采样距离阈值（units）：相邻保留点水平距离小于该值则丢弃（起跳点除外）。", _, true, 8.0, true, 512.0);
	gCV_BreakDist = AutoExecConfig_CreateConVar("gokz_guideline_break_dist", "1000.0",
		"轨迹断点判定距离（units）：相邻两点 3D 距离超过该值视为断点（传送/异常），绘制时断开。", _, true, 100.0, true, 5000.0);
	gCV_VerticalBreakDist = AutoExecConfig_CreateConVar("gokz_guideline_vertical_break_dist", "300.0",
		"双层断点判定距离（units）：相邻两点水平距离 < 64 但垂直距离超过该值视为断点（上下层错位），绘制时断开。", _, true, 100.0, true, 2000.0);
	gCV_MaxSegments = AutoExecConfig_CreateConVar("gokz_guideline_max_segments", "2000",
		"完整路线最大绘制线段数上限（保护上限，超出则自动降低平滑迭代仍保持全图）。", _, true, 16.0, true, 5000.0);
	gCV_ParseBatch = AutoExecConfig_CreateConVar("gokz_guideline_parse_batch", "5000",
		"录像解析每批处理的帧数（分帧解析防止服务器卡顿）。", _, true, 1000.0, true, 50000.0);
	gCV_MetaTimeout = AutoExecConfig_CreateConVar("gokz_guideline_meta_timeout", "10",
		"R2 meta 查询超时（秒）。", _, true, 3.0, true, 60.0);
	gCV_DownloadTimeout = AutoExecConfig_CreateConVar("gokz_guideline_download_timeout", "30",
		"R2 录像下载超时（秒）。", _, true, 5.0, true, 120.0);
	gCV_BatchSize = AutoExecConfig_CreateConVar("gokz_guideline_batch_size", "160",
		"每渲染周期发送的最大线段数（分批滚动发送，防止一次性发送过多被客户端丢弃；\n		建议 段数/批数×刷新间隔 < beam_lifetime 保证连续显示）。", _, true, 8.0, true, 256.0);

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();

	HookConVarChange(gCV_RefreshInterval, OnRefreshIntervalChanged);
}

void GL_CreateCookies()
{
	gH_EnabledCookie = new Cookie("gokz-guideline-enabled", "Guideline route display enabled (per player)", CookieAccess_Private);
}

public void OnRefreshIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GL_RestartRenderTimer();
}



// =====[ GETTERS =====]

bool GL_GetEnabled()
{
	return gCV_Enabled.BoolValue;
}

bool GL_GetAutoCheck()
{
	return gCV_AutoCheck.BoolValue;
}

bool GL_GetDebug()
{
	return gCV_Debug.BoolValue;
}

float GL_GetBeamLifetime()
{
	return gCV_BeamLifetime.FloatValue;
}

float GL_GetBeamWidth()
{
	return gCV_BeamWidth.FloatValue;
}

float GL_GetRefreshInterval()
{
	return gCV_RefreshInterval.FloatValue;
}

bool GL_GetSmooth()
{
	return gCV_Smooth.BoolValue;
}

int GL_GetSmoothPoints()
{
	return gCV_SmoothPoints.IntValue;
}

float GL_GetSampleDist()
{
	return gCV_SampleDist.FloatValue;
}

float GL_GetBreakDist()
{
	return gCV_BreakDist.FloatValue;
}

float GL_GetVerticalBreakDist()
{
	return gCV_VerticalBreakDist.FloatValue;
}

int GL_GetMaxSegments()
{
	return gCV_MaxSegments.IntValue;
}

int GL_GetParseBatch()
{
	return gCV_ParseBatch.IntValue;
}

int GL_GetMetaTimeout()
{
	return gCV_MetaTimeout.IntValue;
}

int GL_GetDownloadTimeout()
{
	return gCV_DownloadTimeout.IntValue;
}

int GL_GetBatchSize()
{
	return gCV_BatchSize.IntValue;
}

void GL_GetColor(int color[4])
{
	char raw[32];
	gCV_Color.GetString(raw, sizeof(raw));
	char parts[4][8];
	int count = ExplodeString(raw, " ", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < 4; i++)
	{
		color[i] = (i < count) ? StringToInt(parts[i]) : 255;
		if (color[i] < 0) color[i] = 0;
		if (color[i] > 255) color[i] = 255;
	}
}
