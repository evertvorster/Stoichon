extends RefCounted
## **The surface bake on the GPU** — that it runs, that it produces a usable map, and that it gives every RID
## back.
##
## Two things this suite exists for, and neither can be checked headlessly:
##
## 1. **`create_local_rendering_device()` returns `null` under `--headless`**, so the ordinary suite run never
##    takes this path at all. `StoichonSurfaceGpu` is nonetheless the build-time bake in flight —
##    `StoichonSurfaceDistribution.prepare()` calls it synchronously for every body with a surface — so a fault here
##    is a fault on the first frame of the game, not in a probe.
## 2. **The RID count.** The allocator exhaustion that cost this project two flights was allocations never
##    given back, found in a pass that was reading someone else's error. The counter lives on the device
##    because that is where the allocations are.
##
## Run it where the bake is real:
##
##     tests/gpu_check.sh          (xvfb-run, the project's own runner, the GPU suites)
##
## The same split as `tests/shader_check.sh`: headless Godot neither compiles shaders nor draws, and a green
## headless run says nothing about either.

const WIDTH := 64
const HEIGHT := 32


func run(h, root: Node) -> void:
	print("  surface gpu")

	var gpu := StoichonSurfaceGpu.new()
	if not gpu.open():
		# **The reported absence, not a silent skip** — the same rule the cloud suite follows, so a run that
		# never reached a device says so rather than looking green. **Note what this check can and cannot say**:
		# it asserts that a REASON was reported, not which one, so a shader that will not compile satisfies it.
		# That is how the surface bake skipped itself for a day (a) and the run still looked healthy (b) — the
		# guard for the second half is `tests/gpu_check.sh` refusing the skip, and the guard for the first is the
		# `surface_field.gdshaderinc` uniform check in `test_render`.
		h.check(not gpu.error().is_empty(),
			"when the device or its kernel is unavailable, the reason is reported: %s" % gpu.error())
		print("    (skipped the bake: no usable rendering device — run tests/gpu_check.sh)")
		return
	h.check(gpu.live_rids() == 2,
		"an open device holds the shader and the pipeline, and nothing else (%d live)" % gpu.live_rids())

	# **The real entry point**: the plan is what the bake reads, exactly as `prepare()` builds it.
	var plan := StoichonSurfaceField.plan("planet:earth", 6.371e6)
	var image := gpu.bake(plan, WIDTH, HEIGHT)
	h.check(image != null, "the bake returned a map, not null")
	if image == null:
		h.check(false, "and its error is empty: '%s'" % gpu.error())
		gpu.close()
		return
	h.check(image.get_width() == WIDTH and image.get_height() == HEIGHT,
		"at the size it was asked for (%dx%d)" % [image.get_width(), image.get_height()])
	h.check(image.get_format() == Image.FORMAT_RH,
		"in the half-float format the surface shader samples")

	# **The map has to be a field, not a blank.** A zeroed read-back would satisfy every size check above, and
	# it is the failure a storage-image dispatch has when its uniform set is bound wrong.
	var lowest := INF
	var highest := -INF
	for y in HEIGHT:
		for x in WIDTH:
			var value := image.get_pixel(x, y).r
			lowest = minf(lowest, value)
			highest = maxf(highest, value)
	h.check(highest - lowest > 0.01,
		"and it carries the field rather than a flat read-back (%.3f to %.3f)" % [lowest, highest])

	h.check(gpu.live_rids() == 2,
		"a bake gives back everything it created — only the shader and pipeline remain (%d live)"
			% gpu.live_rids())

	# ===== THE HEIGHTS, AND THAT THEY ARE THE SAME FIELD ======================================
	#
	# **This is the geometry's height source** (`render.surface_translation`): the field asked at a list of directions
	# rather than rasterised. Two things have to hold — that it answers at all, and that its answer is the field the
	# bake and the draw shader see. The second is checked by RECONSTRUCTING the direction of a baked texel's centre,
	# exactly as the kernel does, and comparing that texel's value with the height asked at that direction: if the two
	# kernels read different plans, or the plan's block drifted, this is what catches it.
	var directions := PackedVector3Array()
	var sampled: Array[Vector3] = []
	var texels: Array[Vector2i] = []
	for y in [3, HEIGHT / 4, HEIGHT / 2, (3 * HEIGHT) / 4, HEIGHT - 4]:
		for x in [2, WIDTH / 4, WIDTH / 2, (3 * WIDTH) / 4, WIDTH - 3]:
			texels.append(Vector2i(x, y))
	for texel in texels:
		var u := (float(texel.x) + 0.5) / float(WIDTH)
		var v := (float(texel.y) + 0.5) / float(HEIGHT)
		var latitude := PI * 0.5 - v * PI
		var longitude := (u - 0.5) * TAU
		var cos_latitude := cos(latitude)
		directions.append(Vector3(
			cos_latitude * cos(longitude), sin(latitude), cos_latitude * sin(longitude)
		))
		sampled.append(directions[directions.size() - 1])
	var heights := gpu.heights(plan, directions)
	h.check(heights.size() == directions.size(),
		"the field answers at each direction it was asked (%d of %d)" % [heights.size(), directions.size()])
	if heights.size() == directions.size():
		var worst := 0.0
		var moving := 0.0
		for index in heights.size():
			var baked := image.get_pixel(texels[index].x, texels[index].y).r
			worst = maxf(worst, absf(heights[index] - baked))
			moving = maxf(moving, absf(heights[index]))
		# **Half a thousandth, not zero**: the map is `R16F`, so a baked texel is quantised at ~1e-3 of a value about 1.
		# A wrong plan would be orders of magnitude worse than that, not a little worse.
		h.check(worst < 2.0e-3,
			"and it is the field the bake drew, texel for texel (worst %.5f over %d samples)" % [worst, texels.size()])
		h.check(moving > 0.05, "with a field in it rather than zeros (largest magnitude %.3f)" % moving)
	h.check(gpu.heights(plan, PackedVector3Array()).is_empty(),
		"and asking for nothing costs nothing, rather than an error")
	h.check(gpu.live_rids() == 4,
		"the heights kernel holds its own shader and pipeline and nothing else (%d live)"
			% gpu.live_rids())
	var again := gpu.heights(plan, directions)
	h.check(again.size() == heights.size() and gpu.live_rids() == 4,
		"and a second call creates nothing and leaks nothing (%d live)" % gpu.live_rids())

	# **The staged dispatch, which is what the scene actually uses.** `dispatch_heights` returns without
	# syncing; the data is collected a frame later. The demo above is one call, so this is the shape the game
	# runs and the only place the split is exercised.
	var request := gpu.dispatch_heights(plan, StoichonSurfaceGpu.pack_directions(directions), directions.size())
	h.check(request >= 0 and gpu.pending_requests() == 1,
		"a dispatch is queued and answers a request id (%d, %d pending)" % [request, gpu.pending_requests()])
	var collected := gpu.collect_heights(request)
	h.check(collected.size() == heights.size(), "and collecting it gives the same count")
	h.check(gpu.pending_requests() == 0, "with nothing left pending")

	# **ONE dispatch at a time, and this is the check that says so.** A local `RenderingDevice` is a
	# single-frame device: a second `submit()` without a `sync()` logs *"device already submitted, call sync
	# to wait until done"* and the dispatch never happens, and a `sync()` with nothing submitted logs its own
	# error. A flight found it — the publish stages overlapped — and `gpu_check.sh` fails on any `ERROR:` in
	# the log, so this is the run that would have said so.
	var packed := StoichonSurfaceGpu.pack_directions(directions)
	var first := gpu.dispatch_heights(plan, packed, directions.size())
	var refused := gpu.dispatch_heights(plan, packed, directions.size())
	h.check(first >= 0 and refused == -1 and gpu.busy(),
		"a second dispatch while one is in flight is refused (%d, %d, busy=%s)" % [first, refused, gpu.busy()])
	h.check(gpu.collect_heights(first).size() == directions.size(), "the first one still collects")
	h.check(not gpu.busy(), "and the device is free once it has")
	var third := gpu.dispatch_heights(plan, packed, directions.size())
	h.check(third >= 0 and gpu.collect_heights(third).size() == directions.size(),
		"so the next dispatch goes and collects")
	if collected.size() == heights.size():
		var same := true
		for index in collected.size():
			same = same and is_equal_approx(collected[index], heights[index])
		h.check(same, "and the same heights, dispatch-then-collect as one call")

	gpu.close()
	h.check(gpu.live_rids() == 0,
		"and closing the device leaves nothing live (%d)" % gpu.live_rids())

	# **A dispatch still in flight when the device goes away.** Evert's flight crashed with signal 11 as the
	# process exited, after a session that had left a publish mid-stage: a submitted frame whose RIDs were
	# freed, and then the device freed, underneath it. Close must sync first — one submit, one sync, which
	# is what a local device allows — and this is the run that says so.
	var teardown := StoichonSurfaceGpu.new()
	h.check(teardown.open(), "a second device opens for the teardown test")
	if teardown.open():
		teardown.dispatch_heights(plan, packed, directions.size())
		teardown.close()
		h.check(teardown.live_rids() == 0,
			"closing with a dispatch in flight gives every RID back (%d live)" % teardown.live_rids())

	_test_a_scene_publishes_its_sea(h, root)


