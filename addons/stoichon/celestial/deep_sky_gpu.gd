class_name StoichonDeepSkyGpu
extends RefCounted
## Bakes the extended objects into one atlas: a cell each, 512x512, RGBA half float.
##
## ## The same machinery as the band, and as the cloud and surface bakers
##
## A local `RenderingDevice`, a compute shader assembled from the `.gdshaderinc` that the real-time quad also
## includes, one dispatch per object into its own cell of the atlas, one readback. Nothing new: a source string
## gets no preprocessor help, so the include is read and prepended by hand — `StoichonCloudGpu._source()` does the
## same three lines.
##
## ## Why an atlas and not seven images
##
## One texture, one binding, one mip chain, and the cell an object lives in is the object's index — which the
## runtime already has, because the quads are instanced in that order. Seven files would be seven bakes to keep in
## step for no gain.
##
## ## What it bakes
##
## The **shape and colour** — dimensionless linear RGB — not the brightness. The object's integrated magnitude, the
## display gain and the frame's currency are applied by whoever samples the cell, so the atlas survives a change to
## any of them without being baked again.

const PROFILE_PATH := "res://addons/stoichon/celestial/shaders/deep_sky_profile.gdshaderinc"
const CELL := 512
const COLUMNS := 4
const ROWS := 2

const KERNEL := """
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform writeonly image2D atlas;
layout(push_constant, std430) uniform Params {
	vec2 origin;
	float ratio;
	float profile;
} params;
void main() {
	ivec2 cell = ivec2(gl_GlobalInvocationID.xy);
	if (cell.x >= CELL_SIZE || cell.y >= CELL_SIZE) {
		return;
	}
	// The quad's own plane: -1..1 across the cell, which is exactly what the real-time quad hands the profile.
	vec2 uv = (vec2(cell) + vec2(0.5)) / float(CELL_SIZE);
	vec2 local = uv * 2.0 - vec2(1.0);
	imageStore(atlas, ivec2(params.origin) + cell, vec4(object_emission(local, params.ratio, params.profile), 1.0));
}
"""

var _device: RenderingDevice
var _shader: RID
var _pipeline: RID
var _error := ""


func open() -> bool:
	if _device != null:
		return _pipeline.is_valid()
	_device = RenderingServer.create_local_rendering_device()
	if _device == null:
		_error = "no local RenderingDevice (headless, or not a Vulkan/Forward+ run)"
		return false
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = (
		"#version 450\n"
		+ "#define CELL_SIZE %d\n" % CELL
		+ FileAccess.get_file_as_string(PROFILE_PATH)
		+ KERNEL
	)
	var spirv := _device.shader_compile_spirv_from_source(source)
	var message := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not message.is_empty():
		_error = "the deep-sky kernel did not compile — %s" % message
		close()
		return false
	_shader = _device.shader_create_from_spirv(spirv)
	_pipeline = _device.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


## Bake the objects, in the order given, into the atlas. Null with [method error] set on failure.
func bake(objects: Array) -> Image:
	if not open():
		return null
	var columns := mini(COLUMNS, maxi(objects.size(), 1))
	var rows := maxi(int(ceil(float(maxi(objects.size(), 1)) / float(COLUMNS))), 1)
	var w := columns * CELL
	var h := rows * CELL

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

	var list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(list, _pipeline)
	_device.compute_list_bind_uniform_set(list, uniform_set, 0)
	for i in objects.size():
		var entry: StoichonDeepSkyEntry = objects[i]
		var origin := Vector2i((i % COLUMNS) * CELL, (i / COLUMNS) * CELL)
		var params := PackedFloat32Array([
			float(origin.x), float(origin.y),
			entry.minor_rad() / maxf(entry.major_rad(), 1.0e-12),
			entry.profile,
		]).to_byte_array()
		_device.compute_list_set_push_constant(list, params, params.size())
		_device.compute_list_dispatch(list, CELL / 8, CELL / 8, 1)
	_device.compute_list_end()

	_device.submit()
	_device.sync()
	var data := _device.texture_get_data(texture, 0)
	_device.free_rid(uniform_set)
	_device.free_rid(texture)

	if data.size() != w * h * 8:
		_error = "read back %d bytes for a %dx%d RGBA half-float atlas" % [data.size(), w, h]
		return null
	var image := Image.create_from_data(w, h, false, Image.FORMAT_RGBAH, data)
	image.set_meta("stoichon_bake", "gpu")
	return image


func error() -> String:
	return _error


## The device is freed, not dropped: a local `RenderingDevice` left alive segfaults at process exit.
func close() -> void:
	if _device == null:
		return
	for rid in [_pipeline, _shader]:
		if (rid as RID).is_valid():
			_device.free_rid(rid)
	_device.free()
	_device = null
