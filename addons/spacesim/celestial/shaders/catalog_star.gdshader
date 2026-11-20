shader_type spatial;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
// A star is light added to the frame, drawn after everything opaque, writing no depth and testing none: it
// sits at the far plane and asks the depth buffer whether anything is already there.
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;
// The catalogued stars: one quad each, sized in PIXELS, snapped to a pixel when smaller than one.
//
// ------------------------------------------------------------------ THE TWO REGIMES
//
//   - **Sub-pixel** — the footprint is clamped to exactly one pixel and the quad's centre is snapped to that
//     pixel's centre, so all of a star's light lands in one pixel from every camera angle. Brightness by
//     magnitude is carried in the colour's intensity, never by shrinking the footprint below a pixel.
//   - **Above a pixel** — the snap is released across `[1.0, 1.5]` pixels with a `smoothstep`, and the quad is
//     drawn as a disk with a one-pixel antialiased edge, so a bright star widens without a step.
//
// **Energy is conserved in both regimes**: the fragment's radiance is the star's flux divided by the area the
// sprite covers, so a wider star is a dimmer one and its total light does not change with its width. The
// specification's "centre pixel keeps 100% peak" would add light as a star widens; a star's flux does not change
// with how it is drawn, and the energy check in the acceptance test cannot pass the other way.
//
// ------------------------------------------------------------------ THE PROJECTION IS THE HOST'S FIVE NUMBERS
//
// `ndc = (dot(d, right), dot(d, up)) / (dot(d, fwd) * tan_half)`, and pixels are `ndc` scaled by the render
// target's size. Nothing here reads `PROJECTION_MATRIX`, `VIEWPORT_SIZE` or a derivative.
//
// That is not fussiness. This project's window, its 3D buffer and its canvas are three different sizes, and a
// shader that guesses which one it was handed gets the pixel size wrong in both axes — which shows as stars of
// the right brightness and the wrong *shape*, and is hard to see. `SpacesimCelestialDome` reads the render
// target's size and the camera's field of view every frame and hands them over, so there is nothing to guess.
//
// ------------------------------------------------------------------ OCCLUSION
//
// The quads sit at the far plane and never write depth. They ask the frame's depth buffer whether something is
// already there — `0` is "nothing drawn here" in this engine's reversed projection — which is what puts a star
// behind a planet without asking a float32 to tell the far plane's distance from a star's.

uniform sampler2D u_stars;        // RGBA32F: xyz unit direction, V magnitude
uniform sampler2D u_star_colour;  // RGBA32F: B-V in R (the rest unused)
uniform sampler2D depth_texture : hint_depth_texture;

// The depth tunable: a star either is or is not above this line, so sweeping it costs a uniform write and cannot
// reshuffle the field.
uniform float u_limit_mag = 6.5;
// The hand scaler on the whole field, in linear units.
uniform float u_gain = 1.0;
// The reference star's footprint, in PIXELS, and how fast a brighter one widens.
uniform float u_psf_px = 0.55;
uniform float u_size_exponent = 0.18;
// The illuminance that gets the reference width — a magnitude-6.5 star.
uniform float u_lux_reference = 1.011e-8;

// ===== THIS FRAME ==================================================================================
uniform vec3 u_right = vec3(1.0, 0.0, 0.0);
uniform vec3 u_up = vec3(0.0, 1.0, 0.0);
uniform vec3 u_fwd = vec3(0.0, 0.0, -1.0);
uniform vec2 u_tan_half = vec2(0.5, 0.5);
uniform vec2 u_view_size = vec2(1280.0, 720.0);

const float LUX_PER_MAG0 = 2.54e-6;
const float UNIT_LUX_PER_SR = 100000.0 / 3.14159265358979;
const float TEXELS_PER_ROW = 512.0;

varying vec3 v_radiance;
varying float v_half_px;

float planck(float nm, float t) {
	float metres = nm * 1.0e-9;
	float c2 = 1.4388e-2;
	return 1.0 / (pow(metres, 5.0) * (exp(c2 / (metres * t)) - 1.0));
}

// Ballesteros' B-V to temperature, then three wavelengths of it, normalised to unit luminance so the colour
// carries no brightness of its own.
vec3 star_tint(float bv) {
	float t = clamp(4600.0 * (1.0 / (0.92 * bv + 1.7) + 1.0 / (0.92 * bv + 0.62)), 1000.0, 40000.0);
	vec3 c = vec3(planck(610.0, t), planck(555.0, t), planck(465.0, t));
	return c / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-30);
}

void vertex() {
	int index = INSTANCE_ID;
	ivec2 texel = ivec2(int(mod(float(index), TEXELS_PER_ROW)), int(float(index) / TEXELS_PER_ROW));
	vec4 star = texelFetch(u_stars, texel, 0);
	float magnitude = star.w;
	vec3 direction = normalize(star.xyz);

	// Where the star is on screen, in pixels. `fwd` describes the direction the camera looks along.
	float depth = dot(direction, u_fwd);
	vec2 ndc = vec2(dot(direction, u_right), dot(direction, u_up)) / max(depth * u_tan_half, vec2(1.0e-9));
	vec2 pixel = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5) * u_view_size;

	// The star's own width, in pixels, from its flux: the reference star is `u_psf_px`, and a brighter one is
	// drawn wider so a very bright star reads as more than a dot.
	float lux = LUX_PER_MAG0 * pow(10.0, -0.4 * magnitude);
	float diameter = u_psf_px * pow(max(lux / u_lux_reference, 1.0e-12), u_size_exponent);

	// **The quantisation.** Below one pixel the centre snaps to a pixel centre and the footprint is exactly one
	// pixel; the snap releases smoothly up to 1.5 px so the handover cannot pop.
	float released = smoothstep(1.0, 1.5, diameter);
	vec2 centre = mix(floor(pixel) + 0.5, pixel, released);
	float half_px = 0.5 * max(diameter, 1.0);
	v_half_px = half_px;

	// Its light over the pixels it covers, in the frame's currency. The pixel's own solid angle is what turns an
	// illuminance into a radiance, and it comes from the same two numbers the projection did.
	float pixel_angle = 2.0 * u_tan_half.y / u_view_size.y;
	float area_px = max(3.14159265358979 * half_px * half_px, 1.0);
	float bv = texelFetch(u_star_colour, texel, 0).r;
	float visible = (magnitude <= u_limit_mag && depth > 1.0e-6) ? 1.0 : 0.0;
	v_radiance = star_tint(bv)
		* (lux * u_gain * RADIANCE_GAIN / (area_px * pixel_angle * pixel_angle * UNIT_LUX_PER_SR))
		* visible;

	vec2 corner = centre + VERTEX.xy * (2.0 * half_px * visible);
	vec2 final_ndc = vec2(corner.x / u_view_size.x * 2.0 - 1.0, 1.0 - corner.y / u_view_size.y * 2.0);
	POSITION = vec4(final_ndc, CLIP_SPACE_FAR, 1.0);
}

void fragment() {
	// A flat disk with a one-pixel antialiased edge: the centre is at full brightness and the edge gives up one
	// pixel at a time, so the release out of the snapped regime has nothing to jump.
	vec2 p = UV * 2.0 - 1.0;
	float radius = length(p) * v_half_px;
	float coverage = 1.0 - smoothstep(v_half_px - 0.5, v_half_px + 0.5, radius);
	ALBEDO = v_radiance * coverage;
	// Hidden by whatever is already in the buffer: a body writes depth, a star is behind every body.
	float scene_depth = texture(depth_texture, SCREEN_UV).r;
	ALPHA = scene_depth > 0.0 ? 0.0 : 1.0;
}
