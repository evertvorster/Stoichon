class_name SpacesimBeltCloud
extends MultiMeshInstance3D
## **A population's real rocks, drawn once.** One MultiMesh, one material, positions that never change.
##
## The shading is the rings' own (`ring_splats.gdshader`): each rock is a disc whose size is its own radius, whose
## light is Lambert's law at the phase angle between the star and the eye as seen FROM that rock, and whose
## coverage is its true area in pixels — so a 10 km rock is a faint dot from far away and grows into a disc as you
## close on it, by `r²` of light rather than by an author's fade.
##
## **What it is not:** the belt. The belt is 1.1e11 rocks of 10 m and up, most of them below a pixel from any
## distance worth drawing, and they stay what they were — a density, which `SpacesimPopulationField` samples around
## the ship. These are only the ones big enough to have a position; see `SpacesimPopulation.shown_floor`.

const SHADER := preload("res://addons/spacesim/render/shaders/ring_splats.gdshader")
## One quad, unit size, scaled per instance to the rock's radius — the same quad the rings use.
const QUAD_PIXELS := 1.0

var _material: ShaderMaterial
var _mesh := ArrayMesh.new()


static func of(rocks: SpacesimPopulationRocks) -> SpacesimBeltCloud:
	var cloud := SpacesimBeltCloud.new()
	if rocks == null or rocks.size() == 0:
		return cloud
	cloud._material = ShaderMaterial.new()
	cloud._material.shader = SHADER
	cloud.material_override = cloud._material
	cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cloud.custom_aabb = AABB(Vector3(-1.0e13, -1.0e13, -1.0e13), Vector3(2.0e13, 2.0e13, 2.0e13))
	var multimesh := MultiMesh.new()
	# **The quad is the same one the rings draw their spots with** — one unit square, and the vertex stage scales it
	# to the rock's own radius, so the mesh is shared rather than made per population.
	multimesh.mesh = SpacesimBodyRenderer.point_quad()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.instance_count = rocks.size()
	for index in rocks.size():
		var radius := rocks.radii[index]
		multimesh.set_instance_transform(
			index, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * radius), rocks.positions[index])
		)
		# A rock in the belt is lit by the star and never in a planet's shadow: `.r` is the shadow term, `.g` is
		# "draw this one" — the same two channels the rings write for their own spots.
		multimesh.set_instance_custom_data(index, Color(1.0, 1.0, 0.0, 0.0))
	cloud.multimesh = multimesh
	return cloud


## **The frame's numbers.** `glow` is the light a rock at the belt's mean radius reflects, divided by `π` — the
## rings' `disc_luminance` with the phase term left to the shader. One value for the whole population, so the belt's
## own `1/r²` across 2.1 to 3.3 AU is not modelled; it is a factor of 2.4 at the edges, and it is named here rather
## than hidden.
func update_view(pixel_angle: float, glow: Color, star_view: Vector3) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("pixel_scale", 1.0 / maxf(pixel_angle, 1.0e-9))
	_material.set_shader_parameter("glow_linear", Vector3(glow.r, glow.g, glow.b))
	_material.set_shader_parameter("unlit_linear", Vector3(0.04, 0.04, 0.04))
	_material.set_shader_parameter("u_star_view", star_view)
