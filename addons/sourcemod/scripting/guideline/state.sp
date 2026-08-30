/*
	Guideline - Player State
	玩家 !gl 开关状态（Cookie 持久化，内存镜像）与按需加载标记。
	独立模块以解决 commands/render 之间的双向依赖。
*/



// =====[ STATE ]=====

bool gB_GLOpen[MAXPLAYERS + 1]; // !gl 开关（Cookie 持久化，内存镜像）
bool gB_GLWantRoute[MAXPLAYERS + 1]; // 需要路线但尚未加载时置位（渲染不打扰）
float gF_GLWantRouteTime[MAXPLAYERS + 1]; // wantRoute 置位时间（重试间隔用）


// =====[ PUBLIC ]=====

void GL_OnMapStart_State()
{
	// 需求：玩家首次进入/换图后默认关闭，需手动 !gl 才开启。
	// 因此换图时强制清空所有在线玩家的 gB_GLOpen（覆盖 Cookie 旧值），
	// 渲染层将不再自动显示，!gl 开关每张图需手动打开。
	for (int client = 1; client <= MaxClients; client++)
	{
		gB_GLOpen[client] = false;
		gB_GLWantRoute[client] = false;
		gF_GLWantRouteTime[client] = 0.0;
		// 同步把持久化 Cookie 置 0，避免旧的 "1" 在重连时又被读取
		if (GL_IsValidClient(client))
		{
			gH_EnabledCookie.Set(client, "0");
		}
	}
}

// Cookie 缓存完成：始终默认关闭（需手动 !gl），忽略旧 Cookie 的 "1"
// 旧版本曾持久化开启状态，现改为每图/每次进入均需手动打开。
void GL_OnClientCookiesCached_State(int client)
{
	// 清理旧 Cookie（若曾为 "1"），确保首次进入/重连均为关闭
	gH_EnabledCookie.Set(client, "0");
	gB_GLOpen[client] = false;
	GL_LogDebug("Client %d cookie: enabled=0 (forced closed, manual !gl required)", client);
}

void GL_OnClientDisconnect_State(int client)
{
	gB_GLOpen[client] = false;
	gB_GLWantRoute[client] = false;
	gF_GLWantRouteTime[client] = 0.0;
}

// 玩家开关状态查询
bool GL_IsOpen(int client)
{
	return gB_GLOpen[client];
}

// 玩家开关状态设置
// persist 仅用于关闭时清理 Cookie；开启也不再持久化为 "1"，
// 保证换图/重连后默认关闭，必须手动 !gl
void GL_SetOpen(int client, bool enabled, bool persist)
{
	gB_GLOpen[client] = enabled;
	gB_GLWantRoute[client] = false;
	if (persist)
	{
		// 始终写 "0"，不让 Cookie 在下一张图/下次进入时自动开启
		gH_EnabledCookie.Set(client, "0");
	}
}

// 读取 Cookie 值 → bool（保留兼容，但当前逻辑已不再依据其自动开启）
#pragma unused GL_ReadEnabledCookie
bool GL_ReadEnabledCookie(int client)
{
	char value[8];
	gH_EnabledCookie.Get(client, value, sizeof(value));
	return StrEqual(value, "1");
}
