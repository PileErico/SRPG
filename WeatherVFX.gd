extends Control
## 天气视觉叠层（屏幕空间氛围层）：按当前天气 id 渲染大气 VFX。
## 挂为 SandboxCanvas 的子节点 → 覆盖战场视口（不盖侧栏 UI）、不随镜头平移/缩放、点击穿透；
## 子节点画在父画布(_draw 地形/单位/迷雾)之上 → 天气氛围在最前，符合"下雨在战场之上"。
##
## 每种天气选最佳技法（全自绘/程序化，无第三方素材）：
## - 雨 / 雪 / 沙暴 / 雷暴 = GPUParticles2D 真实粒子（自绘几像素粒子，NEAREST）：锐利/有机/密度可控/GPU/远近视差。
## - 雾 = 大尺度平滑噪声 shader（weather_fog.gdshader）：柔和无定形的雾岸。
## - 雷暴 = 雨粒子 + 偶发全屏白闪（ColorRect 亮度脉冲，_process 驱动）。
## 天气→fx(shader 名)/tint(大气调色，Sandbox 另叠) 映射是数据，读 EnvDB（data/environment.json）。见 docs/感知系统.md「环境」🔒。

const EnvDB := preload("res://EnvDB.gd")

# 走 shader 渲染的天气：fx 名 → 程序化 shader（目前仅雾；雨/雪等走粒子）
const SHADERS := {
	"fog": preload("res://shaders/weather_fog.gdshader"),
}
# 走粒子渲染的天气
const PARTICLE_WEATHERS := ["rain", "snow", "sandstorm", "storm"]

var _cur_id := "__none__"

# —— 各路径节点 ——
var _pnode: Node2D             # particle：GPUParticles2D 容器（screen-space）
var _fx: ColorRect             # shader（雾）
var _flash: ColorRect          # 雷暴全屏闪光（最上层）

# 自绘粒子纹理（建一次）
var _tex_rain: Texture2D
var _tex_snow: Texture2D
var _tex_sand: Texture2D

# 雷暴闪光状态（_process 驱动）
var _flash_on := false
var _flash_alpha := 0.0
var _flash_timer := 0.0
var _flash_next := 2.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE                 # 点击穿透给画布

	_pnode = Node2D.new()
	_pnode.visible = false
	add_child(_pnode)

	_fx = ColorRect.new()
	_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.material = ShaderMaterial.new()
	_fx.visible = false
	add_child(_fx)

	_flash = ColorRect.new()
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.color = Color(0.9, 0.95, 1.0, 0.0)
	_flash.visible = false
	add_child(_flash)                                          # 最后加＝最上层（闪光盖在雨之上）

	_tex_rain = _make_rain_tex()
	_tex_snow = _make_snow_tex()
	_tex_sand = _make_sand_tex()

	get_viewport().size_changed.connect(_on_resize)
	set_process(false)

func _on_resize() -> void:
	# 视口尺寸变了：粒子发射范围随之重建（shader 走全屏，无需处理）
	if _pnode.visible:
		_build_particles(_cur_id)

# 切到某天气：按天气分派最佳技法；无对应 VFX（如晴）→ 隐藏。同 id 幂等。
func set_weather(id: String) -> void:
	if id == _cur_id:
		return
	_cur_id = id
	var def = EnvDB.weather(id)
	if id in PARTICLE_WEATHERS:
		_stop_shader()
		_build_particles(id)
		_set_flash(id == "storm")          # 雷暴叠全屏闪光
	elif SHADERS.has(str(def.get("fx", "")) if def != null else ""):
		_stop_particle()
		_set_flash(false)
		_show_shader(def)                  # 如雾＝平滑噪声 shader
	else:
		_stop_particle()
		_stop_shader()
		_set_flash(false)

# ============ particle 路径（GPUParticles2D 真实粒子）============
func _stop_particle() -> void:
	for c in _pnode.get_children():
		c.queue_free()
	_pnode.visible = false

