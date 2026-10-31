shader_type canvas_item;
// Side-on grid renderer for nests and the house.
// Data texture (nearest): R = soil index / 255, G = solidity, B = chamber/room id, A = flags
//   flags: bit0 dig mark, bit1 seal door, bit2 flooded, bit3 mould.
// Solid cells get a procedural 16 px-style texture per soil; edges facing open cells
// are darkened and rimmed (edge blending).

uniform sampler2D data : filter_nearest;
uniform sampler2D noise_tex : repeat_enable, filter_linear;
uniform vec2 grid_size;
uniform float cell_px = 4.0;
uniform vec4 soil_colors[16];
uniform vec4 chamber_colors[16];
uniform vec4 open_color : source_color = vec4(0.11, 0.07, 0.045, 1.0);
uniform float is_house = 0.0;
uniform float time = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec4 cell(vec2 c) {
	return texture(data, (c + 0.5) / grid_size);
}

void fragment() {
	vec2 gp = UV * grid_size;
	vec2 c = floor(gp);
	vec2 f = fract(gp);
	vec4 d = cell(c);
	int soil = int(d.r * 255.0 + 0.5);
	float solid = d.g;
	int flags = int(d.a * 255.0 + 0.5);
	int chamber = int(d.b * 255.0 + 0.5);
	vec2 world_px = gp * cell_px;
	vec3 col;
	if (solid > 0.0) {
		vec3 base = soil_colors[soil].rgb;
		float n = texture(noise_tex, world_px / 64.0).r;
		float grain = hash(floor(world_px / 2.0));
		float pebbles = step(0.93, hash(floor(world_px / 5.0) + float(soil)));
		col = base * (0.82 + 0.3 * n + 0.08 * grain);
		col = mix(col, base * 1.25, pebbles * 0.5);
		if (soil == 7) { // root fibres
			col = mix(col, vec3(0.75, 0.6, 0.4), step(0.6, sin(world_px.x * 0.8 + world_px.y * 0.3) * 0.5 + 0.5) * 0.3);
		}
		if (is_house > 0.5) {
			col = base * (0.92 + 0.08 * n);
			if (soil == 15) { // brick courses
				float row = floor(world_px.y / 6.0);
				float bx = fract((world_px.x + mod(row, 2.0) * 6.0) / 12.0);
				float by = fract(world_px.y / 6.0);
				col *= (bx < 0.08 || by < 0.12) ? 0.7 : 1.0;
			}
			if (soil == 13) { // timber grain
				col *= 0.9 + 0.1 * sin(world_px.y * 1.7 + n * 6.0);
			}
		}
		// partially dug: lighter, crumbly
		col = mix(col * 1.35, col, solid);
		// edge darkening toward open neighbours
		float open_n = 0.0;
		open_n += step(cell(c + vec2(1, 0)).g, 0.0) * smoothstep(0.6, 1.0, f.x);
		open_n += step(cell(c + vec2(-1, 0)).g, 0.0) * smoothstep(0.4, 0.0, f.x);
		open_n += step(cell(c + vec2(0, 1)).g, 0.0) * smoothstep(0.6, 1.0, f.y);
		open_n += step(cell(c + vec2(0, -1)).g, 0.0) * smoothstep(0.4, 0.0, f.y);
		col *= 1.0 - 0.35 * clamp(open_n, 0.0, 1.0);
	} else {
		col = open_color.rgb;
		if (is_house > 0.5 && chamber > 0) {
			col = chamber_colors[chamber % 16].rgb * (0.85 + 0.1 * texture(noise_tex, world_px / 128.0).r);
		} else if (chamber > 0) {
			col = mix(col, chamber_colors[chamber % 16].rgb, 0.22);
		}
		// ambient occlusion from solid neighbours
		float ao = 0.0;
		ao += step(0.001, cell(c + vec2(1, 0)).g) * smoothstep(0.5, 1.0, f.x);
		ao += step(0.001, cell(c + vec2(-1, 0)).g) * smoothstep(0.5, 0.0, f.x);
		ao += step(0.001, cell(c + vec2(0, 1)).g) * smoothstep(0.5, 1.0, f.y);
		ao += step(0.001, cell(c + vec2(0, -1)).g) * smoothstep(0.5, 0.0, f.y);
		col *= 1.0 - 0.25 * clamp(ao, 0.0, 1.0) * (1.0 - is_house * 0.7);
		if ((flags & 4) != 0) {
			col = mix(col, vec3(0.2, 0.4, 0.65), 0.6 + 0.1 * sin(time * 2.0 + world_px.x * 0.2));
		}
	}
	if ((flags & 1) != 0) {
		float stripe = step(0.5, fract((world_px.x + world_px.y) / 6.0));
		col = mix(col, vec3(1.0, 0.82, 0.3), 0.35 * stripe + 0.1);
	}
	if ((flags & 2) != 0) {
		col = mix(col, vec3(0.66, 0.41, 0.25), 0.8);
	}
	if ((flags & 8) != 0) {
		col = mix(col, vec3(0.55, 0.75, 0.45), 0.35 * hash(floor(world_px / 1.5)));
	}
	COLOR = vec4(col, 1.0);
}
