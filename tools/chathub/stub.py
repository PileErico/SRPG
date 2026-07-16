"""端到端自测用的桩适配器——不调任何外部 AI，直接回一句固定发言。

把 config.yaml 里某席的 `class` 临时改成 "stub:StubAdapter" 即可在
**无任何 API/CLI** 的情况下跑通 broker 全链路（触发闸→调度→加锁追加）。
真适配器（gpt/deepseek/claude）落地后即可换回。
"""
from __future__ import annotations

from adapters.base import Adapter, Turn


class StubAdapter(Adapter):
    def generate(self, context: str, turn: Turn) -> str:
        tail = context.strip().splitlines()[-1] if context.strip() else "(空)"
        body = (f"[stub] 我是 {self.name} 的桩回复（第 {turn.round_index} 轮）。"
                f"读到最后一行是：{tail[:40]}")
        # 议题模式自测：第 0 轮喊继续、第 1 轮起喊收敛，便于验证收敛+结论逻辑
        if "议题讨论模式" in context:
            body += "\n[继续]" if turn.round_index == 0 else "\n[收敛]"
        elif "结论综合" in context:
            body = "这是桩综合出的结论占位。"
        return body
