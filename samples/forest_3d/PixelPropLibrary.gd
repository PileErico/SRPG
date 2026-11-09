extends RefCounted
## 新道具的制作记录与工厂；占格和碰撞由场景消费，模型仅提供视觉。

const Well := preload("res://samples/forest_3d/PixelWell.gd")
const Roadside := preload("res://samples/forest_3d/PixelRoadsideProps.gd")
const SPECS := {
	"well": {
		"label": "水井", "footprint": [Vector2i.ZERO], "destructible": false,
		"bounds": Vector3(1.4375, 1.6875, 1.25), "shadow": Vector2(1.48, 1.36),
		"materials": ["stone_brick", "wood", "dark", "cutwood"],
		"source": "res://samples/forest_3d/PixelWell.gd",
	},
	"barrels": {
		"label": "木桶", "footprint": [Vector2i.ZERO], "destructible": false,
		"bounds": Vector3(1.224, 0.92, 0.844), "shadow": Vector2(1.30, 0.94),
		"materials": ["wood", "iron", "cutwood"],
		"source": "res://samples/forest_3d/PixelRoadsideProps.gd",
	},
	"signpost": {
		"label": "路牌", "footprint": [Vector2i.ZERO], "destructible": false,
		"bounds": Vector3(1.20, 1.30, 0.24), "shadow": Vector2(0.40, 0.36),
		"materials": ["bark", "wood"],
		"source": "res://samples/forest_3d/PixelRoadsideProps.gd",
	},
}

static func make_model(kind: String) -> Node3D:
	match kind:
		"well": return Well.make_model()
		"barrels": return Roadside.make_barrels()
		"signpost": return Roadside.make_signpost()
	push_error("Unknown pixel prop: " + kind)
	return Node3D.new()
