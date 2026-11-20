class_name SpacesimCelestialDome
extends Node3D
## The infinite-distance astronomical background, drawn as objects: the catalogue's stars, the deep-sky objects,
## the galactic band, and the faint uncatalogued field behind them.
##
## ## Why this is not a sky shader
##
## A star is a flux, not a shape. It has no angular size worth resolving, but it still has to land on *some*
## pixel, and it has to land the same way every frame. Evaluating a per-pixel cell search makes the pixel the
## unit, and a star near a cell boundary is then visited by some of the pixels that should carry it and not
## others: a lattice. That is what SpaceSim has been chasing, and it is not fixable in the cell arithmetic —
## the pixel should not be the unit in the first place.
##
## Drawing one quad per star makes the *star* the unit. Its centre is projected and snapped to a pixel centre
## below one pixel of footprint, its light is its flux over the pixels it covers, and where it lands is
## arithmetic rather than an accident of which cell a pixel happened to look in.
##
## ## The numbers come from the host, and there are only five of them
##
## Every layer is placed with a **direction**: `ndc = (dot(d, right), dot(d, up)) / (dot(d, fwd) * tan_half)`.
## That needs the camera's three basis vectors, the field of view's two tangents, and the render target's size —
## and nothing else. No projection matrix, no viewport built-in, no derivatives.
##
## **That is deliberate.** SpaceSim's 3D buffer, its window and its canvas are three different sizes, and a
## shader that guesses which one it has been handed gets a pixel size wrong by that ratio in *both* axes — which
## looks like stars that are the right brightness and the wrong shape, and is very hard to see. The host knows the
## render target (`Viewport.size`) and reads the field of view every frame, so the host is what says.
##
## ## The frame's currency
##
## These shaders write `RADIANCE_GAIN`-lifted radiance like every other path in the scene — see
## `radiance.gdshaderinc` — so a star and a sunlit planet are in the same units and `SpacesimExposurePass`
## decides what is seen. A layer that applied an exposure of its own would break exactly that.
##
## ## What it does not depend on
##
## No ship, no physics, no UI, no body: it takes a `Camera3D` and a catalogue. The dome carries the camera's
## position each frame and ignores its rotation, because rotation is what the view *means* — a camera that turns
## sees a different part of a fixed sky, which is what a sky is.

const STAR_SHADER := preload("res://addons/spacesim/celestial/shaders/catalog_star.gdshader")
const DEEP_SKY_SHADER := preload("res://addons/spacesim/celestial/shaders/deep_sky_quad.gdshader")
const BAND_SHADER := preload("res://addons/spacesim/celestial/shaders/galactic_band.gdshader")
const SKY_SHADER := preload("res://addons/spacesim/celestial/shaders/celestial_sky.gdshader")

## Texels per row of a catalogue texture. The star data is `(direction.xyz, magnitude)` per star, which is what
## the catalogue's own asset already holds.
const TEXELS_PER_ROW := 512

## How wide a reference star is drawn, as a fraction of a pixel, and how much faster a brighter one widens.
##
## **Sub-pixel on purpose.** At this game's field of view every catalogue star comes out under one pixel, which
## is the regime the snap is built for and the one a star belongs in: it is a point, and a point is a pixel.
const PSF_PX := 0.55
const SIZE_EXPONENT := 0.18

## The display gain on the deep-sky objects. At 1.0 each object is its own integrated magnitude spread over its
## own angular area — physically right, and invisible, because M31 really is about 22 magnitudes per square
## arcsecond. Evert flies with these visible, so this is a chosen gain and is named as one.
const DEEP_SKY_GAIN := 30.0

var _catalogue: SpacesimStarCatalogue
var _stars: MultiMeshInstance3D
var _deep_sky: MultiMeshInstance3D
var _band: MeshInstance3D
var _star_material: ShaderMaterial
var _deep_sky_material: ShaderMaterial
var _band_material: ShaderMaterial
var _sky_material: ShaderMaterial
## The Sky this owns for the Environment's background — Layer 1.
var sky: Sky
var _reference_lux := 1.011e-8


## Build every layer. Returns false when there is no catalogue to draw, so the caller can say so rather than
## render a black sky and let it read as a bug.
func build(catalogue: SpacesimStarCatalogue) -> bool:
	if catalogue == null or catalogue.count == 0:
		return false
	_catalogue = catalogue
	_build_sky()
	_build_stars()
	_build_deep_sky()
	_build_band()
	return true


