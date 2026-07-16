"""GPT adapter —— 通过 Codex CLI 非交互模式调用 ChatGPT（Plus 订阅）。

配置段（config.yaml 的 gpt 席）：
    codex_cmd: ["npx", "--yes", "@openai/codex", "exec", "--ephemeral", "--sandbox", "read-only"]
    role_prompt: |           # 可选·角色约束

通道特性（🔒 经验证）：
- `npx @openai/codex exec --ephemeral --sandbox read-only` 走 ChatGPT 登录
- 不消耗 OpenAI API token（只走 Plus 订阅用量）
- stdout = 发言正文；stderr = 进度/模型信息/警告（须丢弃）
- 冷启动约 10~15s；模型为 gpt-5.6-sol（当前版本）
"""
from __future__ import annotations

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

from adapters.base import Adapter, AdapterError, Turn

REPO_ROOT = Path(__file__).resolve().parents[3]  # adapters→chathub→tools→仓库根


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
        if found:
            cmd[0] = found
        return cmd

    def generate(self, context: str, turn: Turn) -> str:
        # 组装 prompt
        role_block = ""
        if self.role_prompt:
            role_block = f"你的角色身份：{self.role_prompt}\n\n"

        prompt = (
            f"{role_block}"
            f"你是一个参与多人技术讨论的 AI 助手，席位名为 gpt。\n"
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

        # prompt 从 stdin 传给 `codex exec -`，避免 Windows 8191 字符 argv 上限。
        command = self._resolve_cmd() + ["-"]
        try:
            proc = subprocess.run(
                command,
                input=prompt,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=str(REPO_ROOT),
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
