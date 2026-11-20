extends SceneTree
## Bake the extended objects into `addons/spacesim/celestial/generated/deep_sky.exr`.
##
##     timeout 20 xvfb-run -a godot-double-mono --path . --script res://tools/bake_deep_sky.gd
##
## A build step: a local `RenderingDevice` needs a GPU. `quit()` on every path, output to a file.

const OUT_DIR := "res://addons/spacesim/celestial/generated"
const NOTE := """# deep_sky.exr — generated, do not edit

An atlas of the extended objects' **shape and colour**: dimensionless linear RGB in half float, one 512x512 cell
per object, in the order `SpacesimDeepSky.objects()` returns them. The object's integrated magnitude, the display
gain and the frame's currency are applied by the sampler, so the atlas survives a change to any of them.

Produced by `tools/bake_deep_sky.gd` from `addons/spacesim/celestial/shaders/deep_sky_profile.gdshaderinc` — the
same file `deep_sky_quad.gdshader` includes at run time, so a baked object and a procedural one cannot disagree.
"""


func _initialize() -> void:
	var baker := SpacesimDeepSkyGpu.new()
	var image := baker.bake(SpacesimDeepSky.objects())
	if image == null:
		print("BAKE: failed — %s" % baker.error())
		baker.close()
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := "%s/deep_sky.exr" % OUT_DIR
	var error := image.save_exr(path)
	var note := FileAccess.open("%s/deep_sky.provenance.md" % OUT_DIR, FileAccess.WRITE)
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
