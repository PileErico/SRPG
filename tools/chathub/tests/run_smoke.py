"""ChatHub 冒烟测试（独立化改造）：py -3 tests/run_smoke.py

数据铁律 🔒：本文件**绝不触碰真库**——所有 Store/Engine/config 都建在 tempfile
临时目录里；也**绝不 import gui/server.py**（它在模块级就打开真库路径）。
覆盖：Config workspace 解析与注入 / Store 迁移+settings / executor 工作区校验 /
Engine 参与席过滤 / Engine 工作区切换 / dispatch 路由。
"""
from __future__ import annotations

import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHATHUB = HERE.parent
GUI = CHATHUB / "gui"
for p in (str(CHATHUB), str(GUI)):
    if p not in sys.path:
        sys.path.insert(0, p)

import broker                                  # noqa: E402
import executor as executor_mod                # noqa: E402
from engine import Engine                      # noqa: E402
from store import Store                        # noqa: E402

PASS = 0


def ok(cond: bool, msg: str) -> None:
    global PASS
    if not cond:
        raise AssertionError(f"FAIL: {msg}")
    PASS += 1
    print(f"  ✓ {msg}")


def make_git_repo(root: Path) -> Path:
    repo = root / "ws"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True, capture_output=True)
    return repo


def write_config(path: Path, workspace: str, seats: list[str],
                 default_participants: list[str] | None = None,
                 pinned: dict[str, str] | None = None,
                 executors_yaml: str = "  executors: []") -> None:
    pinned = pinned or {}
    seat_blocks = "\n".join(
        f'  {s}:\n    class: "stub:StubAdapter"'
        + (f'\n    workspace: "{pinned[s]}"' if s in pinned else "")
        for s in seats)
    dp = f"default_participants: [{', '.join(default_participants)}]\n" if default_participants else ""
    path.write_text(
        f'workspace: "{workspace}"\n'
        f"chathub_path: docs/chathub.md\n"
        f"trigger_names: [Erico]\n"
        f"speaking_order: [{', '.join(seats)}]\n"
        f"{dp}"
        f"default_timeout: 30\n"
        f"autonomous:\n  marker: \"【议题】\"\n  max_rounds: 2\n  synthesizer: {seats[-1]}\n"
        f"execution:\n  marker: \"【执行】\"\n{executors_yaml}\n"
        f"adapters:\n{seat_blocks}\n",
        encoding="utf-8")


def test_config(tmp: Path) -> None:
    print("— Config：workspace 解析/注入")
    ws = make_git_repo(tmp)
    cfg_path = tmp / "config.yaml"
    write_config(cfg_path, str(ws).replace("\\", "/"), ["a", "b"])
    cfg = broker.Config.load(cfg_path)
    ok(Path(cfg.workspace) == ws, "绝对 workspace 原样解析")
    ok(cfg.chathub_path == ws / "docs/chathub.md", "chathub_path 相对 workspace 解析")
    ok(all(spec.get("workspace") == str(ws) for spec in cfg.adapters.values()),
       "workspace 注入每席 adapter spec")
    # 相对 workspace：相对 config.yaml 所在目录
    write_config(cfg_path, "ws", ["a"])
    cfg2 = broker.Config.load(cfg_path)
    ok(Path(cfg2.workspace) == ws.resolve(), "相对 workspace 相对 config 目录解析")


def test_store(tmp: Path) -> None:
    print("— Store：迁移 + settings + workspace 戳")
    # 旧 schema 库（无 workspace 列/settings 表）→ Store() 应原地迁移不炸
    old_db = tmp / "old.db"
    c = sqlite3.connect(old_db)
    c.executescript(
        "CREATE TABLE topics(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,"
        " mode TEXT NOT NULL DEFAULT 'reactive', status TEXT NOT NULL DEFAULT 'open',"
        " created REAL NOT NULL);"
        "INSERT INTO topics(title,mode,status,created) VALUES('旧议题','reactive','open',1.0);")
    c.commit(); c.close()
    st = Store(old_db)
    rows = st.list_topics()
    ok(len(rows) == 1 and "workspace" in rows[0], "旧库迁移出 workspace 列且数据保留")
    ok(st.get_setting("workspace") is None, "settings 缺键返回 None")
    st.set_setting("workspace", "X:/foo")
    st.set_setting("workspace", "X:/bar")
    ok(st.get_setting("workspace") == "X:/bar", "settings 覆写生效")
    tid = st.create_topic("新议题", workspace="Y:/ws")
    ok(st.get_topic(tid)["workspace"] == "Y:/ws", "create_topic 盖 workspace 戳")


