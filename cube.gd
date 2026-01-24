extends Node3D

var accum = 0
func _process(delta: float) -> void:
	accum += delta
	rotate_y(delta * 0.3)
	rotation.x = sin(accum) * 0.1
