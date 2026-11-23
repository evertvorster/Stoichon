class_name StoichonBeltCloud
extends Node3D
## **A belt, drawn.** One `MultiMesh` of point quads, written once, shaded by the ring's splat shader.
##
## A rock is drawn as the light it reflects, and only becomes a shape when it resolves
## ([StoichonFragmentBodies]) — `S4`, and the same handover a ring makes. What is different from a ring is
## only where the particles come from: a band is generated whole as a sheet, a belt is a *set* of rocks
## placed once (see [StoichonPopulationRocks]).
##
## **`buffer`, not a million `set_instance_transform` calls.** 1.1 million rocks is 17.6 million floats;
## one `PackedFloat32Array` assigned to [member MultiMesh.buffer] is a single upload, where the per-instance
## setters pay a GDScript call and a binding for each of the twelve basis floats. The layout is the
## transform's own three rows of four, then the instance's four custom-data floats.
##
## **The instance transform carries the rock's radius in its basis scale** — the shader reads
## `length(MODELVIEW_MATRIX[0])` and builds its own quad — and the custom data carries "lit" in `.r` and
## "draw this one" in `.g`, exactly as the ring's does.
##
## **The rock's position in the buffer is `float32`, and that is the one number worth knowing here.** At
## 5 x 10^11 m from the origin the quantisation is tens of kilometres — 32 km at 3.6 x 10^11 m, measured —
## which is a quarter of a pixel at any distance a splat is drawn from. A rock close enough to look at is a
## real body with a double-precision node instead, which is why this is a rounding and not a fault.

const SHADER := preload("res://addons/stoichon/render/shaders/ring_splats.gdshader")

var _multimesh: MultiMesh
var _material: ShaderMaterial
## The star's direction as the shader receives it: a unit vector in view space.
var _view_star := Vector3(0.0, 0.0, -1.0)


## Build the draw for a rock set. `population` gives the band's extent, which is what the node's own bounds
## are — **and the bounds have to be set by hand**, because a `MultiMesh` whose buffer was assigned whole
## has no instance data for the engine to compute an AABB from, and one with no bounds is culled at once.
static func of(rocks: StoichonPopulationRocks, population: StoichonPopulation) -> StoichonBeltCloud:
	var cloud := StoichonBeltCloud.new()
	cloud.name = "Belt"
	cloud._build(rocks, population)
	return cloud


func _build(rocks: StoichonPopulationRocks, population: StoichonPopulation) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = StoichonBodyRenderer.point_quad()
	multimesh.instance_count = rocks.count()

	var floats := PackedFloat32Array()
	floats.resize(rocks.count() * 16)
	for index in rocks.count():
		var radius := rocks.diameter_of(index) * 0.5
		var where := rocks.position_of(index)
		var at := index * 16
		# Row 0, row 1, row 2 of the 3x4 transform — a diagonal basis scaled by the radius, then the origin.
		floats[at] = radius
		floats[at + 1] = 0.0
		floats[at + 2] = 0.0
		floats[at + 3] = where.x
		floats[at + 4] = 0.0
		floats[at + 5] = radius
		floats[at + 6] = 0.0
		floats[at + 7] = where.y
		floats[at + 8] = 0.0
		floats[at + 9] = 0.0
		floats[at + 10] = radius
		floats[at + 11] = where.z
		# **Lit, and drawn**: `.r` is the fraction of the star's light the rock gets and `.g` is "draw this
		# one". A belt has no planet casting a shadow on it, so nothing here is ever shaded.
		floats[at + 12] = 1.0
		floats[at + 13] = 1.0
		floats[at + 14] = 0.0
		floats[at + 15] = 0.0
	multimesh.buffer = floats
	_multimesh = multimesh

	var outer := maxf(population.semi_major_axis.y, 1.0)
	multimesh.custom_aabb = AABB(Vector3(-outer, -outer, -outer), Vector3(outer, outer, outer) * 2.0)

	var node := MultiMeshInstance3D.new()
	node.name = "Splats"
	node.multimesh = _multimesh
	# A rock is not a volume of air: nothing here casts or receives a shadow.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.render_priority = StoichonRingView.RING_PRIORITY
	node.material_override = material
	add_child(node)
	_material = material


## **Per frame**: the four things the shader needs that change with the eye, exactly as a ring's does.
##
## `illuminance` is the star's light at the band — taken at the **middle** of the band, because the rocks
## span 2.1 to 3.3 AU and one number for the whole population is a factor of 2.5 either side. It is named
## rather than silently modelled, and a per-rock value would cost a third custom-data channel.
func update(
	pixel_angle: float, illuminance: float, tint: Color, centre: Vector3, star_position: Vector3,
	camera: Camera3D = null
) -> void:
	if _material == null:
		return
	# `disc_luminance` with the phase left out: the phase is per rock, and the shader computes it. What is
	# handed over is the light arriving divided by pi times the bond albedo.
	var radiance := illuminance / PI
	_material.set_shader_parameter("pixel_scale", 1.0 / max(pixel_angle, 1.0e-9))
	_material.set_shader_parameter("glow_linear", Color(tint.r * radiance, tint.g * radiance, tint.b * radiance))
	var floor := StoichonRingModel.unlit_radiance(radiance)
	_material.set_shader_parameter("unlit_linear", Color(tint.r * floor, tint.g * floor, tint.b * floor))
	if camera != null:
		var basis: Basis = camera.get_global_transform_interpolated().basis
		_view_star = (basis.inverse() * (star_position - centre)).normalized()
	_material.set_shader_parameter("u_star_view", _view_star)


## What the shader is being told — for the tests, because "it draws nothing" is answered by reading the
## numbers rather than by looking at a picture.
func shader_parameter(name: String) -> Variant:
	return _material.get_shader_parameter(name) if _material != null else null


func instance_count() -> int:
	return _multimesh.instance_count if _multimesh != null else 0


func multimesh() -> MultiMesh:
	return _multimesh


func draw_node() -> MultiMeshInstance3D:
	return get_node_or_null("Splats") as MultiMeshInstance3D
