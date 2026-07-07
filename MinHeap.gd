extends RefCounted
## 最小二叉堆（寻路优先队列）——BattleState._dijkstra / Overworld.find_path 共用（DB 范式外的轻量容器，无 class_name）。
## 无 decrease-key：同格降本直接再 push，调用方 pop 后比对「弹出成本 > 当前最优」即弃（懒删除）。
## 用法：const MinHeap := preload("res://MinHeap.gd") → var h = MinHeap.new(); h.push(cost, cell); var e = h.pop()  # e=[cost, value]，空堆=[]

var _a: Array = []   # 元素 = [cost:int, value:Variant]

func is_empty() -> bool:
	return _a.is_empty()

func push(cost: int, value) -> void:
	_a.append([cost, value])
	var i := _a.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if int(_a[p][0]) <= int(_a[i][0]):
			break
		var t = _a[p]
		_a[p] = _a[i]
		_a[i] = t
		i = p

func pop() -> Array:
	if _a.is_empty():
		return []
	var top: Array = _a[0]
	var last: Array = _a.pop_back()
	if not _a.is_empty():
		_a[0] = last
		var i := 0
		var n := _a.size()
		while true:
			var l := i * 2 + 1
			var m := i
			if l < n and int(_a[l][0]) < int(_a[m][0]):
				m = l
			if l + 1 < n and int(_a[l + 1][0]) < int(_a[m][0]):
				m = l + 1
			if m == i:
				break
			var t = _a[m]
			_a[m] = _a[i]
			_a[i] = t
			i = m
	return top
