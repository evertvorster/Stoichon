shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;
// The dust sheet of a ring band: **one surface, shaded by a density function in the ring's own coordinates.**
//
// ------------------------------------------------------------------ WHY A SHEET AND NOT PARTICLES
//
// A band's drawn rocks carry about 2e-7 of its optical depth — the band is a million times more opaque than what
// is drawn — so the light that makes a ring bright is the grains, and there are far too many of those to draw.
// SpaceEngine's answer, and the one taken here: the unresolved part of a ring is a **surface with an optical
// depth**, shaded by the slab's own scattering law, and its structure comes from a *density function* rather than
// from geometry. Kitten Space Agency add procedural detail lines to a 1D radial profile for the same reason.
//
// Not particles (that is the rocks, and 10^7 of them is not affordable), and not a flat grey disc either: the
// shading is a function of position in the ring — radius and azimuth — at four scales.
//
// ------------------------------------------------------------------ THE FOUR SCALES OF STRUCTURE
//
//   1. **The radial profile**: the band's optical depth across its width, with soft edges and the band's own
//      `tau` — the only brightness number a band has.
//   2. **Ringlets**: a high-frequency 1D field in radius. This is the single thing that makes a ring look like a
//      ring rather than a hoop, and it is cheap because it varies in one axis only.
//   3. **Azimuthal structure**: density waves and plateaus, low frequency in and across the radius.
//   4. **Grain**: a fine 2D field, so the sheet never reads as painted.
//
// ------------------------------------------------------------------ THE OPTICS
//
// The slab's single-scattering reflectance, exactly as `SpacesimRingModel.reflectance` has it:
//
//     R = (1/4) . mu0/(mu0 + mu) . (1 - exp(-tau (1/mu0 + 1/mu)))
//
// lit at cosine `mu0` (the star above the plane) and seen at `mu` (the eye above it). The per-pixel pieces are
// `mu` and the local optical depth; `mu0` is one number for the whole band, because the star is at infinity.
//
// **The alpha decomposition is the band's own transmittance**: `alpha = 1 - exp(-tau/mu)`, and the colour handed
// over is the radiance divided by that alpha, so compositing the sheet adds the band's reflectance and removes
// what is behind it by exactly the band's opacity. A rock drawn over it adds its own light on top, which is how
// the rocks and the dust sum to the calibrated albedo instead of each trying to be it.

// The band.
uniform float u_tau = 1.2;
uniform float u_inner = 0.0;
uniform float u_outer = 1.0;
// The star: its illuminance at the band, the material's bond albedo, and its direction in this node's frame — one
// set of numbers for the whole band, because a star is at infinity.
uniform float u_illuminance = 0.0;
uniform float u_bond_albedo = 0.0;
uniform vec3 u_star_local = vec3(0.0, 0.0, 1.0);
// The eye, in this node's frame (the planet's centre is the origin, the ring plane is z = 0).
uniform vec3 u_eye_local = vec3(0.0, 0.0, 1.0);
// The planet's radius, for the shadow it casts across the sheet.
uniform float u_planet_radius = 0.0;

const float PI_F = 3.14159265358979;
// A physical radiance becomes the engine's units by dividing by this — a white Lambertian surface under 100,000
// lux renders as 1.0 and has radiance 100,000/pi. **The rocks never needed it because their coverage is ~1e-7**;
// a sheet covers half a pixel, so without it the band is 30,000x too bright — which is what the first frame of
// this shader showed, a white blob where Saturn's rings were.
const float UNIT_LUX_PER_SR = 100000.0 / PI_F;
const float MIN_COSINE = 0.02;
// Where the radial structure lives, relative to the band's width: ringlets per unit of normalised radius.
const float RINGLET_FREQUENCY = 260.0;
const float WAVE_FREQUENCY = 9.0;
const float GRAIN_FREQUENCY = 900.0;

varying vec3 v_local;

float hash11(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}

// Value noise in one dimension: the ringlet field.
float noise1(float x) {
	float cell = floor(x);
	float f = x - cell;
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash11(cell), hash11(cell + 1.0), f);
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(41.7, 289.3))) * 43758.5453);
}

// Value noise in two: the grain and the waves.
float noise2(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash21(cell), hash21(cell + vec2(1.0, 0.0)), f.x),
		mix(hash21(cell + vec2(0.0, 1.0)), hash21(cell + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

void vertex() {
	// Model space: the sheet lies in this node's x-y plane, so `v_local` carries the radius and the azimuth
	// into the fragment stage, where `VERTEX` would already be in view space.
	v_local = VERTEX;
}

void fragment() {
	float radius = length(v_local.xy);
	float azimuth = atan(v_local.y, v_local.x);
	float width = max(u_outer - u_inner, 1.0);
	float t = clamp((radius - u_inner) / width, 0.0, 1.0);

	// **Soft edges**, so a band has no cut rim: the sheet fades over the outer few percent of its width and at
	// both ends.
	float edges = smoothstep(0.0, 0.02, t) * smoothstep(1.0, 0.98, t);

	// **Ringlets**: one-dimensional in radius, at a frequency tuned so a band holds a few hundred of them, and
	// broken up so they are not a comb.
	float ringlets = 0.55
		+ 0.45 * noise1(t * RINGLET_FREQUENCY)
		+ 0.28 * noise1(t * RINGLET_FREQUENCY * 2.7 + 11.0)
		+ 0.16 * noise1(t * RINGLET_FREQUENCY * 7.3 + 31.0);
	// **Waves**: low frequency in radius and in azimuth — the density waves and plateaus a real band has, which
	// are what make its brightness uneven along its length.
	float waves = 0.85 + 0.30 * noise2(vec2(t * WAVE_FREQUENCY, azimuth * 1.6));
	// **Grain**: fine, two-dimensional, so the sheet has texture at the pixel scale.
	float grain = 0.90 + 0.20 * noise2(vec2(t * GRAIN_FREQUENCY, azimuth * 60.0));

	// The band's optical depth at this point — the profile, the structure, and nothing else.
	float tau = u_tau * edges * ringlets * waves * grain;

	// The eye's elevation above the plane, and the star's: `mu0` is one number for the band, `mu` is per pixel.
	float mu = max(abs(dot(normalize(u_eye_local - v_local), vec3(0.0, 0.0, 1.0))), MIN_COSINE);
	float mu0 = max(abs(u_star_local.z), MIN_COSINE);

	// **The slab's reflectance**, the dust's own law — see `SpacesimRingModel.reflectance`.
	float reflectance = 0.25 * mu0 / (mu0 + mu) * (1.0 - exp(-tau * (1.0 / mu0 + 1.0 / mu)));
	float radiance = u_illuminance * u_bond_albedo * reflectance / (PI_F * UNIT_LUX_PER_SR);

	// **The planet's shadow is a cylinder of its radius along the star's direction** — exact for a sphere and a star
	// at infinity, and the only shadow a sheet needs: a point is dark when it is behind the planet along that line.
	vec3 star_local = normalize(u_star_local);
	float along = dot(v_local, star_local);
	float perp = length(v_local - star_local * along);
	float shadowed = (along < 0.0 && perp < u_planet_radius) ? 0.0 : 1.0;

	// The sheet removes what is behind it by its own opacity and adds its reflectance over the alpha.
	float alpha = 1.0 - exp(-tau / mu);
	ALBEDO = vec3(radiance * shadowed) / max(alpha, 1.0e-3);
	ALPHA = alpha;
}
