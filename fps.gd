extends Label

func _process(_delta):
	text = "GPU Time: %.2fms" % (Performance.get_monitor(Performance.TIME_PROCESS) * 1000)