def test_executor(tmp: Path) -> None:
    print("— executor：工作区校验 + git 显式传参")
    ws = tmp / "ws"
    ok(executor_mod.workspace_error(None) is not None, "空工作区被拦")
    ok(executor_mod.workspace_error(tmp / "不存在") is not None, "不存在目录被拦")
    plain = tmp / "plain"; plain.mkdir()
    ok(executor_mod.workspace_error(plain) is not None, "非 git 目录被拦")
    ok(executor_mod.workspace_error(ws) is None, "git 仓库通过")
    br = executor_mod.current_branch(ws)
    ok(isinstance(br, str) and br, f"current_branch 在指定工作区可用（{br}）")


def test_engine(tmp: Path) -> None:
    print("— Engine：参与席过滤 / 工作区切换 / dispatch 路由")
    ws = tmp / "ws"
    cfg_path = tmp / "config.yaml"
    write_config(cfg_path, str(ws).replace("\\", "/"), ["a", "b", "c"],
                 default_participants=["a", "c"])
    db = tmp / "engine.db"
    st = Store(db)
    eng = Engine(st, config_path=cfg_path)
    ok(str(eng.workspace) == str(ws), "engine 初始工作区＝config.workspace")
    ok(eng.cfg.default_participants == ["a", "c"], "default_participants 载入")

    tid = st.create_topic("过滤测试")
    eng.reserve(tid)
    try:
        eng.run_participate(tid, participants=["c", "a"])   # 无序名单
    finally:
        eng.release(tid)
    speakers = [m["speaker"] for m in st.get_messages(tid)]
    ok(speakers == ["a", "c"], f"参与过滤且顺序归 speaking_order（{speakers}）")

    tid2 = st.create_topic("空名单")
    eng.reserve(tid2)
    try:
        eng.run_participate(tid2, participants=[])
    finally:
        eng.release(tid2)
    msgs2 = st.get_messages(tid2)
    ok(len(msgs2) == 1 and msgs2[0]["speaker"] == "system" and "没有勾选" in msgs2[0]["body"],
       "空参与名单→system 取消消息")

    tid3 = st.create_topic("全员")
    eng.reserve(tid3)
    try:
        eng.run_participate(tid3, participants=None)
    finally:
        eng.release(tid3)
    ok([m["speaker"] for m in st.get_messages(tid3)] == ["a", "b", "c"], "None＝全员")

    # 工作区切换：合法→持久化；非法→ValueError；忙时→RuntimeError
    second = tmp / "second"
    second.mkdir(exist_ok=True)
    ws2 = make_git_repo(second)
    try:
        eng.set_workspace(str(tmp / "plain"))
        ok(False, "非 git 目录切换应报错")
    except ValueError:
        ok(True, "非 git 目录切换 ValueError")
    eng.set_workspace(str(ws2))
    ok(str(eng.workspace) == str(ws2.resolve()), "切换生效")
    ok(st.get_setting("workspace") == str(ws2.resolve()), "切换持久化到 settings")
    ok(all(a.config.get("workspace") == str(ws2.resolve())
           for a in eng.adapters.values() if a), "切换同步到各席 adapter cwd")
    eng.reserve(998)
    try:
        eng.set_workspace(str(ws))
        ok(False, "忙时切换应报错")
    except RuntimeError:
        ok(True, "忙时切换 RuntimeError")
    finally:
        eng.release(998)

    # 重启延续：新 Engine 应读 settings 里的选择而非 config
    eng2 = Engine(st, config_path=cfg_path)
    ok(str(eng2.workspace) == str(ws2.resolve()), "重启后延续上次工作区选择")

    # dispatch 路由（reactive）
    tid4 = st.create_topic("路由")
    mode = eng.dispatch(tid4, "普通消息", participants=["b"])
    ok(mode == "reactive" and [m["speaker"] for m in st.get_messages(tid4)] == ["b"],
       "dispatch 透传 participants")


