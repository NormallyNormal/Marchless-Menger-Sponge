shader_type spatial;
uniform int hole_iterations : hint_range(1, 8) = 6;
uniform int cut_iterations : hint_range(1, 16) = 4;
uniform vec3 surface_color : source_color = vec3(1.0);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.5;
uniform int ambient_quality : hint_enum("Off", "Analytic", "4 Samples", "12 Samples") = 1;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.8;
uniform float surface_metallic : hint_range(0.0, 1.0) = 0.0;
uniform bool orthographic = false;
uniform int shadow_dilation : hint_range(0, 2) = 1;
const float POW3[9] = {1.0, 3.0, 9.0, 27.0, 81.0, 243.0, 729.0, 2187.0, 6561.0};
const float INV_POW3[9] = {1.0, 0.333333333, 0.111111111, 0.037037037, 0.012345679, 0.004115226, 0.001371742, 0.000457247, 0.000152416};
const float TRACE_EPSILON = 0.000001;
const float LARGE_DISTANCE = 1000000.0;
const float LOD_GONE_PIXELS = 1.0;
const float LOD_FULL_PIXELS = 2.0;

void vertex() {
	vec4 clip_position = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);

	if (IN_SHADOW_PASS && shadow_dilation > 0) {
		// expand shadow-pass planes in pixel space because fragments cannot dilate beyond the geometery
		vec3 opposite_x = VERTEX;
		vec3 opposite_z = VERTEX;
		opposite_x.x = -opposite_x.x;
		opposite_z.z = -opposite_z.z;

		vec4 x_clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(opposite_x, 1.0);
		vec4 z_clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(opposite_z, 1.0);
		vec4 center_clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(vec3(0.0), 1.0);
		vec2 half_viewport = max(VIEWPORT_SIZE * 0.5, vec2(1.0));
		vec2 pixel_position = clip_position.xy / clip_position.w * half_viewport;
		vec2 x_pixel = x_clip.xy / x_clip.w * half_viewport;
		vec2 z_pixel = z_clip.xy / z_clip.w * half_viewport;
		vec2 center_pixel = center_clip.xy / center_clip.w * half_viewport;

		float x_side = VERTEX.x < 0.0 ? -1.0 : 1.0;
		float z_side = VERTEX.z < 0.0 ? -1.0 : 1.0;
		vec2 x_basis = (x_pixel - pixel_position) * -x_side;
		vec2 z_basis = (z_pixel - pixel_position) * -z_side;
		float x_length = length(x_basis);
		float z_length = length(z_basis);
		float basis_area = abs(x_basis.x * z_basis.y - x_basis.y * z_basis.x);
		float dilation_radius = float(shadow_dilation);
		vec2 pixel_offset;

		if (x_length > 0.001 && z_length > 0.001 &&
			basis_area > x_length * z_length * 0.01) {
			vec2 x_normal = normalize(vec2(-z_basis.y, z_basis.x));
			if (dot(x_normal, x_basis) < 0.0) x_normal = -x_normal;
			x_normal *= x_side;

			vec2 z_normal = normalize(vec2(-x_basis.y, x_basis.x));
			if (dot(z_normal, z_basis) < 0.0) z_normal = -z_normal;
			z_normal *= z_side;

			float determinant = x_normal.x * z_normal.y - x_normal.y * z_normal.x;
			pixel_offset = dilation_radius * vec2(
				(z_normal.y - x_normal.y) / determinant,
				(x_normal.x - z_normal.x) / determinant
			);
		} else {
			// turn quads that collapse at grazing angles into thin rectangles so they remain visible.
			bool x_is_long = x_length >= z_length;
			vec2 long_axis = x_is_long ? x_basis : z_basis;
			if (length(long_axis) < 0.001) long_axis = vec2(1.0, 0.0);
			long_axis = normalize(long_axis);
			vec2 side_axis = vec2(-long_axis.y, long_axis.x);
			vec2 from_center = pixel_position - center_pixel;
			float along_side = dot(from_center, long_axis);
			float across_side = dot(from_center, side_axis);
			float along_sign = abs(along_side) > 0.001
				? (along_side < 0.0 ? -1.0 : 1.0)
				: (x_is_long ? x_side : z_side);
			float across_sign = abs(across_side) > 0.001
				? (across_side < 0.0 ? -1.0 : 1.0)
				: (x_is_long ? z_side : x_side);
			pixel_offset = (long_axis * along_sign + side_axis * across_sign) * dilation_radius;
		}

		clip_position.xy += pixel_offset / half_viewport * clip_position.w;
	}

	POSITION = clip_position;
}

