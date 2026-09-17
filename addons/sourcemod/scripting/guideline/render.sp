/*
	Guideline - Render
	路线渲染：与 GOKZ JumpBeam 同款的激光束线条（laserbeam.vmt）。

	【性能设计：附近窗口 + 滚动续期】
	  GOKZ JumpBeam 便宜的本质是「事件驱动」：仅在空中时触发、每 tick 只发新增的
	  1 条、从不重发、落地即停。guideline 需要常驻显示，无法完全照搬，因此改为：
	    - 只绘制玩家附近窗口内的路线段（不再全图轮转发送，发送量与路线总长无关）
	    - 窗口内滚动续期：每周期只发少量段，使整窗在 beam_lifetime 内滚动一遍
	    - 线段缓存为固定二维数组，热路径零 native 调用、零临时堆分配
	    - 玩家进度游标：局部搜索 O(±数百)，偏离时全局粗扫定位（限流）
	  发送量由「全图常量约 1067 条/秒」降为「窗口约 120 条/秒」（默认参数）。

	【与 JumpBeam 视觉一致性】
	  - 材质：materials/sprites/laserbeam.vmt（OnMapStart 预缓存）
	  - TE_SetupBeamPoints 参数：HaloIndex=0, StartFrame=0, FrameRate=0,
	    Life=beam_lifetime(默认 4.0 与 JumpBeam 一致),
	    Width=EndWidth=beam_width(默认 0.25 与 JumpBeam 一致),
	    FadeLength=10(与 JumpBeam 一致), Amplitude=0.0, Speed=0
	  - 颜色：紫色（默认 148 0 211 110，可配置）
	  - 拐角：Chaikin 角切割平滑（默认 2 次迭代），自然圆弧过渡

	【常驻显示】
	  路线开启后不依赖计时状态，定时续期光束（GL_RENDER_INTERVAL 0.15s，
	  远小于 beam_lifetime，窗口内线条连续）。只发送给开启 !gl 的玩家本人。
*/

// =====[ CONSTANTS ]=====

#define GL_RENDER_INTERVAL 0.15      // 渲染周期（秒）：固定值，与 GL_RestartRenderTimer 一致
#define GL_MAX_SEGMENTS_HARD 5120    // 线段数组硬容量（须 >= gokz_guideline_max_segments 上限）
#define GL_CURSOR_SEARCH_BACK 128    // 游标局部回看段数（覆盖倒退/回跳）
#define GL_CURSOR_SEARCH_FWD 256     // 游标局部前看段数（覆盖快速前进）
#define GL_RELOC_COARSE_STEPS 256    // 全局重定位粗扫步数（步长 = 段数/该值）
#define GL_RELOC_MIN_TICKS 32        // 全局重定位最小间隔（tick），避免离路玩家反复粗扫
#define GL_WINDOW_MARGIN 0.4         // 整窗滚动周期 = beam_lifetime × 该系数
                                     // （实测该值在静止/走/连跳/高速各速度下
                                     //   同一段两次重发间隔最坏约 3.3s < 4s 存活，留足余量）
#define GL_WIN_BACK_SCALE 0.5        // 回看窗口 = near_dist × 该系数
#define GL_WIN_FWD_SCALE 1.0         // 前看窗口 = near_dist × 该系数
#define GL_MIN_BATCH 2               // 每周期最少续期段数（地板值；下限过高会白吞掉保形简化的收益）
                                     // 实测窗口 21~36 段（简化后）时，下限 2 的最坏重发间隔
                                     // 约 2.55s < 4s 存活时间，各速度下均有 1.45s 以上余量
#define GL_MAX_NEW_AHEAD 24          // 每周期最多立即补发的「前方新进入窗口」段数
                                     // （段长 8 units、周期 0.15s 时约合 1280 u/s，
                                     //   高于高速连跳，配额用尽会自动顺延到下周期，不丢段）
#define GL_FILL_BOOST 4              // 窗口跳变后的填充加速倍数（缩短首帧到全窗可见的等待）


