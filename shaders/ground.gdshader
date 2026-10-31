shader_type canvas_item;
// Painterly top-down yard ground. Base colour per 25 mm tile from the ground texture
// (linear filtered for soft borders) plus procedural detail at world scale.

uniform sampler2D noise_tex : repeat_enable, filter_linear;
uniform vec2 world_size = vec2(20000.0, 15000.0);
uniform float daylight = 1.0;
uniform float wet = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec2 wp = UV * world_size;
	float n1 = texture(noise_tex, wp / 900.0).r;
	float n2 = texture(noise_tex, wp / 140.0).r;
	float n3 = texture(noise_tex, wp / 23.0).r;
	vec3 col = base.rgb * (0.78 + 0.22 * n1 + 0.12 * n2);
	float grassiness = base.a;  // 1 = grass tile
	// grass blades: thin directional streaks
	float blade = smoothstep(0.55, 0.95, fract(wp.x * 0.11 + n3 * 3.0 + sin(wp.y * 0.07) * 0.6));
	col = mix(col, col * vec3(1.15, 1.25, 1.05), blade * 0.35 * grassiness);
	// grit / pebbles on dirt & paving
	float grit = step(0.985, hash(floor(wp / 6.0)));
	col = mix(col, vec3(0.62, 0.58, 0.52), grit * (1.0 - grassiness) * 0.6);
	col *= mix(0.45, 1.0, daylight);
	col = mix(col, col * vec3(0.75, 0.82, 0.95), wet * 0.5);
	COLOR = vec4(col, 1.0);
}
