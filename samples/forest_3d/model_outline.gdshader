shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float outline_pixels : hint_range(0.0, 8.0, 0.25) = 3.0;

void vertex() {
	vec4 view_position = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 view_normal = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	vec4 clip_position = PROJECTION_MATRIX * view_position;
	// 用每像素对应的视空间长度做真实 XYZ 外扩：深度也沿法线变化。
	// 不把法线的 XY 分量强行归一，避免近乎正对镜头的面被横向拉出。
	float units_per_pixel = 2.0 * abs(clip_position.w)
		/ max(abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y, 0.0001);
	view_position.xyz += view_normal * units_per_pixel * outline_pixels;
	POSITION = PROJECTION_MATRIX * view_position;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