// =====[ STATE ]=====

// 每模式线段缓存（固定二维数组：热路径直接下标访问，无 native 开销、无临时分配）
float gGL_Segs[3][GL_MAX_SEGMENTS_HARD * 6]; // 6 float/段：x1 y1 z1 x2 y2 z2
int gGL_SegCount[3];    // 实际段数
int gGL_WinBack[3];     // 窗口回看段数（由 near_dist 与平均段长换算）
int gGL_WinFwd[3];      // 窗口前看段数
int gGL_RebuildTick[3]; // 上次因「缓存为空」重建的 tick（限流，防每周期重跑全量细分）

// 每玩家渲染状态
int gGL_Cursor[MAXPLAYERS + 1];    // 玩家在路线上的进度（最近段索引）
bool gGL_CursorValid[MAXPLAYERS + 1];
int gGL_Sweep[MAXPLAYERS + 1];     // 窗口内滚动续期指针（相对窗口起点；-1 = 从玩家处开始扫）
int gGL_Painted[MAXPLAYERS + 1];   // 窗口跳变后已铺满的段数（< winCount 时加速填充）
int gGL_WinStart[MAXPLAYERS + 1];  // 上次窗口起点（检测窗口大幅平移，如传送回起点）
int gGL_WinEnd[MAXPLAYERS + 1];    // 上次窗口末端索引（检测前方新进入的段）
int gGL_RelocTick[MAXPLAYERS + 1]; // 上次全局重定位的 tick（限流用）


// =====[ PUBLIC ]=====

void GL_OnMapStart_Render()
{
	GL_OnMapStart_State();
	GL_ClearSegmentCache();

	for (int client = 1; client <= MaxClients; client++)
	{
		GL_ResetClientRenderState(client);
	}

	// 设置默认构建模式（消除 gGL_BuildMode 未初始化导致的无参语义错误）
	GL_SetBuildMode(GOKZ_GetDefaultMode());
}

// Cookie 缓存完成：恢复开关状态
void GL_OnClientCookiesCached(int client)
{
	GL_OnClientCookiesCached_State(client);
}

void GL_OnClientDisconnect(int client)
{
	GL_OnClientDisconnect_State(client);
	GL_ResetClientRenderState(client);
}

// 重置单个玩家的渲染状态（换图/换模式/断线时调用）
void GL_ResetClientRenderState(int client)
{
	gGL_Cursor[client] = 0;
	gGL_CursorValid[client] = false;
	gGL_Sweep[client] = -1;
	gGL_Painted[client] = 0;
	gGL_WinStart[client] = -1;
	gGL_WinEnd[client] = -1;
	gGL_RelocTick[client] = 0;
}

// 定时器重建
void GL_RestartRenderTimer()
{
	if (gH_RenderTimer != null)
	{
		KillTimer(gH_RenderTimer);
		gH_RenderTimer = null;
	}
	// 固定 0.15s 高刷新率：与 GL_RENDER_INTERVAL 保持一致。
	// 每周期发送量由窗口大小自动换算（见 GL_RenderRouteToClient），
	// 保证整窗在 beam_lifetime 内滚动一遍，连续显示不闪烁。
	gH_RenderTimer = CreateTimer(GL_RENDER_INTERVAL, GL_Timer_Render, _, TIMER_REPEAT);
}

// 热加载兜底：OnMapStart 未触发时确保光束模型已预缓存
void GL_EnsureBeamModelLoaded()
{
	if (gI_BeamModel == 0)
	{
		gI_BeamModel = PrecacheModel("materials/sprites/laserbeam.vmt", true);
		GL_LogDebug("Beam model precached on-demand (hot reload)");
	}
}

