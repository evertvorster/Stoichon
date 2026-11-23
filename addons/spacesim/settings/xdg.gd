class_name SpacesimXdg
extends RefCounted
## XDG Base Directory paths.
##
## Godot's `user://` is a single writable directory, under the *data* home and nested through
## `godot/app_userdata`, so it cannot separate configuration from data and it is not `~/.config`.
## These resolve the paths properly instead, which also puts the world and save repositories
## somewhere predictable.
##
## Per the specification a variable that is unset, empty, or **not an absolute path** is ignored —
## the last of those is the rule nobody implements until it bites.

const APP_DIR := "stoichon"

## **The directory this application used until it was renamed, on 2026-11-23.** It is adopted on first run
## and never deleted: a world is the player's, and learning a new name is not a reason to lose one.
const LEGACY_APP_DIR := "spacesim"

## Whether the adoption has been tried. Every path below asks, and the answer is the same each time.
static var _adopted := false


## **Move a pre-rename directory into place, once.** Both roots are checked — the settings live in one and
## the worlds in the other — and a rename only happens when the new directory does not exist, so a player who
## has already run this build is never moved back onto the old one.
##
## `again` exists for the test, which needs to run it twice against a scratch directory in one process.
static func adopt_legacy(again := false) -> void:
	if _adopted and not again:
		return
	_adopted = true
	for base in [config_home(), data_home()]:
		var old: String = base.path_join(LEGACY_APP_DIR)
		var new: String = base.path_join(APP_DIR)
		if not DirAccess.dir_exists_absolute(old):
			continue
		if DirAccess.dir_exists_absolute(new):
			continue
		var moved := DirAccess.rename_absolute(old, new)
		if moved != OK:
			push_warning(
				"cannot move '%s' to '%s' (%s); the old settings and worlds are left where they are"
				% [old, new, error_string(moved)]
			)


static func config_home() -> String:
	return _base("XDG_CONFIG_HOME", ".config")


static func data_home() -> String:
	return _base("XDG_DATA_HOME", ".local/share")


## Where this application's settings live.
static func config_dir() -> String:
	adopt_legacy()
	return config_home().path_join(APP_DIR)


## Where this application's data (worlds, save branches) lives.
static func data_dir() -> String:
	adopt_legacy()
	return data_home().path_join(APP_DIR)


static func settings_path() -> String:
	return config_dir().path_join("settings.cfg")


## Where the player's bindings live — **beside** the settings and in their own file, because they are
## written by a different store and staged by a different edit.
static func bindings_path() -> String:
	return config_dir().path_join("bindings.cfg")


static func ensure_directory(path: String) -> bool:
	if DirAccess.dir_exists_absolute(path):
		return true
	return DirAccess.make_dir_recursive_absolute(path) == OK


static func _base(variable: String, fallback_relative: String) -> String:
	var value := OS.get_environment(variable)
	if not value.is_empty() and value.is_absolute_path():
		return value
	var home := OS.get_environment("HOME")
	if home.is_empty():
		# Nowhere to put it: fall back to Godot's user directory so the game still runs.
		return OS.get_user_data_dir()
	return home.path_join(fallback_relative)
