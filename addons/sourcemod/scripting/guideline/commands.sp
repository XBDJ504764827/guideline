/*
	Guideline - Commands
	!gl        每个玩家独立开关，只显示给本人（Cookie 持久化）
	!routerefresh  手动强制刷新路线（管理员）

	命令名与 GOKZ 无冲突（gokz 中没有注册 !gl；jumpbeam 只有 !beamoffset）。
*/



// =====[ PUBLIC ]=====

void GL_RegisterCommands()
{
	RegConsoleCmd("sm_gl", CommandGL, "[KZ] Toggle guideline route display.");
	RegConsoleCmd("sm_routerefresh", CommandRouteRefresh, "[KZ] Force refresh current map route. Requires admin.");
}



// =====[ COMMAND HANDLERS ]=====

public Action CommandGL(int client, int args)
{
	if (!GL_IsValidClient(client))
	{
		ReplyToCommand(client, "[Guideline] This command can only be used in-game.");
		return Plugin_Handled;
	}

	if (!GL_GetEnabled())
	{
		GL_Chat(client, "{darkred}本服务器已禁用路线指引。");
		return Plugin_Handled;
	}

	// 切换开关（state.sp 统一管理状态 + Cookie 持久化）
	bool newEnabled = !GL_IsOpen(client);
	GL_SetOpen(client, newEnabled, true);

	if (newEnabled)
	{
		GL_Chat(client, "{lime}路线显示已开启。{grey}（显示最快录像的全图路线，紫色线条）");
		// 确保路线加载（已加载则渲染定时器立即显示）
		GL_EnsureRouteForClient(client);
	}
	else
	{
		GL_Chat(client, "{darkred}路线显示已关闭。");
	}

	return Plugin_Handled;
}

public Action CommandRouteRefresh(int client, int args)
{
	if (!GL_IsValidClient(client))
	{
		ReplyToCommand(client, "[Guideline] This command can only be used in-game.");
		return Plugin_Handled;
	}

	if (!CheckCommandAccess(client, "sm_routerefresh", ADMFLAG_GENERIC))
	{
		GL_Chat(client, "{darkred}你没有权限使用该命令。");
		return Plugin_Handled;
	}

	GL_ForceRefresh(client);
	return Plugin_Handled;
}