public Action GL_Timer_Render(Handle timer)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!GL_IsValidClient(client) || !gB_GLOpen[client])
		{
			continue;
		}

		int mode = GOKZ_GetCoreOption(client, Option_Mode);
		if (!GL_HasRoute(mode))
		{
			// 已开启但该模式路线未就绪：按需触发一次加载；失败后 60 秒允许重试
			if (!gB_GLWantRoute[client])
			{
				gB_GLWantRoute[client] = true;
				gF_GLWantRouteTime[client] = GetEngineTime();
				GL_EnsureRouteForClient(client);
			}
			else if (GetEngineTime() - gF_GLWantRouteTime[client] > 60.0)
			{
				gB_GLWantRoute[client] = false;
			}
			continue;
		}

		// 已就绪则清除未就绪标记（下次换图自动重新触发）
		gB_GLWantRoute[client] = false;

		// 死亡/观战不渲染（复活后游标会自动重新定位）
		if (!IsPlayerAlive(client))
		{
			gGL_CursorValid[client] = false;
			continue;
		}

		// 渲染前确保光束模型已预缓存（热加载兜底）
		GL_EnsureBeamModelLoaded();

		GL_RenderRouteToClient(client, mode);
	}
	return Plugin_Continue;
}

// 为指定模式重建线段缓存（模式切换/路线加载完成时调用）
void GL_RebuildCacheForMode(int mode)
{
	if (mode < 0 || mode > 2)
	{
		return;
	}
	Route routeInfo;
	if (!GL_GetRoute(mode, routeInfo) || routeInfo.points == null)
	{
		return;
	}
	GL_BuildSegmentCache(mode, routeInfo.points);
	GL_LogDebug("Segment cache rebuilt for mode %d (%d segments)", mode, gGL_SegCount[mode]);
}

// 清空线段缓存（换图/重载时）
void GL_ClearSegmentCache()
{
	for (int mode = 0; mode < 3; mode++)
	{
		gGL_SegCount[mode] = 0;
		gGL_WinBack[mode] = 0;
		gGL_WinFwd[mode] = 0;
		gGL_RebuildTick[mode] = 0;
	}
	for (int client = 1; client <= MaxClients; client++)
	{
		GL_ResetClientRenderState(client);
	}
}

// 预构建线段缓存：解析完成后调用（routes.sp 的 GL_RouteFinishParsed）
// 全量 Chaikin 细分后的线段一次性算好存为固定数组，渲染只做窗口内滚动续期，
// 避免每次渲染重复计算 + 一次性发送过多 beam 被客户端丢弃
void GL_BuildSegmentCache(int mode, ArrayList points)
{
	if (mode < 0 || mode > 2)
	{
		return;
	}
	gGL_SegCount[mode] = 0;
	gGL_WinBack[mode] = 0;
	gGL_WinFwd[mode] = 0;
	if (points == null || points.Length < 2)
	{
		return;
	}
	int n = points.Length;
	float breakDist = GL_GetBreakDist();
	float verticalBreakDist = GL_GetVerticalBreakDist();

	// Chaikin 细分迭代次数（性能自适应：超限自动降级，仍保持全图）
	int chaikinIter = GL_GetSmooth() ? GL_GetSmoothPoints() : 0;
	if (chaikinIter < 0) chaikinIter = 0;
	if (chaikinIter > 3) chaikinIter = 3;

	// maxSegments 保护：超出时降低细分（保持全图但线条略直）
	int maxSegments = GL_GetMaxSegments();
	int subdiv = 1 << chaikinIter;
	int totalBeams = (n - 1) * subdiv;
	while (chaikinIter > 0 && totalBeams > maxSegments)
	{
		chaikinIter--;
		subdiv = 1 << chaikinIter;
		totalBeams = (n - 1) * subdiv;
	}
	// 硬容量保护（chaikinIter 已降到 0 仍超限时按序截断，保证不越界）
	if (totalBeams > GL_MAX_SEGMENTS_HARD)
	{
		GL_LogError("Route too long for segment cache (%d > %d), truncating", totalBeams, GL_MAX_SEGMENTS_HARD);
	}

	// 收集连续点序列（断点处断开），逐段细分后直接写入缓存
	ArrayList seq = new ArrayList(3);

	for (int ptIdx = 0; ptIdx < n; ptIdx++)
	{
		bool needFlushBefore = false;
		if (ptIdx > 0)
		{
			TrackPoint prev, cur;
			points.GetArray(ptIdx - 1, prev);
			points.GetArray(ptIdx, cur);

			if (cur.isBreak)
			{
				needFlushBefore = true;
			}
			else
			{
				float dist = GL_Distance3D(prev.origin, cur.origin);
				if (dist > breakDist)
				{
					needFlushBefore = true;
				}
				else
				{
					float vertDelta = FloatAbs(cur.origin[2] - prev.origin[2]);
					if (vertDelta > verticalBreakDist
						&& GL_HorizontalDistance(prev.origin, cur.origin) < 64.0)
					{
						needFlushBefore = true;
					}
				}
			}
		}

		if (needFlushBefore)
		{
			BuildSegmentsFromSequence(mode, seq, chaikinIter);
			delete seq;
			seq = new ArrayList(3);
		}

		TrackPoint tp;
		points.GetArray(ptIdx, tp);
		seq.PushArray(tp.origin);
	}
	// 收尾
	BuildSegmentsFromSequence(mode, seq, chaikinIter);
	delete seq;

	// 换算窗口段数（由 near_dist 与平均段长得出）
	GL_ComputeWindow(mode);

	// 路线内容变化 → 所有玩家游标失效，下次渲染重新定位
	for (int client = 1; client <= MaxClients; client++)
	{
		GL_ResetClientRenderState(client);
	}

	GL_LogDebug("Segment cache built (mode %d): %d segments, window=-%d/+%d",
		mode, gGL_SegCount[mode], gGL_WinBack[mode], gGL_WinFwd[mode]);
}

