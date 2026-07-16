"""ChatHub 统一调度器（broker）骨架。

一个进程顺序驱动多席 AI 参与 docs/chathub.md 的讨论：

    Erico 发言 → 触发一轮 → 按 speaking_order 逐席调用适配器
                 → 每席独立超时/失败即跳过 → 加锁追加发言 → 满 max_rounds 停

设计要点（与讨论 🔒 一致）：
- **单调度器**：三席都被子进程/HTTP 驱动，无分布式竞态；停止/去重/故障恢复集中此处。
- **Erico-only 触发闸**：只有「最后一条发言人 ∈ trigger_names」才开一轮；AI 发言
  不触发别的 AI（防无限回环）。
- **每席独立超时＋跳过**：某席失败/超时不阻塞其它席，末尾留 `[名字：本轮跳过]`。
- **broker 独家写盘**：适配器只回正文，broker 盖「名字＋时间」并加锁追加。

适配器接线位当前为「容错载入」：config.yaml 里指到的适配器类若尚未落地
（copilot 负责 gpt/deepseek、CLI 装好后我写 claude），broker 会记一条警告并
把该席当「不可用」跳过——因此本骨架**现在就能独立跑通全链路**（配合内置 stub）。

用法：
    python broker.py --once            # 检查一次，若最后是 Erico 就跑一轮
    python broker.py --watch           # 轮询 chathub.md，Erico 发言即自动跑一轮
    python broker.py --once --force    # 无视触发闸，强制跑一轮（调试用）
    python broker.py --dry-run         # 只打印将要追加的内容，不写盘
"""
from __future__ import annotations

import argparse
import importlib
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# --- 依赖 pyyaml；缺失时给清晰指引而非堆栈 -------------------------------------
try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("需要 pyyaml：pip install -r requirements.txt（chathub 目录下）\n")
    raise

HERE = Path(__file__).resolve().parent
DEFAULT_CONFIG = HERE / "config.yaml"

# 无论以 `python broker.py` 还是 `python -m` 运行，都能 import 到 adapters 包
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from adapters.base import Adapter, RunMeta, RunResult, Turn  # noqa: E402  (须在 sys.path 调整后)

# 发言人行形如「claude：...」或「Erico:...」，中英冒号皆可
SPEAKER_RE = re.compile(r"^([A-Za-z一-鿿]+)[：:]")


# ============================ 配置 ============================================
@dataclass
class Config:
    workspace: Path                    # 目标工作区（被讨论/被执行的项目仓库根）🔒 独立化后必配
    chathub_path: Path
    trigger_names: list[str]
    speaking_order: list[str]
    default_participants: list[str]    # GUI 讨论默认勾选的席位（空＝全员）
    max_rounds: int
    timeouts: dict[str, float]         # 席位名 → 秒
    default_timeout: float
    adapters: dict[str, dict]          # 席位名 → {class, ...role/config}
    poll_interval: float
    # —— 议题模式（模式②：放置议题→自主多轮→出结论）——
    auto_marker: str                   # Erico 消息含此标记 → 自动进议题模式
    auto_max_rounds: int               # 自主讨论轮数上限
    synthesizer: str                   # 收敛后由谁写【结论】
    converge_tag: str                  # 席位「我已收敛」的行标记
    continue_tag: str                  # 席位「还要继续」的行标记
    arbiter: str                       # 拍板权归谁（空＝无人有拍板权，功能关闭）
    verdict_tag: str                   # arbiter「本议题到此定案」的行标记

    @classmethod
    def load(cls, path: Path) -> "Config":
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}

        # 工作区：chathub 独立于目标项目之外，所有「对项目动手」的行为都以此为根。
        # 相对路径＝相对 config.yaml 所在目录；缺键＝回落到进程 cwd 并警告（别静默）。
        ws_raw = raw.get("workspace")
        if ws_raw:
            workspace = Path(str(ws_raw)).expanduser()
            if not workspace.is_absolute():
                workspace = (path.resolve().parent / workspace).resolve()
        else:
            workspace = Path.cwd()
            sys.stderr.write(f"[warn] config 缺 workspace 键，暂以当前目录为工作区：{workspace}\n")

        chathub = raw.get("chathub_path", "docs/chathub.md")
        chathub_path = (workspace / chathub) if not Path(chathub).is_absolute() else Path(chathub)

        trig = raw.get("trigger_names", ["Erico"])
        if isinstance(trig, str):
            trig = [trig]

        order = list(raw.get("speaking_order", []))
        auto = raw.get("autonomous") or {}

        # 工作区注入各席适配器（CLI 席子进程的 cwd）：config 里显式配了的席不覆盖
        adapters = dict(raw.get("adapters") or {})
        for spec in adapters.values():
            if isinstance(spec, dict):
                spec.setdefault("workspace", str(workspace))

        return cls(
            workspace=workspace,
            chathub_path=chathub_path,
            trigger_names=list(trig),
            speaking_order=order,
            default_participants=list(raw.get("default_participants") or []),
            max_rounds=int(raw.get("max_rounds", 1)),
            timeouts={k: float(v) for k, v in (raw.get("timeouts") or {}).items()},
            default_timeout=float(raw.get("default_timeout", 90)),
            adapters=adapters,
            poll_interval=float(raw.get("poll_interval", 3)),
            auto_marker=str(auto.get("marker", "【议题】")),
            auto_max_rounds=int(auto.get("max_rounds", 4)),
            synthesizer=str(auto.get("synthesizer") or (order[0] if order else "")),
            converge_tag=str(auto.get("converge_tag", "[收敛]")),
            continue_tag=str(auto.get("continue_tag", "[继续]")),
            # arbiter 无默认值：旧 config 没这键＝拍板权关闭，行为与 C 之前完全一致
            arbiter=str(auto.get("arbiter") or ""),
            verdict_tag=str(auto.get("verdict_tag", "[拍板]")),
        )

    def timeout_for(self, name: str) -> float:
        return self.timeouts.get(name, self.default_timeout)


