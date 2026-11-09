shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_inverted, shadows_disabled;

uniform sampler2D sprite_texture : source_color, filter_nearest, repeat_disable;
uniform vec4 outline_color : source_color = vec4(0.35, 0.75, 1.0, 1.0);

void vertex() {
	// 与主精灵的完整 billboard 一致，脚点始终落在原来的格子上。
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	// 略靠近镜头，避免把主精灵自己的深度误当成遮挡物。
	MODELVIEW_MATRIX[3].z += 0.003;
}

void fragment() {
	float center = texture(sprite_texture, UV).a;
	if (center < 0.5) {
		discard;
	}
	vec2 pixel = 1.0 / vec2(textureSize(sprite_texture, 0));
	float inside = 1.0;
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			inside = min(inside, texture(sprite_texture, UV + vec2(float(x), float(y)) * pixel).a);
		}
	}
	if (inside > 0.5) {
		discard;
	}
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
