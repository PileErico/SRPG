extends PanelContainer
## 物品槽：持有 item 定义；悬停时用 tooltip_builder 自建“富 tooltip”
## （名称/标签/数值 + 技能图标/名称/标签/数值）——纯文字 tooltip 放不了图标，故走 _make_custom_tooltip。
## 空槽 item=null → 不出 tooltip。

var item = null
var tooltip_builder := Callable()

func _make_custom_tooltip(_for_text):
	if item == null or not tooltip_builder.is_valid():
		return null
	return tooltip_builder.call(item)
