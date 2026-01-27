# Menger Sponge Interior Mapping Shader
This is a Godot 4 (4.5.1) spatial fragment shader that renders a Menger Sponge fractal onto a plane mesh surface.
Instead of using thousands of polygons to model, or implementing expensive raymarching, this uses a fast raycast check for each fractal level, which removes the need for iterative "marching."

menger_sponge.gdshader is the only file of real significance. Everything else is setup for the demo project.

## Parameters
hole_iterations: Number of fractal iterations for the hole pattern. Higher gives more detail, more cost.

cut_iterations: How many layers deep to raycast into interior walls.

hole_depth: Base depth of holes. Affects parallax intensity, probably shouldn't be changed.

surface_color: Pretty much what it says on the tin. Color of the surfaces.

ao_strength: Blending strength of the approximated ambient occulsion.

orthographic: Set to true if rendering with an orthographic projection.

level_of_detail: Fades out holes below this threshold. Little effect on performace, because it's just meant reduce aliasing and Moiré patterns.

## Limitations
* Because this only renders the complex fractal on the surface of the plane meshes, the camera cannot go inside the fractal structure.
* This method probably would not generalize well to other fractals. A jerusalem cube or tetrix may be doable, but not without significant effort and changes.
<img width="1914" height="1197" alt="image" src="https://github.com/user-attachments/assets/b6ef79e5-ffd2-4b7e-9a36-ea6fe7c64187" />
Image is rendered on my laptop (Intel Core Ultra 5 226V, integrated Intel Arc Graphics 130V, 1920x1200 resolution). 300+ FPS is achivable when the post processing is disabled.
