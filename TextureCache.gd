extends RefCounted
## 纹理加载 + 缓存单一入口（仿 *DB：preload + 静态变量伪单例，不用 class_name）。
## 取代原先散在 SandboxCanvas/EditorCanvas/TurnOrderBar/UnitStatusPanel/ItemEditor
## 各自一份几乎相同的「优先已导入资源 → 否则直读原图兜底 → 缓存」逻辑。
## 缓存是静态的 → 跨实例/跨场景共享，同一图标只解码一次。
##
## 用法：const TextureCache := preload("res://TextureCache.gd") → TextureCache.get_tex(path)

static var _cache := {}

# 按路径取纹理：优先已导入资源(load)，否则直读原图(Image.load，免依赖编辑器导入流程)。
# 结果（含 null）进缓存，避免对缺失/坏路径反复尝试。空路径直接返回 null。
static func get_tex(path: String) -> Texture2D:
	if path == "":
		return null
	if _cache.has(path):
		return _cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var t = load(path)
		if t is Texture2D:
			tex = t
	if tex == null and FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == OK:
			tex = ImageTexture.create_from_image(img)
	_cache[path] = tex
	return tex

# 强制从原始文件解码（Image.load，忽略已导入 .ctex 资源）——运行期会被覆写的图（工坊瓦片）用它，
# 免 load() 命中旧 .ctex 返回陈图（编辑变体后仍显旧图的坑）。独立缓存键（"f:" 前缀），clear() 一并清。
static func get_tex_file(path: String) -> Texture2D:
	if path == "":
		return null
	var key := "f:" + path
	if _cache.has(key):
		return _cache[key]
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == OK:
			tex = ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex

# 清空缓存（如需在换关/换套图后强制重载可调；平时无需）。
static func clear() -> void:
	_cache.clear()
