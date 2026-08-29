/*
	Guideline - Helpers
	工具函数：字符串、客户校验、日志、距离计算。
*/



// =====[ STRINGS ]=====

// 原地转小写
void GL_ToLower(char[] buffer, int maxlength)
{
	for (int i = 0; buffer[i] != '\0' && i < maxlength; i++)
	{
		if (buffer[i] >= 'A' && buffer[i] <= 'Z')
		{
			buffer[i] = view_as<char>(buffer[i] + 32);
		}
	}
}



// =====[ CLIENT ]=====

bool GL_IsValidClient(int client)
{
	return client >= 1 && client <= MaxClients && IsClientInGame(client);
}



// =====[ LOGGING ]=====

void GL_LogDebug(const char[] format, any...)
{
	if (!GL_GetDebug())
	{
		return;
	}

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogMessage("[guideline] %s", buffer);
}

void GL_LogError(const char[] format, any...)
{
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogError("[guideline] %s", buffer);
}

// 聊天提示（玩家在服上才发；client=0 时日志）
void GL_Chat(int client, const char[] format, any...)
{
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);
	if (GL_IsValidClient(client))
	{
		GOKZ_PrintToChat(client, true, "%s", buffer);
	}
	else
	{
		LogMessage("[guideline] %s", buffer);
	}
}



// =====[ DISTANCE ]=====

// 水平距离（忽略 Z）——路线断点/降采样判定用
float GL_HorizontalDistance(const float a[3], const float b[3])
{
	float dx = a[0] - b[0];
	float dy = a[1] - b[1];
	return SquareRoot(dx * dx + dy * dy);
}

// 三维距离
float GL_Distance3D(const float a[3], const float b[3])
{
	float dx = a[0] - b[0];
	float dy = a[1] - b[1];
	float dz = a[2] - b[2];
	return SquareRoot(dx * dx + dy * dy + dz * dz);
}
