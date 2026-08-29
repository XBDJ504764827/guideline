/*
	Guideline - Render
	路线渲染：与 GOKZ JumpBeam 同款的激光束线条（laserbeam.vmt）。

	【与 JumpBeam 视觉一致性】
	  - 材质：materials/sprites/laserbeam.vmt（OnMapStart 预缓存）
	  - TE_SetupBeamPoints 参数：HaloIndex=0, StartFrame=0, FrameRate=0,
	    Life=beam_lifetime(默认 4.0 与 JumpBeam 一致),
	    Width=EndWidth=beam_width(默认 0.25 与 JumpBeam 一致),
	    FadeLength=10(与 JumpBeam 一致), Amplitude=0.0, Speed=0
	  - 颜色：紫色（默认 148 0 211 110，可配置）
	  - 拐角：Chaikin 角切割平滑（默认 1 次迭代），自然圆弧过渡

	【常驻显示】
	  路线开启后不依赖计时状态，定时重发光束（refresh_interval 默认 2.0s，
	  小于 beam_lifetime 4.0s 避免闪烁）。只发送给开启 !gl 的玩家本人。
*/

// =====[ STATE ]=====

int gGL_RenderTick; // 渲染节流计数（大路线降频用）
ArrayList gGL_Segments; // 预计算线段缓存（每项 6 个 float: start[3]+end[3]）
int gGL_SegmentCursor[MAXPLAYERS + 1]; // 分批渲染游标（每玩家独立，滚动窗口起点）
int gGL_CacheMode; // 线段缓存所属的模式（0=VNL 1=SKZ 2=KZT）
// 玩家附近段缓存（性能优化：玩家不动时不重扫）
float gGL_PlayerLastOrigin[MAXPLAYERS + 1][3];
bool gGL_PlayerNearValid[MAXPLAYERS + 1];
int gGL_PlayerNearCount[MAXPLAYERS + 1];
int gGL_PlayerNearSegs[MAXPLAYERS + 1][256]; // 最大缓存 256 个附近段索引



// =====[ PUBLIC ]=====

void GL_OnMapStart_Render()
{
	GL_OnMapStart_State();
	GL_ClearSegmentCache();

	// 重置附近段缓存
	for (int client = 1; client <= MaxClients; client++)
	{
		gGL_PlayerNearValid[client] = false;
		gGL_PlayerNearCount[client] = 0;
	}
}

// Cookie 缓存完成：恢复开关状态
void GL_OnClientCookiesCached(int client)
{
	GL_OnClientCookiesCached_State(client);
}

void GL_OnClientDisconnect(int client)
{
	GL_OnClientDisconnect_State(client);
	gGL_SegmentCursor[client] = 0;
	gGL_PlayerNearValid[client] = false;
	gGL_PlayerNearCount[client] = 0;
}

// 定时器重建（refresh_interval 变化时）
void GL_RestartRenderTimer()
{
	if (gH_RenderTimer != null)
	{
		KillTimer(gH_RenderTimer);
		gH_RenderTimer = null;
	}
	// 固定 0.15s 高刷新率：即使服务器 cfg 里 refresh_interval 残留旧值 (2.0)，
	// 也能保证 段数/批量 × 0.15s < beam_lifetime，整条路线连续显示不闪烁。
	// （cfg 的 gokz_guideline_refresh_interval 仅保留给高级调优，此处不读取）
	float interval = 0.15;
	gH_RenderTimer = CreateTimer(interval, GL_Timer_Render, _, TIMER_REPEAT);
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
	gGL_RenderTick++;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!GL_IsValidClient(client) || !gB_GLOpen[client])
		{
			continue;
		}

		if (!GL_HasRoute(GOKZ_GetCoreOption(client, Option_Mode)))
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
		else
		{
			// 已就绪则清除未就绪标记（下次换图自动重新触发）
			gB_GLWantRoute[client] = false;
		}

		// 渲染前确保光束模型已预缓存（热加载兜底）
		GL_EnsureBeamModelLoaded();

		GL_RenderRouteToClient(client);
	}
	return Plugin_Continue;
}

// 清空线段缓存（换图/重载时）
void GL_ClearSegmentCache()
{
	if (gGL_Segments != null)
	{
		delete gGL_Segments;
	}
	gGL_Segments = null;
	for (int client = 1; client <= MaxClients; client++)
	{
		gGL_SegmentCursor[client] = 0;
	}
}

