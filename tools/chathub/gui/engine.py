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
from adapters.base import RunResult, Turn  # noqa: E402
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
        # 执行工作区互斥：busy 按议题隔离，但所有执行共享同一 git 工作区——
        # 两个议题同时进执行阶段会互相 checkout 踩踏（审查发现#1），全局串行化
        self._exec_lock = threading.Lock()

    # ---- 状态 ----
    def seat_status(self) -> dict:
        """按适配器类型（非席位名）做前置检查：HTTP 席查 key、CLI 席查可执行文件。"""
        out = {}
        for n in self.cfg.speaking_order:
            a = self.adapters.get(n)
            online, reason = a is not None, ""
            if a is None:
                reason = "适配器加载失败"
            elif a.config.get("api_key_env"):            # HTTP 型（deepseek 等）
                env_name = a.config["api_key_env"]
                online = bool(os.environ.get(env_name))
                reason = "" if online else f"缺少环境变量 {env_name}"
            elif hasattr(a, "_resolve_cmd"):             # CLI 型（claude/codex）
                try:
                    cmd = a._resolve_cmd()[0]
                    online = Path(cmd).exists() or shutil.which(cmd) is not None
                    reason = "" if online else f"找不到命令：{cmd}"
                except Exception as exc:  # noqa: BLE001
                    online, reason = False, str(exc)
            out[n] = {"online": online, "reason": reason}
        return out

    def seat_capabilities(self) -> dict:
        """各席自报能力 + 当前生效值——前端据此渲染控件，**不硬编码谁支持什么**。

        capabilities() 是实例方法、返回静态 dict（探测＝施工期取证），此处不产生
        任何模型调用。
        """
        out: dict[str, dict] = {}
        for n in self.cfg.speaking_order:
            a = self.adapters.get(n)
            if a is None:
                continue
            caps = a.capabilities()
            out[n] = {
                "model": caps.get("model") or {},
                "effort": caps.get("effort") or {},
                "current": {"model": a.config.get("model") or "",
                            "effort": a.config.get("effort") or ""},
            }
        return out

    def set_seat_option(self, seat: str, key: str, value: str) -> None:
        """改某席的 model / effort（进程内生效，不写回 config.yaml）。

        非法值**明确报错**、绝不静默：claude CLI 遇非法 effort 是「stderr 警告 +
        静默降默认档 + 退出码 0」（2026-07-16 实测）——不在入口拦，用户会以为
        设了 effort，其实一直跑默认档，正是落款要防的那种悬案。
        """
        a = self.adapters.get(seat)
        if a is None:
            raise KeyError(f"席位 {seat} 不存在或适配器不可用")
        if key not in ("model", "effort"):
            raise ValueError(f"只支持 model / effort，收到 {key!r}")
        caps = a.capabilities().get(key) or {}
        value = (value or "").strip()
        if key == "effort":
            if not caps.get("supported"):
                raise ValueError(f"{seat} 席不支持 effort 轴")
            if value and value not in (caps.get("values") or []):
                raise ValueError(f"{seat} 席的 effort 只接受 {'/'.join(caps.get('values') or [])}")
        elif not caps.get("free_input", True) and value and value not in (caps.get("suggestions") or []):
            raise ValueError(f"{seat} 席的 model 只接受 {'/'.join(caps.get('suggestions') or [])}")
        # 单键赋值＝原子；空串＝回落到「不注入该参数」
        if value:
            a.config[key] = value
        else:
            a.config.pop(key, None)

    def is_busy(self, tid: int) -> bool:
        with self._busy_lock:
            return tid in self._busy

    def any_busy(self) -> bool:
        """有任何议题在讨论/执行中——自动退出看门狗须避让。"""
        with self._busy_lock:
            return bool(self._busy)

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

    def _call(self, name: str, context: str, round_index: int = 0) -> RunResult:
        """调一席，返回 RunResult（正文＋元数据）。元数据随返回值走，不进共享状态。"""
        turn = Turn(round_index=round_index, speaker=name, order_index=0, prior_this_round=[])
        return broker.call_with_timeout(self.adapters[name], context, turn, self.cfg.timeout_for(name))

    def _signed(self, run: RunResult, body: str | None = None) -> str:
        """正文（默认取 run.content）+ 落款。body 显式传入＝已剥标记/已加前缀的清洁正文。"""
        return broker.with_signature(run.content if body is None else body, run.meta)

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
                run = self._call(name, self._context(topic))    # 每席重建 context→读到前席刚写的
                self.store.add_message(tid, name, self._signed(run))
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
            ruled = False
            instr = broker._auto_round_instruction(self.cfg, r)
            for i, name in enumerate(self.cfg.speaking_order):
                if self._cancelled(tid):
                    self.store.add_message(tid, "system", "［议题讨论已由用户停止］")
                    return
                if self.adapters.get(name) is None:
                    continue
                try:
                    # 拍板授权说明只发给 arbiter；与 CLI 共用 broker 的同一套函数，
                    # 提示词/剥标记/留痕措辞都不分叉（GUI 与 CLI 一致靠共用实现，不靠两处对齐）
                    seat_instr = broker.with_arbiter_clause(self.cfg, instr, name)
                    run = self._call(name, self._context(topic, seat_instr), r)
                    raw = run.content
                    if name == self.cfg.arbiter:      # 拍板只认 arbiter，别席写了就是普通文本
                        raw, ruled = broker.extract_verdict(raw, self.cfg.verdict_tag)
                    # 先剥标记再盖落款：反过来落款会变成末行，收敛票永远统计不到
                    body, voted = broker.extract_vote(raw, self.cfg.converge_tag,
                                                      self.cfg.continue_tag)
                    self.store.add_message(tid, name, self._signed(run, body))
                    votes.append(voted)
                except Exception as exc:  # noqa: BLE001
                    self.store.add_message(tid, name, f"[跳过：{exc}]")
                if ruled:
                    skipped = [n for n in self.cfg.speaking_order[i + 1:]
                               if self.adapters.get(n) is not None]
                    self.store.add_message(tid, "system", broker.verdict_notice(self.cfg, skipped))
                    break
            # 拍板＝arbiter 单方收口（不看票数），但结论综合照常走
            if ruled or (votes and all(votes)):
                break

        synth = self.cfg.synthesizer
        if self.adapters.get(synth) is not None:
            instr = (
                "【结论综合】讨论已结束。请为 Erico 输出一段【结论】：1) 最终答案/方案；"
                "2) 仍存分歧/待定；3) 建议的下一步（若需执行，列出动作并标注哪些需 Erico 批准）。"
                "不要复述过程，直给结论。"
            )
            try:
                run = self._call(synth, self._context(topic, instr), 999)
                body = run.content
                concl = body if body.startswith("【结论") else "【结论】" + body
                self.store.add_message(tid, synth, self._signed(run, concl))
                self.store.set_topic_summary(tid, concl)   # 摘要/记忆草案存清洁正文，不带落款
                # 结论→共享记忆「草案」，待 Erico 一键确认才生效（防错误结论污染）
                self.store.add_memory(concl, source=f"议题#{tid}/{synth}", status="draft")
            except Exception as exc:  # noqa: BLE001
                self.store.add_message(tid, synth, f"[结论失败：{exc}]")
        self.store.set_topic_status(tid, "concluded")

    # ---- 执行阶段：授权后由带写权限的执行者落地（opus/codex 各自分支）----
    # 流水：执行者顺序落地（可点名名单）→ 交叉互查（执行者互审对方真实 diff）
    #       → deepseek 参考意见（无文件访问，只评记录）→ fable 终验收（看全部 diff+互查）
    def run_execute(self, tid: int, auth_text: str,
                    only_seats: list[str] | None = None) -> None:
        topic = self.store.get_topic(tid)
        context = self._context(topic)
        all_execs = self.exec_cfg.get("executors") or []
        # 空名单=取消（[] 曾被当「不过滤」反向放行全员——审查发现#6）；None=不过滤
        if only_seats is not None and not only_seats:
            self.store.add_message(tid, "system", "［执行取消：执行名单为空——没有勾选任何执行者］")
            return
        execs = [e for e in all_execs
                 if only_seats is None or e.get("seat") in only_seats]
        if not execs:
            self.store.add_message(
                tid, "system",
                f"［执行取消：名单 {only_seats} 与配置的执行者 "
                f"{[e.get('seat') for e in all_execs]} 无交集］")
            return
        # 基线校验（审查发现#5）：detached HEAD 或基线撞执行分支名 → 全链路静默腐坏，拒绝执行
        base = executor_mod.current_branch()
        exec_branches = {e.get("branch") for e in all_execs}
        if base == "HEAD" or base in exec_branches:
            self.store.add_message(
                tid, "system",
                f"［执行拒绝：当前基线分支异常（{base}）——可能处于 detached HEAD 或停留在执行分支上。"
                f"请先在仓库 `git checkout <正常工作分支>` 再重新授权执行。］")
            return
        # 全局执行互斥：所有执行共享同一 git 工作区，跨议题并发会互相踩踏
        if not self._exec_lock.acquire(blocking=False):
            self.store.add_message(tid, "system", "［执行排队失败：另一议题正在执行中，请等它结束后重试］")
            return
        try:
            self._run_execute_locked(tid, topic, context, auth_text, execs, base)
        finally:
            self._exec_lock.release()

    def _run_execute_locked(self, tid: int, topic: dict, context: str, auth_text: str,
                            execs: list[dict], base: str) -> None:
        timeout = float(self.exec_cfg.get("timeout", 1200))
        diff_budget = int(self.exec_cfg.get("diff_char_budget", 20_000))
        acceptor = self.exec_cfg.get("acceptor")
        reviewer = self.exec_cfg.get("reviewer")
        dirt_baseline = executor_mod.worktree_status()
        roster = ", ".join(e.get("seat", "?") for e in execs)
        self.store.add_message(
            tid, "system",
            f"［执行已授权｜基线分支={base}｜执行名单：{roster}｜"
            f"流程：落地→互查→{reviewer or '—'} 参考→{acceptor or '—'} 验收｜不 push/不碰 main］")

        # ── 1) 逐执行者落地（每人跑完立即回基线，防止下一位在别人分支上开工）──
        done: list[tuple[str, str, bool, bool]] = []    # (seat, branch, ok, fresh=本轮真更新了分支)
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
            tip_before = executor_mod.branch_tip(branch)
            self.store.add_message(tid, seat, f"［开始执行 → {branch} 分支］")
            # 审计：Popen 之前构造白名单 Invocation 入库——spawn 失败/超时也留得住证据
            self.store.add_message(
                tid, "system",
                executor_mod.format_audit(seat, branch, executor_mod.build_invocation(list(cmd))))
            res = executor_mod.run_executor(seat, list(cmd), branch, base, context, auth_text, timeout)
            self.store.add_message(tid, seat, res["report"])
            executor_mod.restore_branch(base)
            tip_after = executor_mod.branch_tip(branch)
            fresh = tip_after is not None and tip_after != tip_before
            leftover = executor_mod.new_dirt(dirt_baseline)
            if leftover:
                self.store.add_message(
                    tid, "system",
                    "⚠［" + seat + " 执行后工作区出现未提交遗留（未自动清理，请人工确认）］\n"
                    + "\n".join(leftover[:20]))
                # 滚动基线：A 的遗留不再栽给 B（审查发现#4）
                dirt_baseline = executor_mod.worktree_status()
            done.append((seat, branch, bool(res.get("ok")), fresh))

        # ── 2) 执行记录：恢复基线 + 各分支 diffstat + 抽取真实 diff（仅本轮更新过的分支）──
        note = executor_mod.restore_branch(base)
        diffs: dict[str, tuple[str, str]] = {}          # seat -> (branch, diff文本)
        lines = ["【执行记录】", note]
        for seat, branch, ok, fresh in done:
            if fresh:
                stat = executor_mod.branch_diffstat(branch, base) or "（分支已更新但相对基线无差异）"
                lines.append(f"— {seat} @ {branch} 分支：{'✓完成' if ok else '✗失败'}\n{stat}")
                d = executor_mod.branch_diff(branch, base, diff_budget)
                if d:
                    diffs[seat] = (branch, d)
            else:
                # 分支本轮未动（spawn 失败/超时/执行者没提交）——旧分支 diff 是上轮遗留，不纳入审查
                lines.append(f"— {seat} @ {branch} 分支：{'✓完成' if ok else '✗失败'}"
                             f"（本轮未更新分支——不纳入互查/验收；若分支存在，其内容为上轮遗留）")
        self.store.add_message(tid, "system", "\n".join(lines))

        # ── 3) 交叉互查：执行者互审对方分支的真实 diff（只读）──
        if self.exec_cfg.get("cross_review", True) and len(diffs) >= 2 and not self._cancelled(tid):
            self.store.add_message(tid, "system", "［交叉互查：执行者互审对方分支 diff］")
            for seat, branch, ok, fresh in done:
                if self._cancelled(tid):
                    break
                if self.adapters.get(seat) is None:
                    continue
                for other, (obranch, odiff) in diffs.items():
                    if other == seat:
                        continue
                    instr = (
                        f"【互查】你是执行者 {seat}（你的实现在 {diffs.get(seat, ('?', ''))[0]} 分支）。"
                        f"请只读审查 {other} 在 {obranch} 分支的实现——下面是其相对基线的真实 diff。"
                        f"指出：①正确性问题；②风险/遗漏；③它比你的版本好的地方。"
                        f"不要改任何代码，直接给审查意见。\n\n"
                        f"=== {other} @ {obranch} 分支 diff ===\n{odiff}"
                    )
                    try:
                        run = self._call(seat, self._context(topic, instr), 0)
                        self.store.add_message(
                            tid, seat, self._signed(run, f"【互查 {other}@{obranch}】\n{run.content}"))
                    except Exception as exc:  # noqa: BLE001
                        self.store.add_message(tid, seat, f"[互查失败：{exc}]")

        # ── 4) 参谋席参考意见（config.execution.reviewer；无文件访问，只评记录中真实存在的内容）──
        if reviewer and reviewer not in {s for s, _, _, _ in done} \
                and self.adapters.get(reviewer) is not None and not self._cancelled(tid):
            instr = (
                "请你作为参谋席给 Erico 一段简短参考意见：基于上方执行报告、diffstat 与互查意见"
                "（你没有文件访问能力，只能评价记录中真实存在的内容；推测必须以「推测：」标注），"
                "指出你认为的关键风险或双方都遗漏的问题。无补充就说「无补充。」"
            )
            try:
                run = self._call(reviewer, self._context(topic, instr), 0)
                self.store.add_message(tid, reviewer, self._signed(run))
            except Exception as exc:  # noqa: BLE001
                self.store.add_message(tid, reviewer, f"[参考意见失败：{exc}]")

        # ── 5) fable 终验收：看全部真实 diff + 互查/参考意见，给裁决 ──
        if acceptor and self.adapters.get(acceptor) is not None and not self._cancelled(tid):
            self.store.add_message(tid, "system", f"［{acceptor} 验收中…］")
            all_diffs = "\n\n".join(
                f"=== {seat} @ {branch} 分支 diff ===\n{d}"
                for seat, (branch, d) in diffs.items()) or "（无任何分支产生 diff）"
            instr = (
                "【验收】你是项目总负责人。执行者已在各自分支落地，互查与参考意见在上方记录中，"
                "下面是各分支相对基线的真实 diff。请给出验收裁决：\n"
                "1) 各版是否正确完成了方案（有无必须修复项，逐条列出）；\n"
                "2) 建议采用哪版 / 如何合并（明确到分支名）；\n"
                "3) 合并前必做与可选改进。\n"
                "直给判断，不复述过程。\n\n" + all_diffs
            )
            try:
                run = self._call(acceptor, self._context(topic, instr), 0)
                body = run.content
                verdict = body if body.startswith("【验收") else "【验收】" + body
                self.store.add_message(tid, acceptor, self._signed(run, verdict))
            except Exception as exc:  # noqa: BLE001
                self.store.add_message(tid, acceptor, f"[验收失败：{exc}]")
        self.store.set_topic_status(tid, "executed")

    # ---- 后台入口：按消息标记选模式 ----
    def dispatch(self, tid: int, user_text: str, *, reserved: bool = False,
                 exec_seats: list[str] | None = None) -> str:
        # 标记语义=「以标记开头」（与前端一致；正文中段引用【议题】/【执行】不触发——审查发现#11）
        exec_marker = self.exec_cfg.get("marker", "【执行】")
        t = user_text.lstrip()
        is_exec = bool(self.exec_cfg.get("executors")) and t.startswith(exec_marker)
        auto = bool(self.cfg.auto_marker) and (t.startswith(self.cfg.auto_marker) or t.startswith("@自动"))
        if not reserved and not self.reserve(tid):
            raise RuntimeError("本议题正在讨论中")
        try:
            if is_exec:
                self.run_execute(tid, user_text, only_seats=exec_seats)
                return "execute"
            if auto:
                self.run_topic(tid)
                return "auto"
            self.run_participate(tid)
        finally:
            self.release(tid)
        return "reactive"
