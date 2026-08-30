/*
	Guideline - Replay File Parser
	GOKZ .replay 录像文件解析（兼容 v1/v2 格式），分帧解析防止服务器卡顿。

	格式参考 ~/gokz/addons/sourcemod/scripting/gokz-replays/：
	- v2: GeneralHeader + RunHeader + delta 压缩 tick 数据
	- v1: GeneralHeader(v1) + 固定 7 int32/tick 的轨迹数据

	同时提供「读成绩 time」与「解析轨迹」两条管线：
	- GL_ReadReplayTime(path, time)  同步快速读 header 成绩（三方对比用，不解析轨迹）
	- GL_StartParsing(path, ...)     分帧异步解析轨迹（路线绘制用）
*/



// =====[ CONSTANTS ]=====

#define RP_MAGIC_NUMBER 0x676F6B7A
#define GL_RP_TICK_BLOCK 20 // RP_V2_TICK_DATA_BLOCKSIZE
#define GL_MAX_REPLAY_SIZE (8 * 1024 * 1024)
#define GL_MAX_TICKS 1000000

// RPDELTA_* 中 guideline 关心的字段索引
#define RPDELTA_ORIGIN_X 7
#define RPDELTA_ORIGIN_Y 8
#define RPDELTA_ORIGIN_Z 9
#define RPDELTA_FLAGS 16

// flags 位
#define RPF_TELEPORT (1 << 22)
#define RPF_TAKEOFF (1 << 23)



// =====[ STREAM STATE ]=====

File gGL_File;
int gGL_FileSize;
int gGL_FilePos;
bool gGL_StreamFailed;

// =====[ PARSE STATE ]=====

int gGL_ParseVersion; // 0 = 未开始, 1/2 = 格式版本
int gGL_ParseCourse;
int gGL_ParseMode;
int gGL_ParseRequesterUserID; // 0 = 自动（无请求者）
int gGL_ParseTickCount;
int gGL_ParseTicksDone;
int gGL_ParseTickrate; // 录像 tickrate（v2 header 读取；v1 缺省 128）
char gGL_ParsePlayer[32];
float gGL_ParseTime;
int gGL_ParseTeleports;
ArrayList gGL_ParseRaw;



// =====[ READ TIME (SYNC) ]=====

// 从录像文件读取成绩（秒）。支持 v2（当前 GOKZ 格式）与 v1（旧版本）。
bool GL_ReadReplayTime(const char[] path, float &time)
{
	File file = OpenFile(path, "rb");
	if (file == null)
	{
		return false;
	}

	int magic;
	if (!file.ReadInt32(magic) || magic != RP_MAGIC_NUMBER)
	{
		delete file;
		return false;
	}

	int version;
	if (!file.ReadInt8(version))
	{
		delete file;
		return false;
	}

	bool ok;
	if (version == 2)
	{
		ok = ReadV2Time(file, time);
	}
	else if (version == 1)
	{
		ok = ReadV1Time(file, time);
	}
	else
	{
		ok = false;
	}

	delete file;
	return ok;
}

// v2：GeneralHeader + RunHeader（time = int32 float 位模式）
static bool ReadV2Time(File file, float &time)
{
	int dummy;

	int replayType;
	if (!file.ReadInt8(replayType) || replayType != 0)
	{
		return false; // 非 Run 录像
	}
	if (!SkipString(file) // gokzVersion
		|| !SkipString(file)) // mapName
	{
		return false;
	}
	file.ReadInt32(dummy); // mapFileSize
	file.ReadInt32(dummy); // serverIP
	file.ReadInt32(dummy); // timestamp
	if (!SkipString(file)) // playerAlias
	{
		return false;
	}
	file.ReadInt32(dummy); // playerSteamID
	file.ReadInt8(dummy);  // mode
	file.ReadInt8(dummy);  // style
	file.ReadInt32(dummy); // playerSensitivity
	file.ReadInt32(dummy); // playerMYaw
	file.ReadInt32(dummy); // tickrate
	file.ReadInt32(dummy); // tickCount
	file.ReadInt32(dummy); // equippedWeapon
	file.ReadInt32(dummy); // equippedKnife

	int timeAsInt;
	if (!file.ReadInt32(timeAsInt))
	{
		return false;
	}
	time = view_as<float>(timeAsInt);
	return time > 0.0;
}

// v1：魔数+版本 之后为 gokzVersion / mapName 字符串，
// course / mode / style / time(int32 float) / teleportsUsed / steamAccountID(int32) ...
static bool ReadV1Time(File file, float &time)
{
	int dummy;

	if (!SkipString(file) // gokzVersion
		|| !SkipString(file)) // mapName
	{
		return false;
	}
	file.ReadInt32(dummy); // course
	file.ReadInt32(dummy); // mode
	file.ReadInt32(dummy); // style

	int timeAsInt;
	if (!file.ReadInt32(timeAsInt))
	{
		return false;
	}
	time = view_as<float>(timeAsInt);
	return time > 0.0;
}