## Follow the camera and hand the layers this frame's five numbers. Called once a frame.
##
## **The render target's size, not the window's and not the canvas's** — `viewport.size` is the buffer the 3D is
## actually drawn into, and it is the only one a pixel means anything in.
func update(camera: Camera3D) -> void:
	if camera == null:
		return
	var viewport := camera.get_viewport()
	if viewport == null:
		return
	var size := Vector2(viewport.size)
	if size.x <= 0.0 or size.y <= 0.0:
		return
	global_position = camera.global_position

	# Typed explicitly: `get_global_transform_interpolated()` has no inferable return type.
	var basis: Basis = camera.get_global_transform_interpolated().basis
	var tan_y := tan(deg_to_rad(camera.fov * 0.5))
	var tan_half := Vector2(tan_y * size.x / size.y, tan_y)
	for material in [_sky_material, _star_material, _deep_sky_material, _band_material]:
		if material == null:
			continue
		material.set_shader_parameter("u_right", basis.x)
		material.set_shader_parameter("u_up", basis.y)
		material.set_shader_parameter("u_fwd", -basis.z)
		material.set_shader_parameter("u_tan_half", tan_half)
		material.set_shader_parameter("u_view_size", size)


## The depth tunable: which catalogue stars are drawn, not which are built. A uniform write, so sweeping it
## cannot reshuffle the field.
func set_limit_magnitude(magnitude: float) -> void:
	if _star_material != null:
		_star_material.set_shader_parameter("u_limit_mag", magnitude)


## The hand brightness scaler, in linear units (`sky.star_gain` arrives in decades and the host converts).
func set_gain(gain: float) -> void:
	if _star_material != null:
		_star_material.set_shader_parameter("u_gain", gain)


## Layer 1: the empty background and the uncatalogued field, in the sky slot.
##
## A sky is drawn behind all geometry, so this is the one layer that cannot be occluded by a body — which is
## exactly right for the background beyond everything, and is why the stars are not here.
func _build_sky() -> void:
	_sky_material = ShaderMaterial.new()
	_sky_material.shader = SKY_SHADER
	sky = Sky.new()
	sky.sky_material = _sky_material


## The depth of the uncatalogued field. It starts where the catalogue ends; see `celestial_sky.gdshader`.
func set_faint_depth(magnitude: float) -> void:
	if _sky_material != null:
		_sky_material.set_shader_parameter("u_faint_depth", magnitude)


## Whether the uncatalogued field is drawn at all. It is light the catalogue does not hold, so a caller that
## wants only the measured sky can ask for that.
func set_faint_on(on: bool) -> void:
	if _sky_material != null:
		_sky_material.set_shader_parameter("u_faint_on", 1.0 if on else 0.0)


## The stars in the field — a test reads this rather than the buffer, which cannot be read back headless.
func star_count() -> int:
	return _catalogue.count if _catalogue != null else 0


# --- the layers -------------------------------------------------------------------------------------

func _build_stars() -> void:
	var data := PackedFloat32Array()
	var colour := PackedFloat32Array()
	var stars := _catalogue.stars_texture.get_image()
	var colours := _catalogue.colour_texture.get_image()
	var width := stars.get_width()
	data.resize(_catalogue.count * 4)
	colour.resize(_catalogue.count * 4)
	for i in _catalogue.count:
		var texel := stars.get_pixel(i % width, i / width)
		data[i * 4 + 0] = texel.r
		data[i * 4 + 1] = texel.g
		data[i * 4 + 2] = texel.b
		data[i * 4 + 3] = texel.a
		colour[i * 4 + 0] = colours.get_pixel(i % width, i / width).r

	_star_material = ShaderMaterial.new()
	_star_material.shader = STAR_SHADER
	# `sky.star_gain` is in decades; the exposure pass divides the frame's gain back out, so this is a plain
	# multiplier on top of a physical radiance.
	_star_material.set_shader_parameter("u_gain", 1.0)
	_star_material.set_shader_parameter("u_psf_px", PSF_PX)
	_star_material.set_shader_parameter("u_size_exponent", SIZE_EXPONENT)
	_star_material.set_shader_parameter("u_lux_reference", _reference_lux)
	_stars = _multimesh_layer("CatalogStars", _star_material, -1, _catalogue.count)
	_star_material.set_shader_parameter("u_stars", _float_texture(data))
	_star_material.set_shader_parameter("u_star_colour", _float_texture(colour))


