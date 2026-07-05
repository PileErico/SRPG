extends SceneTree
## basic_attack 恒读主手（§6.2）+ 比路兹起降主副手互换（§6.3）回归。
## 恒读主手🔒：普攻只读主手武器 attack、主手空即徒手（不退副手）；比路兹靠 set_airborne 换手把
## 当前地/空偏好的爪换进主手，故活跃爪恒在主手、普攻自动切换、不吃副手惩罚。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_basic_attack.gd（退出码 0=PASS）

const UnitFactory := preload("res://UnitFactory.gd")
const WorldState := preload("res://WorldState.gd")
const UnitC := preload("res://Unit.gd")

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _find_proto(id: String):
	for p in UnitFactory.all_prototypes():
		if str(p.get("id", "")) == id:
			return p
	return null

func _initialize() -> void:
	print("=== basic_attack 恒读主手 + 比路兹起降 回归 ===")
	WorldState.current = null   # 纯沙盒域（不触玩家存档）

	# —— 恒读主手：主手空 → 徒手 UNARMED（无 off_hand 兜底）——
	var bare = UnitC.new("赤手", "player", 0, 0)
	bare.equipment = {}
	ck(str(bare.basic_attack().get("name", "")) == "徒手", "主手空 → 徒手 UNARMED（不退副手）")

	# —— 比路兹起降 flip ——
	var belooz = _find_proto("belooz")
	ck(belooz != null, "找到 belooz 原型")
	if belooz == null:
		quit(1)
		return
	var u = UnitFactory.make_unit(belooz, "player", 0, 0)
	var mh0 := int(u.equipment.get("main_hand", 0))
	var oh0 := int(u.equipment.get("off_hand", 0))
	ck(mh0 != 0 and oh0 != 0 and mh0 != oh0, "双爪各占一槽（主/副手各一 uid）")

	# 地面初始态：主手翼爪、普攻＝撕裂（prefer ground）
	ck(not u.is_airborne(), "初始地面态")
	ck(str(u.basic_attack().get("name", "")) == "撕裂（比路兹）", "地面普攻＝撕裂（翼爪·主手）")
	ck(str(u.basic_attack().get("prefer", "")) == "ground", "地面主手爪 prefer=ground")

	# 起飞：主副手 uid 对调 → 主手足爪、普攻＝抓取（prefer air）
	u.set_airborne(true)
	ck(int(u.equipment.get("main_hand", 0)) == oh0 and int(u.equipment.get("off_hand", 0)) == mh0, "起飞：主副手 uid 已对调")
	ck(str(u.basic_attack().get("name", "")) == "抓取（比路兹）", "空中普攻＝抓取（足爪·主手）")
	ck(str(u.basic_attack().get("prefer", "")) == "air", "空中主手爪 prefer=air（活跃爪在主手→不吃副手惩罚）")

	# 降落：对调复位 → 主手翼爪
	u.set_airborne(false)
	ck(int(u.equipment.get("main_hand", 0)) == mh0 and int(u.equipment.get("off_hand", 0)) == oh0, "降落：主副手 uid 复位")
	ck(str(u.basic_attack().get("name", "")) == "撕裂（比路兹）", "落地普攻＝撕裂（翼爪·主手）")

	# 幂等：重复 set_airborne(false) 不再乱换
	u.set_airborne(false)
	ck(int(u.equipment.get("main_hand", 0)) == mh0, "重复降落幂等（主手不误换）")

	# 恒读主手核心禁止行为：主手空 + 副手确有武器 → 仍徒手（绝不退副手）。
	# 用 belooz 清空主手、保留副手爪 → 若误加 off_hand 兜底，此断言会 FAIL（裸单位版测不出，见 review）。
	var u2 = UnitFactory.make_unit(belooz, "player", 0, 0)
	ck(int(u2.equipment.get("off_hand", 0)) != 0, "构造：副手确有武器（爪）")
	u2.equipment["main_hand"] = 0
	ck(str(u2.basic_attack().get("name", "")) == "徒手", "主手空+副手有武器 → 徒手（不退副手·恒读主手🔒）")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(0 if _fail == 0 else 1)
