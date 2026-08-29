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
	// 换图时不清空已连接玩家的 gB_GLOpen（Cookie 不会在换图时重新触发，
	// 清空会导致换图后所有玩家 !gl 状态丢失）。
	// 只清空 wantRoute 标记（路线已失效，允许重新触发加载）。
	for (int client = 1; client <= MaxClients; client++)
	{
		gB_GLWantRoute[client] = false;
		gF_GLWantRouteTime[client] = 0.0;
	}
}

// Cookie 缓存完成：恢复开关状态
void GL_OnClientCookiesCached_State(int client)
{
	gB_GLOpen[client] = GL_ReadEnabledCookie(client);
	GL_LogDebug("Client %d cookie: enabled=%d", client, gB_GLOpen[client] ? 1 : 0);
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

// 玩家开关状态设置（持久化到 Cookie）
void GL_SetOpen(int client, bool enabled, bool persist)
{
	gB_GLOpen[client] = enabled;
	gB_GLWantRoute[client] = false;
	if (persist)
	{
		gH_EnabledCookie.Set(client, enabled ? "1" : "0");
	}
}

// 读取 Cookie 值 → bool
bool GL_ReadEnabledCookie(int client)
{
	char value[8];
	gH_EnabledCookie.Get(client, value, sizeof(value));
	return StrEqual(value, "1");
}
