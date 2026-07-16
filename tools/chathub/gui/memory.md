# ChatHub 共享记忆（自动导出的可读备份）

> 这是 gui/chathub.db 里共享记忆的镜像。库若重置/损坏，server 启动时会从本文件自动恢复。
> 正常改动请在 ChatHub 界面里「确认/弃置」——手工编辑本文件不会写回数据库。

## 已确认 approved（1）

### #1｜approved｜来源：议题#1/claude

【结论】

**1) 最终方案（三席已收敛）**

- **接口形状**：`adapters/base.py` 加 `RunMeta` / `RunResult`（`@dataclass`，与文件里既有的 `Turn` 统一范式）+ `generate_result()` 新入口，默认实现包一层现有 `generate() -> str` 并返回 `unverified` 元数据。`generate() -> str` 的原契约不动，未覆写的适配器零改动照跑。同时加类方法 `capabilities()`，默认 `{"model": {"free_input": true, "suggestions": []}, "effort": {"supported": false, "values": []}}`。
- **broker 侧**：只改 `call_with_timeout` 里那一处调用——`result` 是每次调用的局部变量，元数据随 `RunResult` 一起从这里出来，`run_round` 拆包即可。
- **两个轴各自的规则**：`model` 自由输入、服务端不校验（claude/codex 都吃任意串，写死列表会过期），建议值来自 config 而非硬编码；`effort` 是各席自己声明的封闭枚举，非法值必须明确拒绝。claude 席已实测 `--effort {low,medium,high,xhigh,max}` + `--model`（别名或全名），两轴原生支持；gpt 席以本机 `codex --help` 实测为准；DeepSeek 席 `effort.supported=false`，GUI 灰掉并提示「高强度请在 model 下拉选 `deepseek-reasoner`」——不做 effort→model 映射，避免两个控件互相覆盖。
- **落款**：只写 `model / effort / 验证状态`；回读不到就写 `requested + unverified`，**绝不叫 effective**；完整 requested/effective/warnings 进消息元数据，旧消息缺字段按原格式渲染。
- **分工**：claude 落 `base.py` 骨架 + `claude.py` 填 `--effort` + config 段；gpt 接 `adapters/gpt.py`；copilot 接 `deepseek.py` + GUI + broker 拆包与落款。先合基类兼容层，再三席并行。

**2) 仍有分歧 / 我在此收口的两条**

- **非法 effort 该报错还是 warning**：gpt 要「执行前明确报错」，copilot 要「不抛异常否则线程静默死掉」。两者不冲突，写法是——`generate_result()` 开头就校验，非法即**不调 CLI**、直接返回 `RunResult(content=错误说明, meta.status="error", warnings=[原因])`。既没浪费模型调用，也没在 daemon 线程里抛异常。warning 只留给「无法回读实际模型」这类非阻断情况。
- **copilot 最后提的 `broker.last_meta: dict[str, RunMeta]` 我反对**：这正是我们刚毙掉的 `last_run` 竞态换了个位置——`call_with_timeout` 超时后旧线程仍在跑，晚回来的那次照样能覆盖这张表，落款又变成盖死人的数据。元数据已经随 `RunResult` 从局部 `result` 里出来了，broker 不需要另存一份可变状态。
- **踢出本次范围**：GUI 下拉搜索过滤（建议值就三五项）、`--output-format json` 回读实际模型（字段未实测，`unverified` 本就是给它兜底的）。

**3) 下一步（需 Erico 批准）**

1. **【批准点 A】放行本议题开工**：三席按上述分工各自分支落地，走 `【执行】` 通道。我先落 `base.py` + `claude.py`，形状定下 gpt/copilot 接。
2. **【批准点 B】executor 单独验收**：用一个独立、可撤销的小改动单跑一次 `【执行】`，不与本议题同 diff——两件事各有各的失败信号，混在一起会互相掩盖。
3. **验收硬项**：重启后配置仍在；三席分别验证模型切换；claude/gpt 席验证命令行里真出现了 effort 参数；DeepSeek 席 effort 控件禁用且有提示；非法 effort 明确报错不静默；旧 config / 旧历史消息仍能加载；落款可追溯实际运行配置。
4. **一条流程约束，建议一并放行**：本轮讨论里出现过两次凭形状猜代码（不存在的 `--thinking` flag、不存在的 `broker.self.agents`/`async` 调用链），都是靠实读纠正的。**动手前每席先读自己要改的文件，引用带真行号**——这条比上面任何一项技术决定都更影响这次改动能不能一次做对。

## 草案 draft（待确认）（0）

_（暂无）_
