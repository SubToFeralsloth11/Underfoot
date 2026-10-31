shader_type canvas_item;
// Ant batch: per instance transform = translation only.
// INSTANCE_CUSTOM: x = caste + 8 * faction, y = heading (rad), zw = pos - prev (mm).
// COLOR: carried item colour (alpha 0 = nothing).
// Rendering interpolates between ticks: offset = -(pos - prev) * (1 - alpha).

uniform sampler2D atlas : filter_nearest;
uniform float alpha = 1.0;
uniform float anim_time = 0.0;
uniform float sizes[8];
uniform vec4 tints[16];
uniform float px_scale = 1.0;

varying vec2 local_uv;
varying vec4 tint;
varying vec4 carry_col;

void vertex() {
	float code = INSTANCE_CUSTOM.x;
	float faction = floor(code / 8.0);
	float caste = code - faction * 8.0;
	float sz = sizes[int(caste)] * 1.45 * px_scale;
	float a = INSTANCE_CUSTOM.y;
	vec2 v = VERTEX * sz;
	v = vec2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a));
	v -= INSTANCE_CUSTOM.zw * (1.0 - alpha);
	VERTEX = v;
	float moving = step(0.01, length(INSTANCE_CUSTOM.zw));
	float frame = mod(floor(anim_time * 10.0 + float(INSTANCE_ID) * 0.37), 2.0) * moving;
	local_uv = UV;
	UV = vec2((UV.x + frame) * 0.5, (UV.y + caste) / 8.0);
	tint = tints[int(code)];
	carry_col = COLOR;
}

void fragment() {
	vec4 m = texture(atlas, UV);
	vec4 c = vec4(m.rgb * tint.rgb, m.a * tint.a);
	if (carry_col.a > 0.0) {
		float d = distance(local_uv, vec2(0.98, 0.5));
		if (d < 0.2) {
			c = vec4(carry_col.rgb, 1.0);
		}
	}
	COLOR = c;
}
