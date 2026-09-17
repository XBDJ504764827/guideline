/*
	Guideline - Local Replay Scan
	扫描服务器本地 GOKZ 录像目录（data/gokz-replays/_runs/<map>/），
	读取每份录像 header 中的 course / mode / 成绩 time，找出该地图 course 0
	指定模式的最快录像。

	【为什么不依赖文件名】
	  GOKZ 的录像文件名格式并不稳定：既有 4 段 `<course>_<MODE>_<STYLE>_<TIMETYPE>.replay`
	  （如 0_SKZ_NRM_PRO.replay），也有 5 段 `<steamId>_<course>_<MODE>_<STYLE>_<TIMETYPE>.replay`
	  （如 0_0_VNL_NRM_NUB.replay、365313220_0_KZT_NRM_PRO.replay），
	  还可能被第三方工具改名。而录像 header 里写的 mode/course/teleports 是
	  录像生成时的权威值，因此本模块**只按 header 判定**，文件名完全不参与匹配。

	用于「三方对比」（缓存 / 本地 / R2），选择最小 time 作为路线源：
	  1. 插件自己从 R2 下载并存下的缓存（data/gokz-guideline/）
	  2. 服务器本地 GOKZ 录像（本模块扫描）
	  3. R2 存储上的录像（http.sp 异步比较）
*/



// =====[ CONSTANTS ]=====

#define GL_REPLAY_DIRECTORY "data/gokz-replays/_runs" // 相对 Path_SM



// =====[ PUBLIC ]=====

// 扫描当前地图 data/gokz-replays/_runs/<map>/ 中 course 0 的 RUN 录像，
// 只选择指定模式的录像，返回成绩最快的一条（time 最小）。
// 模式判定完全依赖录像 header（不解析文件名），因此文件名不规范也能正确归类。
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
	int scanned = 0;

	while (listing.GetNext(fileName, sizeof(fileName), type))
	{
		if (type != FileType_File)
		{
			continue;
		}

		// 只处理 .replay 后缀（大小写不敏感）
		if (StrContains(fileName, ".replay", false) == -1)
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
		scanned++;

		// 权威判定：读 header 里的 course / mode / teleports / time
		GL_ReplayMeta meta;
		if (!GL_ReadReplayMeta(fullPath, meta))
		{
			GL_LogDebug("Cannot read replay header: %s", fullPath);
			continue;
		}

		// 只认 course 0（主图）；B1/B2 忽略
		if (meta.course != 0)
		{
			continue;
		}

		// 模式隔离：只选目标模式的录像（按 header 的 mode 字段判定）
		if (targetMode >= 0 && targetMode <= 2 && meta.mode != targetMode)
		{
			continue;
		}

		if (bestFound == 0.0 || meta.time < bestFound)
		{
			bestFound = meta.time;
			strcopy(bestPath, sizeof(bestPath), fullPath);
		}
	}

	delete listing;

	if (bestFound <= 0.0)
	{
		GL_LogDebug("No valid local replay found for %s mode %d (scanned %d files)",
			gC_MapName, targetMode, scanned);
		return false;
	}

	strcopy(pathOutput, maxlength, bestPath);
	bestTime = bestFound;
	GL_LogDebug("Fastest local replay: %s (time=%.2f, scanned=%d)", bestPath, bestFound, scanned);
	return true;
}

