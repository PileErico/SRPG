# ChatHub — 多 AI 共桌讨论与执行调度器

四席 AI 围绕你的项目讨论、出结论、并在授权后真正落地代码。**主产品＝GUI**
（`gui/`，Flask+SQLite+浏览器界面）；`broker.py`＋`docs/chathub.md` 是早期 CLI 版，保留作备用。

## 四席分工（2026-07-16 定）

| 席位 | 模型/通道 | 角色 | 计费 |
|---|---|---|---|
| **fable** | claude-fable-5（Claude CLI） | **项目总负责人**：定方向、做取舍、出【结论】、执行后【验收】；不写代码 | Max 订阅 |
| **opus** | opus（Claude CLI 默认） | **执行者1**：实现视角发言；执行阶段在 `opus` 分支落地 | Max 订阅 |
| **gpt** | Codex CLI | **执行者2**：独立实现视角；执行阶段在 `codex` 分支落地 | ChatGPT 订阅 |
| **copilot** | DeepSeek HTTP | **参谋席**：评价与建议；**无文件访问**，适配器内置反幻觉硬约束（只评记录、推测必须标注） | token 计费 |

发言顺序：opus → gpt → copilot → fable（执行者先给实料，参谋评议，总负责人压轴裁决）。

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
- 🧠 **议题**：自动补【议题】标记 → 四席自主多轮讨论（至多 4 轮，全员收敛提前停）→ fable 出【结论】→ 结论进右栏「共享记忆·草案」，你点 ✓ 确认后跨议题共享。
- ⚙ **执行**：先勾选**执行名单**（opus→opus 分支 / gpt→codex 分支，可只选一个）→ 发送时二次确认 → 流程：
  1. 执行者按名单顺序落地（各自分支；每人跑完立即回基线，防止在别人分支上开工）；
  2. **交叉互查**：执行者互审对方分支的真实 diff（≥2 人产出 diff 才触发）；
  3. copilot 参考意见（只评记录）；
  4. **fable 验收**：看全部 diff＋互查意见，裁决采用哪版/如何合并。
  执行护栏：不 push、不碰 main、只提交自己改动（显式路径）；执行者遗留未提交改动会被检测并 ⚠ 提示。

对话区底部有实时指示器：谁在思考/执行/互查/验收＋已耗时。

## 配置（`config.yaml`）

- `speaking_order` 发言顺序；`timeouts` 每席超时；`autonomous` 议题模式参数（synthesizer=fable）。
- `execution`：执行者名单（seat/branch/cmd）、`cross_review`、`acceptor`（fable）、`reviewer`（copilot）、`diff_char_budget`。
- `adapters.<席>`：接线 + `role_prompt`（角色约束）+ `model`。某席不可用会容错跳过。

## 结构

```
broker.py            CLI 调度器（备用）：触发闸/顺序调度/收敛投票
config.yaml          四席接线、角色提示词、议题/执行参数
adapters/            claude.py（claude -p，fable/opus 共用，席位名动态）
                     gpt.py（codex exec）· deepseek.py（HTTP，反幻觉约束内置）
gui/store.py         SQLite：topics/messages/memory_items/topic_summaries
gui/engine.py        三模式路由、上下文预算、执行编排（名单→落地→互查→参考→验收）
gui/executor.py      执行者子进程、分支 diff/diffstat、脏树守卫、结构化失败报告
gui/server.py        Flask API（127.0.0.1:8765）+ memory.md 备份镜像
gui/static/index.html  三栏前端：模式按钮/执行名单/指示器/记忆确认
gui/memory.md        共享记忆的人类可读备份（可提交 git，库损坏可找回）
```

## Backlog（席位共识 2026-07-16，未实装）

- **证据通道**：席位发言写【取证】path:lines → 下轮把真实文件片段注入其上下文（根治参谋席无文件访问）。
- **结论状态机**：提议→待验证→已验证→已批准→已执行→已验收。
- **变更契约**：执行前声明目标文件/禁区/验收命令，执行后自动核对 diff 是否越界。
- **超时真 kill**：engine 线程超时目前只放弃结果（子进程靠各自 subprocess timeout 兜底）；改为持句柄真杀。
- pytest 回归套件（Windows 可执行解析/超时/分支切换）。