func _build_particles(id: String) -> void:
	for c in _pnode.get_children():
		c.queue_free()
	var vp := get_viewport_rect().size
	var w := vp.x
	var h := vp.y
	if id == "rain":
		var col := Color(0.72, 0.80, 0.92, 0.9)
		# 近层：粗、快、亮；远层：细、慢、暗（视差）
		_pnode.add_child(_make_fall(_tex_rain, 240, 1.15, w, h, Vector2(0.16, 1.0),
			720.0, 900.0, 3.0, 0.9, 1.4, col, 0.0, false))
		_pnode.add_child(_make_fall(_tex_rain, 150, 1.7, w, h, Vector2(0.16, 1.0),
			460.0, 600.0, 3.0, 0.55, 0.9, Color(col.r, col.g, col.b, 0.5), 0.0, false))
		_pnode.visible = true
	elif id == "snow":
		var col := Color(0.95, 0.97, 1.0, 0.95)
		# 整屏均匀发射（立即满屏，preprocess 填池）+ 匀速直落 + 渐入渐出掩盖生灭。近大远小做视差。
		# ⚠️不要开湍流：Godot 湍流是静态噪声场，慢速雪会被其驻点/涡旋困住 → "落一小段就停住闪烁"。
		# 轻微飘摆靠 dir 的横向分量 + spread 制造，不用湍流。
		_pnode.add_child(_make_fall(_tex_snow, 280, 5.0, w, h, Vector2(0.12, 1.0),
			95.0, 135.0, 14.0, 1.0, 2.0, col, 0.0, true))
		_pnode.add_child(_make_fall(_tex_snow, 210, 7.0, w, h, Vector2(0.12, 1.0),
			55.0, 85.0, 14.0, 0.6, 1.1, Color(col.r, col.g, col.b, 0.55), 0.0, true))
		_pnode.visible = true
	elif id == "sandstorm":
		var col := Color(0.90, 0.78, 0.50, 0.85)
		# 横向疾驰的沙粒（整屏发射向右吹）；偏黄大气 tint 由 Sandbox 天气叠层负责。近快远慢做视差
		_pnode.add_child(_make_fall(_tex_sand, 320, 2.2, w, h, Vector2(1.0, 0.10),
			360.0, 560.0, 6.0, 1.0, 2.0, col, 0.0, true))
		_pnode.add_child(_make_fall(_tex_sand, 220, 3.2, w, h, Vector2(1.0, 0.10),
			220.0, 340.0, 6.0, 0.6, 1.1, Color(col.r, col.g, col.b, 0.5), 0.0, true))
		_pnode.visible = true
	elif id == "storm":
		var col := Color(0.68, 0.76, 0.90, 0.95)
		# 雷暴＝更急更密的雨（比 rain 快/密），闪光由 _set_flash 叠加
		_pnode.add_child(_make_fall(_tex_rain, 300, 1.0, w, h, Vector2(0.22, 1.0),
			860.0, 1080.0, 4.0, 1.0, 1.6, col, 0.0, false))
		_pnode.add_child(_make_fall(_tex_rain, 190, 1.5, w, h, Vector2(0.22, 1.0),
			540.0, 700.0, 4.0, 0.6, 1.0, Color(col.r, col.g, col.b, 0.5), 0.0, false))
		_pnode.visible = true
	else:
		_pnode.visible = false

# 造一个下落/横吹粒子发射器。turb>0 ＝ 开湍流（暂不用，慢速粒子会被困住）。
# fullscreen=false：从屏幕上方横条发射（快速雨用，寿命按屏高自适应 + preprocess 预热填屏）。
# fullscreen=true：整屏均匀发射 + 生命周期内 alpha 渐入渐出（慢速雪/横吹沙用，分布恒定立即满屏）。
func _make_fall(tex: Texture2D, amount: int, life: float, w: float, h: float,
		dir: Vector2, vmin: float, vmax: float, spread: float,
		smin: float, smax: float, col: Color, turb: float, fullscreen: bool) -> GPUParticles2D:
	var margin := 24.0
	var p := GPUParticles2D.new()
	p.texture = tex
	p.amount = amount
	p.lifetime = life
	p.explosiveness = 0.0
	p.randomness = 1.0
	p.local_coords = true
	p.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	p.modulate = col
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.direction = Vector3(dir.x, dir.y, 0.0)
	m.spread = spread
	m.initial_velocity_min = vmin
	m.initial_velocity_max = vmax
	m.gravity = Vector3.ZERO
	m.scale_min = smin
	m.scale_max = smax
	if turb > 0.0:
		m.turbulence_enabled = true
		m.turbulence_noise_strength = turb
		m.turbulence_noise_scale = 1.2
		m.turbulence_influence_min = 0.1
		m.turbulence_influence_max = 0.5
	if fullscreen:
		# 整屏均匀发射，且发射框沿"上游"（速度反向）超出屏幕 ext 像素：
		# 粒子在屏外就淡入、已可见地进入前缘 → 消除前缘（雪的顶部/沙的左侧）淡入稀疏带。
		var ext := 220.0
		var d := dir.normalized()
		p.preprocess = life                                      # 预热：开局即满数量
		p.position = Vector2(w * 0.5 - d.x * ext * 0.5, h * 0.5 - d.y * ext * 0.5)
		m.emission_box_extents = Vector3(w * 0.5 + absf(d.x) * ext * 0.5, h * 0.5 + absf(d.y) * ext * 0.5, 1.0)
		m.color_ramp = _fade_ramp()                              # 渐入渐出掩盖生灭
	else:
		# 顶部发射：寿命按实际屏高自适应，保证最慢粒子(vmin)也能落过底边（写死寿命在高屏上会半空消失）
		var need := (h + margin + 60.0) / maxf(vmin, 1.0)
		p.lifetime = need
		p.preprocess = need                                      # 预热：开局即满屏
		p.position = Vector2(w * 0.5, -margin)                    # 屏幕上方中点
		m.emission_box_extents = Vector3(w * 0.5 + margin, 1.0, 1.0)  # 横跨整屏宽
	p.process_material = m
	return p

