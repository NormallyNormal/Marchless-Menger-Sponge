shader_type spatial;

uniform int hole_iterations : hint_range(1, 8) = 6;
uniform int cut_iterations : hint_range(1, 4) = 4;
uniform float hole_depth : hint_range(0.1, 5.0) = 1.0;
uniform vec3 surface_color : source_color = vec3(1.0);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.5;
uniform bool orthographic = false;
uniform float level_of_detail : hint_range(1.0, 10.0) = 4.0;

varying vec3 original_normal;
varying float hole_fade;
varying vec3 interior_albedo;

const float POW3[7] = {1.0, 3.0, 9.0, 27.0, 81.0, 243.0, 729.0};
const float INV_POW3[7] = {1.0, 0.333333333, 0.111111111, 0.037037037, 0.012345679, 0.004115226, 0.001371742};

int check_hole(vec2 uv, out vec2 local_uv, out float current_scale, int max_iterations, int maxsuperhole, out bool corner, bool was_corner) {
	vec2 p = uv;

	int largest_hole = 0;
	vec2 largest_local_uv;
	float largest_scale;

	for (int i = 1; i <= maxsuperhole; i++) {
		if (was_corner && i == 2) continue;

		float inv_scale = INV_POW3[i];
		vec2 local = fract(p * inv_scale);
		vec2 cell3 = floor(local * 3.0);

		if (cell3.x == 1.0 || cell3.y == 1.0) {
			largest_local_uv = fract(local * 3.0);
			largest_scale = INV_POW3[i - 1];
			largest_hole = -i;
		}
	}

	if (largest_hole < 0) {
		local_uv = largest_local_uv;
		current_scale = largest_scale;
		return largest_hole;
	}

	corner = false;
	bool was_corner_last = false;

	for (int i = 0; i < max_iterations; i++) {
		vec2 p3 = p * 3.0;
		vec2 cell = floor(p3);

		if (cell.x == 1.0 && cell.y == 1.0) {
			corner = was_corner_last;
			local_uv = fract(p3);
			current_scale = INV_POW3[i + 1];
			return i + 1;
		}

		vec2 centered = abs(p - 0.5);
		was_corner_last = centered.x > 0.166666667 && centered.y > 0.166666667;

		p = p3 - cell;
	}
	return 0;
}

vec3 ray_box_interior(vec2 hole_uv, vec3 view_dir, float depth, float depth_stretch,
					  out vec2 face_uv, out int face_id, out float z_depth, out float ray_length) {
	vec2 pos = hole_uv * 2.0 - 1.0;
	vec3 ro = vec3(pos, 0.0);
	vec3 rd = normalize(view_dir);

	float scaled_depth = depth * depth_stretch;

	vec3 inv_rd = 1.0 / rd;
	vec3 t1 = vec3(-1.0, -1.0, -scaled_depth) * inv_rd - ro * inv_rd;
	vec3 t2 = vec3(1.0, 1.0, 0.0) * inv_rd - ro * inv_rd;

	vec3 t_far = max(t1, t2);
	float t = min(min(t_far.x, t_far.y), t_far.z);
	ray_length = abs(t);

	vec3 hit = ro + rd * t;
	float inv_depth = 1.0 / depth;
	float inv_scaled_depth = 1.0 / scaled_depth;

	z_depth = -hit.z * inv_scaled_depth;

	vec3 abs_hit = abs(hit);
	float eps = 0.001;

	if (abs(hit.z + scaled_depth) < eps) {
		face_id = 0;
		face_uv = vec2(0.0);
		return vec3(0.0);
	}

	float neg_z_scaled = -hit.z * inv_depth;

	if (abs_hit.y > abs_hit.x) {
		face_uv = vec2((hit.x + 1.0) * 0.5, neg_z_scaled);
		if (hit.y > 0.0) {
			face_id = 4;
			return vec3(0.0, 1.0, 0.0);
		} else {
			face_id = 3;
			return vec3(0.0, -1.0, 0.0);
		}
	} else {
		face_uv = vec2(neg_z_scaled, (hit.y + 1.0) * 0.5);
		if (hit.x < 0.0) {
			face_id = 2;
			return vec3(1.0, 0.0, 0.0);
		} else {
			face_id = 1;
			return vec3(-1.0, 0.0, 0.0);
		}
	}
}

