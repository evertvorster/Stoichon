extends SceneTree
## Bake the galactic band into `addons/spacesim/celestial/generated/milky_way.exr`.
##
##     timeout 180 xvfb-run -a godot-double-mono --path . --script res://tools/bake_band.gd
##
## A build step, not part of the suite: a local `RenderingDevice` needs a GPU, and `tests/run.sh` runs headless.
## `quit()` is on every path, because a `--script` runner that misses it hangs.

const SIZE := Vector2i(2048, 1024)
const OUT_DIR := "res://addons/spacesim/celestial/generated"
const NOTE := """# milky_way.exr — generated, do not edit

An equirectangular map of the galactic band's **shape**: longitude across (zero at the galactic centre), latitude
up, linear RGB in half float, in the GALACTIC frame. The sampler applies the frame's rotation and the band's
surface brightness and display gain, so the map survives a change to any of them.

Produced by `tools/bake_band.gd` from `addons/spacesim/celestial/shaders/milky_way.gdshaderinc` — the same file
`celestial_sky.gdshader` includes at run time, so the baked and the procedural band cannot disagree.
"""


func _initialize() -> void:
	var baker := SpacesimBandGpu.new()
	var image := baker.bake(SIZE.x, SIZE.y)
	if image == null:
		print("BAKE: failed — %s" % baker.error())
		baker.close()
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := "%s/milky_way.exr" % OUT_DIR
	var error := image.save_exr(path)
	var note := FileAccess.open("%s/milky_way.provenance.md" % OUT_DIR, FileAccess.WRITE)
	if note != null:
		note.store_string(NOTE)
		note.close()
	baker.close()
	if error != OK:
		print("BAKE: could not write %s (error %d)" % [path, error])
		quit(1)
		return
	print("BAKE: wrote %s, %s" % [path, str(image.get_size())])
	quit()
