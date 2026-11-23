// Stoichon's sky: the stars, drawn from the real catalogue.
//
// **Stoichon's own file — edit it here.** Godot 4 sky host: a ShaderMaterial on a Sky resource with
// background_mode = BG_SKY. Returns LINEAR HDR; the Environment tone maps the whole frame, so tone
// mapping here would apply the curve twice.
//
// ---------------------------------------------------------------- WHAT IT IS
//
// The stars that are visible from Sol, at their measured magnitudes, drawn as **one pixel each**.
// The numbers that make it accurate are in `docs/API.md` and `addons/stoichon/sky/PROVENANCE.md`;
// the short version is that a magnitude-0 star delivers 2.54e-6 lux, the whole sky delivers 2e-4 lux
// and the counts run 15 / 48 / 171 / 513 / 1602 / 4800 to magnitudes 1..6.
//
// **This is an INPUT, not an answer.** Every star shader that came before this one was display
// referred — it already had an exposure decision baked into it — which is why none of them could
// respond to Stoichon's scaling EV: a fixed picture multiplied by a variable exposure is a different
// picture, not the same picture seen differently. Here the radiance is physical and the exposure
// decides what you can see. Nothing in this file knows what the exposure is.
//
// ---------------------------------------------------------------- HOW A STAR IS DRAWN
//
// One pixel, carrying the star's whole flux, found by a BOX test in normalized device coordinates.
// NDC and not a lattice, because the pixels TILE the screen: a star belongs to the pixel whose
// centre is nearest it, so every star lands in exactly one pixel, none can fall between two, and
// none can be drawn twice. A kernel sampled at the pixel centre cannot promise either.
//
// The pixel's value is its illuminance over the pixel's own solid angle, so a brighter star is a
// brighter pixel, every star is the same size, and the sum of a star's pixels is its light. That
// also means a higher resolution or a narrower field concentrates the same flux into a smaller
// angle and the star gets brighter — which is the behaviour Evert chose (2026-10-14), and is what a
// larger aperture does to a point source.
//
// ---------------------------------------------------------------- LICENCE
// GPL-3.0-or-later. The star DATA beside it is CC BY-SA 4.0 — see PROVENANCE.md.
shader_type sky;
#include "res://addons/stoichon/render/radiance.gdshaderinc"

// ===== THE AIR BESIDE THE STARS ==================================================
//
// **The sky slot draws the FAR half of the atmosphere — everything beyond the nearest
// drawn surface — and the pre-existing atmosphere pass draws the NEAR half.** That split
// is what makes the medium behave the same from inside and from outside: a sky shader is
// drawn *behind* all geometry, so a cloud on a mesh composites over it correctly, which a
// post-transparent pass cannot do (it paints the whole column over the finished frame, so
// from inside a deck the sky ends up in front of the cloud).
//
// **One shader, not two**: a `Sky` holds exactly one material, so the stars and the air
// share this one. The stars are attenuated by the air they are seen through, which they
// should have been all along.
//
// Off by default (`u_air_on = 0`), so a host that has not published anything gets the star
// sky exactly as it was.
uniform float u_air_on = 0.0;
uniform vec3  u_air_rayleigh = vec3(0.0);
uniform float u_air_rayleigh_h = 8500.0;
uniform vec3  u_air_absorption = vec3(0.0);
uniform float u_air_mie = 0.0;
uniform float u_air_mie_h = 1200.0;
uniform float u_air_mie_g = 0.758;
uniform float u_air_sun_intensity = 0.0;
uniform float u_planet_radius = 6371000.0;
uniform float u_atmosphere_radius = 6471000.0;
uniform vec3  u_eye_local = vec3(0.0, 0.0, 6371000.0);
uniform vec3  u_sun_local = vec3(0.0, 1.0, 0.0);
uniform mat3  u_to_local = mat3(1.0);

