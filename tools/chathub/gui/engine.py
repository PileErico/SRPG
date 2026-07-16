"""ChatHub GUI 引擎层：复用现有 adapters，从 SQLite 组装 context 驱动讨论。

与命令行 broker 的区别：broker 的记忆＝chathub.md 整份文件；GUI 的记忆＝
「已确认的共享记忆 + 本议题的消息」，**不发别的议题的历史**——这正是治
「上下文膨胀/成本」的关键。适配器（claude -p / codex / deepseek）原样复用。
"""
from __future__ import annotations

import os
import shutil
import sys
import threading
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
CHATHUB = HERE.parent                      # tools/chathub
if str(CHATHUB) not in sys.path:
    sys.path.insert(0, str(CHATHUB))
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import broker                              # 复用 Config / load_adapter / call_with_timeout / extract_vote
from adapters.base import Turn             # noqa: E402
import executor as executor_mod           # noqa: E402  执行阶段（带写权限）

CTX_MSG_LIMIT = 40                          # 每次最多带本议题最近 N 条原文（防膨胀）
CTX_CHAR_BUDGET = 50_000                    # 总上下文字符硬上限（约束成本）
MEMORY_CHAR_BUDGET = 12_000                 # 共享记忆在总预算中的上限
SINGLE_MESSAGE_LIMIT = 8_000                 # 单条异常长消息也不能吞掉全部预算


