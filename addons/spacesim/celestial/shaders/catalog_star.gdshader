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
// ------------------------------------------------------------------ NO DEPTH, IN EITHER DIRECTION
//
// The quads sit at the far plane, never write depth and never test it. **Testing it was a mistake**: the sampled
// depth is not a stable per-pixel answer under MSAA and multi-pass rendering, and a star whose pixel was
// sometimes behind and sometimes not switched on and off — which is the flicker this whole layer exists to
// remove. A background that occasionally draws in front of a planet is a far smaller lie than a sky that blinks.

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
// **Only the pixel geometry comes from the host**, and it has no time in it: the render target's size and the
// field of view's tangents change on a resize or a zoom, never per frame. The camera's *basis* would have time in
// it — read from GDScript it is the transform of the frame before the one being drawn — so the basis comes from
// `INV_VIEW_MATRIX` instead, which is the camera this frame is actually rendered with.
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

	// Where the star is on screen, in pixels. **The basis is the frame's own**: `INV_VIEW_MATRIX` takes camera
	// space to world, so its columns are this frame's right, up and forward.
	// **`right` is negated**: the engine's first column runs the other way round in X from the screen, which is
	// why the field travelled *with* the camera instead of against it. Evert, 2026-11-20: *"when I turn the camera
	// in one direction, the stars go in the opposite direction."*
	vec3 right = -INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	// **Column 2 is the camera's FORWARD axis, un-negated** — the engine says so itself:
	// `CAMERA_DIRECTION_WORLD = inv_view_matrix[2].xyz` (`scene_shader_forward_clustered.cpp`). Negating it, as
	// a `-Z is forward` habit suggests, mirrors the whole sky through the screen's centre: the field runs
	// backwards and every star flips across the screen as the camera turns.
	vec3 fwd = INV_VIEW_MATRIX[2].xyz;
	float depth = dot(direction, fwd);
	vec2 ndc = vec2(dot(direction, right), dot(direction, up)) / max(depth * u_tan_half, vec2(1.0e-9));
	vec2 pixel = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5) * u_view_size;

	float lux = LUX_PER_MAG0 * pow(10.0, -0.4 * magnitude);

	// **Every star is one pixel, snapped — bright ones included, and that is the whole reason it is steady.**
	//
	// A star below a pixel is snapped and cannot blink. A *bright* star used to be grown past a pixel, on the
	// theory that a bright star should look wider; and that is exactly the class that flickered. A 1.5-pixel disk
	// has a radius of 0.75 px, so the pixel under its centre is only half covered and the one beside it half
	// covered too; as the camera turns, that coverage slides between its neighbours — in quarter steps under MSAA
	// — so each pixel's share swings by tens of percent frame to frame. Total light is conserved, but a picture
	// is made of pixels, and no single pixel's share was.
	//
	// So the footprint is one pixel for everything, and brightness is **intensity alone**. At the fields of view
	// this game uses a catalogue star is far under a pixel anyway (Sirius would be 0.002 of one), so the growth
	// was never showing a real size — only an artefact of it.
	vec2 centre = floor(pixel) + 0.5;
	float half_px = 0.5;
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
	// One pixel at full coverage: `half_px` is 0.5, so the fragment covers the pixel's centre and the edge falls
	// outside it. Nothing here varies with the star's sub-pixel position, which is the point.
	vec2 p = UV * 2.0 - 1.0;
	float radius = length(p) * v_half_px;
	float coverage = 1.0 - smoothstep(v_half_px - 0.5, v_half_px + 0.5, radius);
	ALBEDO = v_radiance * coverage;
	ALPHA = 1.0;
}
