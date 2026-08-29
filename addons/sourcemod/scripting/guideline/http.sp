/*
	Guideline - HTTP
	通过 SteamWorks 从 R2 Worker 获取录像，两阶段下载节省流量：

	阶段 1（meta）：GET {url}?meta=1 → Worker 用 head() 返回元数据
	                （exists/time_ms/sha256），不传输文件 body；
	阶段 2（body）：sha256 与本地缓存不一致（或无缓存）时才 GET 完整录像，
	                写入磁盘缓存后交给 replayfile.sp 分帧解析。

	路径约定（与 stratosphere 完全对齐）：
	  {base}/wr/{mode}/{map}/{type}.replay
	- base ：gokz_guideline_url（R2 基础 URL，域名 + 可选前缀）
	- mode ：请求的 GOKZ 模式（vnl/skz/kzt），默认用服务器默认模式，且自动遍历
	- map  ：服务器当前地图（小写，URLEncode）
	- type ：pro / tp（优先 pro；meta 404 后回退 tp）

	鉴权：gokz_guideline_api_key 非空时携带 X-API-Key 头（与 stratosphere 一致）。

	【三方对比策略】
	  GL_DownloadRoute 被调用时：
	  1. 先扫描本地 GOKZ 录像（localreplay.sp）取 time_local；
	  2. 若本地已有路线缓存（routes.sp），取其 time_cache；
	  3. meta 查询 R2 得 time_remote；
	  4. 三者取最小 → 若最小者是本地录像则直接用本地解析（无下载）；
	     若最小者是 R2（且与缓存 sha 不同）则下载 body 覆盖缓存；
	     否则直接用现有缓存。
	  404 → 回退 tp 格式 → 仍无则只用本地/缓存。
*/



// =====[ CONSTANTS ]=====

#define GL_MAX_URL_LENGTH 512
#define GL_MAX_KEY_LENGTH 128
#define GL_SHA256_LENGTH 128

// 模式遍历顺序（按 GOKZ 默认模式优先）：
// 0 = 服务器默认模式, 1/2 = 其余两种
#define GL_MODE_COUNT 3



// =====[ STATE ]=====

bool gGL_MetaBusy; // 防重入：同一时间只允许一个 meta 查询流程

enum
{
	GL_STRATEGY_AUTO = 0, // 换图自动检查
	GL_STRATEGY_USER,     // 玩家 !routerefresh 手动刷新
	GL_STRATEGY_ENSURE    // 玩家开启 !gl 时按需加载
};



// =====[ PUBLIC ]=====

// 检查并加载当前地图最快路线（自动/手动统一入口）
// 优先本地录像 → 否则走 meta+缓存 → 最后回退下载 R2
void GL_CheckRoutes(int strategy, int requesterUserID = 0)
{
	// 无 SteamWorks 时仍可用本地录像（只跳过 R2 阶段）
	if (!gB_SteamWorksOK)
	{
		GL_LogError("CheckRoutes: SteamWorks not available, using local replay only");
		FinishWithLocalOrCache(requesterUserID);
		return;
	}

	char apiKey[GL_MAX_KEY_LENGTH];
	gCV_APIKey.GetString(apiKey, sizeof(apiKey));
	char url[GL_MAX_URL_LENGTH];
	gCV_URL.GetString(url, sizeof(url));
	if (url[0] == '\0')
	{
		GL_LogError("CheckRoutes skipped: gokz_guideline_url is not set");
		return;
	}
	if (apiKey[0] == '\0')
	{
		GL_LogDebug("gokz_guideline_api_key is EMPTY; R2 requests may be rejected with 401.");
	}

	// 记录请求场景（自动/手动/按需），供调试使用
	GL_LogDebug("CheckRoutes: strategy=%d requester=%d", strategy, requesterUserID);
	GL_MetaStart(requesterUserID, 0); // modeIdx=0 = 服务器默认模式
}

