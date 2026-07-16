"""共享记忆 ⇄ Markdown 镜像：导出（备份）与解析（恢复）。

目的：SQLite（chathub.db）是二进制且被 gitignore——库一旦重置/损坏，记忆就没了。
本模块把记忆导出成 `memory.md`（可读、可提交进 git），并支持从该文件**恢复**：
server 启动时若发现库里记忆为空而 memory.md 有货，自动导回（2026-07-16 数据事故后加）。

格式约定（restore-friendly）：每条记忆一个 `### #<id>｜<status>｜来源：<source>` 标题，
正文原样多行直到下一个标题/分节。内容不含时间戳——记忆没变化文件就不变。
"""
from __future__ import annotations

import re
from pathlib import Path

_ITEM_RE = re.compile(r"^### #(\d+)｜(approved|draft)｜来源：(.*)$")


def render(items: list[dict]) -> str:
    approved = [i for i in items if i.get("status") == "approved"]
    drafts = [i for i in items if i.get("status") == "draft"]
    lines = [
        "# ChatHub 共享记忆（自动导出的可读备份）",
        "",
        "> 这是 gui/chathub.db 里共享记忆的镜像。库若重置/损坏，server 启动时会从本文件自动恢复。",
        "> 正常改动请在 ChatHub 界面里「确认/弃置」——手工编辑本文件不会写回数据库。",
        "",
    ]

    def block(title: str, arr: list[dict]) -> list[str]:
        out = [f"## {title}（{len(arr)}）", ""]
        if not arr:
            out += ["_（暂无）_", ""]
            return out
        for i in arr:
            status = i.get("status", "draft")
            out.append(f"### #{i.get('id', 0)}｜{status}｜来源：{(i.get('source') or '').strip()}")
            out.append("")
            out.append((i.get("content") or "").strip())
            out.append("")
        return out

    lines += block("已确认 approved", approved)
    lines += block("草案 draft（待确认）", drafts)
    return "\n".join(lines)


def parse(text: str) -> list[dict]:
    """从 render() 产出的 memory.md 解析记忆条目（用于库空时恢复）。

    返回 [{content, source, status}]；解析不到就返回空列表（宁可不恢复也不恢复错）。
    """
    items: list[dict] = []
    cur: dict | None = None
    body: list[str] = []

    def flush():
        nonlocal cur, body
        if cur is not None:
            content = "\n".join(body).strip()
            if content:
                items.append({"content": content, "source": cur["source"], "status": cur["status"]})
        cur, body = None, []

    for line in text.splitlines():
        m = _ITEM_RE.match(line.strip())
        if m:
            flush()
            cur = {"status": m.group(2), "source": m.group(3).strip()}
            continue
        if line.startswith("## "):      # 分节标题结束上一条
            flush()
            continue
        if cur is not None:
            body.append(line)
    flush()
    return items


def export(items: list[dict], path: str | Path) -> None:
    Path(path).write_text(render(items), encoding="utf-8")