# ============================ chathub.md 读写 =================================
def read_transcript(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def last_speaker(text: str, known_names: list[str]) -> str | None:
    """返回最后一条发言的发言人名（无则 None）。"""
    known = set(known_names)
    for line in reversed(text.splitlines()):
        m = SPEAKER_RE.match(line.strip())
        if m and m.group(1) in known:
            return m.group(1)
    return None


def speakers_since_trigger(text: str, trigger_names: list[str], speaker_names: list[str]) -> list[str]:
    """从最后一次 trigger 发言之后，已经发过言的 AI 席位名（用于去重/续轮）。"""
    said: list[str] = []
    known = set(trigger_names) | set(speaker_names)
    for line in reversed(text.splitlines()):
        m = SPEAKER_RE.match(line.strip())
        if not m or m.group(1) not in known:
            continue
        who = m.group(1)
        if who in trigger_names:
            break
        said.append(who)
    return list(reversed(said))


def last_trigger_message(text: str, trigger_names: list[str], known_names: list[str]) -> str:
    """返回最后一条 trigger（Erico）发言的完整文本（到下一位已知发言人前）。"""
    lines = text.splitlines()
    known = set(known_names)
    start = None
    for idx in range(len(lines) - 1, -1, -1):
        m = SPEAKER_RE.match(lines[idx].strip())
        if m and m.group(1) in trigger_names:
            start = idx
            break
    if start is None:
        return ""
    collected = [lines[start]]
    for idx in range(start + 1, len(lines)):
        m = SPEAKER_RE.match(lines[idx].strip())
        if m and m.group(1) in known:
            break
        collected.append(lines[idx])
    return "\n".join(collected)


def _last_nonempty(body: str) -> str:
    """发言的最后一个非空行（strip 后）；全空返回 ""。"""
    for line in reversed(body.splitlines()):
        if line.strip():
            return line.strip()
    return ""


def _drop_tag_lines(body: str, tags: tuple[str, ...]) -> str:
    """剥掉「整行严格等于某标签」的行；剥空了就退回原文（宁可留标签也不吞正文）。"""
    cleaned = [ln for ln in body.splitlines() if ln.strip() not in tags]
    return "\n".join(cleaned).strip() or body.strip()


def extract_vote(body: str, converge_tag: str, continue_tag: str) -> tuple[str, bool]:
    """从发言里剥离收敛/继续标记行，返回（清洁正文, 是否投收敛）。"""
    # 只有最后一个非空行严格等于标签才计票；正文引用“[收敛]”不应误触发。
    last = _last_nonempty(body)
    voted = bool(last) and last == converge_tag
    return _drop_tag_lines(body, (converge_tag, continue_tag)), voted


def extract_verdict(body: str, verdict_tag: str) -> tuple[str, bool]:
    """从 **arbiter 席**的发言里剥离拍板标记行，返回（清洁正文, 是否拍板）。

    与 extract_vote 共用同一套严格末行匹配 🔒：只有最后一个非空行严格等于标签才算数，
    正文里行内引用「[拍板]」（如复述本条规则）不触发。
    调用方负责只对 arbiter 席调用——别处写这个标签一律是普通文本。
    """
    last = _last_nonempty(body)
    if not verdict_tag or not last or last != verdict_tag:
        return body, False
    return _drop_tag_lines(body, (verdict_tag,)), True


def with_arbiter_clause(cfg: Config, instruction: str, seat: str) -> str:
    """给 arbiter 席的轮次指令追加拍板授权说明；非 arbiter 席原样返回。

    CLI 与 GUI 共用此函数——两处各写一份提示词，早晚漂移成「两套规则」。
    """
    if not (cfg.arbiter and cfg.verdict_tag and seat == cfg.arbiter):
        return instruction
    return instruction + (
        f"\n【拍板权】你是本桌的 arbiter（{cfg.arbiter}）：若讨论已可定案、不需要其它席位再补充，"
        f"就在发言**最后单独一行**写 {cfg.verdict_tag}（替代 {cfg.converge_tag}/{cfg.continue_tag}）"
        f"——本轮剩余席位立即跳过，讨论直接进入结论综合。"
        f"慎用：只在你已有明确裁决、继续讨论只会重复时才用。"
    )


def verdict_notice(cfg: Config, skipped: list[str]) -> str:
    """拍板留痕（system 消息）：CLI/GUI 共用同一句，措辞不分叉。"""
    who = "、".join(skipped) if skipped else "无（其后已无待发言席位）"
    return (f"［{cfg.arbiter} 已拍板（{cfg.verdict_tag}）：本轮剩余席位跳过——{who}。"
            f"讨论直接进入结论综合。拍板只收当轮，被跳过席位下轮正常参与、不是禁言。］")


class _FileLock:
    """极简跨平台文件锁：O_CREAT|O_EXCL 自旋，防多 broker 实例并发写。"""

    def __init__(self, target: Path, timeout: float = 10.0):
        self.lock_path = target.with_suffix(target.suffix + ".lock")
        self.timeout = timeout
        self._fd: int | None = None

    def __enter__(self):
        import os
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                self._fd = os.open(self.lock_path, os.O_CREAT | os.O_EXCL | os.O_RDWR)
                return self
            except FileExistsError:
                if time.monotonic() > deadline:
                    raise TimeoutError(f"获取文件锁超时：{self.lock_path}")
                time.sleep(0.05)

    def __exit__(self, *exc):
        import os
        if self._fd is not None:
            os.close(self._fd)
        try:
            self.lock_path.unlink()
        except FileNotFoundError:
            pass


def append_message(path: Path, name: str, body: str, *, dry_run: bool = False) -> str:
    """把一条发言盖上「名字＋时间」加锁追加到 chathub.md，返回追加的整块文本。"""
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    block = f"\n{name}：{body.rstrip()} {stamp}\n"
    if dry_run:
        return block
    with _FileLock(path):
        existing = read_transcript(path)
        sep = "" if existing.endswith("\n") or not existing else "\n"
        with path.open("a", encoding="utf-8") as fh:
            fh.write(sep + block)
    return block


# ============================ 适配器载入 ======================================
def load_adapter(name: str, spec: dict) -> Adapter | None:
    """按 spec['class']='pkg.mod:ClassName' 动态载入；失败返回 None（容错跳过）。"""
    dotted = spec.get("class")
    if not dotted:
        sys.stderr.write(f"[warn] 席位 {name} 未配置 class，跳过\n")
        return None
    try:
        mod_path, cls_name = dotted.split(":", 1)
        module = importlib.import_module(mod_path)
        cls = getattr(module, cls_name)
        return cls(name=name, config=spec)
    except Exception as exc:  # 适配器尚未落地/导入报错 → 容错
        sys.stderr.write(f"[warn] 席位 {name} 适配器不可用（{dotted}）：{exc}\n")
        return None


def call_with_timeout(adapter: Adapter, context: str, turn: Turn, timeout: float) -> RunResult:
    """在子线程里调适配器，超时即视为跳过。返回 RunResult（正文＋元数据）。

    注意：Python 无法强杀线程——子进程型适配器（codex/claude CLI）**必须自带
    subprocess timeout**，此处的线程超时只是二道保险。

    元数据**只随返回值出去**（局部 result 拆包）🔒：绝不落到 adapter/broker 的
    共享可变状态上——超时后旧线程仍在跑，晚回来的那次会覆盖共享表，落款就变成
    「盖死人的数据」。
    """
    result: dict[str, object] = {}

    def _run():
        try:
            result["ok"] = adapter.generate_result(context, turn)
        except Exception as exc:  # noqa: BLE001
            result["err"] = exc

    th = threading.Thread(target=_run, daemon=True)
    th.start()
    th.join(timeout)
    if th.is_alive():
        raise TimeoutError(f"{adapter.name} 超时（>{timeout}s）")
    if "err" in result:
        raise result["err"]  # type: ignore[misc]
    run = result.get("ok")
    if not isinstance(run, RunResult) or not (run.content or "").strip():
        raise ValueError(f"{adapter.name} 返回空发言")
    return run


def format_signature(meta: RunMeta) -> str:
    """一行落款：model / effort / 验证状态——只读 RunResult 携带的白名单事实。

    验证状态语义 🔒：requested 与 reported 均非空且相等＝verified；CLI 席无回读
    通道 → 恒 unverified（不是故障，是「我们只能证明请求过、证不到服务端用了谁」）。
    旧消息没有这一行，按原格式渲染即可。
    """
    inv = meta.invocation
    if not (inv.executable or inv.requested_model or inv.effort):
        # 该席适配器还没覆写 generate_result()，默认包装拿不到任何调用事实。
        # 这时写「model: 默认」是撒谎——「默认」是一句断言，真相是「没人申报过」。
        return "———\n［元数据未申报（该席适配器未接 RunResult）｜unverified］"
    model = inv.requested_model or "默认（未指定）"
    if inv.requested_model and not inv.model_injected:
        model += "（⚠ 未注入命令行）"
    effort = inv.effort or "—"
    if inv.effort and not inv.effort_injected:
        effort += "（⚠ 未注入命令行）"
    bits = [f"model: {model}", f"effort: {effort}", meta.verification]
    if inv.reported_model and inv.reported_model != inv.requested_model:
        bits.append(f"⚠ 服务端回读 {inv.reported_model}")
    for w in meta.warnings:
        bits.append(f"⚠ {w}")
    return "———\n［" + "｜".join(bits) + "］"


def with_signature(body: str, meta: RunMeta) -> str:
    """正文 + 落款。注意调用序：先 extract_vote 剥标记、再盖落款——
    反过来会把落款变成最后一个非空行，收敛票永远统计不到。"""
    return f"{body.rstrip()}\n\n{format_signature(meta)}"


# ============================ 调度 ============================================
@dataclass
class RoundOutcome:
    """一轮的结果。spoke ＝ [(席位名, 清洁正文, 是否投收敛)]；ruled ＝ arbiter 已拍板。"""

    spoke: list[tuple[str, str, bool]] = field(default_factory=list)
    ruled: bool = False


def run_round(cfg: Config, adapters: dict[str, Adapter | None], round_index: int,
              *, dry_run: bool, instruction: str = "", dedup: bool = True,
              strip_tags: bool = False) -> RoundOutcome:
    """跑一轮：按顺序逐席发言。返回 RoundOutcome（发言清单 + 是否已拍板）。

    - instruction：broker 注入到 context 末尾的「调度器指令」（模式相关，适配器无需改）。
    - dedup：True＝本次触发已发言过的席位跳过（参与模式续轮）；议题模式关它、每轮全员再说。
    - strip_tags：True＝议题模式——剥离并统计收敛/继续标记，且 arbiter 的拍板标记生效
      （两者同属「轮次标记」家族，没有只要其一的场景）。
    """
    outcome = RoundOutcome()
    prior: list[str] = []
    already = set(speakers_since_trigger(
        read_transcript(cfg.chathub_path), cfg.trigger_names, cfg.speaking_order
    )) if dedup else set()

    for i, name in enumerate(cfg.speaking_order):
        if name in already:
            continue
        adapter = adapters.get(name)
        turn = Turn(round_index=round_index, speaker=name, order_index=i, prior_this_round=list(prior))
        context = read_transcript(cfg.chathub_path)  # 每席都读到「前面席位刚写的」
        if instruction:
            instr = with_arbiter_clause(cfg, instruction, name) if strip_tags else instruction
            context += f"\n\n———[调度器指令]———\n{instr}"

        if adapter is None:
            append_message(cfg.chathub_path, name, "[本轮跳过：适配器未接线]", dry_run=dry_run)
            print(f"— {name}: 跳过（未接线）")
            continue

        ruled = False
        try:
            run = call_with_timeout(adapter, context, turn, cfg.timeout_for(name))
            raw = run.content
            if strip_tags:
                # 拍板只认 arbiter：别席写这个标签就是普通文本，不剥也不生效
                if name == cfg.arbiter:
                    raw, ruled = extract_verdict(raw, cfg.verdict_tag)
                body, voted = extract_vote(raw, cfg.converge_tag, cfg.continue_tag)
            else:
                body, voted = raw, False
            block = append_message(cfg.chathub_path, name, with_signature(body, run.meta), dry_run=dry_run)
            outcome.spoke.append((name, body, voted))
            prior.append(name)
            flag = "（拍板）" if ruled else "（收敛）" if voted else ""
            print(f"✓ {name}: 已发言（{len(body)} 字）{flag}")
            if dry_run:
                print(block)
        except Exception as exc:  # noqa: BLE001
            append_message(cfg.chathub_path, name, f"[本轮跳过：{exc}]", dry_run=dry_run)
            print(f"✗ {name}: 跳过（{exc}）")

        if ruled:
            outcome.ruled = True
            skipped = [n for n in cfg.speaking_order[i + 1:] if n not in already]
            append_message(cfg.chathub_path, "system", verdict_notice(cfg, skipped), dry_run=dry_run)
            print(f"⚖ {cfg.arbiter} 拍板：跳过本轮剩余 {len(skipped)} 席")
            break
    return outcome


def _auto_round_instruction(cfg: Config, r: int) -> str:
    return (
        f"【议题讨论模式 · 第 {r + 1}/{cfg.auto_max_rounds} 轮】你正在与其他 AI 就 Erico 放置的"
        f"议题自主讨论，目标是收敛到一个**可执行的答案**。\n"
        f"- 针对前面各席的发言推进：补充 / 质疑 / 修正 / 给方案，别重复已达成的共识。\n"
        f"- 有条件就用项目里的真实文件、数据佐证你的判断（只读引用即可）。\n"
        f"- 若你认为讨论已收敛、你没有新的实质补充，就在发言**最后单独一行**写 {cfg.converge_tag}；"
        f"否则最后单独一行写 {cfg.continue_tag}。\n"
        f"只输出你的发言正文（含最后那一行标签），不要加名字/时间。"
    )


def run_auto(cfg: Config, adapters: dict[str, Adapter | None], *, dry_run: bool) -> None:
    """议题模式：自主多轮讨论至收敛（或达轮次上限），再由 synthesizer 出【结论】。"""
    print(f"🧠 议题模式：至多 {cfg.auto_max_rounds} 轮，收敛后由 {cfg.synthesizer!r} 出结论")
    for r in range(cfg.auto_max_rounds):
        outcome = run_round(cfg, adapters, r, dry_run=dry_run,
                            instruction=_auto_round_instruction(cfg, r),
                            dedup=False, strip_tags=True)
        if not outcome.spoke:
            print("· 本轮无人发言，终止。")
            break
        # 拍板＝arbiter 单方收口，不看票数；仍照常走下面的结论综合
        if outcome.ruled:
            print(f"· {cfg.arbiter} 已拍板，进入结论综合。")
            break
        votes = [v for _, _, v in outcome.spoke]
        print(f"— 第 {r + 1} 轮收敛票：{sum(votes)}/{len(votes)}")
        if all(votes):
            print("· 全员收敛，进入结论综合。")
            break

    synth = cfg.synthesizer
    if not synth or adapters.get(synth) is None:
        print(f"· 综合者 {synth!r} 不可用，跳过结论。")
        return
    instr = (
        "【结论综合】讨论已结束（收敛或达轮次上限）。请你作为综合者，为 Erico 输出一段【结论】：\n"
        "1) 议题的最终答案 / 方案；2) 仍存的分歧或待定项；3) 建议的下一步——若需要执行，"
        "列出具体动作，并标注哪些需要 Erico 批准、哪些可直接做。\n"
        "不要复述讨论过程，直给结论。"
    )
    context = read_transcript(cfg.chathub_path) + f"\n\n———[调度器指令]———\n{instr}"
    turn = Turn(round_index=999, speaker=synth, order_index=0, prior_this_round=[])
    try:
        run = call_with_timeout(adapters[synth], context, turn, cfg.timeout_for(synth))
        body = run.content
        concl = body if body.startswith("【结论") else "【结论】" + body
        append_message(cfg.chathub_path, synth, with_signature(concl, run.meta), dry_run=dry_run)
        print(f"✓ {synth}: 已出结论")
    except Exception as exc:  # noqa: BLE001
        print(f"✗ 结论综合失败：{exc}")


def run_once(cfg: Config, adapters: dict[str, Adapter | None],
             *, force: bool, dry_run: bool, mode: str = "detect") -> bool:
    """检查触发闸并（若通过）按模式调度。mode: detect|reactive|auto。返回是否真的跑了。"""
    text = read_transcript(cfg.chathub_path)
    known = cfg.trigger_names + cfg.speaking_order
    who = last_speaker(text, known)
    if not force and who not in cfg.trigger_names:
        print(f"· 触发闸未开：最后发言人＝{who!r}，非 {cfg.trigger_names}，静默。")
        return False

    if mode == "reactive":
        is_auto = False
    elif mode == "auto":
        is_auto = True
    else:  # detect：看最后一条 Erico 消息是否带议题标记
        trig_msg = last_trigger_message(text, cfg.trigger_names, known)
        is_auto = bool(cfg.auto_marker) and (cfg.auto_marker in trig_msg or "@自动" in trig_msg)

    if is_auto:
        print(f"▶ 触发（{who!r}）· 议题模式（自主讨论）")
        run_auto(cfg, adapters, dry_run=dry_run)
    else:
        print(f"▶ 触发（{who!r}）· 参与模式（各席一次）")
        for r in range(cfg.max_rounds):
            if not run_round(cfg, adapters, r, dry_run=dry_run).spoke:
                break
    return True


def watch(cfg: Config, adapters: dict[str, Adapter | None], *, dry_run: bool, mode: str) -> None:
    """轮询 chathub.md 的 mtime；变化且触发闸开 → 按模式跑。"""
    print(f"👀 watch：{cfg.chathub_path}（每 {cfg.poll_interval}s 一探）Ctrl-C 退出")
    print(f"   模式＝{mode}（detect＝Erico 消息带「{cfg.auto_marker}」则自动进议题模式）")
    last_mtime = 0.0
    while True:
        try:
            mtime = cfg.chathub_path.stat().st_mtime if cfg.chathub_path.exists() else 0.0
            if mtime != last_mtime:
                last_mtime = mtime
                run_once(cfg, adapters, force=False, dry_run=dry_run, mode=mode)
            time.sleep(cfg.poll_interval)
        except KeyboardInterrupt:
            print("\n已停止。")
            return


# ============================ 入口 ============================================
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="ChatHub 统一调度器")
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="检查一次并（若触发）跑一轮（默认）")
    mode.add_argument("--watch", action="store_true", help="轮询自动跑")
    ap.add_argument("--force", action="store_true", help="无视触发闸强制跑一轮")
    ap.add_argument("--dry-run", action="store_true", help="只打印不写盘")
    md = ap.add_mutually_exclusive_group()
    md.add_argument("--auto", action="store_true", help="强制议题模式（自主多轮+结论）")
    md.add_argument("--reactive", action="store_true", help="强制参与模式（各席一次）")
    args = ap.parse_args(argv)
    run_mode = "auto" if args.auto else "reactive" if args.reactive else "detect"

    # Windows 控制台默认 GBK，会崩在 ▶✓✗ 等字符上——强制 UTF-8 输出
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass

    cfg = Config.load(args.config)
    print(f"chathub: {cfg.chathub_path}")
    print(f"工作区: {cfg.workspace}")
    print(f"顺序: {cfg.speaking_order} | max_rounds={cfg.max_rounds} | 触发={cfg.trigger_names}")

    adapters = {name: load_adapter(name, spec) for name, spec in cfg.adapters.items()}

    if args.watch:
        watch(cfg, adapters, dry_run=args.dry_run, mode=run_mode)
    else:
        run_once(cfg, adapters, force=args.force, dry_run=args.dry_run, mode=run_mode)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