// 手动刷新（!routerefresh）：清除当前路线并重新检查
void GL_ForceRefresh(int client)
{
	GL_ClearCurrentRoute();
	GL_CheckRoutes(GL_STRATEGY_USER, GetClientUserId(client));
	GL_Chat(client, "{green}正在重新检查本图路线（本地录像 → R2）...");
}

// 确保当前地图已加载路线（未加载则触发检查；已加载则渲染定时器自动显示）
void GL_EnsureRouteForClient(int client)
{
	if (!GL_GetEnabled())
	{
		return;
	}

	if (GL_HasRoute())
	{
		return; // 已有路线
	}

	// 触发路线加载（自动 + 手动场景共用；http.sp 内部有防重入）
	GL_CheckRoutes(GL_STRATEGY_ENSURE, GetClientUserId(client));
}



// =====[ META / DOWNLOAD PIPELINE ]=====

static void GL_MetaStart(int requesterUserID, int modeIdx)
{
	if (gGL_MetaBusy)
	{
		GL_LogDebug("Meta pipeline already busy, skip");
		return;
	}
	gGL_MetaBusy = true;

	int mode = GL_ModeFromIndex(modeIdx);
	char modeStr[8];
	GL_GetModeURL(mode, modeStr, sizeof(modeStr));

	// type 顺序：pro → tp（meta 404 后回退）
	GL_MetaRequest(modeIdx, 0, requesterUserID); // typeIdx=0 = pro
}

static void GL_MetaRequest(int modeIdx, int typeIdx, int requesterUserID)
{
	int mode = GL_ModeFromIndex(modeIdx);
	char url[GL_MAX_URL_LENGTH];
	if (!GL_BuildURL(url, sizeof(url), mode, typeIdx))
	{
		GL_MetaFail("URL build failed", requesterUserID);
		return;
	}

	char metaUrl[GL_MAX_URL_LENGTH + 16];
	Format(metaUrl, sizeof(metaUrl), "%s?meta=1", url);

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, metaUrl);
	if (hRequest == null)
	{
		GL_MetaFail("Failed to create meta request", requesterUserID);
		return;
	}

	SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, GL_GetMetaTimeout());
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(hRequest, GL_GetMetaTimeout() * 1000);

	char apiKey[GL_MAX_KEY_LENGTH];
	gCV_APIKey.GetString(apiKey, sizeof(apiKey));
	if (apiKey[0] != '\0')
	{
		SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-API-Key", apiKey);
	}

	DataPack pack = new DataPack();
	pack.WriteCell(modeIdx);
	pack.WriteCell(typeIdx);
	pack.WriteCell(requesterUserID);
	SteamWorks_SetHTTPRequestContextValue(hRequest, pack);
	SteamWorks_SetHTTPCallbacks(hRequest, OnMetaComplete);

	GL_LogDebug("Meta request: %s", metaUrl);

	if (!SteamWorks_SendHTTPRequest(hRequest))
	{
		delete pack;
		delete hRequest;
		GL_MetaFail("Failed to send meta request", requesterUserID);
	}
}

