extends SceneTree
## SaveIO 存档健壮性（2026-07-12 手动存档+原子写落地；技改提案波B-4 兑现）回归：
##  · 原子写：首存无 .bak → 重存产生 .bak（上一版本）→ 无 .tmp 残留
##  · 损坏回退：主档写坏 → load_campaign 自动回退 .bak（响亮警告、读到上一版本）
##  · slot_info 速览（clock_hours/party/gold/ironman）；delete_slot 连 .bak 清；MANUAL_SLOTS 单一源
## ⚠ 测试铁律：不碰 auto 槽——用独立槽名 t_saveio。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_saveio.gd（退出码 0=PASS）

const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")

const SLOT := "t_saveio"

var _fail := 0
func ck(c: bool, m: String) -> void:
	if not c:
		_fail += 1
		push_error("[FAIL] " + m)

func _initialize() -> void:
	print("=== SaveIO 原子写/回退 测试开始 ===")
	SaveIO.delete_slot(SLOT)
	var ws = WorldState.new()
	ws.gold = 111
	ws.clock_hours = 30
	ck(SaveIO.save_campaign(ws, SLOT), "首存成功")
	ck(not FileAccess.file_exists(SaveIO.slot_path(SLOT) + ".bak"), "首存无 .bak")
	ws.gold = 222
	ck(SaveIO.save_campaign(ws, SLOT), "重存成功")
	ck(FileAccess.file_exists(SaveIO.slot_path(SLOT) + ".bak"), "重存产生 .bak（上一版本）")
	var info: Dictionary = SaveIO.slot_info(SLOT)
	ck(int(info.get("gold", -1)) == 222 and int(info.get("clock_hours", -1)) == 30, "slot_info 主档速览（gold/clock）")
	var f := FileAccess.open(SaveIO.slot_path(SLOT), FileAccess.WRITE)
	f.store_string("{broken json")   # 模拟写一半崩：主档变半截
	f.close()
	var back = SaveIO.load_campaign(SLOT)
	ck(back != null and int(back.gold) == 111, "主档损坏 → 自动回退 .bak（读到上一版本）")
	ck(not FileAccess.file_exists(SaveIO.slot_path(SLOT) + ".tmp"), "无 .tmp 残留")
	ck(SaveIO.delete_slot(SLOT), "删槽成功")
	ck(not FileAccess.file_exists(SaveIO.slot_path(SLOT) + ".bak"), "删槽连 .bak 清")
	ck(SaveIO.MANUAL_SLOTS.size() >= 3 and not SaveIO.MANUAL_SLOTS.has(SaveIO.AUTO_SLOT), "手动槽位单一源（≥3 且不含 auto）")
	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(_fail)