// 跳过长度前缀字符串（int8 长度 + 字节）
static bool SkipString(File file)
{
	int len;
	if (!file.ReadInt8(len))
	{
		return false;
	}
	if (len <= 0)
	{
		return len == 0; // 空字符串合法
	}
	int[] dummy = new int[len];
	return file.Read(dummy, len, 1) == len;
}



// =====[ PARSE STATE ]=====

// 解析任务上下文（显式绑定，不依赖全局 pending 变量）
int gGL_ParseContextMode;   // 目标模式
int gGL_ParseContextSource; // 来源（GL_SOURCE_*）
int gGL_ParseContextRequestId; // 请求 ID（解析完成后校验有效性）
bool gGL_ParseContextValid;



// =====[ PUBLIC ]=====

// 开始解析（带完整上下文）：读 header（同步）→ 分帧解析 tick 数据（定时器）
// 解析结果显式写入 mode/source/requestId，完成后校验 requestId 防过期覆盖
void GL_StartParsingWithContext(const char[] path, int course, int mode, int requesterUserID, int source, int requestId)
{
	if (gGL_File != null)
	{
		GL_LogDebug("Parse already in progress, skip: %s", path);
		return;
	}

	gGL_ParseContextMode = mode;
	gGL_ParseContextSource = source;
	gGL_ParseContextRequestId = requestId;
	gGL_ParseContextValid = true;

	GL_StartParsing(path, course, mode, requesterUserID);
}

// 开始解析（基础版）：读 header（同步）→ 分帧解析 tick 数据（定时器）
void GL_StartParsing(const char[] path, int course, int mode, int requesterUserID)
{
	if (gGL_File != null)
	{
		GL_LogDebug("Parse already in progress, skip: %s", path);
		return;
	}

	gGL_File = OpenFile(path, "rb");
	if (gGL_File == null)
	{
		GL_LogError("Failed to open replay file: %s", path);
		return;
	}

	gGL_FileSize = FileSize(path);
	if (gGL_FileSize <= 0 || gGL_FileSize > GL_MAX_REPLAY_SIZE)
	{
		GL_LogError("Replay file size out of range (%d): %s", gGL_FileSize, path);
		delete gGL_File;
		gGL_File = null;
		return;
	}

	gGL_FilePos = 0;
	gGL_StreamFailed = false;
	gGL_ParseVersion = 0;

	int magic;
	StreamReadRawInt32(magic);
	if (magic != RP_MAGIC_NUMBER)
	{
		AbortParsing("bad magic number");
		return;
	}

	int formatVersion = StreamReadByte();
	if (formatVersion == 1)
	{
		gGL_ParseVersion = 1;
		if (!ParseV1Header())
		{
			AbortParsing("invalid v1 header");
			return;
		}
	}
	else if (formatVersion == 2)
	{
		gGL_ParseVersion = 2;
		if (!ParseV2Header())
		{
			AbortParsing("invalid v2 header");
			return;
		}
	}
	else
	{
		AbortParsing("unsupported format version %d", formatVersion);
		return;
	}

	gGL_ParseCourse = course;
	gGL_ParseMode = mode;
	gGL_ParseRequesterUserID = requesterUserID;
	gGL_ParseRaw = new ArrayList(sizeof(TrackPoint));

	GL_LogDebug("Parsing replay: ticks=%d, course=%d, player=\"%s\"",
		gGL_ParseTickCount, course, gGL_ParsePlayer);

	CreateTimer(0.01, GL_ParseBatchTimer, _, TIMER_REPEAT);
}

// 中止当前解析（地图切换/插件卸载时调用）
void GL_AbortParsing()
{
	if (gGL_File == null)
	{
		return;
	}
	AbortParsing("aborted");
}

public Action GL_ParseBatchTimer(Handle timer)
{
	if (gGL_File == null)
	{
		return Plugin_Stop;
	}

	int batch = GL_GetParseBatch();
	int remaining = gGL_ParseTickCount - gGL_ParseTicksDone;
	int toParse = batch < remaining ? batch : remaining;

	for (int i = 0; i < toParse; i++)
	{
		if (!ParseOneTick())
		{
			AbortParsing("tick data truncated");
			return Plugin_Stop;
		}
	}

	if (gGL_ParseTicksDone >= gGL_ParseTickCount)
	{
		FinishParsing();
		return Plugin_Stop;
	}

	return Plugin_Continue;
}



// =====[ PARSE LIFECYCLE ]=====