public void OnMetaComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1)
{
	DataPack pack = view_as<DataPack>(data1);
	if (pack == null)
	{
		delete hRequest;
		return;
	}

	pack.Reset();
	int modeIdx = pack.ReadCell();
	int typeIdx = pack.ReadCell();
	int requesterUserID = pack.ReadCell();
	delete pack;

	int mode = GL_ModeFromIndex(modeIdx);

	// 404 = 该组合无录像 → 回退下一个组合（tp 格式 / 下一个模式）
	if (!bFailure && bRequestSuccessful && eStatusCode == k_EHTTPStatusCode404NotFound)
	{
		GL_LogDebug("Meta 404: mode=%d type=%d", mode, typeIdx);
		// 先试 tp；再试下一个模式（最多 3 个模式 × 2 个类型 = 6 次）
		if (typeIdx == 0)
		{
			GL_MetaRequest(modeIdx, 1, requesterUserID);
			delete hRequest;
			return;
		}
		if (modeIdx + 1 < GL_MODE_COUNT)
		{
			GL_MetaRequest(modeIdx + 1, 0, requesterUserID);
			delete hRequest;
			return;
		}
		// 全部 404：只保留本地录像（若存在）
		GL_LogDebug("Meta all-404 for %s; falling back to local replay", gC_MapName);
		gGL_MetaBusy = false;
		FinishWithLocalOrCache(requesterUserID);
		delete hRequest;
		return;
	}

	// 其它失败（Worker 不可达等）→ 回退本地/缓存
	if (bFailure || !bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK)
	{
		gGL_MetaBusy = false;
		GL_LogError("Meta request failed: mode=%d type=%d failure=%d successful=%d status=%d",
			mode, typeIdx, bFailure ? 1 : 0, bRequestSuccessful ? 1 : 0, view_as<int>(eStatusCode));
		FinishWithLocalOrCache(requesterUserID);
		delete hRequest;
		return;
	}

	// 读 meta JSON，提取 time_ms / sha256
	int bodySize;
	SteamWorks_GetHTTPResponseBodySize(hRequest, bodySize);
	if (bodySize <= 0 || bodySize > 4096)
	{
		gGL_MetaBusy = false;
		FinishWithLocalOrCache(requesterUserID);
		delete hRequest;
		return;
	}

	char[] body = new char[bodySize + 1];
	SteamWorks_GetHTTPResponseBodyData(hRequest, body, bodySize);

	char remoteSha[GL_SHA256_LENGTH];
	ExtractJsonStringValue(body, "sha256", remoteSha, sizeof(remoteSha));
	int remoteTimeMs = ExtractJsonIntValue(body, "time_ms");
	delete hRequest;

	float remoteTime = remoteTimeMs > 0 ? float(remoteTimeMs) / 1000.0 : 0.0;
	GL_LogDebug("Meta OK: mode=%d type=%d time_ms=%d sha=%.12s", mode, typeIdx, remoteTimeMs, remoteSha);

	// ===== 三方对比 =====
	// 本地录像 / 缓存录像 / R2 录像，取最小 time
	char localPath[PLATFORM_MAX_PATH];
	float localTime = 0.0;
	bool hasLocal = GL_FindFastestLocalReplay(localPath, sizeof(localPath), localTime);

	float cacheTime = 0.0;
	bool hasCache = GL_GetCurrentRouteTime(cacheTime);

	// 选最优来源
	// 优先级：R2 > 缓存 > 本地（time 小者胜）
	float bestTime = 0.0;
	int bestSource = GL_SOURCE_NONE; // 见 routes.sp
	char bestPath[PLATFORM_MAX_PATH];

	if (hasLocal && (bestTime == 0.0 || localTime < bestTime))
	{
		bestTime = localTime;
		bestSource = GL_SOURCE_LOCAL;
		strcopy(bestPath, sizeof(bestPath), localPath);
	}
	if (hasCache && (bestTime == 0.0 || cacheTime < bestTime))
	{
		bestTime = cacheTime;
		bestSource = GL_SOURCE_CACHE;
		char cachePath[PLATFORM_MAX_PATH];
		GL_BuildCachePath(cachePath, sizeof(cachePath));
		strcopy(bestPath, sizeof(bestPath), cachePath);
	}
	if (remoteTime > 0.0 && (bestTime == 0.0 || remoteTime < bestTime))
	{
		bestTime = remoteTime;
		bestSource = GL_SOURCE_REMOTE;
	}

	GL_LogDebug("Comparison: local=%.2f cache=%.2f remote=%.2f -> best source=%d",
		localTime, cacheTime, remoteTime, bestSource);

	if (bestSource == GL_SOURCE_REMOTE)
	{
		// R2 最快：sha 与缓存一致 → 直接解析缓存；不一致 → 下载 body
		if (remoteSha[0] != '\0')
		{
			char shaPath[PLATFORM_MAX_PATH];
			GL_BuildCacheShaPath(shaPath, sizeof(shaPath));
			char cachedSha[GL_SHA256_LENGTH];
			ReadShaFile(shaPath, cachedSha, sizeof(cachedSha));

			char cachePath2[PLATFORM_MAX_PATH];
			GL_BuildCachePath(cachePath2, sizeof(cachePath2));
			if (StrEqual(remoteSha, cachedSha, false) && FileExists(cachePath2))
			{
				gGL_MetaBusy = false;
				GL_LogDebug("Cache up-to-date (sha match), using cache");
				GL_SetPendingSource(GL_SOURCE_CACHE);
				GL_StartParsing(cachePath2, 0, mode, requesterUserID);
				return;
			}
		}

		// 需要下载 body（与本次 meta 相同的模式/类型）
		char url[GL_MAX_URL_LENGTH];
		if (!GL_BuildURL(url, sizeof(url), mode, typeIdx))
		{
			gGL_MetaBusy = false;
			FinishWithLocalOrCache(requesterUserID);
			return;
		}
		StartDownload(mode, requesterUserID, url);
		return;
	}

	// 本地/缓存即可，无需下载 R2 body
	gGL_MetaBusy = false;
	if (bestSource == GL_SOURCE_LOCAL)
	{
		GL_SetPendingSource(GL_SOURCE_LOCAL);
		GL_ChatToRequester(requesterUserID, "{lime}使用本服最快录像（{default}%.2f 秒{lime}）。", bestTime);
		GL_StartParsing(bestPath, 0, mode, requesterUserID);
	}
	else if (bestSource == GL_SOURCE_CACHE)
	{
		GL_SetPendingSource(GL_SOURCE_CACHE);
		GL_ChatToRequester(requesterUserID, "{grey}使用缓存录像（{default}%.2f 秒{grey}）。", bestTime);
		char cachePath[PLATFORM_MAX_PATH];
		GL_BuildCachePath(cachePath, sizeof(cachePath));
		GL_StartParsing(cachePath, 0, mode, requesterUserID);
	}
	else
	{
		FinishWithLocalOrCache(requesterUserID);
	}
}

