shader_type spatial;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
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

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(41.7, 289.3))) * 43758.5);
}

// Value noise on the object's own plane, so a galaxy's clumps are fixed in the galaxy and not in the screen.
float noise2(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(cell), hash2(cell + vec2(1.0, 0.0)), f.x),
		mix(hash2(cell + vec2(0.0, 1.0)), hash2(cell + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p, int octaves) {
	float total = 0.0;
	float amplitude = 0.5;
	float norm = 0.0;
	for (int i = 0; i < 5; i++) {
		if (i >= octaves) {
			break;
		}
		total += amplitude * noise2(p);
		norm += amplitude;
		p *= 2.07;
		amplitude *= 0.5;
	}
	return total / max(norm, 1.0e-6);
}

void fragment() {
	// The quad is square and the object inside it is an ellipse, so the minor axis is divided out here.
	vec2 local = vec2(v_local.x, v_local.y / max(v_ratio, 1.0e-4));
	float radius = length(local);
	float angle = atan(local.y, local.x);
	float coverage = 1.0 - smoothstep(0.90, 1.0, radius);

	// **What these objects actually look like**, in the order the light arrives: an old, warm, smooth core; young,
	// blue star-forming arms with dust along their inner edges; pink H II knots on the ridges. The tints below are
	// the measured colours, not a palette — O III at 501 nm is teal-green, H-alpha at 656 nm is red, and an O/B
	// association is blue-white.
	vec3 WARM_CORE = vec3(1.00, 0.86, 0.64);   // G and K stars, an old population
	vec3 YOUNG_BLUE = vec3(0.62, 0.78, 1.00);  // O and B stars, hot and short-lived
	vec3 HII_PINK = vec3(1.00, 0.42, 0.42);    // H-alpha + [N II]
	vec3 OIII_TEAL = vec3(0.30, 1.00, 0.80);   // doubly ionised oxygen, the inner part of an H II region
	vec3 DUST = vec3(0.35, 0.30, 0.28);

	vec3 emission = vec3(0.0);
	if (v_profile < 0.5) {
		// ---- an inclined spiral: bulge, disc, logarithmic arms, dust on their inner edges, sparse H II knots
		float bulge = exp(-pow(radius / 0.22, 2.0) * 3.2);
		// A log spiral in the object's own plane: the arm radius grows with the wound angle, so the arms wind.
		float wound = angle * 9.0 + log(max(radius, 1.0e-3)) * 5.5;
		float arm = pow(0.5 + 0.5 * cos(wound), 3.0);
		float arms = arm * exp(-radius / 0.55) * (1.0 - bulge);
		// Dust follows each arm's inner edge: the same spiral, offset half an arm-width in angle.
		float lane = pow(0.5 + 0.5 * cos(wound + 0.55), 6.0) * exp(-radius / 0.5);
		float knots = smoothstep(0.72, 0.95, fbm2(local * 9.0, 3)) * arm;
		emission = WARM_CORE * bulge
			+ YOUNG_BLUE * arms
			+ HII_PINK * knots * 0.45;
		emission *= 1.0 - 0.55 * lane;
	} else if (v_profile < 1.5) {
		// ---- an irregular: a bar of old stars, and the rest clumped into blue associations with pink knots
		float bar = exp(-pow(length(vec2(local.x / 0.75, local.y / 0.16)), 2.0) * 2.5);
		float clumps = fbm2(local * 5.5 + vec2(17.3, 4.1), 4);
		float knots = smoothstep(0.60, 0.85, fbm2(local * 13.0 + vec2(3.7, 9.2), 3));
		emission = WARM_CORE * bar * 0.8
			+ YOUNG_BLUE * clumps * (1.0 - bar) * 1.4
			+ HII_PINK * knots * 0.55;
	} else if (v_profile < 2.5) {
		// ---- an emission nebula. **Green inside, red outside** — that is not a palette either: the core is hot
		// enough to doubly ionise oxygen, which emits at 501 nm, while the cooler outskirts are dominated by
		// hydrogen's 656 nm line and [N II]. The dust lane across the middle is the one that separates M42 from M43.
		float inner = exp(-pow(radius / 0.34, 2.0) * 2.2);
		float outer = exp(-pow(radius / 0.90, 2.0) * 1.6);
		float filaments = 0.65 + 0.7 * fbm2(local * 7.0 + vec2(5.1, 2.3), 4);
		float lane = exp(-pow((local.y - 0.18 * local.x) / 0.13, 2.0)) * smoothstep(0.15, 0.9, radius);
		emission = OIII_TEAL * inner * filaments + HII_PINK * outer * filaments * 0.8;
		emission *= 1.0 - 0.75 * lane;
		// The Trapezium, at the centre: the hot cluster that lights the whole thing.
		float trapezium = smoothstep(0.10, 0.0, radius);
		emission += vec3(0.85, 0.92, 1.00) * trapezium * 2.0;
	} else if (v_profile < 3.5) {
		// ---- a reflection nebula: **blue**, because the cloud is scattering starlight rather than emitting, and
		// scattering goes as 1/lambda^4. The Pleiades are an open cluster first and a nebula second: the stars
		// themselves are the brightest thing in it.
		float halo = exp(-pow(radius / 0.62, 2.0) * 2.0) * (0.55 + 0.6 * fbm2(local * 6.0, 3));
		emission = YOUNG_BLUE * halo * 0.8;
		// A handful of unresolved cluster members, in fixed places in the object.
		for (int i = 0; i < 6; i++) {
			vec2 seat = (vec2(hash2(vec2(float(i), 3.1)), hash2(vec2(float(i), 8.6))) - 0.5) * 1.2;
			float d = length(local - seat);
			emission += vec3(0.80, 0.90, 1.00) * exp(-pow(d / 0.10, 2.0) * 4.0) * 1.6;
		}
	} else {
		// ---- a globular cluster: old, round and dense, with a core that is a swarm rather than a point.
		float mass = exp(-pow(radius / 0.30, 2.0) * 3.0) + exp(-radius / 0.55) * 0.35;
		float grain = 0.75 + 0.5 * fbm2(local * 22.0, 2);
		emission = WARM_CORE * mass * grain;
	}

	ALBEDO = v_radiance * emission * coverage;
	ALPHA = 1.0;
}