def test_review_fixes(tmp: Path) -> None:
    print("— 审查修复：按席钉死 / 议题工作区戳比对 / 镜像 workspace 往返")
    import topics_export

    ws = tmp / "ws"
    pin_dir = tmp / "pin"
    pin_dir.mkdir(exist_ok=True)
    cfg_path = tmp / "config_pin.yaml"
    write_config(cfg_path, str(ws).replace("\\", "/"), ["a", "b"],
                 pinned={"b": str(pin_dir).replace("\\", "/")},
                 executors_yaml=('  executors:\n    - seat: a\n      branch: wb\n'
                                 '      cmd: ["cmd", "/c", "echo", "x"]'))
    st = Store(tmp / "review.db")
    eng = Engine(st, config_path=cfg_path)
    ok(eng.adapters["b"].config["workspace"] == str(pin_dir).replace("\\", "/"),
       "启动不覆盖按席钉死的 workspace")
    second = tmp / "second" / "ws"
    eng.set_workspace(str(second))
    ok(eng.adapters["a"].config["workspace"] == str(second.resolve()), "未钉席随全局切换")
    ok(eng.adapters["b"].config["workspace"] == str(pin_dir).replace("\\", "/"),
       "切换仍不覆盖钉死席")

    # 议题工作区戳比对：戳≠当前 → 拒绝执行；戳为空（旧议题）→ 放行到后续流程
    tid = st.create_topic("错位议题", workspace=str(ws))
    eng.reserve(tid)
    try:
        eng.run_execute(tid, "【执行】干活", only_seats=["a"])
    finally:
        eng.release(tid)
    msgs = [m["body"] for m in st.get_messages(tid)]
    ok(any("执行拒绝：本议题创建于工作区" in b for b in msgs), "工作区戳错位→拒绝执行")

    tid2 = st.create_topic("无戳旧议题")   # workspace=None
    eng.reserve(tid2)
    try:
        eng.run_execute(tid2, "【执行】干活", only_seats=["a"])
    finally:
        eng.release(tid2)
    msgs2 = [m["body"] for m in st.get_messages(tid2)]
    ok(not any("执行拒绝：本议题创建于工作区" in b for b in msgs2), "无戳旧议题不因戳被拒")

    # 镜像 workspace 往返：render→parse→import_topic 不丢戳；旧格式（无戳）兼容
    topic = st.get_topic(tid)
    text = topics_export.render(topic, st.get_messages(tid))
    data = topics_export.parse(text)
    ok(data["workspace"] == str(ws), "镜像 render/parse 带回 workspace")
    rid = st.import_topic(data["title"], data["status"], data["messages"],
                          workspace=data.get("workspace"))
    ok(st.get_topic(rid)["workspace"] == str(ws), "import_topic 恢复 workspace 戳")
    old = topics_export.parse("# 旧题\n<!--meta id=1 status=open-->\n\n### ⟦Erico｜1.0⟧\n嗨\n")
    ok(old is not None and old["workspace"] is None and old["messages"], "旧格式镜像（无戳）兼容")


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="chathub_smoke_"))
    try:
        test_config(tmp)          # 创建 tmp/ws（git 仓库），后续测试复用
        test_store(tmp)
        test_executor(tmp)
        test_engine(tmp)          # 创建 tmp/second/ws（git 仓库）
        test_review_fixes(tmp)
        print(f"\n全部通过：{PASS} 项")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
