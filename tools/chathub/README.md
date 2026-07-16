# ChatHub — 多 AI 共桌讨论与执行调度器

四席 AI 围绕你的项目讨论、出结论、并在授权后真正落地代码。**主产品＝GUI**
（`gui/`，Flask+SQLite+浏览器界面）；`broker.py`＋`docs/chathub.md` 是早期 CLI 版，保留作备用。

## 四席分工（2026-07-16 定）

> **席位名单的唯一真值＝`config.yaml` 的 `speaking_order` + `adapters` 两处。**
> 下表和前端都只是复述——改席位只改 config，别指望搜索 README 能搜全。

| 席位 | 模型/通道 | 角色 | 计费 |
|---|---|---|---|
| **fable** | claude-fable-5（Claude CLI） | **项目总负责人**：定方向、做取舍、出【结论】、执行后【验收】；不写代码 | Max 订阅 |
| **opus** | claude-opus-4-8（Claude CLI） | **执行者1**：实现视角发言；执行阶段在 `opus` 分支落地 | Max 订阅 |
| **gpt** | Codex CLI | **执行者2**：独立实现视角；执行阶段在 `codex` 分支落地 | ChatGPT 订阅 |
| **deepseek** | DeepSeek HTTP | **参谋席**：评价与建议；**无文件访问**，适配器内置反幻觉硬约束（只评记录、推测必须标注） | token 计费 |

发言顺序：opus → gpt → deepseek → fable（执行者先给实料，参谋评议，总负责人压轴裁决）。

`deepseek` 席 2026-07-16 前叫 `copilot`（改名＝按模型真名叫）。**库里的旧消息 speaker 不迁移**，
前端对旧名保留渲染样式——历史记录照原样可读。

## 一次性准备

```powershell
npm i -g @anthropic-ai/claude-code      # 装 claude CLI，再 claude 登录（Max）
# gpt 无需装，首用 npx 自动拉 @openai/codex（需 ChatGPT 登录）
py -3 -m pip install -r requirements.txt # pyyaml + openai + flask
# 设用户环境变量 DEEPSEEK_API_KEY，重启终端
```

## 日常使用（GUI）

双击 `run_chathub_gui.bat`（或桌面「ChatHub」快捷方式）→ 自动开浏览器 `http://127.0.0.1:8765`。
那个黑色控制台窗口就是服务器，关掉即停。

**三个模式按钮**（输入框上方，手打标记也会自动切换）：

- 💬 **讨论**：写话发送 → 四席各回一次 → 停，你主持。
- 🧠 **议题**：自动补【议题】标记 → 四席自主多轮讨论（至多 4 轮；**全员收敛**或 **fable 拍板**提前停）→ fable 出【结论】→ 结论进右栏「共享记忆·草案」，你点 ✓ 确认后跨议题共享。
  - **拍板权**（`autonomous.arbiter`＝fable）：fable 在发言最后单独一行写 `[拍板]`，本轮剩余席位立即跳过、直接进结论综合——不必再凑齐全票收敛。只有 arbiter 写才算数（别席写就是普通文本），严格末行匹配（正文里引用「[拍板]」不触发）。拍板**只收当轮**，被跳过的席位下轮正常参与，留痕写在 system 消息里。
- ⚙ **执行**：先勾选**执行名单**（opus→opus 分支 / gpt→codex 分支，可只选一个）→ 发送时二次确认 → 流程：
  1. 执行者按名单顺序落地（各自分支；每人跑完立即回基线，防止在别人分支上开工）；
  2. **交叉互查**：执行者互审对方分支的真实 diff（≥2 人产出 diff 才触发）；
  3. deepseek 参考意见（只评记录）；
  4. **fable 验收**：看全部 diff＋互查意见，裁决采用哪版/如何合并。
  执行护栏：不 push、不碰 main、只提交自己改动（显式路径）；执行者遗留未提交改动会被检测并 ⚠ 提示。

对话区底部有实时指示器：谁在思考/执行/互查/验收＋已耗时。

**席位配置**（左侧栏「⚙ 席位配置」）：每席的 model / effort 就地可改，**进程内即时生效、不写回
config.yaml**（重启回落到 config 的值）。控件完全按各席自报的 `capabilities()` 渲染——支持 effort
的席给下拉、不支持的席禁用并给提示，前端不硬编码谁支持什么。非法值当场 400 报错，绝不静默接受。

## 落款与审计

每条 AI 发言末尾有一行落款：`model / effort / 验证状态`。

- **verified 判定 🔒**：请求模型与服务端回读模型**均非空且相等**才算 verified。CLI 席（claude/codex）
  没有回读通道 → **恒 unverified**，这不是故障，是「只能证明请求过、证不到服务端用了谁」的诚实表述；
  HTTP 席（DeepSeek）能从 `resp.model` 回读，可以 verified。
