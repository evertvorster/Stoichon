class_name StoichonRadiance
## The frame's radiance currency — the GDScript half of `radiance.gdshaderinc`, and the one place the
## conversion from a physical radiance into what the frame holds is written for scripts.
##
## ## Why there is a gain
##
## The 3D colour buffer is a 16-bit float and cannot be changed from a project. Its smallest normal value
## is 6.1e-5 and its subnormals lose the mantissa all the way down, so a star at 2.8e-8 or a night-side
## ambient at 2e-9 is stored as a few levels — or as zero, which no later exposure can lift. The whole
## frame is therefore lifted by [`GAIN`], which puts every value where the float is precise, and
## `StoichonExposurePass` divides it back out: **the picture is unchanged, only the exponent is.**
##
## A power of two, so multiplying by it is exact.
##
## ## What must use it
##
## Anything that writes a **physical** radiance or illuminance into the frame: point-source radiances
## (`star_splats.gdshader`, `StoichonBodyRenderer.point_colour`), the star's own light
## (`StoichonStarLight`), the night-side ambient and the air's in-scatter
## (`StoichonAtmosphereModel.sky_scale`). Miss one and that path is a factor of `GAIN` too bright or too
## dim against everything else in the frame.

## The lift. Must equal `RADIANCE_GAIN` in `radiance.gdshaderinc`; `tests/test_render.gd` holds the pair.
const GAIN := 2048.0

## Godot's unit: a white Lambertian surface under `light_intensity_lux = 100,000` renders as 1.0, and has
## radiance 100,000/pi lux per steradian.
const UNIT_LUX_PER_SR := 100_000.0 / PI

## Where the shader half of this constant lives, for the test that compares the two.
const SHADER_INCLUDE := "res://addons/stoichon/render/radiance.gdshaderinc"


## A radiance in lux per steradian, as the number the frame holds.
static func frame(lux_per_sr: float) -> float:
	return lux_per_sr * GAIN / UNIT_LUX_PER_SR


## An illuminance in lux, as the energy a Godot light or the ambient is set from.
##
## The same lift and the same reference: `light_intensity_lux` is already in lux, so this is the gain
## alone.
static func light_lux(lux: float) -> float:
	return lux * GAIN


## A value that is already in the frame's currency from an illuminance, lifted.
##
## `StoichonAtmosphereModel.sky_scale` builds the air's in-scatter from an illuminance — it is the same
## conversion as [`method frame`] with the pi cancelled differently, so it is lifted by the gain here
## rather than repeating the gain inside the model.
static func frame_from_illuminance(value: float) -> float:
	return value * GAIN
