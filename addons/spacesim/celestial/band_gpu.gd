class_name SpacesimBandGpu
extends RefCounted
## Bakes the galactic band into an equirectangular map.
##
## ## The shape is the one `SpacesimSurfaceGpu` and `SpacesimCloudGpu` already use
##
## A **local `RenderingDevice`**, a compute shader assembled by concatenating `.gdshaderinc` files that the game's
## own shaders also `#include`, one dispatch into a texture, and a readback. Nothing here is new: a source string
## gets no preprocessor help, so the include is read and prepended by hand — the same three lines `CloudGpu` uses.
##
## **One source.** `milky_way.gdshaderinc` holds the band's shape, and `celestial_sky.gdshader` includes it for
## run time while this compiles it for the bake. Tune the band, bake again, and the two cannot disagree.
##
## ## What it bakes, and what it does not
##
## The **shape and colour**, not the brightness: `band_shape()` is a dimensionless linear RGB, so the map survives a
## change to the band's surface brightness or its display gain without being baked again. The currency is applied by
## whoever samples it.
##
## `uv` maps to a direction in the GALACTIC frame — longitude across, latitude up — so the map carries no rotation
## and the sampler applies `u_galactic` itself.
##
## ## The run needs a GPU
##
## A local `RenderingDevice` is not available headless (`SpacesimSurfaceGpu.open()` says the same), so a bake is a
## build step run under `xvfb-run`, like `tests/gpu_check.sh` and the cloud bake.

const BAND_PATH := "res://addons/spacesim/celestial/shaders/milky_way.gdshaderinc"

const KERNEL := """
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform writeonly image2D band_image;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float pad0;
	float pad1;
} params;
void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (texel.x >= int(params.size.x) || texel.y >= int(params.size.y)) {
		return;
	}
	// Equirectangular: longitude across, latitude up, zero longitude at the galactic centre.
	vec2 uv = (vec2(texel) + vec2(0.5)) / params.size;
	float longitude = (uv.x - 0.5) * 2.0 * PI_F;
	float latitude = (uv.y - 0.5) * PI_F;
	vec3 galactic = vec3(cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude));
	imageStore(band_image, texel, vec4(band_shape(galactic), 1.0));
}
"""

var _device: RenderingDevice
var _shader: RID
var _pipeline: RID
var _error := ""


## A local device, and the shader compiled from the include plus the kernel.
func open() -> bool:
	if _device != null:
		return _pipeline.is_valid()
	# **`create_local_rendering_device()`, not `RenderingDevice.new()`** — the class is abstract and cannot be
	# constructed. This is the same call `SpacesimSurfaceGpu.open()` makes.
	_device = RenderingServer.create_local_rendering_device()
	if _device == null:
		_error = "no local RenderingDevice (headless, or not a Vulkan/Forward+ run)"
		return false
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = "#version 450\n" + FileAccess.get_file_as_string(BAND_PATH) + KERNEL
	var spirv := _device.shader_compile_spirv_from_source(source)
	var message := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not message.is_empty():
		_error = "the band kernel did not compile — %s" % message
		close()
		return false
	_shader = _device.shader_create_from_spirv(spirv)
	_pipeline = _device.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


## Bake into an image, or null with [method error] set. `width`×`height` texels of the band's shape and colour.
func bake(width: int, height: int) -> Image:
	if not open():
		return null
	var w := maxi(width, 1)
	var h := maxi(height, 1)

	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = w
	format.height = h
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	var texture := _device.texture_create(format, RDTextureView.new())
	if not texture.is_valid():
		_error = "texture_create() gave an invalid RID"
		return null

	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture)
	var uniform_set := _device.uniform_set_create([uniform], _shader, 0)
	if not uniform_set.is_valid():
		_error = "uniform_set_create() gave an invalid RID"
		_device.free_rid(texture)
		return null

	var params := PackedFloat32Array([float(w), float(h), 0.0, 0.0]).to_byte_array()
	var list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(list, _pipeline)
	_device.compute_list_bind_uniform_set(list, uniform_set, 0)
	_device.compute_list_set_push_constant(list, params, params.size())
	_device.compute_list_dispatch(list, ceili(w / 8.0), ceili(h / 8.0), 1)
	_device.compute_list_end()

	# A local device processes nothing until it is told to, and reads back only after a synchronisation.
	_device.submit()
	_device.sync()
	var data := _device.texture_get_data(texture, 0)

	_device.free_rid(uniform_set)
	_device.free_rid(texture)

	if data.size() != w * h * 8:
		_error = "read back %d bytes for a %dx%d RGBA half-float map" % [data.size(), w, h]
		return null
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBAH, data)


func error() -> String:
	return _error


## **The device is freed, not merely dropped.** A local `RenderingDevice` left alive to be destroyed at process
## exit segfaults — the same rule `SpacesimSurfaceGpu` and `SpacesimCloudMaps` carry.
func close() -> void:
	if _device == null:
		return
	for rid in [_pipeline, _shader]:
		if (rid as RID).is_valid():
			_device.free_rid(rid)
	_device.free()
	_device = null