class Engine:
    def __init__(self, store, config_path: Path | None = None):
        self.store = store
        cfg_path = Path(config_path or broker.DEFAULT_CONFIG)
        self.cfg = broker.Config.load(cfg_path)
        self.adapters = {n: broker.load_adapter(n, spec)
                         for n, spec in self.cfg.adapters.items()}
        # 执行阶段配置（execution:）——独立读原始 yaml，不改 broker.Config
        raw = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
        self.exec_cfg = raw.get("execution") or {}
        self._busy: set[int] = set()        # 正在跑的议题 id（防重复触发）
        self._busy_lock = threading.Lock()
        self._cancel: dict[int, threading.Event] = {}

    # ---- 状态 ----
    def seat_status(self) -> dict:
        out = {}
        for n in self.cfg.speaking_order:
            a = self.adapters.get(n)
            online, reason = a is not None, ""
            if a is None:
                reason = "适配器加载失败"
            elif n == "copilot":
                env_name = a.config.get("api_key_env", "DEEPSEEK_API_KEY")
                online = bool(os.environ.get(env_name))
                reason = "" if online else f"缺少环境变量 {env_name}"
            elif hasattr(a, "_resolve_cmd"):
                try:
                    cmd = a._resolve_cmd()[0]
                    online = Path(cmd).exists() or shutil.which(cmd) is not None
                    reason = "" if online else f"找不到命令：{cmd}"
                except Exception as exc:  # noqa: BLE001
                    online, reason = False, str(exc)
            out[n] = {"online": online, "reason": reason}
        return out

    def is_busy(self, tid: int) -> bool:
        with self._busy_lock:
            return tid in self._busy

    def reserve(self, tid: int) -> bool:
        """原子占用议题；HTTP 请求线程在启动后台任务前调用。"""
        with self._busy_lock:
            if tid in self._busy:
                return False
            self._busy.add(tid)
            self._cancel[tid] = threading.Event()
            return True

    def release(self, tid: int) -> None:
        with self._busy_lock:
            self._busy.discard(tid)
            self._cancel.pop(tid, None)

    def cancel(self, tid: int) -> bool:
        with self._busy_lock:
            event = self._cancel.get(tid)
            if event is None:
                return False
            event.set()
            return True

    def _cancelled(self, tid: int) -> bool:
        with self._busy_lock:
            event = self._cancel.get(tid)
            return bool(event and event.is_set())

    # ---- context 组装 ----
    def _memory_block(self) -> str:
        items = self.store.list_memory(status="approved")
        if not items:
            return ""
        lines = ["［共享记忆·已确认］"]
        used = len(lines[0])
        for it in items:
            src = f"（来源：{it['source']}）" if it.get("source") else ""
            line = f"- {it['content']}{src}"
            if used + len(line) > MEMORY_CHAR_BUDGET:
                lines.append("- ［其余已确认记忆因上下文预算省略］")
                break
            lines.append(line)
            used += len(line)
        return "\n".join(lines)

    def _context(self, topic: dict, instruction: str = "") -> str:
        parts: list[str] = []
        mem = self._memory_block()
        if mem:
            parts.append(mem)
        parts.append(f"［议题：{topic['title']}］")
        summary = self.store.get_topic_summary(topic["id"])
        if summary:
            parts.append(f"［本议题阶段摘要］\n{summary[:12_000]}")
        fixed_size = sum(len(p) for p in parts) + len(instruction)
        remaining = max(0, CTX_CHAR_BUDGET - fixed_size)
        selected: list[str] = []
        messages = self.store.get_messages(topic["id"], limit=CTX_MSG_LIMIT)
        for m in reversed(messages):
            line = f"{m['speaker']}：{m['body'][:SINGLE_MESSAGE_LIMIT]}"
            if len(line) > remaining:
                break
            selected.append(line)
            remaining -= len(line)
        parts.extend(reversed(selected))
        if instruction:
            parts.append(f"\n———［调度器指令］———\n{instruction}")
        return "\n".join(parts)

    def _call(self, name: str, context: str, round_index: int = 0) -> str:
        turn = Turn(round_index=round_index, speaker=name, order_index=0, prior_this_round=[])
        return broker.call_with_timeout(self.adapters[name], context, turn, self.cfg.timeout_for(name))

    # ---- 参与模式：各席一次 ----
    def run_participate(self, tid: int) -> None:
        topic = self.store.get_topic(tid)
        for name in self.cfg.speaking_order:
            if self._cancelled(tid):
                self.store.add_message(tid, "system", "［本轮已由用户停止］")
                break
            if self.adapters.get(name) is None:
                self.store.add_message(tid, name, "[跳过：适配器不可用]")
                continue
            try:
                body = self._call(name, self._context(topic))   # 每席重建 context→读到前席刚写的
                self.store.add_message(tid, name, body)
            except Exception as exc:  # noqa: BLE001
                self.store.add_message(tid, name, f"[跳过：{exc}]")

    # ---- 议题模式：自主多轮→收敛→结论→记忆草案 ----
    def run_topic(self, tid: int) -> None:
        topic = self.store.get_topic(tid)
        for r in range(self.cfg.auto_max_rounds):
            if self._cancelled(tid):
                self.store.add_message(tid, "system", "［议题讨论已由用户停止］")
                return
            votes: list[bool] = []
            instr = broker._auto_round_instruction(self.cfg, r)
            for name in self.cfg.speaking_order:
                if self._cancelled(tid):
                    self.store.add_message(tid, "system", "［议题讨论已由用户停止］")
                    return
                if self.adapters.get(name) is None:
                    continue
                try:
                    raw = self._call(name, self._context(topic, instr), r)
                    body, voted = broker.extract_vote(raw, self.cfg.converge_tag, self.cfg.continue_tag)
                    self.store.add_message(tid, name, body)
                    votes.append(voted)
                except Exception as exc:  # noqa: BLE001
                    self.store.add_message(tid, name, f"[跳过：{exc}]")
            if votes and all(votes):
                break

        synth = self.cfg.synthesizer
        if self.adapters.get(synth) is not None:
            instr = (
                "【结论综合】讨论已结束。请为 Erico 输出一段【结论】：1) 最终答案/方案；"
                "2) 仍存分歧/待定；3) 建议的下一步（若需执行，列出动作并标注哪些需 Erico 批准）。"
                "不要复述过程，直给结论。"
            )
            try:
                body = self._call(synth, self._context(topic, instr), 999)
                concl = body if body.startswith("【结论") else "【结论】" + body
                self.store.add_message(tid, synth, concl)
                self.store.set_topic_summary(tid, concl)
                # 结论→共享记忆「草案」，待 Erico 一键确认才生效（防错误结论污染）
                self.store.add_memory(concl, source=f"议题#{tid}/{synth}", status="draft")
            except Exception as exc:  # noqa: BLE001
                self.store.add_message(tid, synth, f"[结论失败：{exc}]")
        self.store.set_topic_status(tid, "concluded")

    # ---- 执行阶段：授权后由带写权限的执行者落地（claude/codex 各自分支）----
    def run_execute(self, tid: int, auth_text: str) -> None:
        topic = self.store.get_topic(tid)
        context = self._context(topic)
        execs = self.exec_cfg.get("executors") or []
        timeout = float(self.exec_cfg.get("timeout", 1200))
        base = executor_mod.current_branch()
        self.store.add_message(
            tid, "system",
            f"［执行已授权｜基线分支={base}｜依次执行：{', '.join(e.get('seat', '?') for e in execs)}｜"
            f"{self.exec_cfg.get('reviewer', 'copilot')} 仅评审｜不 push/不碰 main］")

        done: list[tuple[str, str]] = []
        for e in execs:
            if self._cancelled(tid):
                self.store.add_message(tid, "system", "［执行已由用户停止］")
                break
            seat, branch, cmd = e.get("seat"), e.get("branch"), e.get("cmd")
            if not (seat and branch and cmd):
                continue
            if self.adapters.get(seat) is None:
                self.store.add_message(tid, "system", f"［{seat} 通道不可用，跳过执行］")
                continue
            self.store.add_message(tid, seat, f"［开始执行 → {branch} 分支］")
            res = executor_mod.run_executor(seat, list(cmd), branch, base, context, auth_text, timeout)
            self.store.add_message(tid, seat, res["report"])
            done.append((seat, branch))

        note = executor_mod.restore_branch(base)
        lines = ["【执行记录】", note]
        for seat, branch in done:
            stat = executor_mod.branch_diffstat(branch, base) or "（无 diff 或分支未创建）"
            lines.append(f"— {seat} @ {branch} 分支：\n{stat}")
        self.store.add_message(tid, "system", "\n".join(lines))

        reviewer = self.exec_cfg.get("reviewer")
        if reviewer and self.adapters.get(reviewer) is not None and not self._cancelled(tid):
            instr = ("以上执行者分别在各自分支落地了方案。请你（评审席，不改代码）对比两版实现，"
                     "指出各自优劣、风险、遗漏，建议 Erico 采用哪版或如何合并。")
            try:
                body = self._call(reviewer, self._context(topic, instr), 0)
                self.store.add_message(tid, reviewer, body)
            except Exception as exc:  # noqa: BLE001
                self.store.add_message(tid, reviewer, f"[评审失败：{exc}]")
        self.store.set_topic_status(tid, "executed")

    # ---- 后台入口：按消息标记选模式 ----
    def dispatch(self, tid: int, user_text: str, *, reserved: bool = False) -> str:
        exec_marker = self.exec_cfg.get("marker", "【执行】")
        is_exec = bool(self.exec_cfg.get("executors")) and exec_marker in user_text
        auto = bool(self.cfg.auto_marker) and (self.cfg.auto_marker in user_text or "@自动" in user_text)
        if not reserved and not self.reserve(tid):
            raise RuntimeError("本议题正在讨论中")
        try:
            if is_exec:
                self.run_execute(tid, user_text)
                return "execute"
            if auto:
                self.run_topic(tid)
                return "auto"
            self.run_participate(tid)
        finally:
            self.release(tid)
        return "reactive"
