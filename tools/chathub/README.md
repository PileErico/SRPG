# ChatHub — 多 AI 共桌讨论与执行调度器

多席 AI 围绕**你选定的工作区项目**讨论、出结论、并在授权后真正落地代码。
**主产品＝GUI**（`gui/`，Flask+SQLite+浏览器界面）；`broker.py`＋`<工作区>/docs/chathub.md`
是早期 CLI 版，保留作备用。

**独立工具 🔒（2026-07-16 独立化）**：ChatHub 不属于任何项目仓库——它住在自己的目录里，
通过 `config.yaml` 的 `workspace` 键（GUI 里可切换）指定给哪个项目干活。
维护 ChatHub 自身＝改本仓库；维护目标项目＝ChatHub 作用于工作区。两本账永不混淆。

## 席位分工（2026-07-16 独立化重排）

> **席位名单的唯一真值＝`config.yaml` 的 `speaking_order` + `adapters` + `execution.executors` 三处。**
> 下表和前端都只是复述——改席位只改 config，别指望搜索 README 能搜全。

| 席位 | 模型/通道 | 角色 | 计费 |
|---|---|---|---|
| **fable** | claude-fable-5（Claude CLI） | **项目总负责人**：定方向、做取舍、出【结论】、执行后【验收】；不写代码 | Max 订阅 |
| **gpt** | Codex CLI | **讨论主力**：独立实现视角，与 fable 定稿方案；执行后做**规格审查** | ChatGPT 订阅 |
| **deepseek** | DeepSeek HTTP | **参谋席**：评价与建议；**无文件访问**，适配器内置反幻觉硬约束（只评记录、推测必须标注）；默认不参加，想要时勾选 | token 计费 |
| **opus** | claude-opus-4-8（Claude CLI） | **纯执行席**：不参与讨论；fable+gpt 定稿的文档就是它的全部输入，执行阶段在工作区的 `opus` 分支落地 | Max 订阅 |

**为什么 fable 和 opus 不同桌**：两者同为 Claude，同桌买不来第二视角，却付着最贵的账
（opus 冷启动是全场最慢超时）。fable + gpt 才是两个独立大脑；opus 降级为纯施工方。

讨论顺序：gpt → deepseek → fable（实料 → 参谋评议 → 总负责人压轴）。
每条消息可在 GUI 勾选**谁参加**（默认＝`default_participants`：gpt+fable），顺序永远按 `speaking_order`。

`deepseek` 席 2026-07-16 前叫 `copilot`（改名＝按模型真名叫）。**库里的旧消息 speaker 不迁移**，
前端对旧名保留渲染样式——历史记录照原样可读。同理 opus 退出讨论后，历史讨论里它的发言照常显示。

## 一次性准备

```powershell
npm i -g @anthropic-ai/claude-code      # 装 claude CLI，再 claude 登录（Max）
# gpt 无需装，首用 npx 自动拉 @openai/codex（需 ChatGPT 登录）
py -3 -m pip install -r requirements.txt # pyyaml + openai + flask
# 设用户环境变量 DEEPSEEK_API_KEY，重启终端
```

## 日常使用（GUI）

双击 `run_chathub_gui.bat` → 自动开浏览器 `http://127.0.0.1:8765`。
那个黑色控制台窗口就是服务器，关掉即停（页面关闭后服务器也会自动退）。

**工作区**（侧栏顶部 📁）：显示当前目标项目；点击可切换（校验必须是 git 仓库，
讨论/执行进行中拒绝切换）。选择存进 db，重启后延续。不可用时标红 ⚠，执行会被拒绝。

**三个模式按钮**（输入框上方，手打标记也会自动切换）：

- 💬 **讨论**：先勾**参与席位**（默认 gpt+fable）→ 写话发送 → 勾选的席各回一次 → 停，你主持。
- 🧠 **议题**：自动补【议题】标记 → 勾选的席自主多轮讨论（至多 4 轮；**全员收敛**或 **fable 拍板**提前停）→ fable 出【结论】→ 结论进右栏「共享记忆·草案」，你点 ✓ 确认后跨议题共享。
  - **拍板权**（`autonomous.arbiter`＝fable）：fable 在发言最后单独一行写 `[拍板]`，本轮剩余席位立即跳过、直接进结论综合。只有 arbiter 写才算数，严格末行匹配。拍板**只收当轮**，被跳过的席位下轮正常参与。
- ⚙ **执行**：勾选**执行名单**（默认 opus→工作区的 opus 分支）→ 发送时二次确认 → 流程：
  1. 执行者按名单顺序在**工作区**落地（各自分支；每人跑完立即回基线）；
  2. **审查**：≥2 名执行者产出 diff＝交叉互查；**单执行者＝`spec_reviewer`（gpt）做规格审查**——
     gpt 参与定稿了方案，审「落实是否走样」正合适；
  3. deepseek 参考意见（只评记录）；
  4. **fable 验收**：看全部 diff＋审查意见，裁决采用/必须修复项。
  执行护栏：不 push、不碰 main、只提交自己改动（显式路径）；执行者遗留未提交改动会被检测并 ⚠ 提示；工作区无效/基线异常（detached HEAD、停在执行分支上）直接拒绝执行。

