// The frame's radiance currency: what every path multiplies a physical radiance by before writing it.
//
// ------------------------------------------------------------------ WHY A GAIN AT ALL
//
// The 3D colour buffer is `R16G16B16A16_SFLOAT` and cannot be changed from a project
// (`renderer_scene_render_rd.cpp:1160` returns it unconditionally). Its smallest **normal** value is
// 6.1e-5, and its subnormals run from there down to 5.96e-8 with the mantissa collapsing — by the
// bottom, a value has one bit.
//
// A space scene writes values that are far smaller than that: a magnitude-8 star's pixel is 2.8e-8
// engine units, and the night-side ambient is 2e-9. Both land in the subnormal band or below it, so
// the frame stores a handful of levels — or zero, which no exposure can lift, because zero times
// anything is zero. That is the fault Evert found: faint stars that flicker, then disappear.
//
// **The format is not too narrow; the scene was using the bottom of it.** The normal range is
// 6.1e-5 .. 6.55e4 — nineteen stops at a 10-bit mantissa — and this scene needs about eleven. So the
// whole frame is lifted by this constant, which puts every value in the part of the float that has
// mantissa left, and `SpacesimExposurePass` divides it back out so the picture is unchanged.
//
// **A power of two on purpose**: multiplying by it is exact in a float, so no value is moved by
// rounding on its way into the buffer.
//
// **Why 2048 and not more.** It has to clear the faint end and stay under the top: the catalogue's
// faintest star (magnitude 8) writes 2.2e-4 at 1080p, comfortably normal, and a magnitude-9.5 star
// still writes 3.4e-5 — subnormal, but with five bits rather than none. The ceiling binds it: the
// star's own disc is authored at `STAR_INTENSITY` 24 times white, and 24 x 2048 = 49,152 is inside the
// format's 65,504 while 24 x 4096 would be infinity, and an infinity in the frame propagates through
// the glow rather than clipping quietly.
//
// The GDScript twin is `SpacesimRadiance.GAIN` in `radiance.gd, and `tests/test_render.gd` asserts the
// two agree — a shader and a script that disagree by a factor would show as one layer 1024x too bright.
const float RADIANCE_GAIN = 2048.0;