// 预构建线段缓存：解析完成后调用（routes.sp 的 GL_RouteFinishParsed）
// 全量 Cheikin 细分后的线段存下来，后续渲染只做轮转发送，
// 避免每次渲染重复计算 + 一次性发送过多 beam 被丢弃
void GL_BuildSegmentCache(ArrayList points)
{
	GL_ClearSegmentCache();
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

	gGL_Segments = new ArrayList(6); // 每项 6 float: start[3] + end[3]

	// 收集连续点序列（断点处断开），逐段细分后存入缓存
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
			BuildSegmentsFromSequence(seq, chaikinIter);
			delete seq;
			seq = new ArrayList(3);
		}

		TrackPoint tp;
		points.GetArray(ptIdx, tp);
		seq.PushArray(tp.origin);
	}
	// 收尾
	BuildSegmentsFromSequence(seq, chaikinIter);
	delete seq;

	GL_LogDebug("Segment cache built: %d segments", gGL_Segments.Length);
}

// 对点序列做 Chaikin 细分并把所有线段写入缓存
static void BuildSegmentsFromSequence(ArrayList seq, int iter)
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

	// 写入缓存（每项 6 float: start[3]+end[3]，与 ArrayList(6) 块匹配）
	for (int j = 0; j < cur.Length - 1; j++)
	{
		float a[3], b[3];
		cur.GetArray(j, a);
		cur.GetArray(j + 1, b);
		float seg[6];
		seg[0] = a[0]; seg[1] = a[1]; seg[2] = a[2];
		seg[3] = b[0]; seg[4] = b[1]; seg[5] = b[2];
		gGL_Segments.PushArray(seg);
	}

	delete cur;
}