vec3 projected_axis_pixels_squared(vec3 cube_position, mat4 cube_to_clip,
								   vec2 half_viewport) {
	vec4 clip_position = cube_to_clip * vec4(cube_position, 1.0);
	float inverse_w_squared = 1.0 / max(clip_position.w * clip_position.w, 0.000000000001);
	vec4 clip_delta_x = cube_to_clip[0];
	vec4 clip_delta_y = cube_to_clip[1];
	vec4 clip_delta_z = cube_to_clip[2];
	vec2 ndc_derivative_x = (
		clip_delta_x.xy * clip_position.w - clip_position.xy * clip_delta_x.w
	) * inverse_w_squared * half_viewport;
	vec2 ndc_derivative_y = (
		clip_delta_y.xy * clip_position.w - clip_position.xy * clip_delta_y.w
	) * inverse_w_squared * half_viewport;
	vec2 ndc_derivative_z = (
		clip_delta_z.xy * clip_position.w - clip_position.xy * clip_delta_z.w
	) * inverse_w_squared * half_viewport;
	return vec3(
		dot(ndc_derivative_x, ndc_derivative_x),
		dot(ndc_derivative_y, ndc_derivative_y),
		dot(ndc_derivative_z, ndc_derivative_z)
	);
}

float tunnel_lod_visibility(float cell_size, int tunnel_axis, vec3 axis_pixels_squared) {
	float first_dimension_squared;
	float second_dimension_squared;
	if (tunnel_axis == 0) {
		first_dimension_squared = axis_pixels_squared.y;
		second_dimension_squared = axis_pixels_squared.z;
	} else if (tunnel_axis == 1) {
		first_dimension_squared = axis_pixels_squared.x;
		second_dimension_squared = axis_pixels_squared.z;
	} else {
		first_dimension_squared = axis_pixels_squared.x;
		second_dimension_squared = axis_pixels_squared.y;
	}
	float minimum_pixels = sqrt(min(first_dimension_squared, second_dimension_squared)) * cell_size;
	return clamp(
		(minimum_pixels - LOD_GONE_PIXELS) /
		(LOD_FULL_PIXELS - LOD_GONE_PIXELS),
		0.0, 1.0
	);
}

bool check_hole(vec2 uv, out float hole_visibility, int max_iterations,
				vec3 axis_pixels_squared) {
	vec2 p = uv;
	hole_visibility = 0.0;
	float entry_cross_section_pixels_squared = min(axis_pixels_squared.x, axis_pixels_squared.y);
	for (int i = 0; i < max_iterations; i++) {
		float current_scale = INV_POW3[i + 1];
		if (entry_cross_section_pixels_squared * current_scale * current_scale <=
			LOD_GONE_PIXELS * LOD_GONE_PIXELS) return false;
		vec2 p3 = p * 3.0;
		vec2 cell = floor(p3);
		if (cell.x == 1.0 && cell.y == 1.0) {
			hole_visibility = tunnel_lod_visibility(current_scale, 2, axis_pixels_squared);
			return hole_visibility > 0.0;
		}
		p = p3 - cell;
	}
	return false;
}

float axis_exit_distance(float position, float direction, float lower, float upper) {
	if (direction > 0.0000001) return (upper - position) / direction;
	if (direction < -0.0000001) return (lower - position) / direction;
	return LARGE_DISTANCE;
}

