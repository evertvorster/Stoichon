shader_type sky;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
// Layer 1: the empty sky, and the uncatalogued stars below the catalogue's own depth.
//
// ------------------------------------------------------------------ WHAT IS HERE
//
// The deep background — black, because interplanetary space has no ambient light and no scattered light — and a
// procedural field of stars fainter than the catalogue carries.
//
// It is evaluated strictly from the world-space direction (`EYEDIR`), never from screen coordinates, and never
// from a temporal variable or a screen-space derivative: the value in a direction must not depend on where that
// direction happens to land on the screen, or on which frame it is. That is the only way a procedural field can
// be stable under a camera that turns.
//
// ------------------------------------------------------------------ WHY THE GRID IS FINE
//
// A cell of this grid is smaller than a pixel at any field of view this game uses, so each star's falloff lands
// inside one pixel and the field reads as points rather than as blotches. A coarse grid with a per-pixel lookup
// is what makes smears: the cell, not the star, becomes the visible unit.
//
// **The depth starts at the catalogue's own limit** (`sky/faint_depth`, 10.5 for `hyg_v44`, which is complete to
// 8.0 and holds stars to 10.5), not at the 7.5 a generic specification would name. Drawing a procedural field
// above a catalogue that already holds those stars is drawing the same light twice — which reads as a sky
// brighter than its own ambient, and cannot be fixed by any exposure.

const float LUX_PER_MAG0 = 2.54e-6;
const float LUX_PER_ENGINE_UNIT = 100000.0 / 3.14159265358979;

// This frame's numbers, the same five every other layer takes: a pixel's solid angle is what turns an
// illuminance into a radiance, and it is the host's to know.
uniform vec3 u_right = vec3(1.0, 0.0, 0.0);
uniform vec3 u_up = vec3(0.0, 1.0, 0.0);
uniform vec3 u_fwd = vec3(0.0, 0.0, -1.0);
uniform vec2 u_tan_half = vec2(0.5, 0.5);
uniform vec2 u_view_size = vec2(1280.0, 720.0);

// Cells per unit of direction. 640 puts a cell at about a third of a pixel at this game's widest field of view.
uniform int u_grid = 640;
// How much of a cell a star's light covers, and where its centre sits inside the cell.
uniform float u_spread = 0.22;
// The faint end's depth, in magnitudes.
uniform float u_faint_depth = 10.5;
uniform float u_faint_span = 1.5;
uniform float u_faint_on = 1.0;
uniform float u_faint_gain = 1.0;

float hash13(vec3 cell) {
	vec3 p = fract(cell * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	vec3 radiance = vec3(0.0);

	if (u_faint_on > 0.5) {
		vec3 lattice = direction * float(u_grid);
		vec3 cell = floor(lattice);
		// One star per cell, at a hashed place inside it and at a hashed brightness in the faint band.
		vec3 offset = vec3(hash13(cell + 11.17), hash13(cell + 37.71), hash13(cell + 71.33));
		vec3 star_direction = normalize((cell + offset) / float(u_grid));
		float separation = length(direction - star_direction) * float(u_grid);
		float falloff = exp(-pow(separation / u_spread, 2.0));

		// A star exists in a cell only sometimes, which is what makes the field sparse rather than a wash.
		float present = step(0.80, hash13(cell + 5.19));
		float magnitude = u_faint_depth + hash13(cell + 3.71) * u_faint_span;
		float lux = LUX_PER_MAG0 * pow(10.0, -0.4 * magnitude);
		// The pixel's own solid angle comes from the same two host numbers every other layer uses.
		float pixel_angle = 2.0 * u_tan_half.y / u_view_size.y;
		radiance = vec3(lux * u_faint_gain * RADIANCE_GAIN
			/ (max(pixel_angle * pixel_angle, 1.0e-16) * LUX_PER_ENGINE_UNIT));
		radiance *= falloff * present;
	}

	COLOR = radiance;
}

