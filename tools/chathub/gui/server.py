"""ChatHub GUI 后端：Flask + SQLite，复用现有 adapters。

启动：py -3 gui/server.py  → 自动开浏览器 http://127.0.0.1:8765
只监听 127.0.0.1，不暴露局域网。发送后台跑一轮，前端轮询消息。

API：
  GET  /                          → 前端页面
  GET  /api/status                → 各席在线状态（讨论席+执行席）
  GET  /api/config                → 调度配置（席位/标记/执行名单/工作区+可用性）
  POST /api/workspace {path}      → 切换目标工作区（校验 git 仓库；忙时 409）
  GET  /api/capabilities          → 各席自报的 model/effort 能力 + 当前值
  POST /api/seats/<seat>/options  → 改某席 model/effort（进程内生效；非法值 400）
  GET  /api/topics                → 议题列表
  POST /api/topics {title,mode}   → 新建议题（盖当前工作区戳）→ {id}
  GET  /api/topics/<id>/messages  → 该议题消息（+busy 标记）
  POST /api/topics/<id>/send {text, participants?, executors?} → 追加 Erico 消息并后台跑一轮 → {mode}
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
import topics_export             # noqa: E402  议题的可读备份镜像（恢复用）

DB = Path(os.environ.get("CHATHUB_DB", str(HERE / "chathub.db")))
STATIC = HERE / "static"
PORT = int(os.environ.get("CHATHUB_PORT", "8765"))   # 环境变量可改（自测起备用实例用）

# 双实例护栏（审查发现·major）：改了端口却没改库＝备用实例直接读写真库，且
# Engine 的执行互斥是进程内锁——两个进程可对同一 git 工作区并发执行，互相踩踏。
if PORT != 8765 and "CHATHUB_DB" not in os.environ:
    sys.stderr.write(
        "✗ 设了 CHATHUB_PORT 却没设 CHATHUB_DB：备用实例会读写真库，并与主实例并发踩踏工作区。\n"
        "  请同时设置 CHATHUB_DB=<临时库路径> 再启动。\n")
    sys.exit(1)

MEM_MD = HERE / "memory.md"       # 共享记忆的人类可读持久备份（非 gitignore，可提交）
BACKUP_DIR = HERE / "backups"     # db 启动快照（gitignore；2026-07-16 数据事故后加）
BACKUP_KEEP = 10
_last_mem_md: str | None = None


_last_backup_ts = 0.0
BACKUP_INTERVAL = 600            # 运行时快照最小间隔（秒）


def _backup_db(throttled: bool = False) -> None:
    """给 chathub.db 拍快照（轮换保留最近 N 份）——误删/损坏时可整库找回。

    启动时必拍；运行时经 /api/memory 轮询触发、按 BACKUP_INTERVAL 节流
    ——只在启动拍的教训：服务器不重启就永远没有快照（2026-07-16 第二次事故）。
    """
    global _last_backup_ts
    import time as _time
    try:
        if throttled and _time.time() - _last_backup_ts < BACKUP_INTERVAL:
            return
        if not DB.exists() or DB.stat().st_size == 0:
            return
        import shutil
        from datetime import datetime
        BACKUP_DIR.mkdir(exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(DB, BACKUP_DIR / f"chathub-{stamp}.db")
        _last_backup_ts = _time.time()
        olds = sorted(BACKUP_DIR.glob("chathub-*.db"))
        for p in olds[:-BACKUP_KEEP]:
            p.unlink()
    except Exception as exc:  # 备份失败不阻塞主流程，但要喊出来
        print(f"⚠ db 快照失败：{exc}")


# 快照必须在 Store(DB) 之前拍：Store.__init__ 会跑 schema 迁移（ALTER 等），
# 迁移若有损，事故不能发生在「本轮快照」的覆盖范围之外（审查发现）。
_backup_db()

store = Store(DB)
engine = Engine(store)
app = Flask(__name__, static_folder=None)


def _restore_topics_if_empty() -> None:
    """topics 表为空而镜像目录有货 → 整体恢复议题（含消息/发言人/时间戳/状态）。"""
    try:
        if store.list_topics():
            return
        mirrors = sorted(store.mirror_dir.glob("topic-*.md")) if store.mirror_dir.exists() else []
        restored = 0
        for p in mirrors:
            data = topics_export.parse(p.read_text(encoding="utf-8"))
            if data and data["messages"]:
                store.import_topic(data["title"], data["status"], data["messages"],
                                   workspace=data.get("workspace"))
                restored += 1
        if restored:
            print(f"♻ 已从议题镜像恢复 {restored} 个议题（库此前为空）")
    except Exception as exc:
        print(f"⚠ 议题自动恢复失败：{exc}")


def _restore_memory_if_empty() -> None:
    """库里记忆为空而 memory.md 有条目 → 自动导回（库被重置后的自愈）。"""
    try:
        if store.list_memory():
            return
        if not MEM_MD.exists():
            return
        items = memory_export.parse(MEM_MD.read_text(encoding="utf-8"))
        for it in items:
            store.add_memory(it["content"], source=it.get("source", ""),
                             status=it.get("status", "draft"))
        if items:
            print(f"♻ 已从 memory.md 恢复 {len(items)} 条共享记忆（库此前为空）")
    except Exception as exc:
        print(f"⚠ 记忆自动恢复失败：{exc}")


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
    """前端所需的调度配置：模式标记、席位名单、执行名单候选、验收/参考席、工作区。"""
    ws, ws_err = engine.workspace_status()
    return jsonify({
        "seats": engine.cfg.speaking_order,
        "default_participants": engine.cfg.default_participants,
        "topic_marker": engine.cfg.auto_marker,
        "exec_marker": engine.exec_cfg.get("marker", "【执行】"),
        "executors": [{"seat": e.get("seat"), "branch": e.get("branch")}
                      for e in (engine.exec_cfg.get("executors") or [])],
        "acceptor": engine.exec_cfg.get("acceptor"),
        "reviewer": engine.exec_cfg.get("reviewer"),
        "spec_reviewer": engine.exec_cfg.get("spec_reviewer"),
        "synthesizer": engine.cfg.synthesizer,
        "workspace": ws,
        "workspace_error": ws_err,        # None＝可用
    })


@app.post("/api/workspace")
def api_workspace():
    """切换目标工作区（校验 git 仓库；忙时 409）。选择持久化，重启后延续。"""
    d = request.get_json(force=True, silent=True) or {}
    path = (d.get("path") or "").strip()
    if not path:
        return jsonify({"error": "缺 path"}), 400
    try:
        p = engine.set_workspace(path)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    except RuntimeError as exc:
        return jsonify({"error": str(exc)}), 409
    return jsonify({"ok": True, "workspace": str(p)})


@app.get("/api/capabilities")
def api_capabilities():
    """各席自报的 model/effort 能力 + 当前生效值（前端据此渲染，不硬编码灰掉）。"""
    return jsonify(engine.seat_capabilities())


@app.post("/api/seats/<seat>/options")
def api_seat_options(seat: str):
    """改某席的 model / effort（进程内生效）。非法值 400 明确报错，绝不静默。"""
    d = request.get_json(force=True, silent=True) or {}
    changed = {}
    try:
        for key in ("model", "effort"):
            if key in d:
                engine.set_seat_option(seat, key, str(d.get(key) or ""))
                changed[key] = d.get(key) or ""
    except KeyError as exc:
        return jsonify({"error": str(exc)}), 404
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    if not changed:
        return jsonify({"error": "没给任何可改的键（model / effort）"}), 400
    return jsonify({"ok": True, "changed": changed})


@app.get("/api/topics")
def api_topics():
    return jsonify(store.list_topics())


@app.post("/api/topics")
def api_new_topic():
    d = request.get_json(force=True, silent=True) or {}
    tid = store.create_topic((d.get("title") or "未命名议题").strip(), d.get("mode", "reactive"),
                             workspace=str(engine.workspace))
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
    # 执行名单（可选）：GUI 勾选的执行者，如 ["opus"]——只让这些席执行
    exec_seats = d.get("executors")
    if exec_seats is not None and not (
            isinstance(exec_seats, list) and all(isinstance(s, str) for s in exec_seats)):
        return jsonify({"error": "executors 须为席位名字符串数组"}), 400
    # 参与名单（可选）：GUI 勾选的讨论席，如 ["gpt","fable"]——None＝全员（脚本直连兼容）
    participants = d.get("participants")
    if participants is not None and not (
            isinstance(participants, list) and all(isinstance(s, str) for s in participants)):
        return jsonify({"error": "participants 须为席位名字符串数组"}), 400
    # 标记语义=「以标记开头」（与 engine.dispatch/前端一致）——先判模式，再入库
    exec_marker = engine.exec_cfg.get("marker", "【执行】")
    t = text.lstrip()
    if engine.exec_cfg.get("executors") and t.startswith(exec_marker):
        mode = "execute"
    elif bool(engine.cfg.auto_marker) and (t.startswith(engine.cfg.auto_marker) or t.startswith("@自动")):
        mode = "auto"
    else:
        mode = "reactive"
    # 执行必须带明确的非空名单——防「绕过前端确认（脚本直连/config 竞态）→全员带写权限开跑」
    if mode == "execute" and not exec_seats:
        return jsonify({"error": "执行需要明确执行名单：请在界面的执行模式下勾选执行者"}), 400
    if not engine.reserve(tid):
        return jsonify({"error": "本议题正在讨论中，请稍候"}), 409
    try:
        store.set_topic_status(tid, "open")
        store.add_message(tid, "Erico", text)
    except Exception:
        engine.release(tid)
        raise
    try:
        threading.Thread(
            target=engine.dispatch, args=(tid, text),
            kwargs={"reserved": True, "exec_seats": exec_seats,
                    "participants": participants}, daemon=True,
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
    _backup_db(throttled=True)   # 运行时快照（每 10 分钟至多一次）
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


# ---- 浏览器心跳看门狗：页面关了 → 服务器自动退（治「黑窗叠罗汉」的根）----
IDLE_EXIT = 180          # 有过连接后，无任何请求 N 秒 → 退出（容浏览器后台限流心跳）
FIRST_GRACE = 600        # 启动后从未有浏览器连上过的宽限（手动开浏览器可能慢）
BYE_DELAY = 12           # 收到关页信号后再等 N 秒（页面刷新也会发 bye，须给复连机会）
import time as _time
_last_request = _time.time()
_seen_any = False
_bye_at: float | None = None


@app.before_request
def _heartbeat():
    global _last_request, _seen_any, _bye_at
    _last_request = _time.time()
    _seen_any = True
    _bye_at = None          # 任何请求都取消待决的告别（刷新/多标签场景）


@app.post("/api/bye")
def api_bye():
    """页面 pagehide 时 sendBeacon 打来的告别——短暂等待后若无人复连则退出。"""
    global _bye_at
    _bye_at = _time.time()
    return jsonify({"ok": True})


def _exit_reason(now: float) -> str | None:
    """看门狗决策（纯函数便于测试）：返回退出原因或 None。"""
    if engine.any_busy():
        return None                      # 讨论/执行进行中，绝不自杀
    if _bye_at is not None and now - _bye_at > BYE_DELAY:
        return "浏览器已关闭（收到告别信号且无人复连）"
    limit = IDLE_EXIT if _seen_any else FIRST_GRACE
    if now - _last_request > limit:
        return f"超过 {limit}s 无浏览器心跳"
    return None


def _watchdog():
    while True:
        _time.sleep(5)
        reason = _exit_reason(_time.time())
        if reason and not os.environ.get("CHATHUB_NO_AUTO_EXIT"):
            print(f"⏹ {reason}，服务器自动退出。")
            os._exit(0)


def _port_in_use() -> bool:
    """探测 8765 是否已有 ChatHub 在应答——Windows 允许多进程同绑端口，
    不显式挡会静默叠罗汉：新进程活着但老进程应答，用户看到旧配置（2026-07-16 实况）。"""
    import socket
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=1.5):
            return True
    except OSError:
        return False


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    if _port_in_use():
        print(f"✗ 端口 {PORT} 已被占用——另一个 ChatHub 还开着！")
        print("  请找到那个黑色窗口关掉（或任务管理器结束 python），再重新双击启动。")
        print("  旧实例用的是旧配置：不关掉它，你看到的永远是旧席位/旧功能。")
        sys.exit(1)
    _backup_db(throttled=True)  # 首拍已在模块导入时（Store 迁移之前）完成，这里只是节流补拍
    _restore_memory_if_empty()  # 库空而 memory.md 有货 → 自动恢复记忆
    _restore_topics_if_empty()  # 议题表空而镜像有货 → 自动恢复议题
    _sync_memory()              # 再导出一次，保证 memory.md 与库一致
    st = engine.seat_status()
    ws, ws_err = engine.workspace_status()
    print(f"ChatHub GUI 启动：http://127.0.0.1:{PORT}")
    print(f"工作区：{ws}" + (f"（⚠ {ws_err}）" if ws_err else ""))
    print("席位状态：" + " | ".join(f"{k}={'在线' if v['online'] else '离线'}" for k, v in st.items()))
    # 启动器（bat）会自己开浏览器；设了 CHATHUB_NO_AUTO_OPEN 就不重复弹
    if not os.environ.get("CHATHUB_NO_AUTO_OPEN"):
        threading.Timer(1.0, lambda: webbrowser.open(f"http://127.0.0.1:{PORT}")).start()
    threading.Thread(target=_watchdog, daemon=True).start()   # 浏览器关了→自动退
    print("（页面关闭后服务器会自动退出；执行进行中不会自杀。设 CHATHUB_NO_AUTO_EXIT=1 关闭此行为）")
    app.run(host="127.0.0.1", port=PORT, threaded=True)


if __name__ == "__main__":
    main()