float tunnel_exit_distance(vec3 position, vec3 direction, vec3 lower, vec3 upper,
						   out vec3 exit_normal) {
	vec3 distances = vec3(
		axis_exit_distance(position.x, direction.x, lower.x, upper.x),
		axis_exit_distance(position.y, direction.y, lower.y, upper.y),
		axis_exit_distance(position.z, direction.z, lower.z, upper.z)
	);

	float distance = distances.x;
	int exit_axis = 0;
	if (distances.y < distance) {
		distance = distances.y;
		exit_axis = 1;
	}
	if (distances.z < distance) {
		distance = distances.z;
		exit_axis = 2;
	}

	exit_normal = vec3(0.0);
	if (exit_axis == 0) exit_normal.x = direction.x > 0.0 ? -1.0 : 1.0;
	else if (exit_axis == 1) exit_normal.y = direction.y > 0.0 ? -1.0 : 1.0;
	else exit_normal.z = direction.z > 0.0 ? -1.0 : 1.0;
	return max(distance, 0.0);
}

bool find_tunnel_union_exit(vec3 position, vec3 direction, int max_levels,
							   vec3 axis_pixels_squared,
							   out float farthest_exit, out vec3 farthest_normal,
							   out vec3 farthest_lower, out vec3 farthest_upper,
							   out float farthest_visibility,
							   out float full_exit, out vec3 full_normal,
							   out vec3 full_lower, out vec3 full_upper) {
	bool inside_any_tunnel = false;
	farthest_exit = -1.0;
	farthest_normal = vec3(0.0);
	farthest_lower = vec3(0.0);
	farthest_upper = vec3(1.0);
	farthest_visibility = 0.0;
	full_exit = -1.0;
	full_normal = vec3(0.0);
	full_lower = vec3(0.0);
	full_upper = vec3(1.0);

	vec3 sample_position = clamp(position, vec3(0.0), vec3(1.0 - TRACE_EPSILON * 0.25));
	float largest_cross_section_pixels_squared = max(
		min(axis_pixels_squared.x, axis_pixels_squared.y),
		max(
			min(axis_pixels_squared.x, axis_pixels_squared.z),
			min(axis_pixels_squared.y, axis_pixels_squared.z)
		)
	);
	for (int fractal_level = 1; fractal_level <= max_levels; fractal_level++) {
		float cell_size = INV_POW3[fractal_level];
		if (largest_cross_section_pixels_squared * cell_size * cell_size <=
			LOD_GONE_PIXELS * LOD_GONE_PIXELS) break;
		float scale = POW3[fractal_level];
		vec3 cell = floor(sample_position * scale);
		vec3 digit = mod(cell, vec3(3.0));
		bvec3 middle = equal(digit, vec3(1.0));
		vec3 cell_lower = cell / scale;
		vec3 cell_upper = (cell + vec3(1.0)) / scale;

		if (middle.y && middle.z) {
			float visibility = tunnel_lod_visibility(cell_size, 0, axis_pixels_squared);
			if (visibility > 0.0) {
				vec3 lower = vec3(0.0, cell_lower.y, cell_lower.z);
				vec3 upper = vec3(1.0, cell_upper.y, cell_upper.z);
				vec3 exit_normal;
				float exit_distance = tunnel_exit_distance(
					position, direction, lower, upper, exit_normal
				);
				if (!inside_any_tunnel || exit_distance > farthest_exit) {
					farthest_exit = exit_distance;
					farthest_normal = exit_normal;
					farthest_lower = lower;
					farthest_upper = upper;
					farthest_visibility = visibility;
				}
				if (visibility >= 0.999999 && exit_distance > full_exit) {
					full_exit = exit_distance;
					full_normal = exit_normal;
					full_lower = lower;
					full_upper = upper;
				}
				inside_any_tunnel = true;
			}
		}

		if (middle.x && middle.z) {
			float visibility = tunnel_lod_visibility(cell_size, 1, axis_pixels_squared);
			if (visibility > 0.0) {
				vec3 lower = vec3(cell_lower.x, 0.0, cell_lower.z);
				vec3 upper = vec3(cell_upper.x, 1.0, cell_upper.z);
				vec3 exit_normal;
				float exit_distance = tunnel_exit_distance(
					position, direction, lower, upper, exit_normal
				);
				if (!inside_any_tunnel || exit_distance > farthest_exit) {
					farthest_exit = exit_distance;
					farthest_normal = exit_normal;
					farthest_lower = lower;
					farthest_upper = upper;
					farthest_visibility = visibility;
				}
				if (visibility >= 0.999999 && exit_distance > full_exit) {
					full_exit = exit_distance;
					full_normal = exit_normal;
					full_lower = lower;
					full_upper = upper;
				}
				inside_any_tunnel = true;
			}
		}

		if (middle.x && middle.y) {
			float visibility = tunnel_lod_visibility(cell_size, 2, axis_pixels_squared);
			if (visibility > 0.0) {
				vec3 lower = vec3(cell_lower.x, cell_lower.y, 0.0);
				vec3 upper = vec3(cell_upper.x, cell_upper.y, 1.0);
				vec3 exit_normal;
				float exit_distance = tunnel_exit_distance(
					position, direction, lower, upper, exit_normal
				);
				if (!inside_any_tunnel || exit_distance > farthest_exit) {
					farthest_exit = exit_distance;
					farthest_normal = exit_normal;
					farthest_lower = lower;
					farthest_upper = upper;
					farthest_visibility = visibility;
				}
				if (visibility >= 0.999999 && exit_distance > full_exit) {
					full_exit = exit_distance;
					full_normal = exit_normal;
					full_lower = lower;
					full_upper = upper;
				}
				inside_any_tunnel = true;
			}
		}
	}

	return inside_any_tunnel;
}