public void OnDownloadComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1)
{
	DataPack pack = view_as<DataPack>(data1);
	if (pack == null)
	{
		delete hRequest;
		return;
	}

	pack.Reset();
	int mode = pack.ReadCell();
	int requesterUserID = pack.ReadCell();
	delete pack;

	if (bFailure || !bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK)
	{
		gGL_MetaBusy = false;
		GL_LogError("Download failed: failure=%d successful=%d status=%d",
			bFailure ? 1 : 0, bRequestSuccessful ? 1 : 0, view_as<int>(eStatusCode));
		FinishWithLocalOrCache(requesterUserID);
		delete hRequest;
		return;
	}

	int bodySize;
	SteamWorks_GetHTTPResponseBodySize(hRequest, bodySize);
	if (bodySize <= 0 || bodySize > GL_MAX_REPLAY_SIZE)
	{
		gGL_MetaBusy = false;
		GL_LogError("Downloaded body size out of range (%d)", bodySize);
		FinishWithLocalOrCache(requesterUserID);
		delete hRequest;
		return;
	}

	// 响应体直接流式写入磁盘缓存（不占 SM 堆内存）
	char path[PLATFORM_MAX_PATH];
	GL_BuildCachePath(path, sizeof(path));
	EnsureCacheDir();
	if (!SteamWorks_WriteHTTPResponseBodyToFile(hRequest, path))
	{
		gGL_MetaBusy = false;
		GL_LogError("Failed to write downloaded replay to disk: %s", path);
		FinishWithLocalOrCache(requesterUserID);
		delete hRequest;
		return;
	}

	// 响应头 x-sha256（Worker 下载分支附带）
	char sha256[GL_SHA256_LENGTH];
	SteamWorks_GetHTTPResponseHeaderValue(hRequest, "x-sha256", sha256, sizeof(sha256));
	delete hRequest;

	// 记录 sha256（供下次 meta 比对）
	char shaPath[PLATFORM_MAX_PATH];
	GL_BuildCacheShaPath(shaPath, sizeof(shaPath));
	WriteShaFile(shaPath, sha256);

	// 进入分帧解析管线
	gGL_MetaBusy = false;
	GL_LogDebug("Download OK: %d bytes (sha=%.12s)", bodySize, sha256);
	GL_SetPendingSource(GL_SOURCE_REMOTE);
	GL_StartParsing(path, 0, mode, requesterUserID);
}



