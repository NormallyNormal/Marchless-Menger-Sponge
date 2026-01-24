# Menger Sponge Interior Mapping Shader
This is a Godot 4 (4.5.1) spatial fragment shader that renders a Menger Sponge fractal onto a plane mesh surface.
Instead of using thousands of polygons to model, or implementing expensive raymarching, this uses a fast raycast check for each fractal level, which removes the need for iterative "marching."

## Parameters
hole_iterations: Number of fractal iterations for the hole pattern. Higher = more detail, more cost.
cut_iterations: How many layers deep to raycast into interior walls.
hole_depth: Base depth of holes. Affects parallax intensity, probably shouldn't be changed.
surface_color: Pretty much what it says on the tin. Color of the surfaces.
ao_strength: Blending strength of the approximated ambient occulsion.

## Limitations
Because this only renders the complex fractal on the surface of the plane meshes, the interior of the fractal cannot be entered.
While I was able to implement basic ambient occusion, adding proper shadows (either self shadows or from other objects) would require raymarching.