static void FinishParsing()
{
	GL_LogDebug("Parse done: %d ticks, %d raw points", gGL_ParseTickCount, gGL_ParseRaw.Length);

	// 使用解析上下文（显式绑定，不依赖全局 pending）
	int parseMode = gGL_ParseContextValid ? gGL_ParseContextMode : gGL_ParseMode;
	int parseSource = gGL_ParseContextValid ? gGL_ParseContextSource : GL_SOURCE_NONE;
	int requestId = gGL_ParseContextRequestId;

	// 降采样
	ArrayList points = GL_Downsample(gGL_ParseRaw);
	delete gGL_ParseRaw;
	gGL_ParseRaw = null;

	int course = gGL_ParseCourse;
	int requesterUserID = gGL_ParseRequesterUserID;
	char player[32];
	strcopy(player, sizeof(player), gGL_ParsePlayer);
	float time = gGL_ParseTime;
	int teleports = gGL_ParseTeleports;
	int tickrate = gGL_ParseTickrate;

	CleanupStream();

	GL_LogDebug("Parse finished: course=%d mode=%d", course, parseMode);
	GL_RouteFinishParsed(parseMode, player, parseSource, time, teleports, tickrate, points, requestId);

	// 通知请求者（仅当请求仍有效）
	int requester = GetClientOfUserId(requesterUserID);
	if (requester != 0 && GL_IsValidClient(requester) && GL_IsRequestValid(requestId))
	{
		if (points.Length >= 2)
		{
			GL_Chat(requester, "{lime}路线已就绪：{default}%d{lime} 个点，成绩 {default}%.2f 秒{lime}。", points.Length, time);
		}
		else
		{
			GL_Chat(requester, "{darkred}路线过短，无法显示。");
		}
	}
}

static void AbortParsing(const char[] reason, any...)
{
	char buffer[256];
	VFormat(buffer, sizeof(buffer), reason, 2);
	GL_LogError("Replay parse aborted: %s", buffer);

	if (gGL_ParseRaw != null)
	{
		delete gGL_ParseRaw;
		gGL_ParseRaw = null;
	}
	CleanupStream();
}

static void CleanupStream()
{
	if (gGL_File != null)
	{
		delete gGL_File;
		gGL_File = null;
	}
	gGL_FileSize = 0;
	gGL_FilePos = 0;
	gGL_StreamFailed = false;
	gGL_ParseVersion = 0;
	gGL_ParseTickCount = 0;
	gGL_ParseTicksDone = 0;
	gGL_ParseTickrate = 128;
	gGL_ParsePlayer[0] = '\0';
	gGL_ParseTime = 0.0;
	gGL_ParseTeleports = 0;
}



// =====[ STREAM IO ]=====

static void StreamReadRawInt32(int &value)
{
	if (gGL_StreamFailed)
	{
		value = 0;
		return;
	}
	if (gGL_FilePos + 4 > gGL_FileSize)
	{
		gGL_StreamFailed = true;
		value = 0;
		return;
	}
	gGL_File.ReadInt32(value);
	gGL_FilePos += 4;
}

static int StreamReadInt32()
{
	if (gGL_StreamFailed)
	{
		return 0;
	}
	if (gGL_FilePos + 4 > gGL_FileSize)
	{
		gGL_StreamFailed = true;
		return 0;
	}
	int value;
	gGL_File.ReadInt32(value);
	gGL_FilePos += 4;
	return value;
}

static int StreamReadByte()
{
	if (gGL_StreamFailed || gGL_FilePos + 1 > gGL_FileSize)
	{
		gGL_StreamFailed = true;
		return 0;
	}
	int value;
	gGL_File.ReadInt8(value);
	gGL_FilePos += 1;
	return value;
}

static bool StreamReadString(char[] out, int maxlen)
{
	if (gGL_StreamFailed)
	{
		return false;
	}

	int len = StreamReadByte();
	if (gGL_StreamFailed || len < 0 || len >= maxlen)
	{
		return false;
	}

	for (int i = 0; i < len; i++)
	{
		int b = StreamReadByte();
		if (gGL_StreamFailed)
		{
			return false;
		}
		out[i] = view_as<char>(b);
	}
	out[len] = '\0';
	return true;
}



// =====[ HEADER PARSING ]=====

