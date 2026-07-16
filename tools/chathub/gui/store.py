"""ChatHub GUI 存储层：SQLite。

替代「一坨 chathub.md」——每个议题独立存消息、共享记忆分 draft/approved。
表：topics（议题/模式/状态）、messages（每席发言）、memory_items（共享记忆＋审核态）。
低并发单用户，每次操作开一条新连接（线程安全够用）。
"""
from __future__ import annotations

import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS topics(
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  title   TEXT NOT NULL,
  mode    TEXT NOT NULL DEFAULT 'reactive',   -- reactive|auto（创建时可留 auto 由消息标记决定）
  status  TEXT NOT NULL DEFAULT 'open',        -- open|concluded
  created REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS messages(
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  topic_id INTEGER NOT NULL,
  speaker  TEXT NOT NULL,                       -- Erico|claude|gpt|copilot
  body     TEXT NOT NULL,
  created  REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS memory_items(
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  content TEXT NOT NULL,
  source  TEXT,                                 -- 来自哪个议题/第几轮/谁（可追溯）
  status  TEXT NOT NULL DEFAULT 'draft',        -- draft|approved|rejected
  created REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS topic_summaries(
  topic_id INTEGER PRIMARY KEY,
  content  TEXT NOT NULL,
  updated  REAL NOT NULL,
  FOREIGN KEY(topic_id) REFERENCES topics(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_msg_topic ON messages(topic_id, id);
"""


class Store:
    def __init__(self, path: str | Path):
        self.path = str(path)
        with self._conn() as c:
            c.executescript(SCHEMA)

    @contextmanager
    def _conn(self):
        c = sqlite3.connect(self.path)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA foreign_keys=ON")
        try:
            yield c
            c.commit()
        except Exception:
            c.rollback()
            raise
        finally:
            c.close()

    # ---- topics ----
    def create_topic(self, title: str, mode: str = "reactive") -> int:
        with self._conn() as c:
            cur = c.execute(
                "INSERT INTO topics(title,mode,status,created) VALUES(?,?,?,?)",
                (title, mode, "open", time.time()),
            )
            return int(cur.lastrowid)

    def list_topics(self) -> list[dict]:
        with self._conn() as c:
            return [dict(r) for r in c.execute("SELECT * FROM topics ORDER BY created DESC")]

    def get_topic(self, tid: int) -> dict | None:
        with self._conn() as c:
            r = c.execute("SELECT * FROM topics WHERE id=?", (tid,)).fetchone()
            return dict(r) if r else None

    def set_topic_status(self, tid: int, status: str) -> None:
        with self._conn() as c:
            c.execute("UPDATE topics SET status=? WHERE id=?", (status, tid))

    def set_topic_summary(self, tid: int, content: str) -> None:
        with self._conn() as c:
            c.execute(
                "INSERT INTO topic_summaries(topic_id,content,updated) VALUES(?,?,?) "
                "ON CONFLICT(topic_id) DO UPDATE SET content=excluded.content,updated=excluded.updated",
                (tid, content, time.time()),
            )

    def get_topic_summary(self, tid: int) -> str:
        with self._conn() as c:
            r = c.execute("SELECT content FROM topic_summaries WHERE topic_id=?", (tid,)).fetchone()
            return str(r["content"]) if r else ""

    # ---- messages ----
    def add_message(self, tid: int, speaker: str, body: str) -> int:
        with self._conn() as c:
            cur = c.execute(
                "INSERT INTO messages(topic_id,speaker,body,created) VALUES(?,?,?,?)",
                (tid, speaker, body, time.time()),
            )
            return int(cur.lastrowid)

    def get_messages(self, tid: int, limit: int | None = None) -> list[dict]:
        with self._conn() as c:
            rows = [dict(r) for r in c.execute(
                "SELECT * FROM messages WHERE topic_id=? ORDER BY id", (tid,))]
        return rows[-limit:] if limit else rows

    # ---- shared memory ----
    def add_memory(self, content: str, source: str = "", status: str = "draft") -> int:
        with self._conn() as c:
            cur = c.execute(
                "INSERT INTO memory_items(content,source,status,created) VALUES(?,?,?,?)",
                (content, source, status, time.time()),
            )
            return int(cur.lastrowid)

    def list_memory(self, status: str | None = None) -> list[dict]:
        q = "SELECT * FROM memory_items"
        args: tuple = ()
        if status:
            q += " WHERE status=?"
            args = (status,)
        q += " ORDER BY created DESC"
        with self._conn() as c:
            return [dict(r) for r in c.execute(q, args)]

    def set_memory_status(self, mid: int, status: str) -> None:
        if status not in {"draft", "approved", "rejected"}:
            raise ValueError(f"非法记忆状态：{status}")
        with self._conn() as c:
            c.execute("UPDATE memory_items SET status=? WHERE id=?", (status, mid))