// 由 near_dist 与平均段长换算窗口段数（回看窄、前看宽，前进方向更重要）
static void GL_ComputeWindow(int mode)
{
	int total = gGL_SegCount[mode];
	if (total < 1)
	{
		return;
	}

	float totalLen = 0.0;
	for (int i = 0; i < total; i++)
	{
		int b6 = i * 6;
		float dx = gGL_Segs[mode][b6 + 3] - gGL_Segs[mode][b6];
		float dy = gGL_Segs[mode][b6 + 4] - gGL_Segs[mode][b6 + 1];
		float dz = gGL_Segs[mode][b6 + 5] - gGL_Segs[mode][b6 + 2];
		totalLen += SquareRoot(dx * dx + dy * dy + dz * dz);
	}
	float avgLen = totalLen / float(total);
	if (avgLen < 1.0)
	{
		avgLen = 1.0;
	}

	float nearDist = GL_GetNearDist();
	int back = RoundToNearest(nearDist * GL_WIN_BACK_SCALE / avgLen);
	int fwd = RoundToNearest(nearDist * GL_WIN_FWD_SCALE / avgLen);
	if (back < 8) back = 8;
	if (fwd < 8) fwd = 8;
	if (back > total) back = total;
	if (fwd > total) fwd = total;
	gGL_WinBack[mode] = back;
	gGL_WinFwd[mode] = fwd;
}

// 保形共线简化：把近似共线的相邻点合并，返回新的点序列。
// 贪心策略：从当前点出发尽量向前延伸，只要「中间所有点偏离弦」不超过 tol
// 且弦长不超过 maxLen 就继续延伸；否则落点、从该点重新开始。
// 拐角处中间点偏离弦必然超限 → 自然终止延伸，圆弧得以保留。
// 仅在构建线段缓存时调用一次（非热路径）。
static ArrayList SimplifyCollinear(ArrayList pts, float tol, float maxLen)
{
	ArrayList out = new ArrayList(3);
	int n = pts.Length;
	if (n == 0)
	{
		return out;
	}

	float first[3];
	pts.GetArray(0, first);
	out.PushArray(first);
	if (n == 1)
	{
		return out;
	}

	int anchor = 0;
	while (anchor < n - 1)
	{
		int best = anchor + 1;
		int cand = anchor + 2;

		while (cand < n)
		{
			float a[3], b[3];
			pts.GetArray(anchor, a);
			pts.GetArray(cand, b);

			if (GL_Distance3D(a, b) > maxLen)
			{
				break;
			}

			// 检查 anchor..cand 之间每个点偏离弦的程度
			bool ok = true;
			for (int k = anchor + 1; k < cand; k++)
			{
				float p[3];
				pts.GetArray(k, p);
				if (GL_PointSegmentDistance(a, b, p) > tol)
				{
					ok = false;
					break;
				}
			}
			if (!ok)
			{
				break;
			}

			best = cand;
			cand++;
		}

		float bp[3];
		pts.GetArray(best, bp);
		out.PushArray(bp);
		anchor = best;
	}

	return out;
}

