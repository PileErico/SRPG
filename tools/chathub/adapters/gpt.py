"""GPT adapter —— 通过 Codex CLI 非交互模式调用 ChatGPT（Plus 订阅）。

配置段（config.yaml 的 gpt 席）：
    codex_cmd: ["npx", "--yes", "@openai/codex", "exec", "--ephemeral", "--sandbox", "read-only"]
    model: "gpt-5.6-sol"     # 可选·经 -m 注入
    effort: "high"           # 可选·经 -c model_reasoning_effort= 注入（Codex 无 --effort）
    role_prompt: |           # 可选·角色约束

通道特性（🔒 经验证）：
- `npx @openai/codex exec --ephemeral --sandbox read-only` 走 ChatGPT 登录
- 不消耗 OpenAI API token（只走 Plus 订阅用量）
- stdout = 发言正文；stderr = 进度/模型信息/警告（须丢弃）
- 冷启动约 10~15s；模型为 gpt-5.6-sol（当前版本）
- **无 `--effort` flag**（`codex exec --help` 实测）：effort 走 `-c model_reasoning_effort=<值>`；
  `-m`/`-c` 必须插在 stdin 标记 `-` **之前**，否则被当成 prompt 参数。
"""
from __future__ import annotations

import os
import subprocess
import sys
import shutil
from pathlib import Path

# 允许从仓库根直接运行 `python tools/chathub/adapters/gpt.py --test`。
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

# Codex 的 effort 配置键——`--effort` 不存在，只有 `-c <key>=<value>`。
EFFORT_CONFIG_KEY = "model_reasoning_effort"

# 封闭枚举——**施工期逐值实跑取证所得**（2026-07-16，模型 gpt-5.6-sol）。
# ⚠ 取证要两级证据，缺一不可：
#   ①「配置可解析」：`--strict-config` 只认键名——实测 `-c model_reasoning_effort=bogus`
#     照样过闸，所以 strict-config **单独不构成证据**；
#   ②「模型实际接受」：真跑一次看退出码——服务端把 bogus 打回并列出通用枚举
#     'none','minimal','low','medium','high','xhigh','max'。
# 而 `minimal` 虽在①②的枚举文本里，实测却被当前模型明确拒绝
# （"'minimal' is not supported with the 'gpt-5.6-sol...' model"）——故**不写进来**。
# CLI 大版本或默认模型升级后须重跑探测再改这里。
EFFORT_VALUES = ("none", "low", "medium", "high", "xhigh", "max")


def codex_subprocess_env() -> dict[str, str]:
    """避开 Store/App-Alias 版 pwsh；Codex Windows 沙箱无法启动 WindowsApps 内程序。"""
    env = os.environ.copy()
    path_key = next((k for k in env if k.lower() == "path"), "Path")
    env[path_key] = os.pathsep.join(
        p for p in env.get(path_key, "").split(os.pathsep)
        if p and "windowsapps" not in p.lower()
    )
    return env


