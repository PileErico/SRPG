"""DeepSeek adapter —— 通过 OpenAI 兼容 HTTP API 调用 DeepSeek V4。

配置段（config.yaml 的 deepseek 席）：
    endpoint: "https://api.deepseek.com/v1/chat/completions"
    model: "deepseek-v4-pro"
    effort: "high"           # 可选·经 reasoning_effort 注入
    api_key_env: "DEEPSEEK_API_KEY"
    role_prompt: |           # 可选·系统提示（嵌在 context 前的角色约束）
      ...

⚠ 这个适配器依赖 `openai` 包（OpenAI 兼容 SDK）；本文件不导入 requests，
   统一走 openai 客户端以保持错误处理/重试一致。

本席是唯一能 **verified** 的席位：HTTP 响应带 `resp.model`，可与请求值比对
（CLI 席无回读通道 → 恒 unverified）。
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# 允许从仓库根直接运行 `python tools/chathub/adapters/deepseek.py --test`。
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from adapters.base import (
    Adapter,
    AdapterError,
    Invocation,
    RunMeta,
    RunResult,
    Turn,
)

# 默认模型 🔒——`deepseek-chat` 于 2026-07-24 停用，且**它不报错、静默降级**：
# 实测 model="deepseek-chat" 的响应 `resp.model` 回读为 `deepseek-v4-flash`
# （`deepseek-reasoner` 同样降到 flash）。也就是说继续用旧串不会有任何报错信号，
# 只会一直拿到弱模型——正是 verified 语义要抓的那种「以为在跑 A、实际在跑 B」。
DEFAULT_MODEL = "deepseek-v4-pro"

# 封闭枚举——**施工期逐值实跑取证所得**（2026-07-16，对 deepseek-v4-pro/flash 均通过）。
# ⚠ 文档称只有 {high, max}，**与实测不符**——服务端把非法值打回时列出的枚举是
#    'high','low','medium','max','xhigh'，且这五个逐个真跑均被接受。以实测为准。
# 大小写敏感（'HIGH' 被拒）；空串同样被拒 → 未设 effort 时不发该参数。
EFFORT_VALUES = ("low", "medium", "high", "xhigh", "max")


class DeepSeekAdapter(Adapter):
    """DeepSeek API 席位（deepseek，原名 copilot）。"""

    def __init__(self, name: str, config: dict | None = None) -> None:
        super().__init__(name, config)
        self.endpoint: str = self.config.get("endpoint", "https://api.deepseek.com/v1/chat/completions")
        self.model: str = self.config.get("model", DEFAULT_MODEL)
        # role_prompt 可选——config.yaml 里可以给一段系统级角色约束
        self.role_prompt: str | None = self.config.get("role_prompt")

    def _effort_error(self) -> str | None:
        """非法 effort 返回原因串，合法/未设返回 None。"""
        effort = self.config.get("effort")
        if not effort:
            return None
        if str(effort) not in EFFORT_VALUES:
            return (f"effort={effort!r} 不在 DeepSeek API 支持的枚举 "
                    f"{'/'.join(EFFORT_VALUES)} 内（大小写敏感）")
        return None

    def capabilities(self) -> dict:
        return {
            "model": {
                "free_input": True,
                "suggestions": list(self.config.get("model_suggestions") or []),
            },
            "effort": {"supported": True, "values": list(EFFORT_VALUES)},
        }

    def _build_params(self) -> dict:
        """**实际发出去的请求参数**——本席的 argv 等价物。

        未设 effort 就不放该键：空串会被服务端 400（实测）。
        """
        params: dict = {"model": self.model}
        if self.config.get("effort"):
            params["reasoning_effort"] = str(self.config["effort"])
        return params

    def _invocation(self, params: dict, reported_model: str | None = None) -> Invocation:
        """从**实际请求参数**回读注入事实——与 claude/gpt 席「从真 argv 回读」同构。

        绝不改回从 self.config 推断：那记录的是意图而非事实，预检拦截（根本没发请求）
        时会谎报 injected=True。白名单：只取标量，messages/上下文一律不进。
        """
        return Invocation(
            executable="api:deepseek",     # HTTP 席无可执行文件 → 填标识串
            requested_model=params.get("model"),
            reported_model=reported_model,  # resp.model ＝ 硬证据，本席可 verified
            effort=params.get("reasoning_effort"),
            model_injected="model" in params,
            effort_injected="reasoning_effort" in params,
        )

    def generate_result(self, context: str, turn: Turn) -> RunResult:
        reason = self._effort_error()
        if reason:
            # 参数级错误：不发请求、不抛异常（daemon 线程里抛会静默死掉）。
            # 传空 params ＝ 事实就是「什么都没发出去」，injected 全 False。
            return RunResult(
                content=f"［{self.name}：配置错误，未发请求］{reason}",
                meta=RunMeta(status="error",
                             invocation=self._invocation({}),
                             warnings=[reason]),
            )
        params = self._build_params()
        body, reported = self._call(context, turn)   # 运行期失败照旧抛 AdapterError
        meta = RunMeta(invocation=self._invocation(params, reported))
        if reported and reported != self.model:
            # broker 的落款已单独渲染「⚠ 服务端回读 X」，此处只补它说不出的那层解读，
            # 不复述回读值本身——否则落款读起来像口吃。
            meta.warnings.append(f"model 串 {self.model!r} 被服务端静默重定向（非报错）")
        return RunResult(content=body, meta=meta)

    def generate(self, context: str, turn: Turn) -> str:
        reason = self._effort_error()
        if reason:
            raise AdapterError(reason)     # 旧入口无 RunResult 可携带，只能抛
        return self._call(context, turn)[0]

    def _call(self, context: str, turn: Turn) -> tuple[str, str | None]:
        """返回（发言正文, resp.model 回读值）。"""
        import openai

        api_key = os.environ.get(self.config.get("api_key_env", "DEEPSEEK_API_KEY"))
        if not api_key:
            raise AdapterError(
                f"缺少 API key：请设置环境变量 {self.config.get('api_key_env', 'DEEPSEEK_API_KEY')}"
            )

        client = openai.OpenAI(
            api_key=api_key,
            base_url=self.endpoint.replace("/v1/chat/completions", "/v1"),
        )

        # 组装系统提示：角色约束（可选）＋ 反幻觉硬约束 ＋ 发言格式约定
        system_lines = [
            f"你是一个参与多人技术讨论的 AI 助手，席位名为 {self.name}（背后是 DeepSeek）。",
            "你的定位是**参谋席**：提供评价与建议，不做最终决策，也不执行代码。",
            "",
            "反幻觉硬约束（必须遵守）：",
            "- 你**没有**文件系统访问能力：绝不能声称自己「查看/搜索/验证了某个文件」——",
            "  你所有的判断只能基于下方对话记录里真实出现的内容。",
            "- 评价前先核对对象：明确指出你评价的是哪一席的哪条发言（引用其要点原文），",
            "  确保它真实存在于记录中，不评价记录里没有的东西。",
            "- 严格区分事实与推测：凡是记录中没有直接依据的判断，必须以「推测：」开头标注。",
            "- 记录信息不足以支撑结论时，直说缺什么、建议由谁补证（fable/opus/gpt 可查仓库），",
            "  不要脑补细节来填空。",
            "- 无实质补充就返回单行 '无补充。'——不要为了发言而发言。",
            "",
            "发言规则：",
            "- 只返回发言正文，**不要**加名字前缀或时间戳（broker 会统一盖）。",
            "- 不要写 Markdown 代码块包裹你的发言。",
            "- 保持简洁，聚焦推进讨论或补充未被覆盖的视角。",
        ]
        if self.role_prompt:
            system_lines.insert(0, f"你的角色身份：{self.role_prompt}")

        system_prompt = "\n".join(system_lines)

        user_prompt = (
            f"以下是当前讨论的完整记录（chathub.md）：\n\n"
            f"{context}\n\n"
            f"—— 本轮你是第 {turn.order_index + 1} 个发言的 AI。"
            f"请发表你的看法（只返回发言正文，不加名字/时间）："
        )

        try:
            resp = client.chat.completions.create(
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                temperature=0.7,
                max_tokens=2048,
                timeout=self.config.get("http_timeout", 55),  # 比 broker 超时略短
                # model/reasoning_effort 只此一处来源——与 _invocation 回读的是同一个
                # dict，杜绝「记录的参数」与「发出的参数」各写一份条件后漂移。
                **self._build_params(),
            )
            body = resp.choices[0].message.content
            if body is None:
                raise AdapterError("API 返回空内容")
            return body.strip(), getattr(resp, "model", None)
        except openai.APITimeoutError as exc:
            raise AdapterError(f"DeepSeek API 超时：{exc}") from exc
        except openai.APIError as exc:
            raise AdapterError(f"DeepSeek API 错误：{exc}") from exc
        except Exception as exc:
            raise AdapterError(f"DeepSeek 适配器异常：{exc}") from exc


# ---- 独立自测（`python adapters/deepseek.py --test`） ----
if __name__ == "__main__":
    if "--test" in sys.argv:
        adapter = DeepSeekAdapter("deepseek", config={
            "endpoint": "https://api.deepseek.com/v1/chat/completions",
            "model": DEFAULT_MODEL,
            "api_key_env": "DEEPSEEK_API_KEY",
        })
        test_context = (
            "Erico：测试消息，请 deepseek 回复。\n"
            "fable：骨架测试。 2026-07-16 02:40\n"
        )
        turn = Turn(round_index=0, speaker="deepseek", order_index=2)
        try:
            result = adapter.generate_result(test_context, turn)
            inv = result.meta.invocation
            print(f"✅ DeepSeek 通道测试成功（{result.meta.verification}）。"
                  f"\n   requested={inv.requested_model} / reported={inv.reported_model}"
                  f"\n回复预览（前 200 字）：\n{result.content[:200]}")
        except AdapterError as exc:
            print(f"❌ DeepSeek 通道测试失败：{exc}")
        except Exception as exc:
            print(f"❌ 未预期错误：{exc}")
    else:
        print("用法：python adapters/deepseek.py --test")
