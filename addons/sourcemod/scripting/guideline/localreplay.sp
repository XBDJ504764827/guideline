/*
	Guideline - Local Replay Scan
	扫描服务器本地 GOKZ 录像目录（data/gokz-replays/_runs/<map>/），
	读取每份录像 header 中的成绩 time，找出该地图 course 0 的最快录像。

	用于「三方对比」（缓存 / 本地 / R2），选择最小 time 作为路线源：
	  1. 插件自己从 R2 下载并存下的缓存（data/gokz-guideline/）
	  2. 服务器本地 GOKZ 录像（本模块扫描）
	  3. R2 存储上的录像（http.sp 异步比较）
*/



// =====[ CONSTANTS ]=====

#define GL_REPLAY_DIRECTORY "data/gokz-replays/_runs" // 相对 Path_SM



// =====[ STRUCTS ]=====

// 本地录像扫描结果
enum struct LocalReplayEntry
{
	char path[PLATFORM_MAX_PATH];
	float time;
	
	// 以下用于日志/调试
	char modeShort[8];
	char typeStr[8];
	char playerName[32];
	
	bool valid;
}



// =====[ PUBLIC ]=====

// 扫描当前地图 data/gokz-replays/_runs/<map>/ 中 course 0 的 RUN 录像，
// 只选择指定模式的录像，返回成绩最快的一条（time 最小）。
// 无该模式录像时返回 false（绝不混用其他模式）。
bool GL_FindFastestLocalReplay(char[] pathOutput, int maxlength, float &bestTime, int targetMode = -1)
{
	pathOutput[0] = '\0';
	bestTime = 0.0;

	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "%s/%s", GL_REPLAY_DIRECTORY, gC_MapName);
	if (!DirExists(dir))
	{
		GL_LogDebug("Local replay dir not found: %s", dir);
		return false;
	}

	DirectoryListing listing = OpenDirectory(dir);
	if (listing == null)
	{
		GL_LogDebug("Failed to open local replay dir: %s", dir);
		return false;
	}

	char fileName[PLATFORM_MAX_PATH];
	char fullPath[PLATFORM_MAX_PATH];
	FileType type;

	float bestFound = 0.0;
	char bestPath[PLATFORM_MAX_PATH];

	while (listing.GetNext(fileName, sizeof(fileName), type))
	{
		if (type != FileType_File)
		{
			continue;
		}

		// 解析文件名：<course>_<MODE>_<STYLE>_<TIMETYPE>.replay
		int course;
		char modeShort[8];
		char typeStr[8];
		if (!GL_ParseRunFileName(fileName, course, modeShort, sizeof(modeShort), typeStr, sizeof(typeStr)))
		{
			continue;
		}

		// 模式隔离：只选目标模式的录像
		if (targetMode >= 0 && targetMode <= 2)
		{
			char wantMode[8];
			GL_GetModeShortName(targetMode, wantMode, sizeof(wantMode));
			if (!StrEqual(modeShort, wantMode, false))
			{
				continue;
			}
		}

		BuildPath(Path_SM, fullPath, sizeof(fullPath), "%s/%s", GL_REPLAY_DIRECTORY, gC_MapName);
		Format(fullPath, sizeof(fullPath), "%s/%s", fullPath, fileName);

		float time;
		if (!GL_ReadReplayTime(fullPath, time))
		{
			GL_LogDebug("Cannot read time from local replay: %s", fullPath);
			continue;
		}

		if (bestFound == 0.0 || time < bestFound)
		{
			bestFound = time;
			strcopy(bestPath, sizeof(bestPath), fullPath);
		}
	}

	delete listing;

	if (bestFound <= 0.0)
	{
		GL_LogDebug("No valid local replay found for %s mode %d", gC_MapName, targetMode);
		return false;
	}

	strcopy(pathOutput, maxlength, bestPath);
	bestTime = bestFound;
	GL_LogDebug("Fastest local replay: %s (time=%.2f)", bestPath, bestFound);
	return true;
}

// 解析 GOKZ 永久录像文件名：<course>_<MODE>_<STYLE>_<TIMETYPE>.replay
// 例：0_SKZ_NRM_PRO.replay -> course=0, modeShort="skz", typeStr="pro"
// 只认 course 0、合法模式（vnl/skz/kzt）；NUB 及未知时间类型一律按 tp。
bool GL_ParseRunFileName(const char[] fileName, int &course, char[] modeShort, int modeShortLen, char[] typeStr, int typeStrLen)
{
	char buf[PLATFORM_MAX_PATH];
	strcopy(buf, sizeof(buf), fileName);

	// 去掉扩展名
	int dot = StrContains(buf, ".replay");
	if (dot == -1)
	{
		return false;
	}
	buf[dot] = '\0';

	// 按 '_' 切 4 段
	char parts[4][16];
	int n = ExplodeString(buf, "_", parts, sizeof(parts), sizeof(parts[]));
	if (n < 4)
	{
		return false;
	}

	course = StringToInt(parts[0]);
	if (course != 0)
	{
		return false; // 只处理主图
	}

	strcopy(modeShort, modeShortLen, parts[1]);
	GL_ToLower(modeShort, modeShortLen);
	if (!StrEqual(modeShort, "vnl") && !StrEqual(modeShort, "skz") && !StrEqual(modeShort, "kzt"))
	{
		return false;
	}

	if (StrEqual(parts[3], "PRO", false))
	{
		strcopy(typeStr, typeStrLen, "pro");
	}
	else
	{
		strcopy(typeStr, typeStrLen, "tp");
	}
	return true;
}