- **注入事实从实际 argv 回读**，不是复述「我本该拼哪些参数」的条件——两处逻辑早晚漂移。
- 执行阶段在 spawn **之前**另写一条 `［执行审计…］` system 消息：成功/失败/超时三条路径共享同一证据。
- 落款是 2026-07-16 起才有的；更早的历史消息没有这一行，照原格式渲染。

## 配置（`config.yaml`）

- `speaking_order` 发言顺序（＋`adapters` ＝ **席位名单的唯一真值**）；`timeouts` 每席超时；
  `autonomous` 议题模式参数（`synthesizer`=fable 出结论、`arbiter`=fable 有拍板权、
  `converge_tag`/`continue_tag`/`verdict_tag` 三个行标记）。删掉 `arbiter` 即关闭拍板权，
  行为回落到「全票收敛才停」。
- `execution`：执行者名单（seat/branch/cmd）、`cross_review`、`acceptor`（fable）、`reviewer`（deepseek）、`diff_char_budget`。
- `adapters.<席>`：接线 + `role_prompt`（角色约束）+ `model` + 可选 `effort` / `model_suggestions`
  （GUI 下拉的建议值——model 轴服务端不校验，写死列表会过期，故只作建议、允许自由输入）。
  某席不可用会容错跳过。

## 维护须知（踩过的坑，改代码前先读）

- **CLI 大版本升级 → 必须重跑 effort 探测并更新 `capabilities()` 里的字面量。** 那些枚举
  （如 `claude.py` 的 `EFFORT_VALUES`）是**施工期实测取证**硬编码进去的，运行期不做任何探测调用。
  实测行为：`claude -p --effort <非法值>` 是「stderr 警告 + 静默降回默认档 + 退出码 0」——
  枚举过期不会报错，只会让你以为设了 effort 其实没生效。适配器入口的预检就是唯一拦截点。
- **HTTP 席（DeepSeek）的重跑触发条件不是「CLI 升级」**，而是：**模型停用日到期**（如
  `deepseek-chat` 的 2026-07-24）、**`model` 串变更**、或**服务端枚举变化**。同样只认实测：
  该席文档称 effort 只有 `{high, max}`，实测五个值全通过（见 `deepseek.py:EFFORT_VALUES`）——
  **文档不是证据，跑通才是**。停用的 model 串更阴：`deepseek-chat` 不报错，`resp.model` 回读
  是 `deepseek-v4-flash`——**静默降级**，全靠落款的 verified 才看得见。
- **invocation 白名单原则 🔒**：落款/审计只记标量（executable / model / effort / 是否注入），
  prompt、上下文、完整 argv 一律不入库。**新参数默认不记**——「今天的命令行没有敏感内容」是
  黑名单思维，明天加个 token 就漏了；白名单反着写，新参数默认安全。完整命令行只允许出现在
  失败路径的排障文本里。
- **SQLite 未启用 WAL**（默认 rollback journal）。备份策略依赖「拷 `chathub.db` 单文件即完整快照」
  （`gui/server.py` 的 `_backup_db`）；一旦启用 WAL，`-wal`/`-shm` 旁文件里会有未合并的事务，
  **只拷主库＝拷到旧数据**——要开 WAL 就得先改备份策略（拷三件套或先 checkpoint）。

## 结构

```
broker.py            CLI 调度器（备用）：触发闸/顺序调度/收敛投票
config.yaml          四席接线、角色提示词、议题/执行参数
adapters/base.py     Adapter 抽象 + RunResult/RunMeta/Invocation（元数据白名单）+ capabilities()
adapters/            claude.py（claude -p，fable/opus 共用，席位名动态）
                     gpt.py（codex exec）· deepseek.py（HTTP，反幻觉约束内置）
gui/store.py         SQLite：topics/messages/memory_items/topic_summaries
gui/engine.py        三模式路由、上下文预算、执行编排（名单→落地→互查→参考→验收）
gui/executor.py      执行者子进程、分支 diff/diffstat、脏树守卫、结构化失败报告
gui/server.py        Flask API（127.0.0.1:8765）+ memory.md 备份镜像
gui/static/index.html  三栏前端：模式按钮/执行名单/席位配置(按 capabilities 渲染)/指示器/记忆确认
gui/memory.md        共享记忆的人类可读备份（可提交 git，库损坏可找回）
```

## Backlog（席位共识 2026-07-16，未实装）

- **证据通道**：席位发言写【取证】path:lines → 下轮把真实文件片段注入其上下文（根治参谋席无文件访问）。
- **结论状态机**：提议→待验证→已验证→已批准→已执行→已验收。
- **变更契约**：执行前声明目标文件/禁区/验收命令，执行后自动核对 diff 是否越界。
- **超时真 kill**：engine 线程超时目前只放弃结果（子进程靠各自 subprocess timeout 兜底）；改为持句柄真杀。
- pytest 回归套件（Windows 可执行解析/超时/分支切换）。
