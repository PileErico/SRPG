extends RefCounted
## 有序河格路径 -> 连续河中心线。共边中点与共边法线同时决定跨格连接。
## 普通弯道用圆弧近似，桥格另留穿过格心的短直段；不依赖固定世界轴。

const HexGrid := preload("res://HexGrid.gd")
const SAMPLE_STEP := 0.06
const END_EXTENSION := 0.35
const BRIDGE_STRAIGHT_HALF := 0.22


static func build(path: Array, centers: Dictionary, source: Vector2i,
		outlet: Vector2i, bridge_cell: Vector2i) -> Dictionary:
	assert(not path.is_empty(), "A river needs at least one region")
	assert(centers.has(source) and centers.has(outlet), "River endpoints need world positions")
	var line := PackedVector2Array()
	var profiles: Dictionary = {}
	var bridge_position := Vector2.ZERO
	var bridge_axis := Vector2.RIGHT
	for i in range(path.size()):
		var cell: Vector2i = path[i]
		var previous: Vector2i = path[i - 1] if i > 0 else source
		var next: Vector2i = path[i + 1] if i + 1 < path.size() else outlet
		assert(HexGrid.adjacent(previous, cell) and HexGrid.adjacent(cell, next),
			"River regions must share edges")
		assert(previous != next, "A river cannot reverse through its entrance")
		var center: Vector2 = centers[cell]
		var incoming := (center - Vector2(centers[previous])).normalized()
		var outgoing := (Vector2(centers[next]) - center).normalized()
		var entry := (center + Vector2(centers[previous])) * 0.5
		var leave := (center + Vector2(centers[next])) * 0.5
		var turn := absf(incoming.angle_to(outgoing))
		var kind := "straight" if turn < 0.01 else ("bend" if turn < PI * 0.5 else "sharp")
		profiles[cell] = {"entry": previous, "exit": next, "kind": kind,
			"entry_point": entry, "exit_point": leave,
			"incoming": incoming, "outgoing": outgoing}
		if i == 0:
			_append_line(line, entry - incoming * END_EXTENSION, entry)
		if cell == bridge_cell:
			var along := (incoming + outgoing).normalized()
			bridge_position = center
			bridge_axis = Vector2(along.y, -along.x)
			var before := center - along * BRIDGE_STRAIGHT_HALF
			var after := center + along * BRIDGE_STRAIGHT_HALF
			_append_curve(line, entry, incoming, before, along, entry.distance_to(before) / 3.0)
			_append_line(line, before, after)
			_append_curve(line, after, along, leave, outgoing, after.distance_to(leave) / 3.0)
		else:
			# 圆弧的三次近似：相邻边对应 120° 转弯，隔一边对应 60° 转弯。
			# 半径最小为 0.5，仍可容纳半宽 0.4 的河槽。
			var chord := entry.distance_to(leave)
			var handle := chord / 3.0
			if turn > 0.01:
				var radius := chord / (2.0 * sin(turn * 0.5))
				handle = 4.0 * radius / 3.0 * tan(turn * 0.25)
			_append_curve(line, entry, incoming, leave, outgoing, handle)
		if i + 1 == path.size():
			_append_line(line, leave, leave + outgoing * END_EXTENSION)
	return {"line": line, "profiles": profiles,
		"bridge_position": bridge_position, "bridge_axis": bridge_axis}


static func _append_curve(line: PackedVector2Array, a: Vector2, direction_a: Vector2,
		b: Vector2, direction_b: Vector2, handle: float) -> void:
	var control_a := a + direction_a * handle
	var control_b := b - direction_b * handle
	# 控制多边形长度是曲线长度的上界，采样间隔因此不超过目标步长。
	var length_bound := a.distance_to(control_a) + control_a.distance_to(control_b) + control_b.distance_to(b)
	var steps := maxi(1, ceili(length_bound / SAMPLE_STEP))
	_append_point(line, a)
	for step in range(1, steps + 1):
		_append_point(line, a.bezier_interpolate(control_a, control_b, b, float(step) / float(steps)))


static func _append_line(line: PackedVector2Array, a: Vector2, b: Vector2) -> void:
	var steps := maxi(1, ceili(a.distance_to(b) / SAMPLE_STEP))
	_append_point(line, a)
	for step in range(1, steps + 1):
		_append_point(line, a.lerp(b, float(step) / float(steps)))


static func _append_point(line: PackedVector2Array, point: Vector2) -> void:
	if line.is_empty() or line[-1].distance_squared_to(point) > 0.0000000001:
		line.append(point)