float tunnel_exit_distance_only(vec3 position, vec3 direction, vec3 lower, vec3 upper) {
	vec3 distances = vec3(
		axis_exit_distance(position.x, direction.x, lower.x, upper.x),
		axis_exit_distance(position.y, direction.y, lower.y, upper.y),
		axis_exit_distance(position.z, direction.z, lower.z, upper.z)
	);
	return max(min(distances.x, min(distances.y, distances.z)), 0.0);
}

bool find_tunnel_union_exit_distance(vec3 position, vec3 direction, int max_levels,
									 vec3 axis_pixels_squared,
									 out float farthest_exit) {
	bool inside_any_tunnel = false;
	farthest_exit = -1.0;
	vec3 sample_position = clamp(position, vec3(0.0), vec3(1.0 - TRACE_EPSILON * 0.25));
	float largest_cross_section_pixels_squared = max(
		min(axis_pixels_squared.x, axis_pixels_squared.y),
		max(
			min(axis_pixels_squared.x, axis_pixels_squared.z),
			min(axis_pixels_squared.y, axis_pixels_squared.z)
		)
	);

	for (int fractal_level = 1; fractal_level <= max_levels; fractal_level++) {
		float cell_size = INV_POW3[fractal_level];
		if (largest_cross_section_pixels_squared * cell_size * cell_size <=
			LOD_GONE_PIXELS * LOD_GONE_PIXELS) break;
		float scale = POW3[fractal_level];
		vec3 cell = floor(sample_position * scale);
		vec3 digit = mod(cell, vec3(3.0));
		bvec3 middle = equal(digit, vec3(1.0));
		vec3 cell_lower = cell / scale;
		vec3 cell_upper = (cell + vec3(1.0)) / scale;

		if (middle.y && middle.z &&
			tunnel_lod_visibility(cell_size, 0, axis_pixels_squared) > 0.0) {
			vec3 lower = vec3(0.0, cell_lower.y, cell_lower.z);
			vec3 upper = vec3(1.0, cell_upper.y, cell_upper.z);
			farthest_exit = max(
				farthest_exit,
				tunnel_exit_distance_only(position, direction, lower, upper)
			);
			inside_any_tunnel = true;
		}

		if (middle.x && middle.z &&
			tunnel_lod_visibility(cell_size, 1, axis_pixels_squared) > 0.0) {
			vec3 lower = vec3(cell_lower.x, 0.0, cell_lower.z);
			vec3 upper = vec3(cell_upper.x, 1.0, cell_upper.z);
			farthest_exit = max(
				farthest_exit,
				tunnel_exit_distance_only(position, direction, lower, upper)
			);
			inside_any_tunnel = true;
		}

		if (middle.x && middle.y &&
			tunnel_lod_visibility(cell_size, 2, axis_pixels_squared) > 0.0) {
			vec3 lower = vec3(cell_lower.x, cell_lower.y, 0.0);
			vec3 upper = vec3(cell_upper.x, cell_upper.y, 1.0);
			farthest_exit = max(
				farthest_exit,
				tunnel_exit_distance_only(position, direction, lower, upper)
			);
			inside_any_tunnel = true;
		}
	}

	return inside_any_tunnel;
}

