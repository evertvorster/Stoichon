shader_type spatial;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
#include "res://addons/spacesim/celestial/shaders/deep_sky_profile.gdshaderinc"
// Additive light over the frame, like the stars it sits behind: an extended object is a source, not a surface,
// and it must not occlude anything.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;
// The extended objects — galaxies and nebulae — one quad each, placed by the same five numbers the stars use.
//
// A galaxy at a wide field of view is a few pixels across; the same galaxy close up is a resolved ellipse. Both
// are the same object, and the handover is the problem the star shader solves: **below one pixel nothing may be
// left to the rasteriser**, because an object smaller than a pixel either lands on one or is lost. Above a pixel
// it is resolved and drawn as itself.
//
// The profile is a function of the object's own axes rather than a texture, so it has no resolution to lose and
// cannot shimmer. A photograph would need a texture, a mip chain and a filter, and those are what keep a picture
// still — an analytic shape is still by construction. When there is a real image of the Milky Way, this is the
// layer that grows one.
//
// Energy is conserved the way the stars' is: `luminance` is the object's whole light at the observer, divided by
// the area the disc covers, so a wider object is a dimmer one.

uniform sampler2D u_object;  // RGBA32F: xyz direction, major HALF-angle in radians
uniform sampler2D u_shape;   // RGBA32F: minor/major ratio, roll, profile, illuminance
uniform sampler2D u_tint;    // RGBA32F: linear tint

// **A display gain, not physics.** At 1.0 each object is its own integrated magnitude over its own area — M31
// works out at about 22 magnitudes per square arcsecond, which is dimmer per pixel than a magnitude-6 star and
// therefore invisible. This lifts the layer to where it can be looked at.
uniform float u_gain = 30.0;

// **Only the pixel geometry comes from the host**, and it has no time in it: the render target's size and the
// field of view's tangents change on a resize or a zoom, never per frame. The camera's *basis* would have time in
// it — read from GDScript it is the transform of the frame before the one being drawn — so the basis comes from
// `INV_VIEW_MATRIX` instead, which is the camera this frame is actually rendered with.
uniform vec2 u_tan_half = vec2(0.5, 0.5);

const float UNIT_LUX_PER_SR = 100000.0 / 3.14159265358979;
const float TEXELS_PER_ROW = 512.0;
const float PROFILE_NEBULA = 1.0;

varying vec3 v_radiance;
varying vec2 v_local;
varying float v_ratio;
varying float v_profile;
varying float v_half_px;

void vertex() {
	int index = INSTANCE_ID;
	ivec2 texel = ivec2(int(mod(float(index), TEXELS_PER_ROW)), int(float(index) / TEXELS_PER_ROW));
	vec4 placement = texelFetch(u_object, texel, 0);
	vec4 shape = texelFetch(u_shape, texel, 0);

	// The engine's matrices, as for a star: a direction at infinity through the view and the projection.
	vec4 view = VIEW_MATRIX * vec4(placement.xyz, 0.0);
	vec4 clip = PROJECTION_MATRIX * vec4(view.xyz, 0.0);
	float w = clip.w;
	vec2 ndc = clip.xy / max(w, 1.0e-9);
	vec2 pixel_ndc = 2.0 / VIEWPORT_SIZE;
	float pixel_angle = 2.0 / (max(abs(PROJECTION_MATRIX[1][1]), 1.0e-6) * VIEWPORT_SIZE.y);

	// How wide the object is, in pixels, from its own angular size.
	float diameter = 2.0 * placement.w / max(pixel_angle, 1.0e-12);
	float half_px = 0.5 * max(diameter, 1.0);
	v_half_px = half_px;

	// **Under a pixel it snaps like a star**, so a distant galaxy is a point rather than an alias that comes and
	// goes; above a pixel it keeps its own position and its own size.
	vec2 centre = diameter <= 1.0 ? (floor(ndc / pixel_ndc) + 0.5) * pixel_ndc : ndc;

	v_ratio = max(shape.x, 1.0e-4);
	v_profile = shape.z;
	float area_px = max(3.14159265358979 * half_px * half_px * v_ratio, 1.0);
	float visible = w > 1.0e-6 ? 1.0 : 0.0;
	v_radiance = texelFetch(u_tint, texel, 0).rgb
		* (shape.w * u_gain * RADIANCE_GAIN / (area_px * pixel_angle * pixel_angle * UNIT_LUX_PER_SR))
		* visible;

	// The object's own axes, rolled about its line of sight.
	vec2 local = VERTEX.xy * 2.0;
	float c = cos(shape.y);
	float s = sin(shape.y);
	v_local = vec2(local.x * c + local.y * s, -local.x * s + local.y * c);

	vec2 corner = centre + VERTEX.xy * pixel_ndc * half_px * 2.0 * visible;
	POSITION = vec4(corner * w, (CLIP_SPACE_FAR + 1.0e-6) * w, w);
}

void fragment() {
	vec2 local = vec2(v_local.x, v_local.y);
	ALBEDO = v_radiance * object_emission(local, v_ratio, v_profile);
	ALPHA = 1.0;
}
