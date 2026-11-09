shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform sampler2D pixel_texture : source_color, filter_nearest, repeat_enable;
uniform vec4 palette_dark : source_color = vec4(0.15, 0.20, 0.10, 1.0);
uniform vec4 palette_mid : source_color = vec4(0.35, 0.45, 0.20, 1.0);
uniform vec4 palette_light : source_color = vec4(0.55, 0.65, 0.30, 1.0);
uniform float texels_per_unit : hint_range(2.0, 32.0, 1.0) = 16.0;
uniform bool use_mesh_uv = false;

varying vec3 surface_world_position;
varying vec3 surface_world_normal;

void vertex() {
	surface_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	surface_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	// 模型面使用以世界单位计的局部UV；地形使用世界主轴投影。
	// 两条路径共享纹素密度，不随物件尺寸或镜头变化。
	vec3 n = abs(normalize(surface_world_normal));
	vec2 plane;
	if (use_mesh_uv) {
		plane = UV;
	} else if (n.y >= n.x && n.y >= n.z) {
		plane = surface_world_position.xz;
	} else if (n.x >= n.z) {
		plane = surface_world_position.zy;
	} else {
		plane = surface_world_position.xy;
	}
	vec2 uv = plane * texels_per_unit / vec2(textureSize(pixel_texture, 0));
	vec3 sampled = texture(pixel_texture, uv).rgb;
	float dark_distance = distance(sampled, palette_dark.rgb);
	float mid_distance = distance(sampled, palette_mid.rgb);
	float light_distance = distance(sampled, palette_light.rgb);
	float index = dark_distance < mid_distance ? 0.0 : 1.0;
	if (light_distance < min(dark_distance, mid_distance)) { index = 2.0; }
	// 固定的像素画明暗：背光面降一档，始终只从该材质的三个颜色取色。
	float facing = dot(normalize(surface_world_normal), normalize(vec3(-0.6, 0.8, 0.45)));
	if (facing < 0.25) { index = max(0.0, index - 1.0); }
	ALBEDO = index < 0.5 ? palette_dark.rgb : (index < 1.5 ? palette_mid.rgb : palette_light.rgb);
}