vec3 safe_direction(vec3 vector) {
	return vector * inversesqrt(max(dot(vector, vector), 0.000000000001));
}

vec3 spherical_edge_integral(vec3 direction_a, vec3 direction_b) {
	vec3 edge_cross = cross(direction_a, direction_b);
	float cross_length = length(edge_cross);
	if (cross_length < 0.0000001) return vec3(0.0);
	float edge_angle = atan(cross_length, clamp(dot(direction_a, direction_b), -1.0, 1.0));
	return edge_cross * (edge_angle / cross_length);
}

float projected_quad_visibility(vec3 point, vec3 surface_normal,
								vec3 corner_0, vec3 corner_1,
								vec3 corner_2, vec3 corner_3,
								int first_edge_axis, int second_edge_axis,
								int surface_axis) {
	vec3 direction_0 = safe_direction(corner_0 - point);
	vec3 direction_1 = safe_direction(corner_1 - point);
	vec3 direction_2 = safe_direction(corner_2 - point);
	vec3 direction_3 = safe_direction(corner_3 - point);
	vec3 vector_irradiance;
	if (surface_axis == first_edge_axis) {
		// edges 0-1 and 2-3 are parallel to the surface normal, so their projected contribution is zero.
		vector_irradiance =
			spherical_edge_integral(direction_1, direction_2) +
			spherical_edge_integral(direction_3, direction_0);
	} else if (surface_axis == second_edge_axis) {
		// edges 1-2 and 3-0 are the parallel pair instead.
		vector_irradiance =
			spherical_edge_integral(direction_0, direction_1) +
			spherical_edge_integral(direction_2, direction_3);
	} else {
		// endpoint-facing normals are not tunnel walls, but lod bases can temporarily use this orientation.
		vector_irradiance =
			spherical_edge_integral(direction_0, direction_1) +
			spherical_edge_integral(direction_1, direction_2) +
			spherical_edge_integral(direction_2, direction_3) +
			spherical_edge_integral(direction_3, direction_0);
	}
	return abs(dot(surface_normal, vector_irradiance)) * (0.5 / PI);
}

float tunnel_aperture_visibility(vec3 hit_position, vec3 surface_normal,
								 vec3 lower, vec3 upper, int tunnel_axis,
								 int surface_axis, float endpoint) {
	vec3 corner_0;
	vec3 corner_1;
	vec3 corner_2;
	vec3 corner_3;
	int first_edge_axis;
	int second_edge_axis;
	if (tunnel_axis == 0) {
		corner_0 = vec3(endpoint, lower.y, lower.z);
		corner_1 = vec3(endpoint, upper.y, lower.z);
		corner_2 = vec3(endpoint, upper.y, upper.z);
		corner_3 = vec3(endpoint, lower.y, upper.z);
		first_edge_axis = 1;
		second_edge_axis = 2;
	} else if (tunnel_axis == 1) {
		corner_0 = vec3(lower.x, endpoint, lower.z);
		corner_1 = vec3(lower.x, endpoint, upper.z);
		corner_2 = vec3(upper.x, endpoint, upper.z);
		corner_3 = vec3(upper.x, endpoint, lower.z);
		first_edge_axis = 2;
		second_edge_axis = 0;
	} else {
		corner_0 = vec3(lower.x, lower.y, endpoint);
		corner_1 = vec3(upper.x, lower.y, endpoint);
		corner_2 = vec3(upper.x, upper.y, endpoint);
		corner_3 = vec3(lower.x, upper.y, endpoint);
		first_edge_axis = 0;
		second_edge_axis = 1;
	}
	return projected_quad_visibility(
		hit_position, surface_normal, corner_0, corner_1, corner_2, corner_3,
		first_edge_axis, second_edge_axis, surface_axis
	);
}