// 分批渲染：每个渲染 tick 发送一批线段
// 核心：每批【先发玩家附近段（快速闪现在玩家视野内）】+【轮转补剩余（保证全部段在 life 内被刷新）】
// 附近优先解决"玩家附近不显示"；轮转解决"时有时无"（完整覆盖）
void GL_RenderRouteToClient(int client)
{
	if (!GL_HasRoute())
	{
		return;
	}

	// 按玩家当前模式获取路线；若线段缓存尚未为该模式构建则重建
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	if (!GL_HasRoute(mode))
	{
		return; // 该模式无路线（渲染由 EnsureRoute 触发加载）
	}
	if (gGL_Segments == null || gGL_Segments.Length < 2 || gGL_CacheMode != mode)
	{
		// 该模式已加载但缓存未构建（或模式不符）→ 重建
		gGL_CacheMode = mode;
		Route routeInfo;
		GL_GetRoute(mode, routeInfo);
		if (routeInfo.points != null)
		{
			GL_BuildSegmentCache(routeInfo.points);
		}
	}

	if (gGL_Segments == null || gGL_Segments.Length < 2)
	{
		return;
	}

	int totalSegments = gGL_Segments.Length; // 每项 6 cells = 1 段
	int color[4];
	GL_GetColor(color);
	float life = GL_GetBeamLifetime();
	float width = GL_GetBeamWidth();

	// 每批最多发送段数（客户端单帧可稳定接收）
	int batchSize = GL_GetBatchSize();
	if (batchSize < 8) batchSize = 8;
	if (batchSize > 256) batchSize = 256;
	if (batchSize > totalSegments) batchSize = totalSegments;

	// 玩家位置（附近优先）
	float playerOrigin[3];
	bool playerAlive = IsPlayerAlive(client);
	if (playerAlive)
	{
		GetClientAbsOrigin(client, playerOrigin);
	}

	// 分段：
	// - 前 min(nearQuota, batchSize) 条：玩家附近段（距离升序）
	// - 其余：轮转游标补（顺序覆盖所有段）
	int nearQuota = batchSize / 2; // 附近占批次一半

	// 临时数组（堆分配避免栈溢出）
	int[] sendOrder = new int[batchSize];
	int sendCount = 0;

	// —— 第一步：玩家附近段（附近优先）——
	if (playerAlive && nearQuota >= 4)
	{
		// 性能优化：玩家移动 < 100 units 时不重新扫描，复用上次结果
		bool needRescan = true;
		if (gGL_PlayerNearValid[client])
		{
			float dx = playerOrigin[0] - gGL_PlayerLastOrigin[client][0];
			float dy = playerOrigin[1] - gGL_PlayerLastOrigin[client][1];
			float dz = playerOrigin[2] - gGL_PlayerLastOrigin[client][2];
			float moved = SquareRoot(dx * dx + dy * dy + dz * dz);
			if (moved < 100.0)
			{
				needRescan = false;
			}
		}

		if (needRescan)
		{
			gGL_PlayerLastOrigin[client] = playerOrigin;

			int maxNearScan = totalSegments < 4096 ? totalSegments : 4096; // 扫描上限，防卡
			int[] nearIdx = new int[maxNearScan];
			float[] nearDist = new float[maxNearScan];
			int nearCount = 0;

			float nearDistLimit = GL_GetNearDist();
			for (int s = 0; s < maxNearScan; s++)
			{
				float seg[6];
				gGL_Segments.GetArray(s, seg);
				float mid[3];
				mid[0] = (seg[0] + seg[3]) * 0.5;
				mid[1] = (seg[1] + seg[4]) * 0.5;
				mid[2] = (seg[2] + seg[5]) * 0.5;
				float d = GL_Distance3D(mid, playerOrigin);
				if (d < nearDistLimit)
				{
					nearIdx[nearCount] = s;
					nearDist[nearCount] = d;
					nearCount++;
				}
			}

			// 距离升序简单排序（近段数一般不多；插入排序够用）
			for (int i = 1; i < nearCount; i++)
			{
				int sVal = nearIdx[i];
				float dVal = nearDist[i];
				int j = i - 1;
				while (j >= 0 && nearDist[j] > dVal)
				{
					nearIdx[j + 1] = nearIdx[j];
					nearDist[j + 1] = nearDist[j];
					j--;
				}
				nearIdx[j + 1] = sVal;
				nearDist[j + 1] = dVal;
			}

			// 缓存最近的 nearQuota 个（供下次复用）
			gGL_PlayerNearCount[client] = nearCount < nearQuota ? nearCount : nearQuota;
			for (int i = 0; i < gGL_PlayerNearCount[client]; i++)
			{
				gGL_PlayerNearSegs[client][i] = nearIdx[i];
			}
			gGL_PlayerNearValid[client] = true;
		}

		// 使用（可能缓存的）附近段列表
		int take = gGL_PlayerNearCount[client];
		for (int i = 0; i < take && sendCount < batchSize; i++)
		{
			sendOrder[sendCount++] = gGL_PlayerNearSegs[client][i];
		}
	}

	// —— 第二步：轮转游标补剩余（保证全覆盖）——
	if (sendCount < batchSize)
	{
		int cursor = gGL_SegmentCursor[client];
		int tries = 0;
		while (sendCount < batchSize && tries < totalSegments)
		{
			int s = cursor + tries;
			if (s >= totalSegments) s -= totalSegments;
			// 去重（已在 sendOrder 中）
			bool dup = false;
			for (int k = 0; k < sendCount; k++)
			{
				if (sendOrder[k] == s)
				{
					dup = true;
					break;
				}
			}
			if (!dup)
			{
				sendOrder[sendCount++] = s;
			}
			tries++;
		}
		// 推进游标：按阶段 B 扫描的段数（tries），避免跳批漏段（阶段 A 已占用部分名额）
		gGL_SegmentCursor[client] = (gGL_SegmentCursor[client] + tries) % totalSegments;
	}

	// —— 发送 ——
	for (int i = 0; i < sendCount; i++)
	{
		int s = sendOrder[i];
		float seg[6];
		gGL_Segments.GetArray(s, seg);
		float a[3];
		a[0] = seg[0]; a[1] = seg[1]; a[2] = seg[2];
		float b[3];
		b[0] = seg[3]; b[1] = seg[4]; b[2] = seg[5];
		DrawBeam(client, a, b, life, width, color);
	}

	GL_LogDebug("Render batch: %d sent / %d (tick %d)", sendCount, totalSegments, gGL_RenderTick);
}

// 激光束发送（参数与 GOKZ JumpBeam 完全一致：FadeLength 10、Amplitude 0、Speed 0）
static void DrawBeam(int viewer, const float a[3], const float b[3], float life, float width, const int color[4])
{
	float start[3], end[3];
	start = a;
	start[2] += 10.0; // 与 JumpBeam 一致的小幅抬升，避免贴地穿模
	end = b;
	end[2] += 10.0;

	TE_SetupBeamPoints(start, end, gI_BeamModel, 0, 0, 0, life, width, width, 10, 0.0, color, 0);
	TE_SendToClient(viewer);
}
