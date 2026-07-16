"""ChatHub 执行阶段：把授权后的方案交给带写权限的执行者落地。

- claude：`claude -p`（bypassPermissions，能改文件+跑 git/测试）
- gpt：`codex exec --sandbox workspace-write`（写限工作区、天然沙盒挡联网/越界）
- 每个执行者在**自己的分支**（opus / codex）工作、只提交自己的改动、不 push、不碰 main。
- deepseek 席不在此列（只评审，见 engine）——**能发言 ≠ 能执行**，两回事。
- **审计**：spawn 前用 build_invocation() 从解析后的实际 argv 抽白名单事实，由 engine 写成
  system 消息入库；完整命令行只留在失败路径的排障文本里，不入库。

git 细节交给执行者自己做（“怎么执行是他们的事”）；本模块只：读当前分支、
把任务喂给执行者子进程、结束后把工作区恢复到基线分支、给出分支 diffstat。

**工作区显式传参 🔒（2026-07-16 独立化）**：chathub 已搬出目标仓库，本模块不再
假设「工具上溯三层＝仓库根」——所有 git 操作与执行者子进程都要显式收 `ws`
（目标工作区路径），由 engine 从「config.workspace / GUI 切换」解析后传入。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

CHATHUB = Path(__file__).resolve().parents[1]     # chathub 工具根（仅供 import）
if str(CHATHUB) not in sys.path:
    sys.path.insert(0, str(CHATHUB))

from adapters.base import Invocation             # noqa: E402  与 adapter 路径共用同一元数据形状


def _resolve_cmd(cmd: list[str]) -> list[str]:
    """解析可执行文件；shutil.which 找不到时按 npm 全局目录兜底（npx/claude 通用——
    审查发现原先只兜 npx，导致 opus 席讨论在线、执行 spawn 必败的自相矛盾）。"""
    resolved = list(cmd)
    if not resolved:
        return resolved
    found = shutil.which(resolved[0])
    if not found:
        base = resolved[0].lower()
        base = base[:-4] if base.endswith(".cmd") else base
        for candidate in (
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "nodejs" / f"{base}.cmd",
            Path(os.environ.get("APPDATA", "")) / "npm" / f"{base}.cmd",
        ):
            if candidate.is_file():
                found = str(candidate)
                break
    if found:
        resolved[0] = found
    return resolved


def _flag_value(argv: list[str], *flags: str) -> str | None:
    """取 `--flag value` 形式的值（只认白名单里点名的 flag）。"""
    for i, tok in enumerate(argv[:-1]):
        if tok in flags:
            return argv[i + 1]
    return None


def build_invocation(cmd: list[str]) -> Invocation:
    """从**解析后的实际 argv** 抽白名单事实——与 adapter 路径同构 🔒。

    只取标量（可执行文件/模型/effort/注入状态）：prompt 走 stdin 本就不在 argv 里，
    但完整 argv 一律不留——新参数（token/路径/系统提示词）默认不入库，
    「今天没敏感内容」是黑名单思维，白名单反着写才安全。
    """
    argv = _resolve_cmd(cmd)
    model = _flag_value(argv, "--model", "-m")
    effort = _flag_value(argv, "--effort")
    if effort is None:                      # Codex 无 --effort，走 `-c model_reasoning_effort=<值>`
        for i, tok in enumerate(argv[:-1]):
            if tok == "-c" and argv[i + 1].startswith("model_reasoning_effort="):
                effort = argv[i + 1].split("=", 1)[1]
                break
    return Invocation(
        executable=argv[0] if argv else "",
        requested_model=model,
        reported_model=None,                # 子进程无回读通道 → 恒 unverified
        effort=effort,
        model_injected=model is not None,
        effort_injected=effort is not None,
    )


def format_audit(seat: str, branch: str, inv: Invocation) -> str:
    """执行审计消息正文——Popen **之前**构造，成功/失败/超时三路径共享同一证据。"""
    def _mark(value: str | None, injected: bool) -> str:
        if not value:
            return "—（未注入）"
        return f"{value}（注入✓）" if injected else f"{value}（⚠ 未注入）"
    return (f"［执行审计｜{seat} → {branch} 分支｜executable={inv.executable}｜"
            f"model={_mark(inv.requested_model, inv.model_injected)}｜"
            f"effort={_mark(inv.effort, inv.effort_injected)}｜unverified（子进程无回读通道）］")


def _kill_tree(proc: subprocess.Popen) -> None:
    """杀整棵进程树——Windows 上 TerminateProcess 只杀 .cmd 外壳，node 里的
    codex/claude 会活着继续改文件（审查确认的真事故路径），须 taskkill /T /F。"""
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                           capture_output=True, timeout=15)
        else:
            proc.kill()
    except Exception:
        pass


def _executor_env(seat: str) -> dict[str, str]:
    env = os.environ.copy()
    if seat == "gpt":
        # Store 版 pwsh 位于 WindowsApps；Codex workspace-write 沙箱以受限令牌
        # CreateProcessAsUserW 启动它会报 Windows error 5/1920。移除后 Codex
        # 自动回退到 System32 的 Windows PowerShell，可正常执行仓库命令。
        path_key = next((k for k in env if k.lower() == "path"), "Path")
        env[path_key] = os.pathsep.join(
            p for p in env.get(path_key, "").split(os.pathsep)
            if p and "windowsapps" not in p.lower()
        )
    return env


def _git(ws: str | Path, *args: str, timeout: float = 30) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=str(ws), capture_output=True,
                          text=True, encoding="utf-8", errors="replace", timeout=timeout)


def workspace_error(ws: str | Path | None) -> str | None:
    """工作区可用性校验：返回原因串（不可用）或 None（可用）。

    可用 ＝ 目录存在且是 git 工作树。校验失败要明确报错而非静默——
    执行阶段在错误目录跑 checkout 是全链路腐坏，不是小事。
    """
    if not ws:
        return "未配置工作区（config.yaml 的 workspace 键）"
    p = Path(ws)
    if not p.is_dir():
        return f"目录不存在：{p}"
    try:
        r = _git(p, "rev-parse", "--is-inside-work-tree", timeout=10)
    except Exception as exc:  # noqa: BLE001  git 不在 PATH 等
        return f"无法运行 git：{exc}"
    if r.returncode != 0 or (r.stdout or "").strip() != "true":
        return f"不是 git 仓库：{p}"
    return None


def current_branch(ws: str | Path) -> str:
    r = _git(ws, "rev-parse", "--abbrev-ref", "HEAD")
    return (r.stdout or "").strip() or "HEAD"


def branch_tip(ws: str | Path, branch: str) -> str | None:
    """分支 tip 哈希；分支不存在返回 None。用于判定「本轮是否真的更新了分支」，
    防止上一轮遗留的同名分支 diff 被当成本轮产出送审（审查发现#2）。"""
    r = _git(ws, "rev-parse", "--verify", "--quiet", branch)
    tip = (r.stdout or "").strip()
    return tip if r.returncode == 0 and tip else None


