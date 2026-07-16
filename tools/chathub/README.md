# ChatHub — 多 AI 共桌讨论调度器

让 claude / gpt / copilot 三席 AI 在 `docs/chathub.md` 里自动接力讨论：
**你（Erico）以 `Erico：` 开头写一条 → 三席按序各回一次 → 停，等你下一条。**

单一 broker 顺序驱动三条通道，无并发竞态、无无限回环。三席都走各自的订阅/API：

| 席位 | 通道 | 计费 |
|---|---|---|
| claude | `claude -p`（Claude Code CLI） | Max 订阅，不计 API |
| gpt | `npx @openai/codex exec`（Codex CLI） | ChatGPT 订阅，不计 API |
| copilot | DeepSeek HTTP API | token 计费（便宜） |

## 一次性准备

```powershell
npm i -g @anthropic-ai/claude-code      # 装 claude CLI，再 claude 登录（Max）
# gpt 无需装，首用 npx 自动拉 @openai/codex（需 ChatGPT 登录）
py -3 -m pip install -r requirements.txt # pyyaml + openai
# 设用户环境变量 DEEPSEEK_API_KEY（Win 搜「环境变量」→ 用户变量新建），重启终端
```

## 日常使用

- **自动**：双击 `run_broker.bat`（watch 模式），然后在 `chathub.md` 里以 `Erico：` 写话、保存即自动召集。
- **手动单次**：`py -3 broker.py --once`（最后一条是 Erico 才会跑）。
- **调试**：`--force`（无视触发闸）、`--dry-run`（只打印不写盘）。

### 两种讨论模式

- **参与模式（默认）**：写 `Erico：你的内容`。三席各回复一次后停止，等待你继续主持。
- **议题模式**：写 `Erico：【议题】你的议题`（也支持 `@自动`）。三席最多讨论 4 轮；全员在发言末行标记 `[收敛]` 后可提前结束，最后由配置的 synthesizer 输出 `【结论】`。

议题模式默认只允许读取项目文件来核实事实，不授权无人值守修改。若结论需要改代码、改数据或运行有副作用的命令，应先在结论中列出执行计划，由 Erico 另行明确批准后再进入执行阶段。

## 配置（`config.yaml`）

- `speaking_order` 发言顺序、`max_rounds` 每次触发几轮、`timeouts` 每席超时。
- `adapters.<席>.class` 接线；某席不可用（如没设 key）会自动 `[席：本轮跳过]`，不阻塞其它席。
- 每席可加 `role_prompt`（角色约束）、`model` 等，见各 adapter。

## 结构

```
broker.py            单调度器：触发闸 / 顺序调度 / 每席超时跳过 / 加锁追加
config.yaml          发言顺序、超时、三席接线
adapters/base.py     Adapter 抽象接口（只回正文，不写文件）
adapters/claude.py   claude -p 子进程（stdin 投喂、UTF-8、自带超时）
adapters/gpt.py      codex exec 子进程
adapters/deepseek.py DeepSeek HTTP
stub.py              免外部调用的自测桩
```

## 注意

- broker 是唯一写盘者；适配器只返回发言正文，名字+时间由 broker 统一盖。
- chathub 全文每轮整体重发给各席（文件即共享记忆）；长了以后可加截断/摘要（TODO）。
- 别把含明文 key 的脚本提交 git；本 `run_broker.bat` 从环境继承 key、可安全提交。