static bool ParseV2Header()
{
	// General Header
	int replayType = StreamReadByte();
	if (replayType != 0) // ReplayType_Run
	{
		GL_LogDebug("Skipping non-run replay (type %d)", replayType);
		return false;
	}

	char dummy[32];
	if (!StreamReadString(dummy, sizeof(dummy))) // gokzVersion
	{
		return false;
	}

	char mapName[64];
	if (!StreamReadString(mapName, sizeof(mapName))) // mapName
	{
		return false;
	}
	// 宽容处理：不强制与当前地图一致（文件已按地图组织），仅调试日志
	GL_LogDebug("Replay map name: \"%s\"", mapName);

	StreamReadInt32(); // mapFileSize
	StreamReadInt32(); // serverIP
	StreamReadInt32(); // timestamp

	if (!StreamReadString(gGL_ParsePlayer, sizeof(gGL_ParsePlayer))) // playerAlias
	{
		return false;
	}

	StreamReadInt32(); // playerSteamID
	StreamReadByte(); // mode（录像自身的模式，忽略，route 记录请求时的 mode）
	StreamReadByte(); // style
	StreamReadInt32(); // playerSensitivity
	StreamReadInt32(); // playerMYaw
	int tickrateAsInt = StreamReadInt32();
	gGL_ParseTickrate = RoundToNearest(view_as<float>(tickrateAsInt));
	if (gGL_ParseTickrate < 1)
	{
		gGL_ParseTickrate = 128;
	}

	gGL_ParseTickCount = StreamReadInt32();
	if (gGL_ParseTickCount <= 0 || gGL_ParseTickCount > GL_MAX_TICKS)
	{
		GL_LogDebug("Invalid tick count %d", gGL_ParseTickCount);
		return false;
	}

	StreamReadInt32(); // equippedWeapon
	StreamReadInt32(); // equippedKnife

	// Run Header
	int timeAsInt = StreamReadInt32();
	gGL_ParseTime = view_as<float>(timeAsInt);
	StreamReadByte(); // course（录像自身的 course，忽略）
	gGL_ParseTeleports = StreamReadInt32();

	return !gGL_StreamFailed;
}

static bool ParseV1Header()
{
	char dummy[32];
	if (!StreamReadString(dummy, sizeof(dummy))) // gokzVersion
	{
		return false;
	}
	if (!StreamReadString(dummy, sizeof(dummy))) // mapName
	{
		return false;
	}

	StreamReadInt32(); // course
	StreamReadInt32(); // mode
	StreamReadInt32(); // style

	int timeAsInt = StreamReadInt32();
	gGL_ParseTime = view_as<float>(timeAsInt);

	gGL_ParseTeleports = StreamReadInt32(); // teleportsUsed
	StreamReadInt32(); // steamAccountID

	if (!StreamReadString(dummy, sizeof(dummy))) // steamID2
	{
		return false;
	}
	if (!StreamReadString(dummy, sizeof(dummy))) // IP
	{
		return false;
	}
	if (!StreamReadString(gGL_ParsePlayer, sizeof(gGL_ParsePlayer))) // alias
	{
		return false;
	}

	gGL_ParseTickCount = StreamReadInt32();
	if (gGL_ParseTickCount <= 0 || gGL_ParseTickCount > GL_MAX_TICKS)
	{
		GL_LogDebug("Invalid v1 tick count %d", gGL_ParseTickCount);
		return false;
	}

	return !gGL_StreamFailed;
}



// =====[ TICK DATA ]=====

static bool ParseOneTick()
{
	TrackPoint tp;

	if (gGL_ParseVersion == 1)
	{
		int td[7];
		for (int i = 0; i < 7; i++)
		{
			td[i] = StreamReadInt32();
			if (gGL_StreamFailed)
			{
				return false;
			}
		}
		tp.origin[0] = view_as<float>(td[0]);
		tp.origin[1] = view_as<float>(td[1]);
		tp.origin[2] = view_as<float>(td[2]);
		tp.tick = gGL_ParseTicksDone; // v1 无时间信息，tick 索引即帧序号
		// v1 无 takeoff/teleport 标记
		gGL_ParseRaw.PushArray(tp);
		gGL_ParseTicksDone++;
		return true;
	}

	// v2：delta 压缩
	int deltaFlags = StreamReadInt32();
	if (gGL_StreamFailed)
	{
		return false;
	}

	int fields[GL_RP_TICK_BLOCK];
	fields[0] = deltaFlags;
	for (int idx = 1; idx < GL_RP_TICK_BLOCK; idx++)
	{
		if (deltaFlags & (1 << idx))
		{
			int v = StreamReadInt32();
			if (gGL_StreamFailed)
			{
				return false;
			}
			fields[idx] = v;
		}
	}

	// 只保留 origin、flags 与 tick 索引
	tp.origin[0] = view_as<float>(fields[RPDELTA_ORIGIN_X]);
	tp.origin[1] = view_as<float>(fields[RPDELTA_ORIGIN_Y]);
	tp.origin[2] = view_as<float>(fields[RPDELTA_ORIGIN_Z]);
	tp.isTeleport = (fields[RPDELTA_FLAGS] & RPF_TELEPORT) != 0;
	tp.isTakeoff = (fields[RPDELTA_FLAGS] & RPF_TAKEOFF) != 0;
	tp.tick = gGL_ParseTicksDone;

	gGL_ParseRaw.PushArray(tp);
	gGL_ParseTicksDone++;
	return true;
}
