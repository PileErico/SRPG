extends RefCounted
## Reaction 触发词代码注册表（决策36）：编辑器/lint/运行时三方单一源。
## DB 专指 json 注册表；本表是引擎能力清单，implemented=false 的词只作未来 schema 占位。

const ENTRIES := {
	"unit_entered_zoc": {
		"id": "unit_entered_zoc", "name": "单位进入控制区", "timing": "post", "implemented": true,
		"context": ["owner", "event.unit", "event.path", "event.kind", "round"],
	},
	"attack_action_finished": {
		"id": "attack_action_finished", "name": "攻击动作结束", "timing": "post", "implemented": false,
		"context": ["owner", "event.actor", "event.target", "event.skill"],
	},
	"attack_resolution_finished": {
		"id": "attack_resolution_finished", "name": "攻击判定结束", "timing": "post", "implemented": false,
		"context": ["owner", "event.actor", "event.target", "event.skill", "event.hit", "event.blocked", "event.critical"],
	},
	"damage_instance_resolved": {
		"id": "damage_instance_resolved", "name": "伤害判定完成", "timing": "post", "implemented": false,
		"context": ["owner", "event.actor", "event.target", "event.damage_amount"],
	},
	"on_kill": {"id": "on_kill", "name": "击杀", "timing": "post", "implemented": false, "context": ["owner", "event.unit"]},
	"on_hit_taken": {"id": "on_hit_taken", "name": "受到命中", "timing": "post", "implemented": false, "context": ["owner", "event.actor"]},
	"on_ally_death_nearby": {"id": "on_ally_death_nearby", "name": "附近友军死亡", "timing": "post", "implemented": false, "context": ["owner", "event.unit"]},
}

static func get_entry(id: String) -> Dictionary:
	return ENTRIES.get(id, {})

static func exists(id: String) -> bool:
	return ENTRIES.has(id)

static func implemented(id: String) -> bool:
	return bool(ENTRIES.get(id, {}).get("implemented", false))

static func options() -> Array:
	var out := []
	for id in ENTRIES:
		var e: Dictionary = ENTRIES[id]
		var suffix := "" if bool(e.get("implemented", false)) else "（未接线）"
		out.append([str(id), "%s %s%s" % [str(e.get("name", id)), str(id), suffix]])
	return out
