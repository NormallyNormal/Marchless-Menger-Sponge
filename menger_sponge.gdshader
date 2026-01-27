shader_type spatial;

uniform int hole_iterations : hint_range(1, 6) = 5;
uniform int cut_iterations : hint_range(1, 4) = 2;
uniform float hole_depth : hint_range(0.1, 5.0) = 1.0;
uniform vec3 surface_color : source_color = vec3(1.0);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.5;
uniform bool orthographic = false;

varying vec3 original_normal;

int check_hole(vec2 uv, out vec2 local_uv, out float current_scale, int max_iterations, int maxsuperhole, out bool corner, bool was_corner) {
	vec2 p = uv;
	
	int largest_hole = 0;
	vec2 largest_local_uv;
	float largest_scale;
	
	for (int i = 1; i <= maxsuperhole; i++) {
		if (was_corner && i == 2) {
			continue;
		}
		float scale = pow(3.0, float(i));
		vec2 cell = floor(p / scale);
		vec2 local = fract(p / scale);
		if (floor(local.x * 3.0) == 1.0 || floor(local.y * 3.0) == 1.0) {
			largest_local_uv = fract(local * 3.0);
			largest_scale = scale / 3.0;
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
		vec2 cell = floor(p * 3.0);
		vec2 local = fract(p * 3.0);
		if (cell.x == 1.0 && cell.y == 1.0) {
			if(was_corner_last) {
				corner = true;
			}
			local_uv = local;
			current_scale = 1.0 / pow(3.0, float(i + 1));
			return i + 1;
		}
		was_corner_last = (abs(p.x - 0.5) > 1.0/6.0) && (abs(p.y - 0.5) > 1.0/6.0);
		p = p * 3.0 - cell;
	}
	return 0;
}

vec3 ray_box_interior(vec2 hole_uv, vec3 view_dir, float depth, float depth_stretch, out vec2 face_uv, out int face_id, out float z_depth, out float ray_length) {
	vec2 pos = hole_uv * 2.0 - 1.0;
	
	vec3 ro = vec3(pos, 0.0);
	vec3 rd = normalize(view_dir);
	
	vec3 box_min = vec3(-1.0, -1.0, -depth * depth_stretch);
	vec3 box_max = vec3(1.0, 1.0, 0.0);
	
	vec3 t1 = (box_min - ro) / rd;
	vec3 t2 = (box_max - ro) / rd;
	
	vec3 t_far = max(t1, t2);
	float t = min(min(t_far.x, t_far.y), t_far.z);
	ray_length = abs(t);
	
	vec3 hit = ro + rd * t;
	
	float eps = 0.001;
	
	face_id = 0;
	face_uv = vec2(0.0);
	z_depth = -hit.z / (depth * depth_stretch);
	
	if (abs(hit.z + depth) < eps) {
		face_id = 0;
		return vec3(0.0);
	}
	
	if (abs(hit.y - 1.0) < eps) {
		face_id = 4;
		face_uv = vec2((hit.x + 1.0) / 2.0, (-hit.z) / depth);
		return vec3(0.0, 1.0, 0.0);
	}
	
	if (abs(hit.y + 1.0) < eps) {
		face_id = 3;
		face_uv = vec2((hit.x + 1.0) / 2.0, (-hit.z) / depth);
		return vec3(0.0, -1.0, 0.0);
	}
	
	if (abs(hit.x + 1.0) < eps) {
		face_id = 2;
		face_uv = vec2((-hit.z) / depth, (hit.y + 1.0) / 2.0);
		return vec3(1.0, 0.0, 0.0);
	}
	
	if (abs(hit.x - 1.0) < eps) {
		face_id = 1;
		face_uv = vec2((-hit.z) / depth, (hit.y + 1.0) / 2.0);
		return vec3(-1.0, 0.0, 0.0);
	}
	
	return vec3(0.0, 0.0, 1.0);
}

float calculate_ao(vec2 face_uv, float z_depth, vec2 hole_uv, int face_id) {
	if (face_uv.x < 0.0 || face_uv.x > 1.0 || face_uv.y < 0.0 || face_uv.y > 1.0) {
		return 1.0;
	}
	
	float ao = 1.0;
	float adjacent_edge = 0.0;
	
	float depth_edge = 0.0;
	
	if (face_id == 2 || face_id == 1) {
		adjacent_edge = min(face_uv.y, 1.0 - face_uv.y);
		depth_edge = min(face_uv.x, 1.0 - face_uv.x);
		ao *= smoothstep(0.0, 0.25, adjacent_edge);
	}
	if (face_id == 3 || face_id == 4) {
		adjacent_edge = min(face_uv.x, 1.0 - face_uv.x);
		depth_edge = min(face_uv.y, 1.0 - face_uv.y);
		ao *= smoothstep(0.0, 0.25, adjacent_edge);
	}
	
	float entrance_exit_factor = smoothstep(0.0, 0.3, depth_edge);
	ao = mix(1.0, ao, entrance_exit_factor);
	
	ao *= mix(1.0, 0.7, z_depth);
	
	return ao;
}

void fragment() {
	ALBEDO = surface_color;
	original_normal = NORMAL;
	vec2 uv = UV;
	vec2 local_uv;
	float current_scale;
	float total_ray_length = 0.0;
	float accumulated_scale = 1.0;
	
	vec4 clip_pos = PROJECTION_MATRIX * vec4(VERTEX, 1.0);
	DEPTH = clip_pos.z / clip_pos.w;
	
	vec3 view_dir;
	if (orthographic) {
		vec3 cam_forward = normalize(INV_VIEW_MATRIX[2].xyz);
		view_dir = normalize((VIEW_MATRIX * vec4(cam_forward, 0.0)).xyz);
	} else {
		view_dir = normalize(VIEW);
	}
	
	bool is_corner = false;
	int level = check_hole(uv, local_uv, current_scale, hole_iterations, 0, is_corner, is_corner);

	if (level != 0) {
		vec3 tan_view = vec3(
			dot(view_dir, TANGENT),
			dot(view_dir, BINORMAL),
			dot(view_dir, NORMAL)
		);
		tan_view = vec3(-tan_view.x, tan_view.y, -abs(tan_view.z) - 0.001);
		
		vec2 face_uv;
		int face_id;
		float z_depth;
		float ray_length;
		vec3 tan_normal = ray_box_interior(local_uv, tan_view, hole_depth * 2.0, pow(3.0, float(level)), face_uv, face_id, z_depth, ray_length);
		
		accumulated_scale = current_scale / 2.0;
		total_ray_length += ray_length * accumulated_scale;
		
		if (face_id == 0) {
			discard;
		}
		
		float ao_total = calculate_ao(face_uv, z_depth, local_uv, face_id);
		int total_level = level;
		
		vec3 cur_tangent = TANGENT;
		vec3 cur_binormal = BINORMAL;
		vec3 cur_normal = NORMAL;
		
		vec2 cur_face_uv = face_uv;
		int cur_face_id = face_id;
		vec3 cur_tan_normal = tan_normal;
		
		float handedness = FRONT_FACING ? 1.0 : -1.0;
		
		for (int cut = 0; cut < cut_iterations; cut++) {
			if (cur_face_id < 1 || cur_face_id > 4) {
				break;
			}
			
			vec2 inner_local_uv;
			float inner_scale;
			int inner_level = check_hole(cur_face_uv, inner_local_uv, inner_scale, hole_iterations - total_level, hole_iterations - total_level, is_corner, is_corner);
			
			if (inner_level == 0) {
				break;
			}
			
			if (cut == cut_iterations - 1) {
				ALBEDO = ALBEDO * 0.2;
				break;
			}
			
			vec3 wall_normal = normalize(
				cur_tan_normal.x * cur_tangent +
				cur_tan_normal.y * cur_binormal +
				cur_tan_normal.z * cur_normal
			);
			
			vec3 wall_tangent;
			vec3 wall_binormal;
			
			if (cur_face_id == 1 || cur_face_id == 2) {
				wall_binormal = cur_binormal;
				wall_tangent = handedness * cross(wall_normal, wall_binormal);
			} else {
				wall_tangent = cur_tangent;
				wall_binormal = handedness * cross(wall_normal, wall_tangent);
			}
			
			if (cur_face_id == 2) {
				wall_tangent = -wall_tangent;
			}
			if (cur_face_id == 4) {
				wall_binormal = -wall_binormal;
			}
			if (cur_face_id == 1 || cur_face_id == 4) {
				handedness *= -1.0;
			}
			
			if (inner_level <= -2) {
				if (cur_face_id == 4 || cur_face_id == 3) {
					inner_local_uv.x = inner_local_uv.x + 1.0 / 3.0;
				}
				if (cur_face_id == 1 || cur_face_id == 2) {
					inner_local_uv.y = inner_local_uv.y + 1.0 / 3.0;
				}
			}
			
			wall_tangent = normalize(wall_tangent);
			wall_binormal = normalize(wall_binormal);
			
			vec3 inner_tan_view = vec3(
				dot(view_dir, wall_tangent),
				dot(view_dir, wall_binormal),
				dot(view_dir, wall_normal)
			);
			inner_tan_view = vec3(-inner_tan_view.x, inner_tan_view.y, -abs(inner_tan_view.z) - 0.001);
			
			vec2 new_face_uv;
			int new_face_id;
			float new_z_depth;
			float new_ray_length;
			vec3 new_tan_normal = ray_box_interior(inner_local_uv, inner_tan_view, hole_depth * 2.0, pow(3.0, float(abs(inner_level))), new_face_uv, new_face_id, new_z_depth, new_ray_length);
			
			accumulated_scale *= inner_scale;
			total_ray_length += new_ray_length * accumulated_scale;
			
			if (new_face_id == 0) {
				discard;
			}
			
			ao_total *= calculate_ao(new_face_uv, new_z_depth, inner_local_uv, new_face_id);
			
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
		float depth_darken = exp(-float(total_level) * 0.1);
		ALBEDO = ALBEDO * ao * depth_darken * 0.4;
		
		vec3 interior_pos = VERTEX - normalize(VIEW) * total_ray_length;
		clip_pos = PROJECTION_MATRIX * vec4(interior_pos, 1.0);
		DEPTH = clip_pos.z / clip_pos.w;
		
	} else {
		ALBEDO = ALBEDO * ((FRONT_FACING) ? 1.0 : 0.4);
	}
}

void light() {
	float NdotL = max(dot(NORMAL, LIGHT), 0.0);
	float surface_NdotL = max(dot(original_normal, LIGHT), 0.0);
	NdotL = min(NdotL, surface_NdotL);
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * ATTENUATION * clamp(NdotL, 0.0, 1.0);
}