# 生命周期 alpha 曲线：0→满→满→0（渐入渐出），供整屏均匀发射掩盖粒子生灭
func _fade_ramp() -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.18, 0.82, 1.0])
	g.colors = [Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)]
	var gt := GradientTexture1D.new()
	gt.gradient = g
	return gt

func _make_rain_tex() -> Texture2D:
	var img := Image.create(2, 10, false, Image.FORMAT_RGBA8)
	for y in 10:
		var a: float = lerp(0.25, 1.0, float(y) / 9.0)   # 上淡下浓（头在下）
		img.set_pixel(0, y, Color(1, 1, 1, a))
		img.set_pixel(1, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)

func _make_snow_tex() -> Texture2D:
	# 3×3 菱形雪花：.X. / XXX / .X.
	var img := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	img.set_pixel(1, 0, Color.WHITE)
	img.set_pixel(0, 1, Color.WHITE)
	img.set_pixel(1, 1, Color.WHITE)
	img.set_pixel(2, 1, Color.WHITE)
	img.set_pixel(1, 2, Color.WHITE)
	return ImageTexture.create_from_image(img)

func _make_sand_tex() -> Texture2D:
	# 6×2 横向沙粒短条：左淡右浓（头在右，随向右吹）
	var img := Image.create(6, 2, false, Image.FORMAT_RGBA8)
	for x in 6:
		var a: float = lerp(0.2, 1.0, float(x) / 5.0)
		img.set_pixel(x, 0, Color(1, 1, 1, a))
		img.set_pixel(x, 1, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)

# ============ 雷暴全屏闪光（_process 驱动）============
func _set_flash(on: bool) -> void:
	_flash_on = on
	_flash.visible = on
	if on:
		_flash_alpha = 0.0
		_flash_timer = 0.0
		_flash_next = randf_range(2.0, 5.0)
	else:
		_flash.color = Color(_flash.color.r, _flash.color.g, _flash.color.b, 0.0)
	set_process(_flash_on)

func _process(delta: float) -> void:
	# 雷暴闪光：偶发骤亮 → 快速衰减（约 0.1s），随机间隔像闪电
	if _flash_on:
		_flash_alpha = maxf(0.0, _flash_alpha - delta * 5.0)
		_flash_timer += delta
		if _flash_timer >= _flash_next:
			_flash_timer = 0.0
			_flash_next = randf_range(2.0, 5.0)
			_flash_alpha = randf_range(0.35, 0.6)
		_flash.color = Color(0.9, 0.95, 1.0, _flash_alpha)

# ============ shader 路径（雾）============
func _show_shader(def) -> void:
	var fx := (str(def.get("fx", "")) if def != null else "")
	if not SHADERS.has(fx):
		_stop_shader()
		return
	var mat := _fx.material as ShaderMaterial
	mat.shader = SHADERS[fx]
	if def != null and def.has("fx_intensity"):
		mat.set_shader_parameter("intensity", float(def["fx_intensity"]))
	_fx.visible = true

func _stop_shader() -> void:
	_fx.visible = false
