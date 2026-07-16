"""DeepSeek adapter —— 通过 OpenAI 兼容 HTTP API 调用 DeepSeek V4。

配置段（config.yaml 的 copilot 席）：
    endpoint: "https://api.deepseek.com/v1/chat/completions"
    model: "deepseek-chat"
    api_key_env: "DEEPSEEK_API_KEY"
    role_prompt: |           # 可选·系统提示（嵌在 context 前的角色约束）
      ...

⚠ 这个适配器依赖 `openai` 包（OpenAI 兼容 SDK）；本文件不导入 requests，
   统一走 openai 客户端以保持错误处理/重试一致。
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

from adapters.base import Adapter, AdapterError, Turn


class DeepSeekAdapter(Adapter):
    """DeepSeek API 席位（copilot）。"""

    def __init__(self, name: str, config: dict | None = None) -> None:
        super().__init__(name, config)
        self.endpoint: str = self.config.get("endpoint", "https://api.deepseek.com/v1/chat/completions")
        self.model: str = self.config.get("model", "deepseek-chat")
        # role_prompt 可选——config.yaml 里可以给一段系统级角色约束
        self.role_prompt: str | None = self.config.get("role_prompt")

    def generate(self, context: str, turn: Turn) -> str:
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
                model=self.model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                temperature=0.7,
                max_tokens=2048,
                timeout=self.config.get("http_timeout", 55),  # 比 broker 超时略短
            )
            body = resp.choices[0].message.content
            if body is None:
                raise AdapterError("API 返回空内容")
            return body.strip()
        except openai.APITimeoutError as exc:
            raise AdapterError(f"DeepSeek API 超时：{exc}") from exc
        except openai.APIError as exc:
            raise AdapterError(f"DeepSeek API 错误：{exc}") from exc
        except Exception as exc:
            raise AdapterError(f"DeepSeek 适配器异常：{exc}") from exc


# ---- 独立自测（`python adapters/deepseek.py --test`） ----
if __name__ == "__main__":
    if "--test" in sys.argv:
        adapter = DeepSeekAdapter("copilot", config={
            "endpoint": "https://api.deepseek.com/v1/chat/completions",
            "model": "deepseek-chat",
            "api_key_env": "DEEPSEEK_API_KEY",
        })
        test_context = (
            "Erico：测试消息，请 copilot 回复。\n"
            "claude：骨架测试。 2026-07-16 02:40\n"
        )
        turn = Turn(round_index=0, speaker="copilot", order_index=2)
        try:
            reply = adapter.generate(test_context, turn)
            print(f"✅ DeepSeek 通道测试成功。\n回复预览（前 200 字）：\n{reply[:200]}")
        except AdapterError as exc:
            print(f"❌ DeepSeek 通道测试失败：{exc}")
        except Exception as exc:
            print(f"❌ 未预期错误：{exc}")
    else:
        print("用法：python adapters/deepseek.py --test")
