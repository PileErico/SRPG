"""ChatHub 适配器抽象接口。

每个「席位」（opus/gpt/deepseek/fable…）是一个 Adapter。约定 🔒：
- **无状态**：chathub.md 就是全部共享记忆；适配器每次被调用都重新读上下文。
- **只产出发言正文**：适配器 *不* 写 chathub.md——由 broker 统一盖上「名字＋时间」
  并加锁追加。这样杜绝「模型与 broker 双写」和多席并发写同一文件。
- **失败即抛异常**：无法产出发言时抛 AdapterError（或任意异常），broker 记
  `[名字：本轮跳过]` 后继续下一席，不阻塞。
- **元数据白名单 🔒**：Invocation 只收标量字段（可执行文件/模型/effort/注入状态），
  prompt 与上下文一律不进——新参数默认不入库，避免「今天没敏感内容」式的黑名单思维。
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


@dataclass
class Invocation:
    """一次调用的白名单事实——落款与审计的唯一数据源。

    只放标量：prompt / 上下文 / 完整 argv 一律不进（会随 CLI 加参数而泄露上下文）。
    executable 对 HTTP 席位填标识串（如 "api:deepseek"）。
    """

    executable: str = ""
    requested_model: str | None = None     # 我们要求的模型（来自 config）
    reported_model: str | None = None      # 服务端回读的模型；CLI 席无从回读，留空
    effort: str | None = None
    model_injected: bool = False           # --model 是否真进了命令行
    effort_injected: bool = False          # --effort（或等价参数）是否真进了命令行


@dataclass
class RunMeta:
    """单次调用的元数据，随 RunResult 一起回到调用方（不设共享可变状态）。"""

    status: str = "ok"                     # "ok" | "error"
    invocation: Invocation = field(default_factory=Invocation)
    warnings: list[str] = field(default_factory=list)

    @property
    def verified(self) -> bool:
        """requested 与 reported 均非空且相等才算 verified 🔒。

        CLI 席 reported 恒空 → 恒 unverified；HTTP 席可 verified，语义自洽。
        """
        inv = self.invocation
        return bool(inv.requested_model) and inv.requested_model == inv.reported_model

    @property
    def verification(self) -> str:
        return "verified" if self.verified else "unverified"


@dataclass
class RunResult:
    """发言正文 + 元数据。"""

    content: str
    meta: RunMeta = field(default_factory=RunMeta)


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

    def generate_result(self, context: str, turn: Turn) -> RunResult:
        """带元数据的调用入口；默认包一层 generate()，返回 unverified。

        未覆写的适配器零改动照跑。覆写者的约定 🔒：
        - 非法 effort 等**参数级**错误在调用外部命令**之前**拦下，返回
          status="error" 的 RunResult（不浪费一次模型调用，也不在 daemon 线程里抛）；
        - 超时/非零退出/空输出等**运行期**失败照旧抛 AdapterError，保住 broker
          「本轮跳过」的容错语义。
        """
        return RunResult(content=self.generate(context, turn))

    def capabilities(self) -> dict:
        """本席位支持哪些轴——**实例方法**：fable/opus 共用 ClaudeAdapter 仅 model 不同，
        且要读 self.config，类方法读不到。

        返回静态 dict：探测是施工期取证，运行期不做任何模型调用。
        """
        return {
            "model": {"free_input": True, "suggestions": []},
            "effort": {"supported": False, "values": []},
        }
