extends PanelContainer
## 物品槽：持有 item 定义；悬停时用 tooltip_builder 自建“富 tooltip”
## （名称/标签/数值 + 技能图标/名称/标签/数值）——纯文字 tooltip 放不了图标，故走 _make_custom_tooltip。
## 空槽 item=null → 不出 tooltip。
## 拖拽（装备穿卸交互用，通用无策略）：drag_payload 非空＝可拖出（内容由宿主定义，如 {kind,slot,iuid}）；
## can_drop/on_drop 回调＝本槽作为拖放目标的判定与执行——策略全在宿主（UnitStatusPanel 等），本类只做管道。

var item = null
var tooltip_builder := Callable()

var drag_payload = null        # 非空 → _get_drag_data 返回它（拖拽预览＝本槽图标截图）
var can_drop := Callable()     # Callable(payload) -> bool；无效＝不接受任何拖放
var on_drop := Callable()      # Callable(payload) -> void

func _make_custom_tooltip(_for_text):
	if item == null or not tooltip_builder.is_valid():
		return null
	return tooltip_builder.call(item)

func _get_drag_data(_pos):
	if drag_payload == null:
		return null
	var preview := Control.new()   # 预览挂中心锚点小容器：图标跟手心
	var ic := TextureRect.new()
	for c in get_children():
		if c is TextureRect and c.texture != null:
			ic.texture = c.texture
			break
	if ic.texture != null:
		ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.custom_minimum_size = Vector2(40, 40)
		ic.size = Vector2(40, 40)
		ic.position = -ic.size / 2
		ic.modulate = Color(1, 1, 1, 0.85)
		preview.add_child(ic)
	set_drag_preview(preview)
	return drag_payload

func _can_drop_data(_pos, data) -> bool:
	return can_drop.is_valid() and bool(can_drop.call(data))

func _drop_data(_pos, data) -> void:
	if on_drop.is_valid():
		on_drop.call(data)