// 对点序列做 Chaikin 细分并把所有线段直接写入该模式的固定数组
static void BuildSegmentsFromSequence(int mode, ArrayList seq, int iter)
{
	if (seq.Length < 2)
	{
		return;
	}

	ArrayList cur = seq.Clone();

	for (int k = 0; k < iter; k++)
	{
		ArrayList next = new ArrayList(3);

		float first[3];
		cur.GetArray(0, first);
		next.PushArray(first); // 保留首点

		for (int j = 0; j < cur.Length - 1; j++)
		{
			float p0[3], p1[3];
			cur.GetArray(j, p0);
			cur.GetArray(j + 1, p1);

			// Chaikin 角切割：Q 在段 1/4 处，R 在段 3/4 处
			float q[3], r[3];
			for (int d = 0; d < 3; d++)
			{
				q[d] = 0.75 * p0[d] + 0.25 * p1[d];
				r[d] = 0.25 * p0[d] + 0.75 * p1[d];
			}
			next.PushArray(q);
			next.PushArray(r);
		}

		float last[3];
		cur.GetArray(cur.Length - 1, last);
		next.PushArray(last); // 保留尾点

		delete cur;
		cur = next;
	}

	// 保形简化：把近似共线的短段合并成长段。
	// Chaikin 的价值只在拐角（切出圆弧），直线段被切成 8u 碎片纯属浪费——
	// 而发送量正比于「1/平均段长」（窗口段数 = near_dist ÷ 平均段长），
	// 因此合并直线段可成倍降低渲染开销，且拐角圆弧完整保留（不满足共线条件）。
	if (GL_GetSimplify())
	{
		ArrayList simplified = SimplifyCollinear(cur, GL_GetSimplifyTol(), GL_GetSimplifyMaxLen());
		delete cur;
		cur = simplified;
	}

	// 写入缓存（每段 6 float；超出硬容量则停止，保证不越界）
	int count = gGL_SegCount[mode];
	for (int j = 0; j < cur.Length - 1; j++)
	{
		if (count >= GL_MAX_SEGMENTS_HARD)
		{
			break;
		}
		float a[3], b[3];
		cur.GetArray(j, a);
		cur.GetArray(j + 1, b);
		int b6 = count * 6;
		gGL_Segs[mode][b6] = a[0];
		gGL_Segs[mode][b6 + 1] = a[1];
		gGL_Segs[mode][b6 + 2] = a[2];
		gGL_Segs[mode][b6 + 3] = b[0];
		gGL_Segs[mode][b6 + 4] = b[1];
		gGL_Segs[mode][b6 + 5] = b[2];
		count++;
	}
	gGL_SegCount[mode] = count;

	delete cur;
}


// =====[ RENDERING ]=====

