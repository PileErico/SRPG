"""把 SQLite 里的共享记忆镜像成一个人类可读的 Markdown 文件。

目的：SQLite（chathub.db）是二进制且被 gitignore——库一旦重置/损坏，记忆就没了。
本模块把记忆导出成 `memory.md`（可读、可提交进 git、可手工查看），当作**持久备份**。
内容**不含时间戳**，这样只有记忆真的变化时文件才变（便于「变了才写」省 I/O，也利于 git diff）。
"""
from __future__ import annotations

from pathlib import Path


def render(items: list[dict]) -> str:
    approved = [i for i in items if i.get("status") == "approved"]
    drafts = [i for i in items if i.get("status") == "draft"]
    lines = [
        "# ChatHub 共享记忆（自动导出的可读备份）",
        "",
        "> 这是 gui/chathub.db 里共享记忆的镜像。库若重置/损坏，用它找回。",
        "> 正常改动请在 ChatHub 界面里「确认/弃置」——手工编辑本文件不会写回数据库。",
        "",
    ]

    def block(title: str, arr: list[dict]) -> list[str]:
        out = [f"## {title}（{len(arr)}）", ""]
        if not arr:
            out += ["_（暂无）_", ""]
            return out
        for i in arr:
            src = f"  \n  <sub>来源：{i['source']}</sub>" if i.get("source") else ""
            body = (i.get("content") or "").strip()
            out.append(f"- {body}{src}")
        out.append("")
        return out

    lines += block("已确认 approved", approved)
    lines += block("草案 draft（待确认）", drafts)
    return "\n".join(lines)


def export(items: list[dict], path: str | Path) -> None:
    Path(path).write_text(render(items), encoding="utf-8")
