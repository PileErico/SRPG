shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform sampler2D grass_texture : source_color, filter_nearest, repeat_enable;
uniform sampler2D stone_texture : source_color, filter_nearest, repeat_enable;
uniform vec4 grass_dark : source_color;
uniform vec4 grass_mid : source_color;
uniform vec4 grass_light : source_color;
uniform vec4 stone_dark : source_color;
uniform vec4 stone_mid : source_color;
uniform vec4 stone_light : source_color;
uniform float texels_per_unit : hint_range(2.0, 32.0, 1.0) = 16.0;
uniform float rock_start : hint_range(0.0, 4.0, 0.01) = 0.50;
uniform float rock_full : hint_range(0.0, 4.0, 0.01) = 0.90;
uniform float cluster_texels : hint_range(2.0, 32.0, 1.0) = 8.0;
uniform vec3 shade_direction = vec3(-0.6, 0.8, 0.45);
uniform float shadow_threshold : hint_range(-1.0, 1.0, 0.01) = 0.70;
uniform float highlight_threshold : hint_range(-1.0, 1.0, 0.01) = 0.88;

varying vec3 relief_world_position;
varying vec3 relief_world_normal;

void vertex() {
	relief_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	relief_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

float cluster_hash(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

float cluster_threshold(vec2 texel) {
	// 只对覆盖率做连续插值；颜色始终在草与石之间择一，不混合 RGB。
	// 先量化到世界像素，再以半单位左右的色簇形成连片岩块，避免散点噪声。
	vec2 p = (floor(texel) + vec2(0.5)) / max(cluster_texels, 1.0);
	vec2 cell = floor(p);
	vec2 part = fract(p);
	vec2 weight = part * part * (vec2(3.0) - 2.0 * part);
	float bottom = mix(cluster_hash(cell), cluster_hash(cell + vec2(1.0, 0.0)), weight.x);
	float top = mix(cluster_hash(cell + vec2(0.0, 1.0)), cluster_hash(cell + vec2(1.0, 1.0)), weight.x);
	return 0.02 + 0.96 * mix(bottom, top, weight.y);
}

float palette_index(vec3 sampled, vec3 dark_color, vec3 mid_color, vec3 light_color) {
	float dark_distance = distance(sampled, dark_color);
	float mid_distance = distance(sampled, mid_color);
	float light_distance = distance(sampled, light_color);
	float index = dark_distance < mid_distance ? 0.0 : 1.0;
	if (light_distance < min(dark_distance, mid_distance)) {
		index = 2.0;
	}
	return index;
}

void fragment() {
	vec3 normal = normalize(relief_world_normal);
	vec3 axis = abs(normal);
	vec2 plane;
	if (axis.y >= axis.x && axis.y >= axis.z) {
		plane = relief_world_position.xz;
	} else if (axis.x >= axis.z) {
		plane = relief_world_position.zy;
	} else {
		plane = relief_world_position.xy;
	}
	vec2 uv = plane * texels_per_unit / vec2(textureSize(grass_texture, 0));
	float coverage = smoothstep(rock_start, max(rock_full, rock_start + 0.001), relief_world_position.y);
	bool is_rock = coverage >= cluster_threshold(relief_world_position.xz * texels_per_unit);
	vec3 dark_color = is_rock ? stone_dark.rgb : grass_dark.rgb;
	vec3 mid_color = is_rock ? stone_mid.rgb : grass_mid.rgb;
	vec3 light_color = is_rock ? stone_light.rgb : grass_light.rgb;
	vec3 sampled = is_rock ? texture(stone_texture, uv).rgb : texture(grass_texture, uv).rgb;
	float index = palette_index(sampled, dark_color, mid_color, light_color);
	// 水平面保持主色；背坡降一档，草坡迎光升一档；岩体用纹理亮色保留简洁面。
	float facing = dot(normal, normalize(shade_direction));
	if (facing < shadow_threshold) {
		index = max(0.0, index - 1.0);
	} else if (!is_rock && facing > highlight_threshold) {
		index = min(2.0, index + 1.0);
	}
	ALBEDO = index < 0.5 ? dark_color : (index < 1.5 ? mid_color : light_color);
}