// =====[ PRIVATE ]=====

static void StartDownload(int mode, int requesterUserID, const char[] url)
{
	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	if (hRequest == null)
	{
		gGL_MetaBusy = false;
		GL_LogError("Failed to create download request: %s", url);
		FinishWithLocalOrCache(requesterUserID);
		return;
	}

	SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, GL_GetDownloadTimeout());
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(hRequest, GL_GetDownloadTimeout() * 1000);

	char apiKey[GL_MAX_KEY_LENGTH];
	gCV_APIKey.GetString(apiKey, sizeof(apiKey));
	if (apiKey[0] != '\0')
	{
		SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-API-Key", apiKey);
	}

	DataPack pack = new DataPack();
	pack.WriteCell(mode);
	pack.WriteCell(requesterUserID);
	SteamWorks_SetHTTPRequestContextValue(hRequest, pack);
	SteamWorks_SetHTTPCallbacks(hRequest, OnDownloadComplete);

	GL_LogDebug("Download: %s", url);

	if (!SteamWorks_SendHTTPRequest(hRequest))
	{
		delete pack;
		delete hRequest;
		gGL_MetaBusy = false;
		GL_LogError("Failed to send download request: %s", url);
		FinishWithLocalOrCache(requesterUserID);
	}
}

// =====[ PRIVATE ]=====

static void GL_MetaFail(const char[] reason, int requesterUserID)
{
	GL_LogError("%s", reason);
	gGL_MetaBusy = false;
	FinishWithLocalOrCache(requesterUserID);
}

// meta 全部失败/404 时的最终兜底：本地录像 → 缓存 → 无
static void FinishWithLocalOrCache(int requesterUserID)
{
	char localPath[PLATFORM_MAX_PATH];
	float localTime = 0.0;
	if (GL_FindFastestLocalReplay(localPath, sizeof(localPath), localTime))
	{
		GL_SetPendingSource(GL_SOURCE_LOCAL);
		GL_ChatToRequester(requesterUserID, "{lime}使用本服最快录像（{default}%.2f 秒{lime}）。", localTime);
		GL_StartParsing(localPath, 0, GOKZ_GetDefaultMode(), requesterUserID);
		return;
	}

	char cachePath[PLATFORM_MAX_PATH];
	GL_BuildCachePath(cachePath, sizeof(cachePath));
	if (FileExists(cachePath))
	{
		GL_SetPendingSource(GL_SOURCE_CACHE);
		GL_ChatToRequester(requesterUserID, "{grey}使用缓存录像。");
		GL_StartParsing(cachePath, 0, GOKZ_GetDefaultMode(), requesterUserID);
		return;
	}

	GL_ChatToRequester(requesterUserID, "{darkred}未找到本图路线（本地无录像，R2 无录像）。");
}

static void GL_ChatToRequester(int requesterUserID, const char[] format, any...)
{
	int requester = GetClientOfUserId(requesterUserID);
	if (requester == 0 || !GL_IsValidClient(requester))
	{
		return;
	}

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);
	GOKZ_PrintToChat(requester, true, "%s", buffer);
}

void EnsureCacheDir()
{
	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "data/gokz-guideline");
	if (!DirExists(dir))
	{
		CreateDirectory(dir, 511);
	}
}

// 构建 R2 录像 URL：{base}/wr/{mode}/{map}/{type}.replay
bool GL_BuildURL(char[] url, int maxlength, int mode, int typeIdx)
{
	char base[GL_MAX_URL_LENGTH];
	gCV_URL.GetString(base, sizeof(base));

	if (base[0] == '\0')
	{
		url[0] = '\0';
		return false;
	}

	char encodedMap[192];
	GL_URLEncode(gC_MapName, encodedMap, sizeof(encodedMap));

	char modeStr[8];
	GL_GetModeURL(mode, modeStr, sizeof(modeStr));

	char typeStr[8];
	strcopy(typeStr, sizeof(typeStr), typeIdx == 0 ? "pro" : "tp");

	Format(url, maxlength, "%s/wr/%s/%s/%s.replay", base, modeStr, encodedMap, typeStr);
	return true;
}

