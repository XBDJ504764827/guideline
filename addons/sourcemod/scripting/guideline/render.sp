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



// =====[ PUBLIC ]=====

void GL_OnMapStart_Render()
{
	GL_OnMapStart_State();
}

// Cookie 缓存完成：恢复开关状态
void GL_OnClientCookiesCached(int client)
{
	GL_OnClientCookiesCached_State(client);
}

void GL_OnClientDisconnect(int client)
{
	GL_OnClientDisconnect_State(client);
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
	if (interval < 0.5)
	{
		interval = 0.5;
	}
	gH_RenderTimer = CreateTimer(interval, GL_Timer_Render, _, TIMER_REPEAT);
}

public Action GL_Timer_Render(Handle timer)
{
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

		GL_RenderRouteToClient(client);
	}
	return Plugin_Continue;
}

// 渲染路线给单个玩家（只发给本人）
void GL_RenderRouteToClient(int client)
{
	if (!GL_HasRoute())
	{
		return;
	}

	ArrayList points = gGL_Route.points;
	int n = points.Length;
	if (n < 2)
	{
		return;
	}

	int maxSegments = GL_GetMaxSegments();
	float breakDist = GL_GetBreakDist();
	float verticalBreakDist = GL_GetVerticalBreakDist();

	int color[4];
	GL_GetColor(color);
	float life = GL_GetBeamLifetime();
	float width = GL_GetBeamWidth();

	// Chaikin 细分迭代次数（性能自适应：超限自动降级，仍保持全图）
	int chaikinIter = GL_GetSmooth() ? GL_GetSmoothPoints() : 0;
	if (chaikinIter < 0) chaikinIter = 0;
	if (chaikinIter > 3) chaikinIter = 3;
	int subdiv = 1 << chaikinIter;
	int totalBeams = (n - 1) * subdiv;
	while (chaikinIter > 0 && totalBeams > maxSegments)
	{
		chaikinIter--;
		subdiv = 1 << chaikinIter;
		totalBeams = (n - 1) * subdiv;
	}
	// 硬保护：超过 4000 条 beam 强制再降（极长图）
	if (totalBeams > 4000)
	{
		chaikinIter = 0;
		subdiv = 1;
	}

	// 收集连续点序列（断点处断开），保证起点与终点必定可见
	ArrayList seq = new ArrayList(3);

	for (int ptIdx = 0; ptIdx < n; ptIdx++)
	{
		bool needFlushBefore = false;
		if (ptIdx > 0)
		{
			TrackPoint prev, cur;
			points.GetArray(ptIdx - 1, prev);
			points.GetArray(ptIdx, cur);

			// 优先使用降采样时确定的断点标记（双层/传送/距离断点）
			if (cur.isBreak)
			{
				needFlushBefore = true;
			}
			// 兜底：3D 距离断点（渲染时点序变化导致标记失效的情况）
			else
			{
				float dist = GL_Distance3D(prev.origin, cur.origin);
				if (dist > breakDist)
				{
					needFlushBefore = true;
				}
				// 双层场景：水平距离近但垂直距离突变也断开
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
			if (seq.Length >= 2)
			{
				FlushChaikinRoute(client, seq, chaikinIter, color, life, width);
			}
			delete seq;
			seq = new ArrayList(3);
		}

		TrackPoint tp;
		points.GetArray(ptIdx, tp);
		seq.PushArray(tp.origin);
	}
	// 收尾：最后一段序列必定绘制（含终点）
	if (seq.Length >= 2)
	{
		FlushChaikinRoute(client, seq, chaikinIter, color, life, width);
	}
	delete seq;
}

// 对连续点序列做 Chaikin 角切割细分并绘制
static void FlushChaikinRoute(int viewer, ArrayList seq, int iter, const int color[4], float life, float width)
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

	for (int j = 0; j < cur.Length - 1; j++)
	{
		float a[3], b[3];
		cur.GetArray(j, a);
		cur.GetArray(j + 1, b);
		DrawBeam(viewer, a, b, life, width, color);
	}

	delete cur;
}

// Team 激光束发送（参数与 GOKZ JumpBeam 完全一致：FadeLength 10、Amplitude 0、Speed 0）
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