float analytic_tunnel_visibility(vec3 hit_position, vec3 surface_normal, vec3 lower, vec3 upper) {
	vec3 span = upper - lower;
	int tunnel_axis = 0;
	if (span.y > span.x && span.y >= span.z) tunnel_axis = 1;
	else if (span.z > span.x && span.z > span.y) tunnel_axis = 2;
	vec3 absolute_normal = abs(surface_normal);
	int surface_axis = 0;
	if (absolute_normal.y > absolute_normal.x) surface_axis = 1;
	if (absolute_normal.z > max(absolute_normal.x, absolute_normal.y)) surface_axis = 2;
	float visibility =
		tunnel_aperture_visibility(hit_position, surface_normal, lower, upper, tunnel_axis, surface_axis, 0.0) +
		tunnel_aperture_visibility(hit_position, surface_normal, lower, upper, tunnel_axis, surface_axis, 1.0);
	return clamp(visibility, 0.0, 1.0);
}

float hash_position(vec3 position) {
	vec3 hashed = fract(position * 0.1031);
	hashed += dot(hashed, hashed.yzx + vec3(33.33));
	return fract((hashed.x + hashed.y) * hashed.z);
}

float trace_environment_visibility(vec3 origin, vec3 direction, int max_levels,
								   mat4 cube_to_clip, vec2 half_viewport) {
	vec3 trace_position = origin;
	for (int traversal = 0; traversal < cut_iterations; traversal++) {
		if (any(lessThan(trace_position, vec3(0.0))) || any(greaterThan(trace_position, vec3(1.0)))) return 1.0;

		vec3 axis_pixels_squared = projected_axis_pixels_squared(
			trace_position, cube_to_clip, half_viewport
		);
		float exit_distance;
		bool inside_void = find_tunnel_union_exit_distance(
			trace_position, direction, max_levels, axis_pixels_squared,
			exit_distance
		);
		if (!inside_void) return 0.0;
		trace_position += direction * (exit_distance + TRACE_EPSILON);
	}
	return any(lessThan(trace_position, vec3(0.0))) || any(greaterThan(trace_position, vec3(1.0)))
		? 1.0
		: 0.0;
}