def restore_branch(ws: str | Path, base: str) -> str:
    """尽力把工作区切回基线分支；返回一句状态说明。"""
    r = _git(ws, "checkout", base)
    if r.returncode == 0:
        return f"已恢复到基线分支 {base}"
    return f"⚠ 恢复到 {base} 失败（可能有未提交改动）：{(r.stderr or '').strip()[-300:]}"


def branch_diffstat(ws: str | Path, branch: str, base: str) -> str:
    r = _git(ws, "diff", "--stat", f"{base}...{branch}")
    return (r.stdout or "").strip()


def branch_diff(ws: str | Path, branch: str, base: str, max_chars: int = 20_000) -> str:
    """分支相对基线的完整 diff（截断至 max_chars）——供互查/验收席阅读真实改动。"""
    r = _git(ws, "diff", f"{base}...{branch}", timeout=60)
    d = (r.stdout or "").strip()
    if len(d) > max_chars:
        total = len(d)
        d = d[:max_chars] + f"\n…［diff 已截断：全文 {total} 字，仅展示前 {max_chars} 字］"
    return d


def worktree_status(ws: str | Path) -> set[str]:
    """工作区 porcelain 状态快照（含未跟踪），供执行前后对比查执行者遗留。"""
    r = _git(ws, "status", "--porcelain")
    return {line for line in (r.stdout or "").splitlines() if line.strip()}


