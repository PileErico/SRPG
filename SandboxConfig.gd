extends RefCounted
## 跨场景参数（沙盒模式）：MapSelect 写、Sandbox 读。
## 仿 ItemDB/SkillDB/TraitDB：preload + 静态变量 = 全局单例，不用 autoload/class_name
## （静态变量在 change_scene_to_file 之后仍存活——脚本资源常驻内存）。
## 用法：const SandboxConfig := preload("res://SandboxConfig.gd")；写 SandboxConfig.map_path = "..."。

# 进入沙盒要打开的地图路径。空 = 用 Sandbox 默认 MAP_PATH（兼容 .bat 直接跑 Sandbox.tscn）。
static var map_path := ""

# 战役战斗通道（M5 BattleIO）：Overworld 写、Sandbox _ready 读后即清。
# null＝纯沙盒模式；非 null＝{"map_path", "unit_uids":[uid…], "provisions":[]}（BattleIO.make_setup 产物）。
static var battle_setup = null