float calculate_ao(vec2 face_uv, float z_depth, int face_id) {
	if (any(lessThan(face_uv, vec2(0.0))) || any(greaterThan(face_uv, vec2(1.0)))) {
		return 1.0;
	}

	vec2 edge_dist = min(face_uv, 1.0 - face_uv);

	float adjacent_edge, depth_edge;
	if (face_id == 1 || face_id == 2) {
		adjacent_edge = edge_dist.y;
		depth_edge = edge_dist.x;
	} else {
		adjacent_edge = edge_dist.x;
		depth_edge = edge_dist.y;
	}

	float ao = smoothstep(0.0, 0.25, adjacent_edge);
	float entrance_exit_factor = smoothstep(0.0, 0.3, depth_edge);
	ao = mix(1.0, ao, entrance_exit_factor);
	ao *= mix(1.0, 0.7, z_depth);

	return ao;
}

void fragment() {
	hole_fade = 0.0;
	ALBEDO = surface_color;
	original_normal = NORMAL;

	vec4 clip_pos = PROJECTION_MATRIX * vec4(VERTEX, 1.0);
	DEPTH = clip_pos.z / clip_pos.w;

	vec3 view_dir;
	if (orthographic) {
		vec3 cam_forward = normalize(INV_VIEW_MATRIX[2].xyz);
		view_dir = normalize((VIEW_MATRIX * vec4(cam_forward, 0.0)).xyz);
	} else {
		view_dir = normalize(VIEW);
	}

	vec2 local_uv;
	float current_scale;
	bool is_corner = false;

	int level = check_hole(UV, local_uv, current_scale, hole_iterations, 0, is_corner, false);

	if (level != 0) {
		float uv_detail = fwidth(UV.x) + fwidth(UV.y);
		float detail_threshold = uv_detail / current_scale;
		if (detail_threshold > level_of_detail) {
			// lod exit
		} else {
			vec3 tan_view = vec3(
				-dot(view_dir, TANGENT),
				dot(view_dir, BINORMAL),
				-abs(dot(view_dir, NORMAL)) - 0.001
			);

			vec2 face_uv;
			int face_id;
			float z_depth;
			float ray_length;

			float depth_stretch = POW3[min(level, 6)];
			vec3 tan_normal = ray_box_interior(local_uv, tan_view, hole_depth * 2.0, depth_stretch,
												face_uv, face_id, z_depth, ray_length);

			float accumulated_scale = current_scale * 0.5;
			float total_ray_length = ray_length * accumulated_scale;

			if (face_id == 0) discard;

			float ao_total = calculate_ao(face_uv, z_depth, face_id);
			int total_level = level;

			vec3 cur_tangent = TANGENT;
			vec3 cur_binormal = BINORMAL;
			vec3 cur_normal = NORMAL;
			vec3 cur_tan_normal = tan_normal;
			vec2 cur_face_uv = face_uv;
			int cur_face_id = face_id;

			float handedness = 1.0;

			for (int cut = 0; cut < cut_iterations; cut++) {
				if (cur_face_id < 1 || cur_face_id > 4) break;

				vec2 inner_local_uv;
				float inner_scale;
				int max_inner = hole_iterations - total_level;
				int inner_level = check_hole(cur_face_uv, inner_local_uv, inner_scale, max_inner, max_inner, is_corner, is_corner);


				if (inner_level == 0) break;


				detail_threshold = fwidth(cur_face_uv.x) + fwidth(cur_face_uv.y);
				if (detail_threshold / inner_scale > level_of_detail) break;

				if (cut == cut_iterations - 1) {
					ALBEDO *= 0.5;
					break;
				}



				vec3 wall_normal = normalize(
					cur_tan_normal.x * cur_tangent +
					cur_tan_normal.y * cur_binormal +
					cur_tan_normal.z * cur_normal
				);

				vec3 wall_tangent, wall_binormal;

				bool is_x_wall = (cur_face_id == 1 || cur_face_id == 2);
				if (is_x_wall) {
					wall_binormal = cur_binormal;
					wall_tangent = handedness * cross(wall_normal, wall_binormal);
				} else {
					wall_tangent = cur_tangent;
					wall_binormal = handedness * cross(wall_normal, wall_tangent);
				}

				if (cur_face_id == 2) wall_tangent = -wall_tangent;
				if (cur_face_id == 4) wall_binormal = -wall_binormal;
				if (cur_face_id == 1 || cur_face_id == 4) handedness = -handedness;

				if (inner_level <= -2) {
					float offset = 0.333333333;
					if (cur_face_id == 3 || cur_face_id == 4) {
						inner_local_uv.x += offset;
					} else {
						inner_local_uv.y += offset;
					}
				}

				wall_tangent = normalize(wall_tangent);
				wall_binormal = normalize(wall_binormal);

				vec3 inner_tan_view = vec3(
					-dot(view_dir, wall_tangent),
					dot(view_dir, wall_binormal),
					-abs(dot(view_dir, wall_normal)) - 0.001
				);

				vec2 new_face_uv;
				int new_face_id;
				float new_z_depth;
				float new_ray_length;

				int abs_inner = abs(inner_level);
				float inner_depth_stretch = POW3[min(abs_inner, 6)];
				vec3 new_tan_normal = ray_box_interior(inner_local_uv, inner_tan_view, hole_depth * 2.0, inner_depth_stretch, new_face_uv, new_face_id, new_z_depth, new_ray_length);

				accumulated_scale *= inner_scale;
				total_ray_length += new_ray_length * accumulated_scale;

				if (new_face_id == 0) discard;

				ao_total *= calculate_ao(new_face_uv, new_z_depth, new_face_id);

				total_level += inner_level;
				cur_face_uv = new_face_uv;
				cur_face_id = new_face_id;
				cur_tan_normal = new_tan_normal;
				cur_tangent = wall_tangent;
				cur_binormal = wall_binormal;
				cur_normal = wall_normal;
			}

			NORMAL = normalize(
				cur_tan_normal.x * cur_tangent +
				cur_tan_normal.y * cur_binormal +
				cur_tan_normal.z * cur_normal
			);

			float ao = mix(1.0, ao_total, ao_strength);
			float depth_darken = exp(float(-total_level) * 0.3);
			hole_fade = smoothstep(0.0, 1.0, clamp(level_of_detail - detail_threshold, 0.0, 1.0));
			interior_albedo = surface_color * ao * depth_darken;
			ALBEDO = mix(surface_color, interior_albedo, hole_fade);
			NORMAL = mix(original_normal, NORMAL, hole_fade);

			vec3 interior_pos = VERTEX - normalize(VIEW) * total_ray_length;
			vec3 faded_pos = mix(VERTEX, interior_pos, hole_fade);
			if (level < 6) {
				LIGHT_VERTEX = interior_pos;
			}
			clip_pos = PROJECTION_MATRIX * vec4(interior_pos, 1.0);
			DEPTH = clip_pos.z / clip_pos.w;
		}
	}
}

void light() {
	vec3 interior_light = LIGHT_COLOR * (1.0 / PI) * ATTENUATION * max(dot(NORMAL, LIGHT), 0.0);
	vec3 surface_light = LIGHT_COLOR * (1.0 / PI) * ATTENUATION * max(dot(original_normal, LIGHT), 0.0);

	DIFFUSE_LIGHT += mix(
		surface_color * surface_light,
		interior_albedo * interior_light,
		hole_fade
	);
}