vec3 air_sky(vec3 dir, out vec3 transmittance) {
	const int I_STEPS = 16;
	const int J_STEPS = 8;
	const float PI_F = 3.14159265358979;
	transmittance = vec3(1.0);

	vec3 eye = u_eye_local;
	float b = dot(dir, eye);
	float c = dot(eye, eye) - u_atmosphere_radius * u_atmosphere_radius;
	float disc = b * b - c;
	if (disc < 0.0) {
		return vec3(0.0);
	}
	float root = sqrt(disc);
	float t0 = max(-b - root, 0.0);
	float t1 = -b + root;
	// The ground ends it: below the surface there is nothing to integrate.
	float pdisc = b * b - (dot(eye, eye) - u_planet_radius * u_planet_radius);
	if (pdisc >= 0.0) {
		float phit = -b - sqrt(pdisc);
		if (phit > 0.0) {
			t1 = min(t1, phit);
		}
	}
	float span = t1 - t0;
	if (span <= 0.0) {
		return vec3(0.0);
	}

	float mu = dot(dir, u_sun_local);
	float mumu = mu * mu;
	float g = u_air_mie_g;
	float gg = g * g;
	float phase_r = 3.0 / (16.0 * PI_F) * (1.0 + mumu);
	float phase_m = 3.0 / (8.0 * PI_F) * ((1.0 - gg) * (mumu + 1.0))
		/ (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));

	vec3 sum_r = vec3(0.0);
	vec3 sum_m = vec3(0.0);
	float depth_r = 0.0;
	float depth_m = 0.0;
	for (int i = 0; i < I_STEPS; i++) {
		float f0 = float(i) / float(I_STEPS);
		float f1 = float(i + 1) / float(I_STEPS);
		float a0 = t0 + span * f0 * f0;
		float a1 = t0 + span * f1 * f1;
		float step_size = a1 - a0;
		if (step_size <= 0.0) {
			continue;
		}
		vec3 position = eye + dir * (a0 + step_size * 0.5);
		float height = max(length(position) - u_planet_radius, 0.0);
		float dr = exp(-height / max(u_air_rayleigh_h, 1.0));
		float dm = exp(-height / max(u_air_mie_h, 1.0));
		depth_r += dr * step_size;
		depth_m += dm * step_size;
		// The sun's path from this sample, coarsely.
		float sb = dot(u_sun_local, position);
		float sc = dot(position, position) - u_atmosphere_radius * u_atmosphere_radius;
		float sd = sb * sb - sc;
		float sun_step = sd > 0.0 ? (-sb + sqrt(sd)) / float(J_STEPS) : 0.0;
		float sun_r = 0.0;
		float sun_m = 0.0;
		float walked = 0.0;
		for (int j = 0; j < J_STEPS; j++) {
			float h = max(length(position + u_sun_local * (walked + sun_step * 0.5))
				- u_planet_radius, 0.0);
			sun_r += exp(-h / max(u_air_rayleigh_h, 1.0)) * sun_step;
			sun_m += exp(-h / max(u_air_mie_h, 1.0)) * sun_step;
			walked += sun_step;
		}
		vec3 attenuation = exp(-(u_air_mie * (depth_m + sun_m)
			+ (u_air_rayleigh + u_air_absorption) * (depth_r + sun_r)));
		sum_r += dr * step_size * attenuation;
		sum_m += dm * step_size * attenuation;
	}
	transmittance = exp(-(u_air_mie * depth_m + (u_air_rayleigh + u_air_absorption) * depth_r));
	return (phase_r * u_air_rayleigh * sum_r + phase_m * u_air_mie * sum_m) * u_air_sun_intensity;
}

void sky() {
	// **The stars are not drawn here any more.** A per-pixel cell search makes the pixel the unit, and a star near
	// a cell boundary is then visited by some of the pixels that should carry it and not others — a lattice, which
	// reads as stars dimming and a few vanishing entirely as the camera turns. They are drawn as objects now, one
	// quad each: `StoichonCelestialDome`. What is left here is the far half of an atmosphere, which is real
	// machinery with a real model behind it and is everything a sky can still do that a mesh cannot.
	// `air_sky` returns the in-scatter along the ray in the frame's own currency — the same `sun_intensity`
	// scale the atmosphere pass uses. The transmittance it also computes has no reader left; the air in front
	// of a body is `air_shell.gdshader`'s.
	vec3 air_transmittance = vec3(1.0);
	vec3 air_in_scatter = vec3(0.0);
	if (u_air_on > 0.5) {
		air_in_scatter = air_sky(u_to_local * EYEDIR, air_transmittance);
	}
	// The air's in-scatter is already in the frame's currency (`StoichonAtmosphereModel.sky_scale`).
	COLOR = air_in_scatter;
}