func _build_deep_sky() -> void:
	var objects := SpacesimDeepSky.objects()
	_deep_sky_material = ShaderMaterial.new()
	_deep_sky_material.shader = DEEP_SKY_SHADER
	_deep_sky_material.set_shader_parameter("u_gain", DEEP_SKY_GAIN)
	_deep_sky = _multimesh_layer("DeepSkyObjects", _deep_sky_material, -2, objects.size())

	var placement := PackedFloat32Array()
	var shape := PackedFloat32Array()
	var tint := PackedFloat32Array()
	var texels := TEXELS_PER_ROW * maxi(int(ceil(float(objects.size()) / TEXELS_PER_ROW)), 1)
	for array in [placement, shape, tint]:
		array.resize(texels * 4)
	for i in objects.size():
		var entry: SpacesimDeepSkyEntry = objects[i]
		var direction := entry.direction.normalized()
		placement[i * 4 + 0] = direction.x
		placement[i * 4 + 1] = direction.y
		placement[i * 4 + 2] = direction.z
		placement[i * 4 + 3] = entry.major_rad() * 0.5
		shape[i * 4 + 0] = entry.minor_rad() / maxf(entry.major_rad(), 1.0e-12)
		shape[i * 4 + 1] = entry.roll_rad()
		shape[i * 4 + 2] = entry.profile
		shape[i * 4 + 3] = entry.luminance()
		tint[i * 4 + 0] = entry.tint.r
		tint[i * 4 + 1] = entry.tint.g
		tint[i * 4 + 2] = entry.tint.b
	_deep_sky_material.set_shader_parameter("u_object", _float_texture(placement))
	_deep_sky_material.set_shader_parameter("u_shape", _float_texture(shape))
	_deep_sky_material.set_shader_parameter("u_tint", _float_texture(tint))


## The galactic band: a sphere the camera sits inside, and a function of galactic latitude and longitude.
##
## **A function, not a photograph.** The band has no resolution of its own to lose, so it cannot shimmer: a pixel
## asks which way in the galactic frame it is looking and gets a value. A real image of the Milky Way would need
## a texture, a mip chain and a filter, and those are what keep a picture still — an analytic field is still by
## construction. The sphere is only there to give the fragment stage a surface to compute on.
func _build_band() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 100.0
	sphere.height = 200.0
	sphere.radial_segments = 64
	sphere.rings = 32
	_band_material = ShaderMaterial.new()
	_band_material.shader = BAND_SHADER
	_band_material.render_priority = -3
	_band_material.set_shader_parameter("u_galactic", SpacesimDeepSky.galactic_basis())
	_band = MeshInstance3D.new()
	_band.name = "MilkyWaySphere"
	_band.mesh = sphere
	_band.material_override = _band_material
	add_child(_band)


## One MultiMesh layer: a unit quad per instance, identity transforms, and an AABB that says "always visible".
##
## **A quad, not a vertex list.** The instance index picks the object, so the geometry is the same four vertices
## for everything in the layer, and the position is computed in the shader from a direction.
func _multimesh_layer(name: String, material: ShaderMaterial, priority: int, count: int) -> MultiMeshInstance3D:
	material.render_priority = priority
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.orientation = PlaneMesh.FACE_Z
	var buffer := MultiMesh.new()
	buffer.transform_format = MultiMesh.TRANSFORM_3D
	buffer.mesh = quad
	buffer.use_colors = false
	buffer.use_custom_data = false
	buffer.instance_count = count
	# The instances sit at the origin and are placed in the shader, so an engine-side bound would be a point.
	buffer.custom_aabb = AABB(Vector3(-1.0e7, -1.0e7, -1.0e7), Vector3(2.0e7, 2.0e7, 2.0e7))
	var identity := Transform3D.IDENTITY
	for i in count:
		buffer.set_instance_transform(i, identity)
	var node := MultiMeshInstance3D.new()
	node.name = name
	node.multimesh = buffer
	node.material_override = material
	add_child(node)
	return node


## A float texture of `(x, y, z, w)` texels, padded: a texture's data is `rows * width` texels and the count is
## rarely a multiple of the width, which `Image.create_from_data` rejects outright.
func _float_texture(values: PackedFloat32Array) -> ImageTexture:
	var texels: int = values.size() / 4
	var rows: int = maxi(int(ceil(float(texels) / TEXELS_PER_ROW)), 1)
	values.resize(TEXELS_PER_ROW * rows * 4)
	var image := Image.create_from_data(
		TEXELS_PER_ROW, rows, false, Image.FORMAT_RGBAF, values.to_byte_array()
	)
	return ImageTexture.create_from_image(image)
