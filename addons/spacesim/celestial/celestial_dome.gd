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

## The uncatalogued field: how many, and the magnitudes it spans. **It starts where `hyg_v44` ends** — that
## catalogue is complete to 8.0 and holds stars to 10.5 — so this is light the catalogue does not already hold,
## and every star in it is dimmer than anything the catalogue carries.
const FAINT_COUNT := 400_000
const FAINT_MAG_MIN := 10.5
const FAINT_MAG_MAX := 12.0
const FAINT_SEED := 20261120

## The baked maps: 2048x1024 each, made once when the dome is built and **held in memory** — they are a way of not
## re-evaluating the same function every frame, not content to ship. The maths stays in the shaders, so the
## procedural path is always there to tune against.
const BAND_MAP_SIZE := Vector2i(2048, 1024)
const DEEP_SKY_CELL := 512
const DEEP_SKY_COLUMNS := 4

## The display gain on the deep-sky objects. At 1.0 each object is its own integrated magnitude spread over its
## own angular area — physically right, and invisible, because M31 really is about 22 magnitudes per square
## arcsecond. Evert flies with these visible, so this is a chosen gain and is named as one.
const DEEP_SKY_GAIN := 30.0

var _catalogue: SpacesimStarCatalogue
var _stars: MultiMeshInstance3D
var _deep_sky: MultiMeshInstance3D
var _star_material: ShaderMaterial
var _deep_sky_material: ShaderMaterial
var _sky_material: ShaderMaterial
var _faint: MultiMeshInstance3D
var _faint_material: ShaderMaterial
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
	_build_faint()
	_build_deep_sky()
	return true


## Follow the camera. Called once a frame.
##
## **Nothing else is published, deliberately.** Every layer places itself with the engine's own `VIEW_MATRIX` and
## `PROJECTION_MATRIX` and measures its pixels from the drawing buffer's own `VIEWPORT_SIZE` — all three of which
## belong to the frame being drawn. A number read here would be the *previous* frame's camera, and this project
## has three different resolutions (the 3D render resolution, the viewport, and the canvas the text is laid out
## in) for a host-side number to be wrong about.
func update(camera: Camera3D) -> void:
	if camera == null:
		return
	global_position = camera.global_position


## The depth tunable: which catalogue stars are drawn, not which are built. A uniform write, so sweeping it
## cannot reshuffle the field.
func set_limit_magnitude(magnitude: float) -> void:
	if _star_material != null:
		_star_material.set_shader_parameter("u_limit_mag", magnitude)
	# **The uncatalogued field appears only past the catalogue's own depth.** Below it the catalogue already holds
	# everything the setting asks for, and a generated field underneath it would be light the catalogue does not
	# have — which is how a sky ends up brighter than its own ambient.
	if _faint != null:
		_faint.visible = magnitude > FAINT_MAG_MIN


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
	# The band's tilt, built from the published pole and centre rather than from Euler angles.
	_sky_material.set_shader_parameter("u_galactic", SpacesimDeepSky.galactic_basis())
	sky = Sky.new()
	sky.sky_material = _sky_material


## Whether the uncatalogued field is drawn at all. It is light the catalogue does not hold, so a caller that
## wants only the measured sky can ask for that.
func set_faint_on(on: bool) -> void:
	if _faint != null:
		_faint.visible = on


## The uncatalogued field: sprites below the catalogue's own depth, drawn by the star shader itself.
##
## **A drawn star, not an evaluated one.** A per-pixel field would be finer than the pixel it lands on and would
## therefore be sampled afresh every frame the camera moves — the flicker this whole module exists to remove. These
## are the same quads as the catalogue's, snapped to a pixel and holding their light, just dimmer than anything the
## catalogue holds: `FAINT_MAG_MIN` is `hyg_v44`'s own limit, so this is light the catalogue does not already
## carry.
func _build_faint() -> void:
	var count := FAINT_COUNT
	var data := PackedFloat32Array()
	var colour := PackedFloat32Array()
	data.resize(count * 4)
	colour.resize(count * 4)
	var rng := RandomNumberGenerator.new()
	rng.seed = FAINT_SEED
	var lo := pow(10.0, 0.4 * FAINT_MAG_MIN)
	var hi := pow(10.0, 0.4 * FAINT_MAG_MAX)
	for i in count:
		# A uniform direction: `z` uniform on [-1, 1] and the azimuth uniform, which is the only way to get one.
		var z := rng.randf_range(-1.0, 1.0)
		var phi := rng.randf_range(0.0, TAU)
		var ring := sqrt(maxf(1.0 - z * z, 0.0))
		data[i * 4 + 0] = ring * cos(phi)
		data[i * 4 + 1] = ring * sin(phi)
		data[i * 4 + 2] = z
		data[i * 4 + 3] = 2.5 * log(lo + rng.randf() * (hi - lo)) / log(10.0)
		colour[i * 4 + 0] = clampf(rng.randfn(1.2, 0.4), -0.3, 2.0)

	_faint_material = ShaderMaterial.new()
	_faint_material.shader = STAR_SHADER
	_faint_material.set_shader_parameter("u_gain", 1.0)
	_faint_material.set_shader_parameter("u_psf_px", PSF_PX)
	_faint_material.set_shader_parameter("u_size_exponent", SIZE_EXPONENT)
	_faint_material.set_shader_parameter("u_lux_reference", _reference_lux)
	# The field is its own layer, so its depth is its own: it is drawn only when the sky's depth asks for it, and
	# the layer above it never has to know.
	_faint_material.set_shader_parameter("u_limit_mag", FAINT_MAG_MAX)
	_faint = _multimesh_layer("FaintField", _faint_material, -1, count)
	_faint_material.set_shader_parameter("u_stars", _float_texture(data))
	_faint_material.set_shader_parameter("u_star_colour", _float_texture(colour))
	_faint.visible = false


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


## Bake the band and the objects into textures, once, in memory.
##
## **Baking is a way of not doing the same arithmetic every frame**, not a way of shipping pictures: two
## `ImageTexture`s are created here and dropped with the dome. The shaders keep the maths, so the procedural path
## is always available to tune against — bake again after a change, or turn `u_use_baked` off and look at the
## original.
##
## A failure is not fatal: if there is no local `RenderingDevice` (a headless run, or a driver without one) the
## flag simply stays off and the shaders evaluate as before.
func _bake_maps() -> void:
	var band := SpacesimBandGpu.new()
	var band_image := band.bake(BAND_MAP_SIZE.x, BAND_MAP_SIZE.y)
	band.close()
	if band_image != null:
		_sky_material.set_shader_parameter("u_band_map", _textured(band_image))
		_sky_material.set_shader_parameter("u_use_baked", true)

	var atlas := SpacesimDeepSkyGpu.new()
	var atlas_image := atlas.bake(SpacesimDeepSky.objects())
	atlas.close()
	if atlas_image != null:
		_deep_sky_material.set_shader_parameter("u_atlas", _textured(atlas_image))
		_deep_sky_material.set_shader_parameter("u_use_baked", true)


## An `ImageTexture` with a mip chain: the maps are drawn at every size from a few pixels to the whole sky, and
## without mips the small end aliases.
func _textured(image: Image) -> ImageTexture:
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## The band is in the sky slot, not on a mesh: it is a function of the direction you look in, and a sky shader is
## handed exactly that per pixel. See `celestial_sky.gdshader` — a 100 m sphere in a 1.6e12 m scene never appeared.
func set_band(basis: Basis) -> void:
	if _sky_material != null:
		_sky_material.set_shader_parameter("u_galactic", basis)


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
