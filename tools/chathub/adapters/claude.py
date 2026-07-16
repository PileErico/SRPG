"""Claude 席位适配器：封装 `claude -p`（Claude Code CLI 非交互模式）。

前置：独立 CLI 已装并登录（`npm i -g @anthropic-ai/claude-code`；
`claude auth status` 显示 max 订阅）——走订阅、不计 API token。

关键实现点（都踩过坑）：
- **prompt 走 stdin，不走 argv**：chathub 全文常 >15KB，Windows 命令行上限
  ~8191 字符，塞 argv 必炸；`claude -p` 从 stdin 读 prompt 天然规避。
- **subprocess 强制 UTF-8**：Windows 默认 GBK 会把中文输出/输入弄乱。
- **自带 subprocess timeout**：broker 的线程超时杀不掉子进程，此处才是真超时。
- **stdout=发言正文，stderr 丢弃**：进度/警告在 stderr。
- **默认权限模式不改**：`-p` 非交互下无法批准编辑，天然不会动文件；如需更严，
  在 config.yaml 该席位段设 `permission_mode`（勿设 bypassPermissions）。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

# 允许 `python adapters/claude.py --test` 直接跑（把 tools/chathub 挂上 path）
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from adapters.base import Adapter, AdapterError, Turn  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]        # adapters→chathub→tools→仓库根

DEFAULT_ROLE = (
    "你是一场多 AI 设计讨论中的参与者，代号 claude，正在与 gpt、copilot 及用户 "
    "Erico 于 docs/chathub.md 协作。规则：只输出你本轮的发言正文——不要加"
    "「claude：」前缀、不要加时间戳、不要写任何文件、不要复述整段历史。可以引用"
    "项目文件里的事实。若无补充就回一句「无补充。」。"
)

DEFAULT_ASK = (
    "\n\n———\n以上是 chathub.md 全文。请针对最后一条尚未回应的发言，发表你（claude）"
    "本轮的观点。只输出发言正文。"
)


class ClaudeAdapter(Adapter):
    def _resolve_cmd(self) -> list[str]:
        """定位 claude 可执行文件；config.claude_cmd 优先。"""
        cmd = self.config.get("claude_cmd")
        if cmd:
            return list(cmd)
        found = shutil.which("claude")
        if found:
            return [found]
        # PATH 未刷新时的兜底：用户级 npm 全局目录
        for cand in (
            Path(os.environ.get("APPDATA", "")) / "npm" / "claude.cmd",
            Path(os.environ.get("APPDATA", "")) / "npm" / "claude",
        ):
            if cand.exists():
                return [str(cand)]
        return ["claude"]  # 交给系统解析，失败会在 run 时抛错

    def _build_args(self) -> list[str]:
        args = self._resolve_cmd() + ["-p", "--output-format", "text"]
        role = self.config.get("role_prompt", DEFAULT_ROLE)
        if role:
            args += ["--append-system-prompt", role]
        if self.config.get("model"):
            args += ["--model", str(self.config["model"])]
        if self.config.get("permission_mode"):
            args += ["--permission-mode", str(self.config["permission_mode"])]
        return args

    def generate(self, context: str, turn: Turn) -> str:
        args = self._build_args()
        prompt = context + self.config.get("ask", DEFAULT_ASK)
        timeout = float(self.config.get("timeout", 140))
        try:
            proc = subprocess.run(
                args,
                input=prompt,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                cwd=str(REPO_ROOT),          # 让 claude 能引用项目文件（只读）
            )
        except FileNotFoundError as exc:
            raise AdapterError(f"找不到 claude 可执行文件：{args[0]}（先装 CLI）") from exc
        except subprocess.TimeoutExpired as exc:
            raise AdapterError(f"claude -p 超时（>{timeout}s）") from exc

        if proc.returncode != 0:
            tail = (proc.stderr or "").strip().splitlines()[-3:]
            raise AdapterError(f"claude -p 退出码 {proc.returncode}：{' / '.join(tail)}")
        body = (proc.stdout or "").strip()
        if not body:
            raise AdapterError("claude -p 返回空发言")
        return body


# ------------------------------ 独立自测 ------------------------------------
if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="ClaudeAdapter 自测")
    ap.add_argument("--test", action="store_true", help="真实调一次 claude -p")
    ap.add_argument("--plumbing", action="store_true",
                    help="用 echo 假命令验证 stdin/stdout 管道，不花 claude 调用")
    args = ap.parse_args()

    if args.plumbing:
        # 把 claude_cmd 换成打印 stdin 的假命令，验证 argv 组装/管道/编码
        import platform
        fake = (["cmd", "/c", "more"] if platform.system() == "Windows"
                else ["cat"])
        a = ClaudeAdapter("claude", {"claude_cmd": fake, "role_prompt": "", "ask": ""})
        # 直接调底层，避免 --output-format 等 claude 专属 flag 干扰 echo
        out = subprocess.run(fake, input="管道自测：你好 claude。", capture_output=True,
                             text=True, encoding="utf-8", errors="replace").stdout
        print("plumbing stdout:", out.strip())
    elif args.test:
        a = ClaudeAdapter("claude", {})
        print("=== 真实 claude -p 输出 ===")
        print(a.generate("Erico：请用一句话打个招呼，证明通道可用。", Turn(0, "claude", 0, [])))
    else:
        ap.print_help()
