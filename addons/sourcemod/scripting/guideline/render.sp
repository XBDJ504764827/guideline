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



// =====[ PUBLIC ]=====

void GL_OnMapStart_Render()
{
	GL_OnMapStart_State();
	GL_ClearSegmentCache();
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
}

// 定时器重建（refresh_interval 变化时）
void GL_RestartRenderTimer()
{
	if (gH_RenderTimer != null)
	{
		KillTimer(gH_RenderTimer);
		gH_RenderTimer = null;
	}
	float interval = GL_GetRefreshInterval();
	if (interval < 0.1)
	{
		interval = 0.1;
	}
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

		if (!GL_HasRoute())
		{
			// 已开启但路线未就绪：按需触发一次加载；失败后 60 秒允许重试
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

// 分批渲染：每个渲染 tick 只发送一批线段，轮转游标
// 这样任意时刻客户端在途 beam ≤ 一批数量，不会因一次性发送过多被丢弃
void GL_RenderRouteToClient(int client)
{
	if (!GL_HasRoute() || gGL_Segments == null || gGL_Segments.Length < 2)
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

	// 本 tick 只发送一批（轮转）
	int cursor = gGL_SegmentCursor[client];
	int end = cursor + batchSize;
	if (end > totalSegments)
	{
		end = totalSegments;
	}

	float seg[6];
	// 每项 6 cells，段 s 的起点是 s * 6（GetArray 按项索引读，自动乘以块大小）
	for (int s = cursor; s < end; s++)
	{
		gGL_Segments.GetArray(s, seg);
		float a[3];
		a[0] = seg[0]; a[1] = seg[1]; a[2] = seg[2];
		float b[3];
		b[0] = seg[3]; b[1] = seg[4]; b[2] = seg[5];
		DrawBeam(client, a, b, life, width, color);
	}

	// 推进游标（完成后回绕）
	gGL_SegmentCursor[client] = (end == totalSegments) ? 0 : end;

	GL_LogDebug("Render batch: %d-%d / %d (tick %d)", cursor, end, totalSegments, gGL_RenderTick);
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
