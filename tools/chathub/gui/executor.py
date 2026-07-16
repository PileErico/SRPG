"""ChatHub 执行阶段：把授权后的方案交给带写权限的执行者落地。

- claude：`claude -p`（bypassPermissions，能改文件+跑 git/测试）
- gpt：`codex exec --sandbox workspace-write`（写限工作区、天然沙盒挡联网/越界）
- 每个执行者在**自己的分支**（claude / codex）工作、只提交自己的改动、不 push、不碰 main。
- copilot 不在此列（只评审，见 engine）。

git 细节交给执行者自己做（“怎么执行是他们的事”）；本模块只：读当前分支、
把任务喂给执行者子进程、结束后把工作区恢复到基线分支、给出分支 diffstat。
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]   # gui→chathub→tools→仓库根


def _resolve_cmd(cmd: list[str]) -> list[str]:
    resolved = list(cmd)
    if resolved:
        found = shutil.which(resolved[0])
        if not found and resolved[0].lower() in {"npx", "npx.cmd"}:
            for candidate in (
                Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "nodejs" / "npx.cmd",
                Path(os.environ.get("APPDATA", "")) / "npm" / "npx.cmd",
            ):
                if candidate.is_file():
                    found = str(candidate)
                    break
        if found:
            resolved[0] = found
    return resolved


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


def _git(*args: str, timeout: float = 30) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=REPO_ROOT, capture_output=True,
                          text=True, encoding="utf-8", errors="replace", timeout=timeout)


def current_branch() -> str:
    r = _git("rev-parse", "--abbrev-ref", "HEAD")
    return (r.stdout or "").strip() or "HEAD"


def restore_branch(base: str) -> str:
    """尽力把工作区切回基线分支；返回一句状态说明。"""
    r = _git("checkout", base)
    if r.returncode == 0:
        return f"已恢复到基线分支 {base}"
    return f"⚠ 恢复到 {base} 失败（可能有未提交改动）：{(r.stderr or '').strip()[-300:]}"


def branch_diffstat(branch: str, base: str) -> str:
    r = _git("diff", "--stat", f"{base}...{branch}")
    return (r.stdout or "").strip()


def branch_diff(branch: str, base: str, max_chars: int = 20_000) -> str:
    """分支相对基线的完整 diff（截断至 max_chars）——供互查/验收席阅读真实改动。"""
    r = _git("diff", f"{base}...{branch}", timeout=60)
    d = (r.stdout or "").strip()
    if len(d) > max_chars:
        total = len(d)
        d = d[:max_chars] + f"\n…［diff 已截断：全文 {total} 字，仅展示前 {max_chars} 字］"
    return d


def worktree_status() -> set[str]:
    """工作区 porcelain 状态快照（含未跟踪），供执行前后对比查执行者遗留。"""
    r = _git("status", "--porcelain")
    return {line for line in (r.stdout or "").splitlines() if line.strip()}


def new_dirt(baseline: set[str]) -> list[str]:
    """相对基线快照新出现的未提交条目（执行者遗留的脏改动）。"""
    return sorted(worktree_status() - baseline)


EXEC_PROMPT = """你是本项目的执行者（{seat}）。用户 Erico 已授权执行下面这个方案。你拥有本仓库的写权限。

务必遵守：
1. `git checkout -B {branch} {base}`（显式从 {base} 分叉——不要省略起点参数），只在 **{branch}** 分支上工作。
2. 按方案实现：改代码/数据，必要时跑 headless 测试（`tools/run_tests.ps1` 须 pwsh7）。
3. **只提交你自己改动的文件——显式 `git add <具体路径>`，严禁 `git add -A` / `git add .`**；提交信息写清改了什么。仓库里已存在的未提交文件（美术 WIP 等）一律别碰、别提交。
4. **不要 push、不要切到/提交到 main、不要装包、不要删目录、不要联网。**
5. 完成后 `git checkout {base}`。然后简要报告：你在 {branch} 分支改了哪些文件、跑了什么测试、结果如何、有无遗留问题。

【方案与议题上下文】
{context}

【Erico 的执行授权 / 范围】
{auth}
"""


def run_executor(seat: str, cmd: list[str], branch: str, base: str,
                 context: str, auth: str, timeout: float = 1200) -> dict:
    """启动一个执行者子进程，prompt 走 stdin。返回 {ok, report}。

    失败报告结构化（席位共识 2026-07-16）：标明失败阶段（spawn/运行/超时）、
    解析后的真实命令路径、退出码、stderr 末尾——「executor 坏了」和「席没干活」
    必须一眼可分。
    """
    prompt = EXEC_PROMPT.format(seat=seat, branch=branch, base=base, context=context, auth=auth)
    command = _resolve_cmd(cmd)
    try:
        proc = subprocess.run(command, input=prompt, cwd=REPO_ROOT, capture_output=True,
                              text=True, encoding="utf-8", errors="replace", timeout=timeout,
                              env=_executor_env(seat))
    except subprocess.TimeoutExpired:
        restore_branch(base)
        return {"ok": False, "report": (f"[{seat} 失败｜阶段=超时(>{timeout}s，子进程已 kill)｜"
                                        f"命令={command[0]}｜已尝试恢复到 {base}]")}
    except FileNotFoundError as exc:
        return {"ok": False, "report": f"[{seat} 失败｜阶段=spawn(找不到可执行文件)｜命令={command[0]}｜{exc}]"}
    except OSError as exc:
        return {"ok": False, "report": f"[{seat} 失败｜阶段=spawn(OS 拒绝启动)｜命令={command[0]}｜{exc}]"}
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    if proc.returncode == 0 and out:
        return {"ok": True, "report": out}
    tail = err[-600:] if err else "（stderr 为空）"
    return {"ok": False,
            "report": (f"[{seat} 失败｜阶段=运行返回｜命令={command[0]}｜退出码={proc.returncode}]\n"
                       f"{out}\nstderr 尾：{tail}").strip()}
