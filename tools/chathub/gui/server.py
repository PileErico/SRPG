"""ChatHub GUI 后端：Flask + SQLite，复用现有 adapters。

启动：py -3 gui/server.py  → 自动开浏览器 http://127.0.0.1:8765
只监听 127.0.0.1，不暴露局域网。发送后台跑一轮，前端轮询消息。

API：
  GET  /                          → 前端页面
  GET  /api/status                → 三席在线状态
  GET  /api/topics                → 议题列表
  POST /api/topics {title,mode}   → 新建议题 → {id}
  GET  /api/topics/<id>/messages  → 该议题消息（+busy 标记）
  POST /api/topics/<id>/send {text} → 追加 Erico 消息并后台跑一轮 → {mode}
  POST /api/topics/<id>/stop       → 请求在当前席结束后停止
  GET  /api/memory                → 共享记忆（draft/approved/rejected）
  POST /api/memory/<id>/approve   → 确认记忆
  POST /api/memory/<id>/reject    → 弃置记忆
"""
from __future__ import annotations

import os
import sys
import threading
import webbrowser
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

try:
    from flask import Flask, jsonify, request, send_from_directory
except ImportError:
    sys.stderr.write("需要 flask：py -3 -m pip install -r tools/chathub/requirements.txt\n")
    raise

from store import Store          # noqa: E402
from engine import Engine        # noqa: E402
import memory_export             # noqa: E402  共享记忆的可读备份镜像

DB = Path(os.environ.get("CHATHUB_DB", str(HERE / "chathub.db")))
STATIC = HERE / "static"
PORT = 8765

store = Store(DB)
engine = Engine(store)
app = Flask(__name__, static_folder=None)

MEM_MD = HERE / "memory.md"       # 共享记忆的人类可读持久备份（非 gitignore，可提交）
_last_mem_md: str | None = None


def _sync_memory() -> None:
    """把当前共享记忆镜像到 memory.md；内容变了才写盘（省 I/O，利于 git diff）。"""
    global _last_mem_md
    try:
        content = memory_export.render(store.list_memory())
        if content != _last_mem_md:
            MEM_MD.write_text(content, encoding="utf-8")
            _last_mem_md = content
    except Exception:
        pass  # 备份失败不影响主流程


@app.get("/")
def index():
    return send_from_directory(STATIC, "index.html")


@app.get("/api/status")
def api_status():
    return jsonify(engine.seat_status())


@app.get("/api/config")
def api_config():
    """前端所需的调度配置：模式标记、执行名单候选、验收/参考席。"""
    return jsonify({
        "seats": engine.cfg.speaking_order,
        "topic_marker": engine.cfg.auto_marker,
        "exec_marker": engine.exec_cfg.get("marker", "【执行】"),
        "executors": [{"seat": e.get("seat"), "branch": e.get("branch")}
                      for e in (engine.exec_cfg.get("executors") or [])],
        "acceptor": engine.exec_cfg.get("acceptor"),
        "reviewer": engine.exec_cfg.get("reviewer"),
    })


@app.get("/api/topics")
def api_topics():
    return jsonify(store.list_topics())


@app.post("/api/topics")
def api_new_topic():
    d = request.get_json(force=True, silent=True) or {}
    tid = store.create_topic((d.get("title") or "未命名议题").strip(), d.get("mode", "reactive"))
    return jsonify({"id": tid})


@app.get("/api/topics/<int:tid>/messages")
def api_messages(tid: int):
    if store.get_topic(tid) is None:
        return jsonify({"error": "议题不存在"}), 404
    return jsonify({"busy": engine.is_busy(tid), "messages": store.get_messages(tid)})


@app.post("/api/topics/<int:tid>/send")
def api_send(tid: int):
    if store.get_topic(tid) is None:
        return jsonify({"error": "议题不存在"}), 404
    d = request.get_json(force=True, silent=True) or {}
    text = (d.get("text") or "").strip()
    if not text:
        return jsonify({"error": "空消息"}), 400
    # 执行名单（可选）：GUI 勾选的执行者，如 ["gpt"]——只让这些席执行
    exec_seats = d.get("executors")
    if exec_seats is not None and not (
            isinstance(exec_seats, list) and all(isinstance(s, str) for s in exec_seats)):
        return jsonify({"error": "executors 须为席位名字符串数组"}), 400
    if not engine.reserve(tid):
        return jsonify({"error": "本议题正在讨论中，请稍候"}), 409
    try:
        store.set_topic_status(tid, "open")
        store.add_message(tid, "Erico", text)
    except Exception:
        engine.release(tid)
        raise
    exec_marker = engine.exec_cfg.get("marker", "【执行】")
    if engine.exec_cfg.get("executors") and exec_marker in text:
        mode = "execute"
    elif bool(engine.cfg.auto_marker) and (engine.cfg.auto_marker in text or "@自动" in text):
        mode = "auto"
    else:
        mode = "reactive"
    try:
        threading.Thread(
            target=engine.dispatch, args=(tid, text),
            kwargs={"reserved": True, "exec_seats": exec_seats}, daemon=True,
        ).start()
    except Exception:
        engine.release(tid)
        raise
    return jsonify({"ok": True, "mode": mode})


@app.post("/api/topics/<int:tid>/stop")
def api_stop(tid: int):
    if store.get_topic(tid) is None:
        return jsonify({"error": "议题不存在"}), 404
    if not engine.cancel(tid):
        return jsonify({"error": "本议题当前没有运行中的讨论"}), 409
    return jsonify({"ok": True, "message": "已请求停止；当前席返回后生效"})


@app.get("/api/memory")
def api_memory():
    _sync_memory()          # 前端每几秒轮询一次→memory.md 始终跟手（含新草案）
    return jsonify(store.list_memory())


@app.post("/api/memory/<int:mid>/approve")
def api_mem_approve(mid: int):
    store.set_memory_status(mid, "approved")
    _sync_memory()
    return jsonify({"ok": True})


@app.post("/api/memory/<int:mid>/reject")
def api_mem_reject(mid: int):
    store.set_memory_status(mid, "rejected")
    _sync_memory()
    return jsonify({"ok": True})


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    _sync_memory()          # 启动即导出一次，保证 memory.md 与库一致
    st = engine.seat_status()
    print(f"ChatHub GUI 启动：http://127.0.0.1:{PORT}")
    print("三席状态：" + " | ".join(f"{k}={'在线' if v['online'] else '离线'}" for k, v in st.items()))
    # 启动器（bat）会自己开浏览器；设了 CHATHUB_NO_AUTO_OPEN 就不重复弹
    if not os.environ.get("CHATHUB_NO_AUTO_OPEN"):
        threading.Timer(1.0, lambda: webbrowser.open(f"http://127.0.0.1:{PORT}")).start()
    app.run(host="127.0.0.1", port=PORT, threaded=True)


if __name__ == "__main__":
    main()
