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

DB = Path(os.environ.get("CHATHUB_DB", str(HERE / "chathub.db")))
STATIC = HERE / "static"
PORT = 8765

store = Store(DB)
engine = Engine(store)
app = Flask(__name__, static_folder=None)


@app.get("/")
def index():
    return send_from_directory(STATIC, "index.html")


@app.get("/api/status")
def api_status():
    return jsonify(engine.seat_status())


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
    if not engine.reserve(tid):
        return jsonify({"error": "本议题正在讨论中，请稍候"}), 409
    try:
        store.set_topic_status(tid, "open")
        store.add_message(tid, "Erico", text)
    except Exception:
        engine.release(tid)
        raise
    auto = bool(engine.cfg.auto_marker) and (engine.cfg.auto_marker in text or "@自动" in text)
    try:
        threading.Thread(
            target=engine.dispatch, args=(tid, text), kwargs={"reserved": True}, daemon=True
        ).start()
    except Exception:
        engine.release(tid)
        raise
    return jsonify({"ok": True, "mode": "auto" if auto else "reactive"})


@app.post("/api/topics/<int:tid>/stop")
def api_stop(tid: int):
    if store.get_topic(tid) is None:
        return jsonify({"error": "议题不存在"}), 404
    if not engine.cancel(tid):
        return jsonify({"error": "本议题当前没有运行中的讨论"}), 409
    return jsonify({"ok": True, "message": "已请求停止；当前席返回后生效"})


@app.get("/api/memory")
def api_memory():
    return jsonify(store.list_memory())


@app.post("/api/memory/<int:mid>/approve")
def api_mem_approve(mid: int):
    store.set_memory_status(mid, "approved")
    return jsonify({"ok": True})


@app.post("/api/memory/<int:mid>/reject")
def api_mem_reject(mid: int):
    store.set_memory_status(mid, "rejected")
    return jsonify({"ok": True})


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    st = engine.seat_status()
    print(f"ChatHub GUI 启动：http://127.0.0.1:{PORT}")
    print("三席状态：" + " | ".join(f"{k}={'在线' if v['online'] else '离线'}" for k, v in st.items()))
    # 启动器（bat）会自己开浏览器；设了 CHATHUB_NO_AUTO_OPEN 就不重复弹
    if not os.environ.get("CHATHUB_NO_AUTO_OPEN"):
        threading.Timer(1.0, lambda: webbrowser.open(f"http://127.0.0.1:{PORT}")).start()
    app.run(host="127.0.0.1", port=PORT, threaded=True)


if __name__ == "__main__":
    main()
