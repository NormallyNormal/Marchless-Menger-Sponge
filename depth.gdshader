shader_type spatial;
render_mode unshaded;

uniform sampler2D depth_texture : hint_depth_texture;

void fragment() {
    float depth = texture(depth_texture, SCREEN_UV).r;
    // Visualize - depth is 0-1, near to far
    ALBEDO = vec3(depth);
}