对话区底部有实时指示器：谁在思考/执行/审查/验收＋已耗时。

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

- **`workspace`**：目标工作区（项目仓库根）。相对路径＝相对 config.yaml 所在目录；
  所有 CLI 席子进程的 cwd、执行阶段全部 git 操作都以它为根（`Config.load` 自动注入各席，
  在某席下显式写 `workspace` 键可按席覆盖）。GUI 切换的选择存 db（`settings` 表），优先于 config。
- `speaking_order` 讨论席全集＋顺序；`default_participants` GUI 默认勾选；`timeouts` 每席超时；
  `autonomous` 议题模式参数（`synthesizer`/`arbiter`＝fable、三个行标记）。
- `execution`：执行席名单（seat/branch/cmd，工位分支开在工作区里）、`cross_review`（≥2 人互查）、
  **`spec_reviewer`（单执行者时的规格审查席＝gpt）**、`review_timeout`（审查专用线程超时——
  审查读整份 diff，负载远超讨论档）、`reviewer`（deepseek 参考）、
  `acceptor`（fable 验收）、`diff_char_budget`。执行拒绝条件：工作区无效、基线分支异常、
  **议题的 workspace 戳与当前工作区不符**（防「A 项目的方案落进 B 仓库」）。
- 超时分两层 🔒：`timeouts.<席>` 是 broker 线程超时；各席适配器另有**子进程超时**才是真闸
  （claude 席 `timeout`、gpt 席 `cli_timeout`、deepseek 席 `http_timeout`，均已在 config 显式写出）。
  约定：子进程超时 < 线程超时。
- `adapters.<席>`：接线 + `role_prompt` + `model` + 可选 `effort` / `model_suggestions`。
  某席不可用会容错跳过。opus 挂在 adapters 里只为执行前通道检查——它不在 speaking_order，永不被讨论调用。

## 维护须知（踩过的坑，改代码前先读）

- **数据铁律 🔒**：`gui/chathub.db` 是唯一真库，**任何脚本/测试严禁 rm/覆盖**。测试必须
  显式重指 DB/store/MEM_MD/BACKUP_DIR 到临时目录（`tests/` 有现成做法）。防护：启动+运行时
  轮换快照 `gui/backups/`（留 10 份）、`memory.md` 与 `gui/topics/` 双镜像、库空自愈导回。
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
  prompt、上下文、完整 argv 一律不入库。**新参数默认不记**——白名单反着写，新参数默认安全。
  完整命令行只允许出现在失败路径的排障文本里。
- **SQLite 未启用 WAL**（默认 rollback journal）。备份策略依赖「拷 `chathub.db` 单文件即完整快照」
  （`gui/server.py` 的 `_backup_db`）；一旦启用 WAL，`-wal`/`-shm` 旁文件里会有未合并的事务，
  **只拷主库＝拷到旧数据**——要开 WAL 就得先改备份策略（拷三件套或先 checkpoint）。
- **路径纪律 🔒（独立化后）**：代码里**禁止**出现「工具目录上溯 N 层＝项目根」式推导
  （旧 `REPO_ROOT` 已全数拆除）。要项目根一律走 `workspace`（engine/executor 显式传参、
  适配器读 `self.config["workspace"]`）。

## 结构

```
broker.py            CLI 调度器（备用）：Config（workspace 解析+注入）/触发闸/顺序调度/收敛投票
config.yaml          workspace + 席位接线、角色提示词、议题/执行参数
adapters/base.py     Adapter 抽象 + RunResult/RunMeta/Invocation（元数据白名单）+ capabilities()
adapters/            claude.py（claude -p，fable/opus 共用，席位名动态）
                     gpt.py（codex exec）· deepseek.py（HTTP，反幻觉约束内置）
gui/store.py         SQLite：topics(+workspace)/messages/memory_items/topic_summaries/settings
gui/engine.py        三模式路由、参与席过滤、工作区切换、执行编排（落地→审查→参考→验收）
gui/executor.py      执行者子进程、workspace_error 校验、分支 diff/diffstat、脏树守卫
gui/server.py        Flask API（127.0.0.1:8765，CHATHUB_PORT 可改）+ memory.md 备份镜像
gui/static/index.html  三栏前端：工作区行/参与席 chips/执行名单/席位配置/指示器/记忆确认
gui/memory.md        共享记忆的人类可读备份（可提交 git，库损坏可找回）
gui/topics/          议题的逐条镜像（库损坏可整体恢复）
tests/               冒烟测试（临时库，py -3 tests/run_smoke.py）
```

## Backlog（席位共识 2026-07-16，未实装）

- **证据通道**：席位发言写【取证】path:lines → 下轮把真实文件片段注入其上下文（根治参谋席无文件访问）。
- **结论状态机**：提议→待验证→已验证→已批准→已执行→已验收。
- **变更契约**：执行前声明目标文件/禁区/验收命令，执行后自动核对 diff 是否越界。
- **超时真 kill**：engine 线程超时目前只放弃结果（子进程靠各自 subprocess timeout 兜底）；改为持句柄真杀。
- **记忆/议题按工作区分库**：现在 topics 已盖 workspace 戳；真正分库等第二个项目进场再做。
