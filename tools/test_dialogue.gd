extends SceneTree
## M8 回归：DialogueDB 注册表 / DialogueUI 播放核心（线性推进·分支选项·效果落档·无档安全）
## / EventEngine dialogue 动作注册+转发 / Overworld·Sandbox 宿主接线。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_dialogue.gd（退出码 0=PASS）

const DialogueDB := preload("res://DialogueDB.gd")
const DialogueUI := preload("res://DialogueUI.gd")
const EventEngine := preload("res://EventEngine.gd")
const WorldState := preload("res://WorldState.gd")
const OverworldScript := preload("res://Overworld.gd")
const SandboxScript := preload("res://Sandbox.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

class StubHost:
	extends RefCounted
	var got := ""
	func event_dialogue(id: String) -> void:
		got = id

func _initialize() -> void:
	print("=== M8 对话系统测试开始 ===")

	# 1) DialogueDB 注册表
	ck(DialogueDB.all_dialogues().size() >= 2, "对话表非空")
	var dlg = DialogueDB.dialogue("dlg_merchant")
	ck(dlg != null, "dlg_merchant 存在")
	ck(DialogueDB.dialogue("no_such") == null, "未知对话 → null")
	ck(str(DialogueDB.first_node(dlg).get("id")) == "n1", "首节点=nodes[0]")
	ck(DialogueDB.node(dlg, "n2") != null and DialogueDB.node(dlg, "nope") == null, "节点查找")

	# 2) 线性播放（纯演出）：start → advance… → finished 信号 + 失活
	var fin := [0]
	var ui = DialogueUI.new()
	ui.finished.connect(func(): fin[0] += 1)
	ck(ui.start("dlg_merchant", null), "开播成功")
	ck(ui.is_active() and str(ui.current_node().get("id")) == "n1", "起点 n1")
	ui.advance()
	ck(str(ui.current_node().get("id")) == "n2", "推进到 n2")
	ui.advance()
	ck(not ui.is_active() and fin[0] == 1, "next 空 → 结束 + finished 信号")
	ui.free()

	# 3) 分支播放：choices 节点点击不推进、choose 落效果（set_flags + rep）并跳转
	var ws = WorldState.start_new()
	var ui2 = DialogueUI.new()
	ui2.start("dlg_elder_astra", ws)
	ui2.advance()   # n1 → n2（分支节点）
	ck(str(ui2.current_node().get("id")) == "n2", "到分支节点 n2")
	ui2.advance()   # 分支节点：advance 无效
	ck(str(ui2.current_node().get("id")) == "n2", "分支节点点击不推进")
	ui2.choose(0)   # 选「美言」：set_flags + rep empire+5 → n_yes
	ck(bool(ws.flags.get("astra_elder_favor", false)), "选项 set_flags 落档")
	ck(int(ws.reputation.get("empire", 0)) == 5, "选项 rep 累加声望")
	ck(str(ui2.current_node().get("id")) == "n_yes", "choose 跳转 n_yes")
	ui2.advance()
	ck(not ui2.is_active(), "分支线走完")
	ui2.free()

	# 4) 无档安全（纯沙盒）：带效果的选项不写、不崩
	WorldState.current = null
	var ui3 = DialogueUI.new()
	ui3.start("dlg_elder_astra", null)
	ui3.advance()
	ui3.choose(0)   # set_flags/rep 应跳过（仅警告）
	ck(str(ui3.current_node().get("id")) == "n_yes", "无档仍正常跳转")
	ui3.free()

	# 5) 坏数据兜底：未知对话 id → 直接 finished；choose 越界不动
	var fin4 := [0]
	var ui4 = DialogueUI.new()
	ui4.finished.connect(func(): fin4[0] += 1)
	ck(not ui4.start("no_such", null) and fin4[0] == 1, "未知对话 → 开播失败 + finished")
	ui4.free()
	var ui5 = DialogueUI.new()
	ui5.start("dlg_elder_astra", null)
	ui5.advance()
	ui5.choose(9)
	ck(str(ui5.current_node().get("id")) == "n2", "choose 越界不动")
	ui5.free()

	# 6) EventEngine：dialogue 动作已登记（编辑器表单同源）+ 转发宿主原语；空 id 不转发
	ck(not EventEngine.action_def("dialogue").is_empty(), "动作注册表含 dialogue")
	ck(str(EventEngine.default_action("dialogue").get("dialogue_id")) == "", "default_action 字段齐")
	var stub := StubHost.new()
	EventEngine.execute_action({"action": "dialogue", "dialogue_id": "dlg_x"}, stub)
	ck(stub.got == "dlg_x", "dialogue 动作转发 event_dialogue")
	stub.got = ""
	EventEngine.execute_action({"action": "dialogue", "dialogue_id": ""}, stub)
	ck(stub.got == "", "空 dialogue_id 不转发")

	# 7) 宿主接线：Overworld / Sandbox 的 event_dialogue 建对话并在结束后清引用
	var ow = OverworldScript.new()
	ow.event_dialogue("dlg_merchant")
	ck(ow._dialogue != null and ow._dialogue.is_active(), "Overworld 开对话")
	ow._dialogue.advance()
	ow._dialogue.advance()
	ck(ow._dialogue == null, "Overworld 对话结束清引用")
	ow.event_dialogue("no_such")
	ck(ow._dialogue == null, "开播失败同步清引用")
	ow.free()
	var sb = SandboxScript.new()
	sb.event_dialogue("dlg_merchant")
	ck(sb._dialogue != null and sb._dialogue.is_active(), "Sandbox（战场内）开对话")
	sb._dialogue.advance()
	sb._dialogue.advance()
	ck(sb._dialogue == null, "Sandbox 对话结束清引用")
	sb.free()

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
