# Menger Sponge Interior Mapping Shader

A Godot 4.7 Forward+ spatial shader that renders a finite Menger sponge on the six plane faces of a cube.

Instead of building dense fractal geometry or raymarching through the entire volume, the shader analytically traverses the sponge's axis-aligned tunnels. It writes the depth and normals of the first visible interior wall, uses automatic screen-space level of detail (LOD), supports several ambient occlusion (AO) modes, and participates in Godot's normal PBR and shadow pipeline.

## Requirements

- Godot 4.7
- The Forward+ renderer and a compatible RenderingDevice backend

Aprrox. 60 FPS at 1920x1200 with integrated Intel Arc Graphics 130V.
Approx. 700 FPS at 2560x1440 with an RX 7900 XT

The project disables the OpenGL 3 fallback because the demo targets Forward+.

## Running the demo

1. Open `project.godot` in Godot 4.7.
2. Run the project with <kbd>F5</kbd> or the play button.

The sponge rotates automatically, and the label in the upper-left corner reports frame process time. A Linux export preset is included but is not required to run the project from the editor.

## Shader parameters

| Parameter | Range or options | Shader default | Description |
| --- | --- | --- | --- |
| `hole_iterations` | 1-8 | 6 | Number of ternary fractal levels. More levels add smaller holes at a higher cost. The demo uses 8. |
| `cut_iterations` | 1-16 | 4 | Maximum number of tunnel exits followed while finding an interior wall. The demo uses 6. |
| `surface_color` | Color | White | Base color of the sponge. |
| `ao_strength` | 0-1 | 0.5 | Blends between no AO and the result of the selected AO method. |
| `ambient_quality` | Off, Analytic, 4 Samples, 12 Samples | Analytic | Selects no AO, analytic rectangular-aperture AO, or traced AO with 4 or 12 samples. |
| `surface_roughness` | 0-1 | 0.8 | PBR surface roughness. |
| `surface_metallic` | 0-1 | 0.0 | PBR metallic value. |
| `orthographic` | Boolean | `false` | Enable when the active camera uses orthographic projection. |
| `shadow_dilation` | 0-2 | 1 | Expands shadow-pass silhouettes by this many shadow-map pixels to reduce leaks on thin or edge-on faces. |

Hole detail is selected from its actual exterior or interior screen position. A hole is fully visible at 2 pixels, fades between 1 and 2 pixels, and is removed at 1 pixel or less.

## Project structure

- `menger_sponge.gdshader` contains the Menger sponge renderer.
- `CUBE.tscn` assembles six plane meshes with the shader material and the demo parameter overrides.
- `main.tscn` provides the camera, lighting, environment, and performance label.
- `cube.gd` rotates the sponge.
- `fps.gd` displays frame process time.
- `stripes.gdshader` and `depth.gdshader` are optional debug shaders used by disabled scene nodes.

## Advantages

- Custom depth, normals, PBR material properties, and shadows remain integrated with Godot's rendering pipeline.
- Other meshes can pass through the holes or cast shadows onto the sponge.
- Analytic tunnel traversal avoids the cost of raymarching the full fractal volume.

## Limitations

- The fractal exists only on the six surface meshes, so the camera cannot move inside it, although other meshes can intersect it.
- Analytic AO is local to the material and does not darken other geometry placed inside the sponge.
- Supporting other fractals, such as a Jerusalem cube or Sierpiński tetrahedron, would require a different traversal model.

## License

This project is licensed under the GNU General Public License v3.0. See `LICENSE` for the full terms.
