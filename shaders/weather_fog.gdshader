shader_type canvas_item;
// 程序化雾（屏幕空间）：大尺度【平滑】FBM 噪声的柔和浓淡，缓慢飘移的雾岸。无循环、零 CPU（内置 TIME）。
// ⚠️雾是唯一"本该柔和"的天气：不做像素量化/阈值/alpha 分档——那些会把噪声切成有边界的团块＝"怪形状"，就不像雾了。
// 挂 WeatherVFX 的 ColorRect；参数由 EnvDB(environment.json) 经 GDScript 写入。见 WeatherVFX.gd。

uniform float intensity : hint_range(0.0, 1.0) = 0.6;   // 浓度总控（薄雾↔浓雾，非全遮）
uniform vec4  fog_color : source_color = vec4(0.82, 0.86, 0.90, 1.0);

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 5; i++) {   // 多倍频 → 更绵密柔和的雾质
		s += amp * vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return s;
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float aspect = res.x / max(res.y, 1.0);
	vec2 uv = UV;
	uv.x *= aspect;
	float t = TIME;

	// 两层大尺度平滑噪声，缓慢反向飘移 → 柔和无定形的雾岸浓淡（无阈值/无量化 = 无硬边形状）
	vec2 p = uv * 1.5;
	float f = fbm(p + vec2(t * 0.04, t * 0.012));
	f = mix(f, fbm(p * 1.6 - vec2(t * 0.025, 0.0)), 0.5);

	float d = 0.6 + 0.4 * f;                 // 平滑浓淡，处处有雾（无透明洞、无团块边界）
	float a = d * intensity * 0.55;          // 例：intensity=0.6 → alpha ≈ 0.20~0.33（半透，战场仍可见）

	COLOR = vec4(fog_color.rgb, fog_color.a * a);
}
