extends SceneTree
## 通用截图 harness：窗口模式跑任意场景 → 等若干帧（布局+首绘就绪）→ 存 PNG → 退出。
## 用途：headless 跑不出画面，AI 协作改 UI/美术时靠它自动验收画面效果；跨窗口/跨内容通用（编辑器/战斗/大地图/物品编辑器都能截）。
## ⚠️ 刻意不加 --headless（headless 无渲染，截出来是空的）。工程无关，可整份拷去别的 Godot 项目复用。
##
## 运行（注意 -- 之后才是本工具参数）：
##   ..._console.exe --path "D:/1战棋" -s res://tools/screenshot.gd -- --scene=res://MapEditor.tscn --out=user://shots/editor.png
## 参数（key=value，-- 之后）：
##   scene   必填，res://Xxx.tscn
##   out     输出 PNG（默认 user://screenshot.png；user://res:// 会 globalize 成绝对路径）
##   w / h   窗口尺寸（默认 1600×900）
##   frames  截图前等待帧数（默认 12；UI 有动画/延迟布局时调大）
##   setup   可选，调实例上的一个无参方法名（如给场景喂测试数据）
##   call/arg 可选，调实例方法（带一个字符串参）——如 --call=_shell_load --arg=spear_set_stance 定位编辑器条目
##   scroll  可选，bottom＝全部 ScrollContainer 滚到底（目检表单下半区）
## 输出：stdout 打印 "SHOT: <绝对路径> (err=0 ...)"；退出码 0=成功。

func _initialize() -> void:
	var args := _parse_args()
	var scene_path := str(args.get("scene", ""))
	if scene_path == "":
		push_error("[screenshot] 缺 --scene=res://Xxx.tscn")
		quit(1)
		return
	var out_path := str(args.get("out", "user://screenshot.png"))
	var w := int(args.get("w", "1600"))
	var h := int(args.get("h", "900"))
	var frames := maxi(2, int(args.get("frames", "12")))
	var packed = load(scene_path)
	if packed == null or not (packed is PackedScene):
		push_error("[screenshot] 场景加载失败：%s" % scene_path)
		quit(1)
		return
	get_root().size = Vector2i(w, h)
	DisplayServer.window_set_size(Vector2i(w, h))
	var inst = (packed as PackedScene).instantiate()
	get_root().add_child(inst)
	# 可选 setup 钩子（喂测试数据/切状态）——_ready 是延迟的，等一帧再调
	await process_frame
	var setup := str(args.get("setup", ""))
	if setup != "" and inst.has_method(setup):
		inst.call(setup)
	# 可选 load 钩子：若场景有 load_from_file(path)（如地图编辑器），先载入指定地图再截
	var load_path := str(args.get("load", ""))
	if load_path != "" and inst.has_method("load_from_file"):
		inst.call("load_from_file", load_path)
	# 可选 call 钩子：调实例方法（带一个字符串参数）——定位编辑器条目等
	var callm := str(args.get("call", ""))
	if callm != "" and inst.has_method(callm):
		if args.has("arg"):
			inst.call(callm, str(args.get("arg", "")))
		else:
			inst.call(callm)
	# 等待若干帧：确保容器布局稳定 + Control._draw 至少跑过一次
	for i in frames:
		await process_frame
	if str(args.get("scroll", "")) == "bottom":   # 滚到底再补几帧（滚动条重布局）
		_scroll_bottom(get_root())
		for i in 3:
			await process_frame
	var img := get_root().get_texture().get_image()
	if img == null:
		push_error("[screenshot] 取不到 viewport image")
		quit(1)
		return
	var abs_out := ProjectSettings.globalize_path(out_path) if (out_path.begins_with("user://") or out_path.begins_with("res://")) else out_path
	var base_dir := abs_out.get_base_dir()
	if base_dir != "":
		DirAccess.make_dir_recursive_absolute(base_dir)
	var err := img.save_png(abs_out)
	print("SHOT: %s (err=%d, %dx%d)" % [abs_out, err, img.get_width(), img.get_height()])
	quit(0 if err == OK else 1)

func _scroll_bottom(n: Node) -> void:
	if n is ScrollContainer:
		(n as ScrollContainer).scroll_vertical = 999999
	for c in n.get_children():
		_scroll_bottom(c)

# -- 之后的 --key=value → {key: value}
func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", false, 1)
		if kv.size() == 2:
			out[kv[0]] = kv[1]
	return out
