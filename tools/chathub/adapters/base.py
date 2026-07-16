"""ChatHub 适配器抽象接口。

每个「席位」（claude/gpt/copilot…）是一个 Adapter。约定 🔒：
- **无状态**：chathub.md 就是全部共享记忆；适配器每次被调用都重新读上下文。
- **只产出发言正文**：适配器 *不* 写 chathub.md——由 broker 统一盖上「名字＋时间」
  并加锁追加。这样杜绝「模型与 broker 双写」和多席并发写同一文件。
- **失败即抛异常**：无法产出发言时抛 AdapterError（或任意异常），broker 记
  `[名字：本轮跳过]` 后继续下一席，不阻塞。
"""
from __future__ import annotations

import abc
from dataclasses import dataclass, field


@dataclass
class Turn:
    """交给适配器的单次发言元信息。"""

    round_index: int                       # 本次触发内的第几轮（0 起）
    speaker: str                           # 席位名，如 "claude"
    order_index: int                       # 本轮发言顺序中的位置（0 起）
    prior_this_round: list[str] = field(default_factory=list)  # 本轮已发言的席位名


class AdapterError(RuntimeError):
    """适配器无法产出发言时抛出。"""


class Adapter(abc.ABC):
    """一个参与者通道。"""

    #: 在 chathub.md 中出现的席位名（如 "claude"）
    name: str = "adapter"

    def __init__(self, name: str, config: dict | None = None) -> None:
        self.name = name
        self.config = config or {}

    @abc.abstractmethod
    def generate(self, context: str, turn: Turn) -> str:
        """返回该席位本轮的发言正文。

        context ＝ 完整共享记录（chathub.md 内容）。
        role 约束等由 self.config（来自 config.yaml 的该席位段）提供。
        """
        raise NotImplementedError
