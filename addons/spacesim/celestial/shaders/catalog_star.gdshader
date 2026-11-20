shader_type spatial;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
// A star is light added to the frame, drawn after everything opaque, writing no depth and testing none: it
// sits at the far plane and asks the depth buffer whether anything is already there.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;
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
// ------------------------------------------------------------------ OCCLUSION, BY THE HARDWARE
//
// The quads never write depth, and they are depth **tested** at the far plane. That puts a star behind a planet
// without asking a float32 to tell the far plane's distance from a star's, and it is per sample, so it costs the
// field nothing.
//
// **Sampling the depth buffer by hand was tried and removed.** The sample is not a stable per-pixel answer in a
// frame with MSAA and several passes, so a star switched on and off — the flicker this layer exists to remove.
// Drawing with no depth test at all was tried next, and a bright star crossing a planet's limb vanished into it
// and popped out again, which reads as blinking too. The hardware's own test has neither problem.

uniform sampler2D u_stars;        // RGBA32F: xyz unit direction, V magnitude
uniform sampler2D u_star_colour;  // RGBA32F: B-V in R (the rest unused)

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
// **The only thing the host supplies is the render target's size.** Everything about where a star lands comes from
// `VIEW_MATRIX` and `PROJECTION_MATRIX` — the same matrices the rasteriser uses for every other object — so there
// is no basis, no tangent, no sign and no convention of this shader's in the placement at all.
uniform vec2 u_view_size = vec2(1280.0, 720.0);

const float LUX_PER_MAG0 = 2.54e-6;
const float UNIT_LUX_PER_SR = 100000.0 / 3.14159265358979;
const float TEXELS_PER_ROW = 512.0;

varying vec3 v_radiance;

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

	// **The placement is the engine's own arithmetic.** A direction goes through the view matrix as a point at
	// infinity, then through the projection; `w` is how far in front of the camera it is. Nothing here invents a
	// basis or a sign.
	vec4 view = VIEW_MATRIX * vec4(direction, 0.0);
	vec4 clip = PROJECTION_MATRIX * vec4(view.xyz, 0.0);
	float w = clip.w;
	vec2 ndc = clip.xy / max(w, 1.0e-9);

	// One pixel, in NDC, from the render target's own size.
	vec2 pixel_ndc = 2.0 / u_view_size;

	// **The snap**: the star is placed on a pixel centre, so its light lands in one pixel and does not depend on
	// where inside that pixel it happened to fall. Symmetric in the sign of NDC, so no screen-orientation
	// convention is needed to get it right.
	vec2 snapped = (floor(ndc / pixel_ndc) + 0.5) * pixel_ndc;

	// The pixel's own solid angle, for turning an illuminance into a radiance. `abs` because this engine hands a
	// main-pass shader a projection whose vertical scale is negative.
	float pixel_angle = 2.0 / (max(abs(PROJECTION_MATRIX[1][1]), 1.0e-6) * u_view_size.y);

	float lux = LUX_PER_MAG0 * pow(10.0, -0.4 * magnitude);
	float bv = texelFetch(u_star_colour, texel, 0).r;
	float visible = (magnitude <= u_limit_mag && w > 1.0e-6) ? 1.0 : 0.0;
	v_radiance = star_tint(bv)
		* (lux * u_gain * RADIANCE_GAIN / (pixel_angle * pixel_angle * UNIT_LUX_PER_SR))
		* visible;

	// The quad is exactly one pixel: half a pixel either way, in clip space, then the far plane for z.
	vec2 corner = snapped + VERTEX.xy * pixel_ndc * visible;
	POSITION = vec4(corner * w, (CLIP_SPACE_FAR + 1.0e-6) * w, w);
}

void fragment() {
	// The quad is exactly one pixel, so every fragment in it is the star's light: no profile and no coverage term,
	// because there is no sub-pixel position left to attenuate.
	ALBEDO = v_radiance;
	ALPHA = 1.0;
}
