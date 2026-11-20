shader_type spatial;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
// Additive light over the frame, like the stars it sits behind: an extended object is a source, not a surface,
// and it must not occlude anything.
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;
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
uniform sampler2D depth_texture : hint_depth_texture;

// **A display gain, not physics.** At 1.0 each object is its own integrated magnitude over its own area — M31
// works out at about 22 magnitudes per square arcsecond, which is dimmer per pixel than a magnitude-6 star and
// therefore invisible. This lifts the layer to where it can be looked at.
uniform float u_gain = 30.0;

uniform vec3 u_right = vec3(1.0, 0.0, 0.0);
uniform vec3 u_up = vec3(0.0, 1.0, 0.0);
uniform vec3 u_fwd = vec3(0.0, 0.0, -1.0);
uniform vec2 u_tan_half = vec2(0.5, 0.5);
uniform vec2 u_view_size = vec2(1280.0, 720.0);

const float UNIT_LUX_PER_SR = 100000.0 / 3.14159265358979;
const float TEXELS_PER_ROW = 512.0;
const float PROFILE_NEBULA = 1.0;

varying vec3 v_radiance;
varying vec2 v_local;
varying float v_ratio;
varying float v_profile;

void vertex() {
	int index = INSTANCE_ID;
	ivec2 texel = ivec2(int(mod(float(index), TEXELS_PER_ROW)), int(float(index) / TEXELS_PER_ROW));
	vec4 placement = texelFetch(u_object, texel, 0);
	vec4 shape = texelFetch(u_shape, texel, 0);

	float pixel_angle = 2.0 * u_tan_half.y / u_view_size.y;
	// The major axis decides its angular size; the minor axis is the ratio of the two.
	float diameter = 2.0 * placement.w / max(pixel_angle, 1.0e-12);

	float depth = dot(placement.xyz, u_fwd);
	vec2 ndc = vec2(dot(placement.xyz, u_right), dot(placement.xyz, u_up))
		/ max(depth * u_tan_half, vec2(1.0e-9));
	vec2 pixel = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5) * u_view_size;

	// The same quantisation as the stars: an object under a pixel snaps to one, and the snap releases to 1.5 px.
	float released = smoothstep(1.0, 1.5, diameter);
	vec2 centre = mix(floor(pixel) + 0.5, pixel, released);
	float half_px = 0.5 * max(diameter, 1.0);

	v_ratio = max(shape.x, 1.0e-4);
	v_profile = shape.z;
	float area_px = max(3.14159265358979 * half_px * half_px * v_ratio, 1.0);
	float visible = depth > 1.0e-6 ? 1.0 : 0.0;
	v_radiance = texelFetch(u_tint, texel, 0).rgb
		* (shape.w * u_gain * RADIANCE_GAIN / (area_px * pixel_angle * pixel_angle * UNIT_LUX_PER_SR))
		* visible;

	// The object's own axes, rolled about its line of sight.
	vec2 local = VERTEX.xy * 2.0;
	float c = cos(shape.y);
	float s = sin(shape.y);
	v_local = vec2(local.x * c + local.y * s, -local.x * s + local.y * c);

	vec2 corner = centre + VERTEX.xy * (2.0 * half_px * visible);
	vec2 final_ndc = vec2(corner.x / u_view_size.x * 2.0 - 1.0, 1.0 - corner.y / u_view_size.y * 2.0);
	POSITION = vec4(final_ndc, CLIP_SPACE_FAR, 1.0);
}

void fragment() {
	// The quad is square and the object inside it is an ellipse, so the minor axis is divided out here.
	vec2 local = vec2(v_local.x, v_local.y / max(v_ratio, 1.0e-4));
	float radius = length(local);
	float profile = exp(-3.0 * radius * radius);
	if (v_profile > PROFILE_NEBULA - 0.5) {
		// A nebula is the same ellipse with a ragged edge rather than a smooth one.
		profile *= 0.6 + 0.4 * sin(radius * 11.0) * sin(local.x * 7.0 + local.y * 5.0);
	}
	float coverage = 1.0 - smoothstep(0.85, 1.0, radius);
	ALBEDO = v_radiance * profile * coverage;
	float scene_depth = texture(depth_texture, SCREEN_UV).r;
	ALPHA = scene_depth > 0.0 ? 0.0 : 1.0;
}