class GptAdapter(Adapter):
    """Codex CLI 席位（gpt / GPT）。"""

    def __init__(self, name: str, config: dict | None = None) -> None:
        super().__init__(name, config)
        self.codex_cmd: list[str] = self.config.get(
            "codex_cmd",
            ["npx", "--yes", "@openai/codex", "exec", "--ephemeral", "--sandbox", "read-only"],
        )
        self.role_prompt: str | None = self.config.get("role_prompt")

    def _resolve_cmd(self) -> list[str]:
        """解析 Windows 上的 npx.cmd；CreateProcess 不会可靠补全 PATHEXT。"""
        cmd = list(self.codex_cmd)
        if not cmd:
            raise AdapterError("codex_cmd 为空")
        found = shutil.which(cmd[0])
        if not found and cmd[0].lower() in {"npx", "npx.cmd"}:
            for candidate in (
                Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "nodejs" / "npx.cmd",
                Path(os.environ.get("APPDATA", "")) / "npm" / "npx.cmd",
            ):
                if candidate.is_file():
                    found = str(candidate)
                    break
        if found:
            cmd[0] = found
        return cmd

    def _build_args(self) -> list[str]:
        """`-m` / `-c` 必须插在 stdin 标记 `-` **之前**——`-` 之后会被当成 prompt 参数。"""
        args = self._resolve_cmd()
        if self.config.get("model"):
            args += ["-m", str(self.config["model"])]
        if self.config.get("effort"):
            args += ["-c", f"{EFFORT_CONFIG_KEY}={self.config['effort']}"]
        return args + ["-"]

    def _effort_error(self) -> str | None:
        """非法 effort 返回原因串，合法/未设返回 None。"""
        effort = self.config.get("effort")
        if not effort:
            return None
        if str(effort) not in EFFORT_VALUES:
            return (f"effort={effort!r} 不在 Codex CLI 当前模型接受的枚举 "
                    f"{'/'.join(EFFORT_VALUES)} 内")
        return None

    def capabilities(self) -> dict:
        return {
            # model 服务端不校验预设列表，写死会过期 → 自由输入，建议值来自 config。
            "model": {
                "free_input": True,
                "suggestions": list(self.config.get("model_suggestions") or []),
            },
            "effort": {"supported": True, "values": list(EFFORT_VALUES)},
        }

    def _invocation(self, args: list[str]) -> Invocation:
        """从**实际 argv** 回读注入事实，避免与 _build_args 的条件逻辑漂移。

        白名单：只取标量；prompt 走 stdin，本就不在 args 里。
        """
        effort_flag = f"{EFFORT_CONFIG_KEY}="
        return Invocation(
            executable=args[0] if args else "",
            requested_model=str(self.config["model"]) if self.config.get("model") else None,
            reported_model=None,           # Codex CLI 无回读通道 → 恒 unverified
            effort=str(self.config["effort"]) if self.config.get("effort") else None,
            model_injected="-m" in args,
            effort_injected=any(a.startswith(effort_flag) for a in args),
        )

    def generate_result(self, context: str, turn: Turn) -> RunResult:
        reason = self._effort_error()
        if reason:
            # 参数级错误：不进 CLI、不抛异常（daemon 线程里抛会静默死掉）
            return RunResult(
                content=f"［{self.name}：配置错误，未调用 CLI］{reason}",
                meta=RunMeta(status="error",
                             invocation=self._invocation(self._resolve_cmd()),
                             warnings=[reason]),
            )
        args = self._build_args()
        body = self._run(args, context, turn)   # 运行期失败照旧抛 AdapterError
        return RunResult(content=body, meta=RunMeta(invocation=self._invocation(args)))

    def generate(self, context: str, turn: Turn) -> str:
        reason = self._effort_error()
        if reason:
            raise AdapterError(reason)     # 旧入口无 RunResult 可携带，只能抛
        return self._run(self._build_args(), context, turn)

    def _run(self, command: list[str], context: str, turn: Turn) -> str:
        # 组装 prompt
        role_block = ""
        if self.role_prompt:
            role_block = f"你的角色身份：{self.role_prompt}\n\n"

        prompt = (
            f"{role_block}"
            f"你是一个参与多人技术讨论的 AI 助手，席位名为 {self.name}。\n"
            f"当前讨论记录在共享 Markdown 文件中，以下是完整对话历史：\n\n"
            f"{context}\n\n"
            f"—— 本轮你是第 {turn.order_index + 1} 个发言的 AI。\n"
            f"请发表你的看法。\n"
            f"**严格规则**：\n"
            f"- 只输出发言正文，不要加名字前缀或时间戳。\n"
            f"- 不要用 Markdown 代码块包裹你的发言。\n"
            f"- 不要编辑 chathub.md 文件——你处在只读沙盒中，写文件不会生效。\n"
            f"- 如果本轮无补充，输出单行 '无补充。'。\n"
            f"- 保持简洁。"
        )

        # Codex CLI 有时会因 prompt 过长而参数溢出 → 走 stdin
        timeout = self.config.get("cli_timeout", 80)  # 比 broker 超时略短

        # cwd=目标工作区（broker.Config 注入；未注入＝继承进程 cwd）——
        # codex read-only 沙盒的可读范围由 cwd 决定，指错目录＝席位看不到项目。
        ws = self.config.get("workspace")
        # prompt 从 stdin 传给 `codex exec -`，避免 Windows 8191 字符 argv 上限。
        try:
            proc = subprocess.run(
                command,
                input=prompt,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=str(ws) if ws else None,
                env=codex_subprocess_env(),
                # Codex CLI 需要 UTF-8；Windows 默认 GBK 会乱码
                encoding="utf-8",
                errors="replace",
            )
        except subprocess.TimeoutExpired as exc:
            raise AdapterError(f"Codex CLI 超时（>{timeout}s）") from exc
        except FileNotFoundError as exc:
            raise AdapterError(
                f"Codex CLI 未找到。请确认已安装：npm install -g @openai/codex\n"
                f"或确保 npx 在 PATH 中。原始错误：{exc}"
            ) from exc
        except Exception as exc:
            raise AdapterError(f"Codex CLI 启动失败：{exc}") from exc

        stdout = (proc.stdout or "").strip()
        stderr = (proc.stderr or "").strip()

        # 退出码非零 → 报错
        if proc.returncode != 0:
            detail = stderr[:500] if stderr else stdout[:500]
            raise AdapterError(
                f"Codex CLI 退出码 {proc.returncode}。stderr 摘要：{detail}"
            )

        # stdout 为空 → 可能是模型静默或输出到了 stderr
        if not stdout:
            raise AdapterError(
                f"Codex CLI stdout 为空。stderr 前 500 字：{stderr[:500] if stderr else '(空)'}"
            )

        # 防御：如果模型违规输出了带名字前缀的内容，尝试剥掉
        # （broker 会再统一盖，但这里做一道保险）
        return stdout


# ---- 独立自测（`python adapters/gpt.py --test`） ----
if __name__ == "__main__":
    if "--test" in sys.argv:
        adapter = GptAdapter("gpt", config={
            "codex_cmd": ["npx", "--yes", "@openai/codex", "exec", "--ephemeral", "--sandbox", "read-only"],
            "cli_timeout": 90,
        })
        test_context = (
            "Erico：测试消息，请 gpt 回复。\n"
            "只输出一行：'Codex CLI adapter 测试成功。' 不要名字前缀或解释。"
        )
        turn = Turn(round_index=0, speaker="gpt", order_index=1)
        try:
            reply = adapter.generate(test_context, turn)
            print(f"✅ GPT 通道测试成功。\n回复预览（前 200 字）：\n{reply[:200]}")
        except AdapterError as exc:
            print(f"❌ GPT 通道测试失败：{exc}")
        except Exception as exc:
            print(f"❌ 未预期错误：{exc}")
    else:
        print("用法：python adapters/gpt.py --test")