## **A scene, on a real device, publishes the sea with the ground.** This is the shape the game runs: a walk,
## a build, a heights DISPATCH, a collect a frame later, an offset on the pool, then the publish. Every other
## test of the publish happens headlessly, where there is no device and `_begin_publish` takes the immediate
## path — which is why a sea that only the staged path loses could ship.
##
## Evert, 2026-11-23: *"the ocean was absent for a long time while I was stationary. The second I started
## moving it popped in"* — and a body only republishes when its selection changes, so a publish that drops it
## leaves it missing until the ship moves.
func _test_a_scene_publishes_its_sea(h, root: Node) -> void:
	var sol: StoichonSolarSystem = load("res://systems/sol.tres")
	var scene := StoichonSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		h.check(false, "the Sol scene builds")
		return
	var earth := scene.body_by_id("planet:earth")
	h.check(earth != null and earth.ocean != null, "Earth has a sea node")
	if earth == null or earth.ocean == null:
		return
	var camera := Camera3D.new()
	root.add_child(camera)
	var pixel := StoichonLod.pixel_angle(camera.fov, 1080.0)
	var direction := Vector3(1.0, 0.0, 0.0)
	var angular := atan(200.0 * pixel)
	camera.global_position = earth.node.global_position + direction * (
		earth.radius / maxf(sin(angular), 1.0e-9)
	)
	# **Successive refinements, as a descent makes**: each one publishes again, and a publish that loses the
	# sea leaves it missing until the ship moves — because a body only republishes when its selection changes.
	for screen_radius in [200.0, 2000.0, 20000.0, 200.0]:
		var angle := atan(screen_radius * pixel)
		camera.global_position = earth.node.global_position + direction * (
			earth.radius / maxf(sin(angle), 1.0e-9)
		)
		scene.update_lod(camera)
		scene.await_patch_builds()
		h.check(earth.mesh.mesh != null, "the ground publishes at %d px on a device" % int(screen_radius))
		h.check(earth.ocean.mesh != null,
			"and the sea publishes with it at %d px, not on the next walk" % int(screen_radius))
	if earth.mesh.mesh != null and earth.ocean.mesh != null:
		var ground: Array = (earth.mesh.mesh as ArrayMesh).surface_get_arrays(0)
		var sea: Array = (earth.ocean.mesh as ArrayMesh).surface_get_arrays(0)
		h.check(
			(sea[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				== (ground[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
			"from the same lattice as the ground"
		)
	root.remove_child(camera)
	camera.free()