def new_dirt(ws: str | Path, baseline: set[str]) -> list[str]:
    """相对基线快照新出现的未提交条目（执行者遗留的脏改动）。"""
    return sorted(worktree_status(ws) - baseline)


EXEC_PROMPT = """你是本项目的执行者（{seat}）。用户 Erico 已授权执行下面这个方案。你拥有工作区仓库（{ws}）的写权限。

务必遵守：
1. `git checkout -B {branch} {base}`（显式从 {base} 分叉——不要省略起点参数），只在 **{branch}** 分支上工作。
2. **忠实按方案落实**：方案含糊或与代码现状冲突时，选保守解读并在报告中明确写出你的解读与取舍——不要自作主张扩大范围。必要时跑项目自带的测试（以仓库文档说明的测试方式为准）。
3. **只提交你自己改动的文件——显式 `git add <具体路径>`，严禁 `git add -A` / `git add .`**；提交信息写清改了什么。仓库里已存在的未提交文件（美术 WIP 等）一律别碰、别提交。
4. **不要 push、不要切到/提交到 main、不要装包、不要删目录、不要联网。**
5. 完成后 `git checkout {base}`。然后简要报告：你在 {branch} 分支改了哪些文件、跑了什么测试、结果如何、有无遗留问题。

【方案与议题上下文】
{context}

【Erico 的执行授权 / 范围】
{auth}
"""


def run_executor(seat: str, cmd: list[str], branch: str, base: str,
                 context: str, auth: str, ws: str | Path,
                 timeout: float = 1200) -> dict:
    """启动一个执行者子进程，prompt 走 stdin。返回 {ok, report}。

    失败报告结构化（席位共识 2026-07-16）：标明失败阶段（spawn/运行/超时）、
    解析后的真实命令路径、退出码、stderr 末尾——「executor 坏了」和「席没干活」
    必须一眼可分。
    """
    prompt = EXEC_PROMPT.format(seat=seat, branch=branch, base=base, ws=ws,
                                context=context, auth=auth)
    command = _resolve_cmd(cmd)
    try:
        proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, cwd=str(ws), text=True,
                                encoding="utf-8", errors="replace", env=_executor_env(seat))
    except FileNotFoundError as exc:
        return {"ok": False, "report": f"[{seat} 失败｜阶段=spawn(找不到可执行文件)｜命令={command[0]}｜{exc}]"}
    except OSError as exc:
        return {"ok": False, "report": f"[{seat} 失败｜阶段=spawn(OS 拒绝启动)｜命令={command[0]}｜{exc}]"}
    try:
        out, err = proc.communicate(input=prompt, timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_tree(proc)                    # 杀整棵树，不留继续写文件的僵尸
        try:
            proc.communicate(timeout=15)
        except Exception:
            pass
        restore_branch(ws, base)
        return {"ok": False, "report": (f"[{seat} 失败｜阶段=超时(>{timeout}s，已 taskkill 进程树)｜"
                                        f"命令={command[0]}｜已尝试恢复到 {base}]")}
    out = (out or "").strip()
    err = (err or "").strip()
    if proc.returncode == 0 and out:
        return {"ok": True, "report": out}
    tail = err[-600:] if err else "（stderr 为空）"
    return {"ok": False,
            "report": (f"[{seat} 失败｜阶段=运行返回｜命令={command[0]}｜退出码={proc.returncode}]\n"
                       f"{out}\nstderr 尾：{tail}").strip()}
