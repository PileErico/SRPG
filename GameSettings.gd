extends RefCounted
## 全局游戏设置：读写 user://settings.cfg + 应用（音量→AudioServer Master 总线、分辨率→窗口）。
## 仿 *DB 伪单例：preload + 静态缓存、无 class_name；刷新叫 reload_data（DB 铁律）。
## 启动时 GameSettings.apply_all()（StartMenu._ready 调）；设置页改动即存即用。
## 用法：const GameSettings := preload("res://GameSettings.gd") → GameSettings.set_volume(0.8)

const PATH := "user://settings.cfg"

# 可选分辨率（16:9；显示名 + 尺寸）。可加，改不返工。
const RESOLUTIONS := [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

static var _cfg: ConfigFile = null

static func _conf() -> ConfigFile:
	if _cfg == null:
		_cfg = ConfigFile.new()
		_cfg.load(PATH)   # 文件缺失 = 空表，取值走默认
	return _cfg

static func reload_data() -> void:
	_cfg = null

static func _save() -> void:
	if _cfg != null:
		_cfg.save(PATH)

# —— 音频：全局音量 0..1（Master 总线）——
static func get_volume() -> float:
	return clampf(float(_conf().get_value("audio", "volume", 1.0)), 0.0, 1.0)

static func set_volume(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	_conf().set_value("audio", "volume", v)
	_save()
	_apply_volume(v)

static func _apply_volume(v: float) -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus < 0:
		return
	AudioServer.set_bus_mute(bus, v <= 0.001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(v) if v > 0.001 else -80.0)

# —— 图像：分辨率（窗口尺寸）——
static func get_resolution() -> Vector2i:
	var d = _conf().get_value("video", "resolution", RESOLUTIONS[0])
	return d if d is Vector2i else RESOLUTIONS[0]

static func set_resolution(res: Vector2i) -> void:
	_conf().set_value("video", "resolution", res)
	_save()
	_apply_resolution(res)

static func _apply_resolution(res: Vector2i) -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		return   # 全屏态不改尺寸（预留：将来加全屏开关）
	DisplayServer.window_set_size(res)
	var screen := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	DisplayServer.window_set_position(((screen - res) / 2).max(Vector2i.ZERO))

static func has_resolution() -> bool:
	return _conf().has_section_key("video", "resolution")

# 启动应用全部（幂等；主场景 _ready 调一次即可）。
# 分辨率仅在玩家「显式选过」时才强制——否则保持窗口原样（不每次回菜单都硬改尺寸）。
static func apply_all() -> void:
	_apply_volume(get_volume())
	if has_resolution():
		_apply_resolution(get_resolution())