static void GL_GetModeURL(int mode, char[] buffer, int maxlength)
{
	switch (mode)
	{
		case 0: strcopy(buffer, maxlength, "vnl");
		case 1: strcopy(buffer, maxlength, "skz");
		default: strcopy(buffer, maxlength, "kzt");
	}
}

static int GL_ModeFromIndex(int modeIdx)
{
	switch (modeIdx)
	{
		case 0: return GOKZ_GetDefaultMode();
		case 1: return (GOKZ_GetDefaultMode() + 1) % 3;
		default: return (GOKZ_GetDefaultMode() + 2) % 3;
	}
}

// URL 编码：保留 [a-zA-Z0-9_.-]，其余转 %XX
static void GL_URLEncode(const char[] input, char[] output, int maxlength)
{
	int outPos;
	for (int i = 0; input[i] != '\0' && outPos < maxlength - 4; i++)
	{
		char c = input[i];
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
			|| (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-')
		{
			output[outPos++] = c;
		}
		else
		{
			Format(output[outPos], maxlength - outPos, "%%%02X", view_as<int>(c) & 0xFF);
			outPos += 3;
		}
	}
	output[outPos] = '\0';
}

static void WriteShaFile(const char[] path, const char[] sha)
{
	if (sha[0] == '\0')
	{
		return;
	}

	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "data/gokz-guideline");
	if (!DirExists(dir))
	{
		CreateDirectory(dir, 511);
	}

	File file = OpenFile(path, "w");
	if (file == null)
	{
		return;
	}
	file.WriteLine(sha);
	delete file;
}

static void ReadShaFile(const char[] path, char[] out, int maxlen)
{
	out[0] = '\0';
	if (!FileExists(path))
	{
		return;
	}

	File file = OpenFile(path, "r");
	if (file == null)
	{
		return;
	}
	file.ReadLine(out, maxlen);
	delete file;
	TrimString(out);
}

// 从 meta JSON 中提取字符串值：{"key":"value", ...}
static void ExtractJsonStringValue(const char[] json, const char[] key, char[] out, int maxlen)
{
	out[0] = '\0';

	char pattern[64];
	Format(pattern, sizeof(pattern), "\"%s\":\"", key);
	int pos = StrContains(json, pattern);
	if (pos == -1)
	{
		return; // 值为 null 或不存在
	}
	pos += strlen(pattern);

	int end = pos;
	while (json[end] != '\0' && json[end] != '"')
	{
		end++;
	}
	if (end == pos)
	{
		return;
	}

	int len = end - pos;
	if (len >= maxlen)
	{
		len = maxlen - 1;
	}
	for (int i = 0; i < len; i++)
	{
		out[i] = json[pos + i];
	}
	out[len] = '\0';
}

// 从 meta JSON 中提取整数值：{"time_ms":12345, ...}
static int ExtractJsonIntValue(const char[] json, const char[] key)
{
	char pattern[64];
	Format(pattern, sizeof(pattern), "\"%s\":", key);
	int pos = StrContains(json, pattern);
	if (pos == -1)
	{
		return 0;
	}
	pos += strlen(pattern);

	int start = pos;
	while (json[pos] != '\0' && json[pos] != ',' && json[pos] != '}')
	{
		pos++;
	}
	if (pos == start)
	{
		return 0;
	}

	char num[32];
	int len = pos - start;
	if (len >= sizeof(num))
	{
		len = sizeof(num) - 1;
	}
	for (int i = 0; i < len; i++)
	{
		num[i] = json[start + i];
	}
	num[len] = '\0';
	TrimString(num);
	return StringToInt(num);
}
