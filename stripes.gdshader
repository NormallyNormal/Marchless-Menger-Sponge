shader_type spatial;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
    if (mod(UV.x + UV.y * 10.0, 0.1) < 0.05) {
        ALBEDO = vec3(0.0);
    } else {
        discard;  // Don't render non-stripe pixels
    }
}
