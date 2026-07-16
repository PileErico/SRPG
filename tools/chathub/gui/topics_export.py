"""议题 ⇄ Markdown 镜像：导出（每条消息即时落盘）与解析（库空时恢复）。

背景：共享记忆早有 memory.md 镜像，议题却只活在 SQLite 里——两次 db 误删事故
（2026-07-16）议题全灭、记忆都救回来了。本模块补齐这个不对称：
每个议题一个 `topics/topic-<id>.md`，Store 写消息时同步刷新；server 启动时
若 topics 表为空而镜像存在 → 自动整体恢复（含消息、发言人、时间戳、状态）。

格式（restore-friendly，与 memory_export 同族）：
    # <标题>
    <!--meta id=3 status=concluded-->
    ### <speaker>｜<unix_ts>
    正文多行……直到下一个 ### 头
"""
from __future__ import annotations

import re
from pathlib import Path

_META_RE = re.compile(r"<!--meta id=(\d+) status=(\w+)-->")
# 消息头带 ⟦⟧ 括记——正文里常见的「### 标题｜数字」不会被误当消息边界
_MSG_RE = re.compile(r"^### ⟦(\S+)｜([\d.]+)⟧$")


def render(topic: dict, messages: list[dict]) -> str:
    lines = [
        f"# {topic.get('title', '未命名议题')}",
        f"<!--meta id={topic.get('id', 0)} status={topic.get('status', 'open')}-->",
        "",
    ]
    for m in messages:
        lines.append(f"### ⟦{m['speaker']}｜{m['created']}⟧")
        lines.append((m.get("body") or "").rstrip())
        lines.append("")
    return "\n".join(lines)


def parse(text: str) -> dict | None:
    """解析单个议题镜像 → {title, status, messages:[{speaker, created, body}]}；坏文件返回 None。"""
    lines = text.splitlines()
    if not lines or not lines[0].startswith("# "):
        return None
    title = lines[0][2:].strip()
    status = "open"
    for probe in lines[1:3]:
        m = _META_RE.search(probe)
        if m:
            status = m.group(2)
            break
    messages: list[dict] = []
    cur: dict | None = None
    body: list[str] = []

    def flush():
        nonlocal cur, body
        if cur is not None:
            cur["body"] = "\n".join(body).strip()
            if cur["body"]:
                messages.append(cur)
        cur, body = None, []

    for line in lines[1:]:
        m = _MSG_RE.match(line.strip())
        if m:
            flush()
            try:
                created = float(m.group(2))
            except ValueError:
                created = 0.0
            cur = {"speaker": m.group(1), "created": created}
            continue
        if cur is not None:
            body.append(line)
    flush()
    return {"title": title, "status": status, "messages": messages}


def mirror_path(mirror_dir: str | Path, tid: int) -> Path:
    return Path(mirror_dir) / f"topic-{tid}.md"