float sampled_ambient_visibility(vec3 hit_position, vec3 surface_normal,
								 int max_levels, int sample_count,
								 mat4 cube_to_clip, vec2 half_viewport) {
	vec3 helper_axis = abs(surface_normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	vec3 tangent_axis = normalize(cross(helper_axis, surface_normal));
	vec3 bitangent_axis = cross(surface_normal, tangent_axis);
	float scale = POW3[max_levels];
	float rotation = hash_position(floor(hit_position * scale + vec3(0.5))) * 2.0 * PI;
	float visible_samples = 0.0;
	vec3 ray_origin = hit_position + surface_normal * (TRACE_EPSILON * 4.0);

	for (int sample_index = 0; sample_index < 12; sample_index++) {
		if (sample_index >= sample_count) break;
		float sequence = (float(sample_index) + 0.5) / float(sample_count);
		float radial = sqrt(sequence);
		float azimuth = float(sample_index) * 2.39996323 + rotation;
		vec3 local_direction = vec3(
			radial * cos(azimuth),
			radial * sin(azimuth),
			sqrt(max(1.0 - radial * radial, 0.0))
		);
		vec3 ray_direction = normalize(
			tangent_axis * local_direction.x +
			bitangent_axis * local_direction.y +
			surface_normal * local_direction.z
		);
		visible_samples += trace_environment_visibility(
			ray_origin, ray_direction, max_levels, cube_to_clip, half_viewport
		);
	}

	return visible_samples / float(sample_count);
}

void fragment() {
	ALBEDO = surface_color;
	ROUGHNESS = surface_roughness;
	METALLIC = surface_metallic;
	AO = 1.0;
	AO_LIGHT_AFFECT = 0.0;
	ALPHA = 1.0;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	vec3 outer_normal_view = NORMAL;
	vec4 clip_pos = PROJECTION_MATRIX * vec4(VERTEX, 1.0);
	DEPTH = clip_pos.z / clip_pos.w;
	
	vec3 view_dir;
	if (orthographic) {
		vec3 cam_forward = normalize(INV_VIEW_MATRIX[2].xyz);
		view_dir = normalize((VIEW_MATRIX * vec4(cam_forward, 0.0)).xyz);
	} else {
		view_dir = normalize(VIEW);
	}

	// project the cube, where x/y follow the entry uv and +z points inward, to calculate interior ss lod without derivatives that can cause bad behavior on some gpus.
	mat3 cube_to_view = mat3(TANGENT, -BINORMAL, -NORMAL);
	vec3 ray_origin = vec3(UV, 0.0);
	vec3 cube_origin_view = VERTEX - cube_to_view * ray_origin;
	vec2 half_viewport = max(VIEWPORT_SIZE * 0.5, vec2(1.0));
	mat4 cube_to_clip = mat4(
		PROJECTION_MATRIX * vec4(cube_to_view[0], 0.0),
		PROJECTION_MATRIX * vec4(cube_to_view[1], 0.0),
		PROJECTION_MATRIX * vec4(cube_to_view[2], 0.0),
		PROJECTION_MATRIX * vec4(cube_origin_view, 1.0)
	);
	vec3 entry_axis_pixels_squared = projected_axis_pixels_squared(
		ray_origin, cube_to_clip, half_viewport
	);
	float entry_visibility;
	bool entry_hole = check_hole(
		UV, entry_visibility, hole_iterations, entry_axis_pixels_squared
	);
	
	if (entry_hole) {
		// a unit cube where x/y follow the entry uv and +z points inward, menger holes are always axis-aligned tunnels at each level.
		vec3 ray_direction = normalize(vec3(
			-dot(view_dir, TANGENT),
			dot(view_dir, BINORMAL),
			abs(dot(view_dir, NORMAL)) + 0.000001
		));

		float trace_distance = TRACE_EPSILON;
		vec3 trace_position = ray_origin + ray_direction * trace_distance;

		bool hit_surface = false;
		bool escaped_cube = false;
		float candidate_distance = 0.0;
		vec3 candidate_position = ray_origin;
		vec3 candidate_normal = vec3(0.0, 0.0, -1.0);
		vec3 candidate_lower = vec3(0.0);
		vec3 candidate_upper = vec3(1.0);

		bool partial_lod = entry_visibility < 0.999999;
		float path_visibility = entry_visibility;
		bool base_is_outer = true;
		vec3 base_position = ray_origin;
		vec3 base_normal = vec3(0.0, 0.0, -1.0);
		vec3 base_lower = vec3(0.0);
		vec3 base_upper = vec3(1.0);

		for (int traversal = 0; traversal < cut_iterations; traversal++) {
			vec3 trace_axis_pixels_squared = traversal == 0
				? entry_axis_pixels_squared
				: projected_axis_pixels_squared(trace_position, cube_to_clip, half_viewport);
			float farthest_exit;
			vec3 farthest_normal;
			vec3 farthest_lower;
			vec3 farthest_upper;
			float farthest_visibility;
			float full_exit;
			vec3 full_normal;
			vec3 full_lower;
			vec3 full_upper;
			bool inside_any_tunnel = find_tunnel_union_exit(
				trace_position, ray_direction, hole_iterations, trace_axis_pixels_squared,
				farthest_exit, farthest_normal, farthest_lower, farthest_upper,
				farthest_visibility,
				full_exit, full_normal, full_lower, full_upper
			);

			if (!inside_any_tunnel) {
				hit_surface = traversal > 0;
				break;
			}

			bool repeats_entry_fade = entry_visibility < 0.999999 && traversal == 0;
			if (farthest_visibility < 0.999999 && !repeats_entry_fade) {
				if (!partial_lod) {
					partial_lod = true;
					path_visibility = farthest_visibility;
					if (full_exit >= 0.0) {
						base_is_outer = false;
						base_position = ray_origin + ray_direction * (trace_distance + full_exit);
						base_normal = full_normal;
						base_lower = full_lower;
						base_upper = full_upper;
					} else if (traversal > 0) {
						base_is_outer = false;
						base_position = candidate_position;
						base_normal = candidate_normal;
						base_lower = candidate_lower;
						base_upper = candidate_upper;
					}
				} else {
					path_visibility *= farthest_visibility;
				}
			}

			candidate_distance = trace_distance + farthest_exit;
			candidate_position = ray_origin + ray_direction * candidate_distance;
			candidate_normal = farthest_normal;
			candidate_lower = farthest_lower;
			candidate_upper = farthest_upper;

			trace_distance = candidate_distance + TRACE_EPSILON;
			trace_position = ray_origin + ray_direction * trace_distance;
			if (any(lessThan(trace_position, vec3(0.0))) || any(greaterThan(trace_position, vec3(1.0)))) {
				escaped_cube = true;
				break;
			}
			if (traversal == cut_iterations - 1) hit_surface = true;
		}

		float lod_blend = partial_lod ? clamp(path_visibility, 0.0, 1.0) : 1.0;
		if (escaped_cube) {
			if (!partial_lod) {
				ALPHA = 0.0;
			} else {
				// alpha scissor turns the continuous lod blend into a stable midpoint switch for subpixel holes.
				ALPHA = 1.0 - lod_blend;
				vec3 base_view_position = cube_origin_view + cube_to_view * base_position;
				NORMAL = normalize(cube_to_view * base_normal);
				LIGHT_VERTEX = base_view_position;
				clip_pos = PROJECTION_MATRIX * vec4(base_view_position, 1.0);
				DEPTH = clip_pos.z / clip_pos.w;
				if (!IN_SHADOW_PASS && ambient_quality != 0 && !base_is_outer) {
					float base_ambient = analytic_tunnel_visibility(
						base_position, base_normal, base_lower, base_upper
					);
					AO = mix(1.0, base_ambient, ao_strength);
				}
			}
		} else if (hit_surface) {
			float target_ao = 1.0;
			if (!IN_SHADOW_PASS && ambient_quality != 0) {
				float ambient_visibility;
				if (ambient_quality == 1) {
					ambient_visibility = analytic_tunnel_visibility(
						candidate_position, candidate_normal, candidate_lower, candidate_upper
					);
				} else {
					int sample_count = ambient_quality == 2 ? 4 : 12;
					ambient_visibility = sampled_ambient_visibility(
						candidate_position, candidate_normal, hole_iterations, sample_count,
						cube_to_clip, half_viewport
					);
				}
				target_ao = mix(1.0, ambient_visibility, ao_strength);
			}

			vec3 interior_normal = normalize(
				cube_to_view * candidate_normal
			);
			vec3 interior_pos = cube_origin_view + cube_to_view * candidate_position;
			vec3 final_normal = interior_normal;
			vec3 final_position = interior_pos;
			AO = target_ao;

			if (partial_lod) {
				vec3 base_view_position = cube_origin_view + cube_to_view * base_position;
				vec3 base_view_normal = base_is_outer
					? outer_normal_view
					: normalize(cube_to_view * base_normal);
				float base_ao = 1.0;
				if (!IN_SHADOW_PASS && ambient_quality != 0 && !base_is_outer) {
					float base_ambient = analytic_tunnel_visibility(
						base_position, base_normal, base_lower, base_upper
					);
					base_ao = mix(1.0, base_ambient, ao_strength);
				}
				final_normal = safe_direction(mix(base_view_normal, interior_normal, lod_blend));
				final_position = mix(base_view_position, interior_pos, lod_blend);
				AO = mix(base_ao, target_ao, lod_blend);
			}

			NORMAL = final_normal;
			LIGHT_VERTEX = final_position;
			clip_pos = PROJECTION_MATRIX * vec4(final_position, 1.0);
			DEPTH = clip_pos.z / clip_pos.w;
		}
	}

	// keep color outputs live so depth-prepass and color variants compile traversal math identically and avoid depth-test speckling, alas godot lacks glsl's precise and invariant qualifiers but this hack works for me at least.
	if (NORMAL.x + LIGHT_VERTEX.x + AO + ALBEDO.x > 1.0e30) DEPTH += 1.0;
}