// 附近窗口渲染：只维护玩家周围窗口内的线段，每周期滚动续期一小批
void GL_RenderRouteToClient(int client, int mode)
{
	// 该模式线段缓存尚未构建则重建一次。
	// 加限流：解析出的路线过短（0 段）时避免每个渲染周期都重跑一次全量细分。
	int total = gGL_SegCount[mode];
	if (total < 1)
	{
		int tick = GetGameTickCount();
		if (gGL_RebuildTick[mode] == 0 || tick - gGL_RebuildTick[mode] >= 128)
		{
			gGL_RebuildTick[mode] = tick;
			GL_RebuildCacheForMode(mode);
		}
		total = gGL_SegCount[mode];
		if (total < 1)
		{
			return;
		}
	}

	// 1) 更新玩家进度游标（局部搜索；必要时全局粗定位）
	float origin[3];
	GetClientAbsOrigin(client, origin);
	GL_UpdateCursor(client, mode, origin, total);

	// 2) 计算当前窗口 [start, end]
	int cursor = gGL_Cursor[client];
	if (cursor < 0) cursor = 0;
	if (cursor > total - 1) cursor = total - 1;

	int start = cursor - gGL_WinBack[mode];
	if (start < 0) start = 0;
	int end = cursor + gGL_WinFwd[mode];
	if (end > total - 1) end = total - 1;
	int winCount = end - start + 1;
	if (winCount < 1)
	{
		return;
	}

	float life = GL_GetBeamLifetime();
	float width = GL_GetBeamWidth();
	int color[4];
	GL_GetColor(color);

	// 3) 前方新进入窗口的段立即补发（独立额度，不挤占下面的续期额度）
	//    否则新段要等一整轮滚动才可见，前进时会明显滞后。
	//    配额用尽时只推进到实际发出的位置，剩余部分下一周期接着发（自校正，不丢段）。
	int prevEnd = gGL_WinEnd[client];
	if (prevEnd >= start && prevEnd < end)
	{
		int newCount = end - prevEnd;
		if (newCount > GL_MAX_NEW_AHEAD) newCount = GL_MAX_NEW_AHEAD;
		for (int i = 0; i < newCount; i++)
		{
			GL_SendSegment(client, mode, prevEnd + 1 + i, life, width, color);
		}
		gGL_WinEnd[client] = prevEnd + newCount;
	}
	else
	{
		gGL_WinEnd[client] = end;
	}

	// 4) 窗口内滚动续期：额度使整窗在 life × GL_WINDOW_MARGIN 内滚动一遍
	//    静态线条不受续期时机影响，只需在过期前重发即可，因此周期可放宽
	int budget = RoundToNearest(float(winCount) * GL_RENDER_INTERVAL / (life * GL_WINDOW_MARGIN));
	if (budget < GL_MIN_BATCH) budget = GL_MIN_BATCH;
	int cap = GL_GetBatchSize();
	if (budget > cap) budget = cap;
	if (budget > winCount) budget = winCount;

	// 窗口刚跳变（首次开启/传送/进度重定位）时整窗尚未铺满：先加速铺满，
	// 缩短「刚开 !gl 只有脚下一小段线」的等待；铺满后回到常规额度续期。
	int prevStart = gGL_WinStart[client];
	int startDelta = start - prevStart;
	if (startDelta < 0) startDelta = -startDelta;
	int rel = gGL_Sweep[client];
	if (rel < 0 || rel >= winCount || prevStart < 0 || startDelta > winCount)
	{
		// 从玩家所在处开始扫：先画脚边和前方的线，而不是从窗口最后方扫过来
		rel = cursor - start;
		if (rel < 0) rel = 0;
		if (rel >= winCount) rel = 0;
		gGL_Painted[client] = 0;
	}
	gGL_WinStart[client] = start;

	if (gGL_Painted[client] < winCount)
	{
		int fillBudget = budget * GL_FILL_BOOST;
		if (fillBudget > cap) fillBudget = cap;
		if (fillBudget > winCount) fillBudget = winCount;
		budget = fillBudget;
		gGL_Painted[client] += budget;
	}

	for (int i = 0; i < budget; i++)
	{
		GL_SendSegment(client, mode, start + (rel + i) % winCount, life, width, color);
	}
	gGL_Sweep[client] = (rel + budget) % winCount;
}

