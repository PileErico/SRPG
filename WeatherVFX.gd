extends TextureRect
## 天气视觉叠层（屏幕空间氛围层）：按当前天气 id 播放 48 帧无缝循环的大气 VFX。
## 挂为 SandboxCanvas 的子节点 → 覆盖战场视口（不盖侧栏 UI）、不随镜头平移/缩放、点击穿透；
## 子节点画在父画布(_draw 地形/单位/迷雾)之上 → 天气氛围在最前，符合"下雨在战场之上"。
## 素材：weather/individual_frames/<vfx>/<vfx>_NNN.png（320×180、48 帧循环，Alenia Studios · CC BY 4.0，见 CREDITS.md）。
## 天气→vfx/tint/fps 映射是数据，读 EnvDB（data/environment.json）。见 docs/感知系统.md「环境」🔒。

const EnvDB := preload("res://EnvDB.gd")
const TextureCache := preload("res://TextureCache.gd")   # 已导入优先 / 否则 Image.load，跨实例缓存
const FRAME_COUNT := 48
const FRAME_PATH := "res://weather/individual_frames/%s/%s_%03d.png"

var _cur_id := "__none__"
var _frames := []       # 当前天气的帧纹理数组
var _cache := {}        # vfx 名 -> [Texture2D]（避免反复加载解码）
var _t := 0.0           # 当前帧位（浮点，_process 累加）
var _fps := 14.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE                 # 点击穿透给画布（不挡选单位/走位）
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST         # 像素图放大不糊（与项目一致）
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED     # 320×180 覆盖视口、保持比例（裁边不拉伸）
	visible = false
	set_process(false)

# 切到某天气：加载其 vfx 帧 + tint；无 vfx（如晴）→ 隐藏并停处理。同 id 幂等。
func set_weather(id: String) -> void:
	if id == _cur_id:
		return
	_cur_id = id
	var def = EnvDB.weather(id)
	var vfx := (str(def.get("vfx", "")) if def != null else "")
	if vfx == "":
		_stop()
		return
	_frames = _load_frames(vfx)
	if _frames.is_empty():
		_stop()
		return
	_fps = float(def.get("vfx_fps", 14)) if def != null else 14.0
	modulate = Color.html(str(def.get("tint", "#FFFFFFFF")) if def != null else "#FFFFFFFF")
	_t = 0.0
	texture = _frames[0]
	visible = true
	set_process(true)

func _stop() -> void:
	visible = false
	set_process(false)
	texture = null
	_frames = []

func _process(delta: float) -> void:
	if _frames.is_empty():
		return
	_t = fmod(_t + delta * _fps, float(_frames.size()))
	texture = _frames[int(_t)]

func _load_frames(vfx: String) -> Array:
	if _cache.has(vfx):
		return _cache[vfx]
	var arr := []
	for i in FRAME_COUNT:
		var t = TextureCache.get_tex(FRAME_PATH % [vfx, vfx, i])
		if t == null:
			break   # 帧缺失即停（容忍不足 48 帧）
		arr.append(t)
	_cache[vfx] = arr
	return arr
