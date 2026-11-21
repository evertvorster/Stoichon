class_name SpacesimStarSky
extends RefCounted
## The background sky: the real star field, drawn from the catalogue.
##
## It owns the `Sky` and its material, and it is the only thing that knows the host plumbing the
## shader needs. Everything it hands the shader is either the catalogue itself or a property of the
## camera it was given — nothing is hand-tuned per system, so there is no per-location constant that
## could drift out of step with the physics.
##
## **Why a `Sky` and not a sphere mesh.** There is no mesh to keep centred on the camera, an infinite
## background cannot be clipped by the far plane, and `EYEDIR` is already a world-space direction —
## verified by rolling the camera, not assumed — so the `CAMERA_POSITION_WORLD - centre` subtraction the
## deleted air shell needed, against a GLSL float's ~7 significant digits, cannot arise here.
##
## **The camera basis is passed in rather than taken from a built-in.** The shader computes where a
## star lands on screen and where the pixel is on screen, and those two MUST be computed the same
## way. Feeding both from the same basis is the only way to guarantee that; it is also what lets a
## test check the arithmetic without a GPU.

const SHADER := preload("res://addons/spacesim/render/sky_stars.gdshader")

## The catalogue is Sol calibration data — see `sky/PROVENANCE.md`. The generator for other systems
## is the next stage; when it exists, a system will name its own sky source and this constant goes.
const CATALOGUE_PATH := "res://addons/spacesim/sky/hyg_v44.stars"

var material: ShaderMaterial
var catalogue: SpacesimStarCatalogue
## The Sky this owns, for the Environment. Null when the catalogue could not be loaded, in which case
## the caller should keep whatever background it had.
var sky: Sky


## Returns false if the catalogue is missing or malformed, so the caller can fall back rather than
## render a black sky and let it read as a bug.
func create() -> bool:
	catalogue = SpacesimStarCatalogue.new()
	if not catalogue.load_file(CATALOGUE_PATH):
		catalogue = null
		return false

	material = ShaderMaterial.new()
	material.shader = SHADER

	sky = Sky.new()
	sky.sky_material = material
	return true


## **The body's air, for the far half of the atmosphere the star shader now draws.**
##
## Everything here is the physics the atmosphere pass already uses, handed over in the body's own
## frame: the eye's offset from the body centre, the sun as a direction, and the rotation that turns
## a world `EYEDIR` into that frame. The shader integrates the air from the camera to the top of the
## atmosphere, which is everything BEYOND the nearest drawn surface — the pass keeps the near half.
func set_air(
	air: Dictionary, planet_radius: float, atmosphere_radius: float,
	eye_local: Vector3, sun_local: Vector3, to_local: Basis
) -> void:
	if material == null:
		return
	material.set_shader_parameter("u_air_on", 1.0)
	material.set_shader_parameter("u_air_rayleigh", air.get("rayleigh", Vector3.ZERO))
	material.set_shader_parameter("u_air_rayleigh_h", float(air.get("rayleigh_scale_height", 1.0)))
	material.set_shader_parameter("u_air_absorption", air.get("absorption", Vector3.ZERO))
	material.set_shader_parameter("u_air_mie", float(air.get("mie", 0.0)))
	material.set_shader_parameter("u_air_mie_h", float(air.get("mie_scale_height", 1.0)))
	material.set_shader_parameter("u_air_mie_g", float(air.get("mie_anisotropy", 0.758)))
	material.set_shader_parameter("u_air_sun_intensity", float(air.get("sun_intensity", 0.0)))
	material.set_shader_parameter("u_planet_radius", planet_radius)
	material.set_shader_parameter("u_atmosphere_radius", atmosphere_radius)
	material.set_shader_parameter("u_eye_local", eye_local)
	material.set_shader_parameter("u_sun_local", sun_local)
	material.set_shader_parameter("u_to_local", to_local.orthonormalized())


## No atmosphere under the camera: the star sky exactly as it was.
func set_air_off() -> void:
	if material != null:
		material.set_shader_parameter("u_air_on", 0.0)


## The sky's own light, in lux — the sum of every star at or above the depth limit.
##
## This is the number the light floor comes from: in empty space it is the only light there is, so an
## exposure set for it IS the dark-adapted eye. Computed from the catalogue rather than authored, so
## it cannot drift from the sky it describes. The whole naked-eye sky comes to ~2e-4 lux, which is
## the measured figure the calibration was checked against.
func illuminance(limit_magnitude: float = 6.5) -> float:
	if catalogue == null:
		return 0.0
	# ponytail: a full scan of 119,613 stars, and it runs once — not per frame, and not per pixel.
	# If it ever needs to be live, the catalogue's cell table is already the index for it.
	var total := 0.0
	var image := catalogue.stars_texture.get_image()
	var width := image.get_width()
	for i in catalogue.count:
		var mag := image.get_pixel(i % width, i / width).a
		if mag <= limit_magnitude:
			total += 2.54e-6 * pow(10.0, -0.4 * mag)
	return total