// 更新玩家进度游标：先局部搜索（便宜），偏离路线时再全局粗定位（限流）
static void GL_UpdateCursor(int client, int mode, const float origin[3], int total)
{
	float bestDist = 0.0;

	if (!gGL_CursorValid[client])
	{
		gGL_Cursor[client] = GL_FindNearestSegment(mode, origin, total, 0, total - 1, 1, bestDist);
		gGL_CursorValid[client] = true;
		gGL_RelocTick[client] = 0;
		return;
	}

	int cursor = gGL_Cursor[client];
	if (cursor < 0) cursor = 0;
	if (cursor > total - 1) cursor = total - 1;

	int lo = cursor - GL_CURSOR_SEARCH_BACK;
	if (lo < 0) lo = 0;
	int hi = cursor + GL_CURSOR_SEARCH_FWD;
	if (hi > total - 1) hi = total - 1;

	int best = GL_FindNearestSegment(mode, origin, total, lo, hi, 1, bestDist);

	// 局部范围都太远（瞬移/上下层错位/长时间无渲染）→ 全局粗扫 + 局部细化。
	// 用 tick 间隔限流：离路玩家（如在起点外徘徊）不必每次渲染都粗扫。
	int tick = GetGameTickCount();
	float nearDist = GL_GetNearDist();
	if (bestDist > nearDist * nearDist && tick - gGL_RelocTick[client] >= GL_RELOC_MIN_TICKS)
	{
		int stride = total / GL_RELOC_COARSE_STEPS;
		if (stride < 1) stride = 1;
		int coarse = GL_FindNearestSegment(mode, origin, total, 0, total - 1, stride, bestDist);
		int clo = coarse - stride;
		if (clo < 0) clo = 0;
		int chi = coarse + stride;
		if (chi > total - 1) chi = total - 1;
		best = GL_FindNearestSegment(mode, origin, total, clo, chi, 1, bestDist);
		gGL_RelocTick[client] = tick;
	}

	gGL_Cursor[client] = best;
}

// 在 [lo, hi] 内按步长 step 搜索离 origin 最近的段（中点平方距离）
// 中点就地计算（省一份缓存数组）；返回最佳段索引，bestDist 输出最佳平方距离
static int GL_FindNearestSegment(int mode, const float origin[3], int total, int lo, int hi, int step, float &bestDist)
{
	int best = lo;
	bestDist = 99999999.0;
	for (int i = lo; i <= hi; i += step)
	{
		if (i < 0 || i >= total)
		{
			continue;
		}
		int b6 = i * 6;
		float mx = (gGL_Segs[mode][b6] + gGL_Segs[mode][b6 + 3]) * 0.5;
		float my = (gGL_Segs[mode][b6 + 1] + gGL_Segs[mode][b6 + 4]) * 0.5;
		float mz = (gGL_Segs[mode][b6 + 2] + gGL_Segs[mode][b6 + 5]) * 0.5;
		float dx = mx - origin[0];
		float dy = my - origin[1];
		float dz = mz - origin[2];
		float dSq = dx * dx + dy * dy + dz * dz;
		if (dSq < bestDist)
		{
			bestDist = dSq;
			best = i;
		}
	}
	return best;
}

// 激光束发送（参数与 GOKZ JumpBeam 完全一致：FadeLength 10、Amplitude 0、Speed 0）
static void GL_SendSegment(int viewer, int mode, int idx, float life, float width, const int color[4])
{
	if (idx < 0 || idx >= gGL_SegCount[mode])
	{
		return;
	}
	int b6 = idx * 6;
	float start[3], end[3];
	start[0] = gGL_Segs[mode][b6];
	start[1] = gGL_Segs[mode][b6 + 1];
	start[2] = gGL_Segs[mode][b6 + 2] + 10.0; // 与 JumpBeam 一致的小幅抬升，避免贴地穿模
	end[0] = gGL_Segs[mode][b6 + 3];
	end[1] = gGL_Segs[mode][b6 + 4];
	end[2] = gGL_Segs[mode][b6 + 5] + 10.0;

	TE_SetupBeamPoints(start, end, gI_BeamModel, 0, 0, 0, life, width, width, 10, 0.0, color, 0);
	TE_SendToClient(viewer);
}
