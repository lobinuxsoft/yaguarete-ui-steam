extends Library

# Other interesting commands
# steamcmd +login shadowapex +apps_installed +quit
# Steam Overlay Config is in:
# ~/.steam/steam/userdata/<user_id>/config/localconfig.vdf

const VDF = preload("res://plugins/steam/core/vdf.gd")
const SteamClient := preload("res://plugins/steam/core/steam_client.gd")
const SteamAPIClient := preload("res://plugins/steam/core/steam_api_client.gd")
const _apps_cache_file: String = "apps.json"
const _local_apps_cache_file: String = "local_apps.json"

var thread_pool := load("res://core/systems/threading/thread_pool.tres") as ThreadPool
var steam_api_client := SteamAPIClient.new()
var libraryfolders_path := "/".join([OS.get_environment("HOME"), ".steam/steam/steamapps/libraryfolders.vdf"])

@onready var steam: SteamClient = get_tree().get_first_node_in_group("steam_client")


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	super()
	add_child(steam_api_client)
	logger = Log.get_logger("Steam", Log.LEVEL.DEBUG)
	logger.info("Steam Library loaded")
	steam.logged_in.connect(_on_logged_in)


# Return a list of installed steam apps. Called by the LibraryManager.
func get_library_launch_items() -> Array[LibraryLaunchItem]:
	return await _load_library(Cache.FLAGS.LOAD | Cache.FLAGS.SAVE)


# Installs the given library item.
func install(item: LibraryLaunchItem) -> void:
	# Start the install
	var app_id := item.provider_app_id
	logger.info("Installing " + item.name + " with app ID: " + app_id)
	# Check if title supports Linux or Windows
	if await _app_supports_linux(app_id):
		await steam.set_platform_type("linux")
	else:
		await steam.set_platform_type("windows")
	steam.install(app_id)

	# Connect to progress updates
	var on_progress := func(id: String, bytes_cur: int, bytes_total: int):
		if id != app_id:
			return
		logger.info("Install progressing: " + str(bytes_cur) + "/" + str(bytes_total))
		var progress: float = float(bytes_cur) / float(bytes_total)
		if bytes_total == 0:
			progress = 0
		install_progressed.emit(item, progress)
	steam.install_progressed.connect(on_progress)

	# Wait for the app_installed signal
	var success := false
	var installed_app := ""
	while installed_app != app_id:
		var results = await steam.app_installed
		installed_app = results[0]
		success = results[1]
	install_completed.emit(item, success)
	logger.info("Install of " + item.name + " completed with status: " + str(success))

	# Disconnect from progress updates 
	steam.install_progressed.disconnect(on_progress)


# Updates the given library item.
func update(item: LibraryLaunchItem) -> void:
	# Start the install
	var app_id := item.provider_app_id
	logger.info("Updating " + item.name + " with app ID: " + app_id)
	steam.install(app_id)

	# Connect to progress updates
	var on_progress := func(id: String, bytes_cur: int, bytes_total: int):
		if id != app_id:
			return
		logger.info("Update progressing: " + str(bytes_cur) + "/" + str(bytes_total))
		install_progressed.emit(item, float(bytes_total)/float(bytes_cur))
	steam.install_progressed.connect(on_progress)

	# Wait for the app_updated signal
	var success := false
	var installed_app := ""
	while installed_app != app_id:
		var results = await steam.app_updated
		installed_app = results[0]
		success = results[1]
	update_completed.emit(item, success)
	logger.info("Update of " + item.name + " completed with status: " + str(success))

	# Disconnect from progress updates 
	steam.install_progressed.disconnect(on_progress)


# Uninstalls the given library item.
func uninstall(item: LibraryLaunchItem) -> void:
	# Start the uninstall
	var app_id := item.provider_app_id
	logger.info("Uninstalling " + item.name + " with app ID: " + app_id)
	steam.uninstall(app_id)

	# Wait for the app_uninstalled signal
	var success := false
	var installed_app := ""
	while installed_app != app_id:
		var results = await steam.app_uninstalled
		installed_app = results[0]
		success = results[1]
	uninstall_completed.emit(item, success)
	logger.info("Uninstall of " + item.name + " completed with status: " + str(success))


# Should return true if the given library item has an update available
func has_update(item: LibraryLaunchItem) -> bool:
	return false


# Re-load our library when we've logged in
func _on_logged_in(status: SteamClient.LOGIN_STATUS):
	if status != SteamClient.LOGIN_STATUS.OK:
		return

	# Upon login, fetch the user's library without loading it from cache and
	# reconcile it with the library manager.
	logger.info("Logged in. Updating library cache from Steam.")
	var cmd := func():
		return await _load_library(Cache.FLAGS.SAVE)
	var items: Array = await thread_pool.exec(cmd)
	for i in items:
		var item: LibraryLaunchItem = i
		if not LibraryManager.has_app(item.name):
			var msg := "App {0} was not loaded. Adding item".format([item.name])
			logger.info(msg)
			launch_item_added.emit(item)
			#LibraryManager.add_library_launch_item(library_id, item)
		# TODO: Update installed status
	
	# TODO: Remove library items that have been deleted

	logger.info("Library is up-to-date")


# Return a list of installed steam apps. Optionally caching flags can be passed to
# determine caching behavior.
# Example:
#   _load_library(Cache.FLAGS.LOAD|Cache.FLAGS.SAVE)
func _load_library(
	caching_flags: int = Cache.FLAGS.LOAD | Cache.FLAGS.SAVE
) -> Array[LibraryLaunchItem]:
	# Check to see if our library was cached. If it was, return the cached
	# items.
	if caching_flags & Cache.FLAGS.LOAD and Cache.is_cached(_cache_dir, _apps_cache_file):
		var json_items = Cache.get_json(_cache_dir, _apps_cache_file)
		if json_items != null:
			logger.info("Available apps exist in cache. Using cache.")
			var items := [] as Array[LibraryLaunchItem]
			for i in json_items:
				var item: Dictionary = i
				var launch_item := LibraryLaunchItem.from_dict(item)
				items.append(LibraryLaunchItem.from_dict(item))
				launch_item_added.emit(launch_item)
			return items

	# Wait for the steam client if it's not ready
	if steam.state == steam.STATE.BOOT:
		logger.info("Steam client is not ready yet.")
		return await _load_local_library(caching_flags)

	if not steam.is_logged_in:
		logger.info("Steam client is not logged in yet.")
		return await _load_local_library(caching_flags)

	logger.info("Fetching Steam library...")
	
	# Get all available apps
	var app_ids: PackedInt64Array = await get_available_apps()

	# Get installed apps
	var apps_installed: Array = await steam.get_installed_apps()
	var app_ids_installed := PackedStringArray()
	for app in apps_installed:
		app_ids_installed.append(app["id"])

	# Get the app info for each discovered game and create a launch item for
	# it.
	var items := [] as Array[LibraryLaunchItem]
	for app_id in app_ids:
		var id := str(app_id)
		var info := await get_app_info(id, caching_flags)
		
		if not id in info:
			continue

		var item := _app_info_to_launch_item(info, str(app_id) in app_ids_installed)
		if not item:
			logger.debug("Unable to create launch item for: " + str(app_id))
			continue
		items.append(item)
		launch_item_added.emit(item)

	# Cache the discovered apps
	if caching_flags & Cache.FLAGS.SAVE:
		logger.debug("Saving available apps to cache.")
		var json_items := []
		for i in items:
			var item: LibraryLaunchItem = i
			json_items.append(item.to_dict())
		if Cache.save_json(_cache_dir, _apps_cache_file, json_items) != OK:
			logger.warn("Unable to save Steam apps cache")

	logger.info("Steam library loaded")

	return items


# Return a list of installed locally installed steam apps. Optionally caching 
# flags can be passed to determine caching behavior.
# Example:
#   _load_local_library(Cache.FLAGS.LOAD|Cache.FLAGS.SAVE)
func _load_local_library(
	caching_flags: int = Cache.FLAGS.LOAD | Cache.FLAGS.SAVE
) -> Array[LibraryLaunchItem]:
	# Ensure there is a libraryfolders file
	if not FileAccess.file_exists(libraryfolders_path):
		logger.warn("The libraryfolders.vdf file was not found at: " + libraryfolders_path)
		return []
	
	# Check to see if our library was cached. If it was, return the cached
	# items.
	if caching_flags & Cache.FLAGS.LOAD and Cache.is_cached(_cache_dir, _local_apps_cache_file):
		var json_items = Cache.get_json(_cache_dir, _local_apps_cache_file)
		if json_items != null:
			logger.info("Local apps exist in cache. Using cache.")
			var items := [] as Array[LibraryLaunchItem]
			for i in json_items:
				var item: Dictionary = i
				var launch_item := LibraryLaunchItem.from_dict(item)
				items.append(LibraryLaunchItem.from_dict(item))
				launch_item_added.emit(launch_item)
			return items

	logger.info("Parsing local Steam library...")
	var vdf_string := FileAccess.get_file_as_string(libraryfolders_path)
	var vdf: VDF = VDF.new()
	if vdf.parse(vdf_string) != OK:
		var err_line := vdf.get_error_line()
		logger.debug("Error parsing vdf output on line " + str(err_line) + ": " + vdf.get_error_message())
		return []
	var libraryfolders := vdf.get_data()
	
	# Parse the library folders
	if not "libraryfolders" in libraryfolders:
		return []
	var app_ids := PackedStringArray()
	var entries := libraryfolders["libraryfolders"] as Dictionary
	for folder in entries.values():
		if not "apps" in folder:
			continue
		var apps := folder["apps"] as Dictionary
		for app_id in apps.keys():
			app_ids.append(app_id)
	
	# Get the app info for each discovered game and create a launch item for
	# it.
	var items := [] as Array[LibraryLaunchItem]
	for app_id in app_ids:
		var id := str(app_id)
		var info := await get_app_info(id, caching_flags)
		
		if not id in info:
			continue

		var item := _app_info_to_launch_item(info, true)
		if not item:
			logger.debug("Unable to create launch item for: " + str(app_id))
			continue
		items.append(item)
		launch_item_added.emit(item)

	# Cache the discovered apps
	if caching_flags & Cache.FLAGS.SAVE:
		logger.debug("Saving local apps to cache.")
		var json_items := []
		for i in items:
			var item: LibraryLaunchItem = i
			json_items.append(item.to_dict())
		if Cache.save_json(_cache_dir, _local_apps_cache_file, json_items) != OK:
			logger.warn("Unable to save Steam apps cache")

	logger.info("Local Steam library loaded")

	return items


# Returns an array of available steamAppIds
func get_available_apps() -> Array:
	var app_ids = await steam.get_available_apps()
	return app_ids


## Returns the app information for the given app ids. This is returned as a
## dictionary where the key is the app ID, and the value is the app info.
func get_apps_info(app_ids: Array, caching_flags: int = Cache.FLAGS.LOAD | Cache.FLAGS.SAVE) -> Dictionary:
	var app_info := {}
	for app_id in app_ids:
		var id := str(app_id)
		var info := await get_app_info(id, caching_flags)
		
		if not id in info:
			continue

		app_info[id] = info
		
	return app_info


## Returns the app info dictionary parsed from the VDF
func get_app_info(app_id: String, caching_flags: int = Cache.FLAGS.LOAD | Cache.FLAGS.SAVE) -> Dictionary:
	# Load the app info from cache if requested
	var cache_key := app_id + ".app_info"
	if caching_flags & Cache.FLAGS.LOAD and Cache.is_cached(_cache_dir, cache_key):
		return Cache.get_json(_cache_dir, cache_key)
	else:
		var info = await steam_api_client.get_app_details(app_id)
		logger.debug("Found app info for " + app_id + ": " + str(info))
		if info == null:
			return {}
		if caching_flags & Cache.FLAGS.SAVE:
			Cache.save_json(_cache_dir, cache_key, info)
		return info


## Builds a library launch item from the given Steam app information from the store API.
func _app_info_to_launch_item(info: Dictionary, is_installed: bool) -> LibraryLaunchItem:
	if info.size() == 0:
		return null

	var app_id := info.keys()[0] as String
	var details := info[app_id] as Dictionary
	if not "data" in details:
		return null
	var data := details["data"] as Dictionary
	if not "type" in data:
		return null
	if not data["type"] == "game":
		return null
	var categories := PackedStringArray()
	if "categories" in data:
		for category in data["categories"]:
			categories.append(category["description"])
	var tags := PackedStringArray()
	if "genres" in data:
		for genre in data["genres"]:
			tags.append((genre["description"] as String).to_lower())

	# Launched through Goldberg + umu-run against the REAL Steam-created
	# wineprefix and its matching Proton build (see _find_real_install),
	# not Aurelia's own managed --umu prefix — confirmed 2026-09-07 via
	# Aurelia's own launch summary.json ("per_game_prefix_honored": false)
	# that --umu ignores any externally set WINEPREFIX, so it can only
	# ever run in a prefix Steam Cloud has never heard of. Every
	# real-Steam-client bridge combination (--steam, --umu --steam) was
	# also retested this same session and failed 4/4 times in 3 distinct
	# ways — including steamwebhelper itself crash-looping (its own
	# -startcount arg climbing 0->1->2 unprompted) with FINAL FANTASY VII
	# REMAKE INTERGRADE, never once reaching the actual game process — so
	# there is no real-client fallback to reach for here either.
	var item := LibraryLaunchItem.new()
	item.provider_app_id = app_id
	item.name = data["name"]
	var real := _find_real_install(app_id)
	if real.is_empty():
		item.command = "/".join([OS.get_environment("HOME"), ".local", "bin", "aurelia"])
		item.args = ["play", "--umu", app_id, "--json"]
		# _find_real_install already rejected any real prefix living on a
		# FUSE mount (Proton's own game-drive symlink can't be created
		# there — see _supports_wineprefix) and fell through to here, but
		# a real, populated prefix may still exist at that same rejected
		# path with actual save files in it that Aurelia's own separate
		# master prefix has never seen. Bridge just the save folders
		# across via symlink, not the whole prefix.
		var real_prefix := _find_any_real_prefix(app_id)
		if not real_prefix.is_empty():
			_link_real_saves(app_id, real_prefix)
	else:
		item.command = "/usr/bin/umu-run"
		item.args = [real["exe_path"]]
		item.cwd = real["install_dir"]
		item.env = {
			"GAMEID": app_id,
			"STORE": "steam",
			"PROTONPATH": real["proton_path"],
			"WINEPREFIX": real["wineprefix"],
			"STEAM_COMPAT_INSTALL_PATH": real["install_dir"],
			"STEAM_COMPAT_LIBRARY_PATHS": real["library_root"],
			"UMU_RUNTIME_UPDATE": "0",
		}
	item.categories = categories
	item.tags = ["steam"]
	item.tags.append_array(tags)
	item.installed = is_installed
	
	return item


# Returns whether or not the given app id has a Linux binary
func _app_supports_linux(app_id: String) -> bool:
	var info = await steam_api_client.get_app_details(app_id)
	if not app_id in info:
		return false
	if not "data" in info[app_id]:
		return false
	if not "platform" in info[app_id]["data"]:
		return false
	if not "linux" in info[app_id]["data"]["platform"]:
		return false

	return info[app_id]["data"]["platform"]["linux"]


## Resolves a real, already-Steam-created install + wineprefix for the
## given app id. Checks every registered library's own steamapps dir
## directly for the manifest — NOT libraryfolders.vdf's own "apps" list,
## which can go stale (a game moved onto a cartridge after Steam last
## scanned it still lists the OLD folder there while the manifest and a
## real, populated wineprefix live on the new one; live-caught 2026-09-07,
## FINAL FANTASY VII REMAKE INTERGRADE listed under the main library while
## every actual file was on a cartridge mount). Among every library that
## has the manifest, the first with a REAL prefix (Tatu's own
## _is_real_prefix check: system.reg present) wins; a manifest-only match
## with no real prefix is kept as a fallback in case none do. Returns {}
## if nothing at all resolves — callers fall back to Aurelia's own --umu,
## which manages its own prefix instead.
func _find_real_install(app_id: String) -> Dictionary:
	if not FileAccess.file_exists(libraryfolders_path):
		return {}
	var vdf := VDF.new()
	if vdf.parse(FileAccess.get_file_as_string(libraryfolders_path)) != OK:
		return {}
	var libraryfolders := vdf.get_data()
	if not "libraryfolders" in libraryfolders:
		return {}
	var entries := libraryfolders["libraryfolders"] as Dictionary
	var fallback := {}
	for folder in entries.values():
		if not "path" in folder:
			continue
		var library_root := folder["path"] as String
		var manifest_path := "/".join([library_root, "steamapps", "appmanifest_" + app_id + ".acf"])
		if not FileAccess.file_exists(manifest_path):
			continue
		var manifest_vdf := VDF.new()
		if manifest_vdf.parse(FileAccess.get_file_as_string(manifest_path)) != OK:
			continue
		var manifest := manifest_vdf.get_data()
		if not "AppState" in manifest or not "installdir" in manifest["AppState"]:
			continue
		var install_dir := "/".join([library_root, "steamapps", "common", manifest["AppState"]["installdir"]])
		var exe_path := _find_main_exe(install_dir)
		if exe_path == "":
			continue
		var compatdata := "/".join([library_root, "steamapps", "compatdata", app_id])
		var version_path := "/".join([compatdata, "version"])
		if not FileAccess.file_exists(version_path):
			continue
		var proton_name := FileAccess.get_file_as_string(version_path).strip_edges()
		var proton_path := _find_proton_path(proton_name)
		if proton_path == "":
			continue
		var wineprefix := "/".join([compatdata, "pfx"])
		if not _supports_wineprefix(wineprefix):
			continue
		var candidate := {
			"install_dir": install_dir,
			"exe_path": exe_path,
			"wineprefix": wineprefix,
			"proton_path": proton_path,
			"library_root": library_root,
		}
		if FileAccess.file_exists("/".join([wineprefix, "system.reg"])):
			return candidate
		if fallback.is_empty():
			fallback = candidate
	return fallback


## Same manifest walk as _find_real_install, but without the
## _supports_wineprefix filter — used only to locate save files to bridge
## across, never to pick a WINEPREFIX to actually launch with.
func _find_any_real_prefix(app_id: String) -> String:
	if not FileAccess.file_exists(libraryfolders_path):
		return ""
	var vdf := VDF.new()
	if vdf.parse(FileAccess.get_file_as_string(libraryfolders_path)) != OK:
		return ""
	var libraryfolders := vdf.get_data()
	if not "libraryfolders" in libraryfolders:
		return ""
	for folder in (libraryfolders["libraryfolders"] as Dictionary).values():
		if not "path" in folder:
			continue
		var compatdata := "/".join([folder["path"], "steamapps", "compatdata", app_id])
		var wineprefix := "/".join([compatdata, "pfx"])
		if FileAccess.file_exists("/".join([wineprefix, "system.reg"])):
			return wineprefix
	return ""


## Symlinks every real save folder this account's Steam Cloud already
## knows about (Aurelia's own cloud_sync cache — the same real paths, not
## a guessed per-game folder name) from wherever a real prefix actually
## has them into Aurelia's single shared --umu prefix, so a standalone
## launch through it sees the same saves a real prefix launch would.
## Idempotent and additive only: never touches a destination that isn't
## itself already one of our own symlinks, so a save a standalone launch
## has genuinely written on its own is never clobbered.
func _link_real_saves(app_id: String, real_prefix: String) -> void:
	var home := OS.get_environment("HOME")
	var cloud_sync_path := "/".join([home, ".config/Aurelia/cloud_sync", app_id + ".json"])
	if not FileAccess.file_exists(cloud_sync_path):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(cloud_sync_path))
	if not parsed is Dictionary or not "files" in parsed:
		return
	var master_prefix := "/".join([home, ".config/Aurelia/master_steam_prefix/pfx/pfx"])
	var linked_rel_dirs := {}
	for key in (parsed["files"] as Dictionary).keys():
		var rel_key := (key as String)
		if not rel_key.begins_with("%WinMyDocuments%"):
			continue
		var rel_dir := rel_key.trim_prefix("%WinMyDocuments%").get_base_dir()
		if rel_dir in linked_rel_dirs:
			continue
		linked_rel_dirs[rel_dir] = true
		var dest := "/".join([master_prefix, "drive_c/users/steamuser/Documents", rel_dir])
		# Anything already here — a real directory from a prior standalone
		# save, or a symlink this same function made on an earlier launch —
		# is left alone. Only ever fills in a destination that doesn't
		# exist yet at all.
		if DirAccess.dir_exists_absolute(dest):
			continue
		for source in [
			"/".join([real_prefix, "drive_c/users/steamuser/documents", rel_dir.to_lower()]),
			"/".join([real_prefix, "drive_c/users/steamuser/Documents", rel_dir]),
		]:
			if not DirAccess.dir_exists_absolute(source):
				continue
			DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
			OS.execute("ln", ["-s", source, dest])
			break


## FUSE-mounted NTFS/exFAT (the norm for external cartridges/USB storage)
## doesn't support real POSIX symlinks, and Proton's own game-drive setup
## (the "S:" dosdevice, done on every session init, not just the first)
## needs exactly that — live-caught 2026-09-07, FINAL FANTASY VII REMAKE:
## os.symlink() failed with EINVAL trying to create pfx/dosdevices/s: on a
## fuseblk mount. Matches Tatu's own goldberg.rs, which explicitly never
## reuses a real prefix living on the cartridge itself for the same reason
## (_find_real_prefix skips it, always falling back to a fresh prefix on
## internal storage instead).
func _supports_wineprefix(path: String) -> bool:
	var f := FileAccess.open("/proc/mounts", FileAccess.READ)
	if not f:
		return true
	var best_mount_point := ""
	var best_fstype := ""
	while not f.eof_reached():
		var fields := f.get_line().split(" ")
		if fields.size() < 3:
			continue
		var mount_point: String = fields[1]
		if path.begins_with(mount_point) and mount_point.length() > best_mount_point.length():
			best_mount_point = mount_point
			best_fstype = fields[2]
	return not best_fstype.to_lower() in ["fuseblk", "ntfs", "ntfs3", "exfat", "fuse.ntfs-3g", "fuse.exfat"]


## Picks the main .exe for an install directory. No appinfo.vdf lookup
## (Steam's own binary VDF cache — a separate format vdf.gd doesn't parse)
## — just the install root's own .exe if there's exactly one, or the
## shallowest non-redistributable .exe within a few directories of it.
## Covers the common case (single root-level exe, or a UE-style
## Binaries/Win64 layout); games Steam itself resolves a different way for
## "Play" need appinfo.vdf support added here later.
func _find_main_exe(install_dir: String) -> String:
	var root_exes := _list_exes(install_dir)
	if root_exes.size() == 1:
		return root_exes[0]
	var non_game_needles := [
		"vcredist", "vc_redist", "directx", "dxsetup", "redist",
		"crashpad", "crashhandler", "easyanticheat", "uninstall", "setup.exe",
	]
	for candidate in _walk_exes(install_dir, 0, 5):
		var lower := candidate.get_file().to_lower()
		var is_redist := false
		for needle in non_game_needles:
			if needle in lower:
				is_redist = true
				break
		if not is_redist:
			return candidate
	return ""


func _list_exes(dir_path: String) -> PackedStringArray:
	var result := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "exe":
			result.append("/".join([dir_path, file_name]))
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


func _walk_exes(dir_path: String, depth: int, max_depth: int) -> PackedStringArray:
	var result := _list_exes(dir_path)
	if depth >= max_depth:
		return result
	var dir := DirAccess.open(dir_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if dir.current_is_dir() and not file_name.begins_with("."):
			result.append_array(_walk_exes("/".join([dir_path, file_name]), depth + 1, max_depth))
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


func _find_proton_path(proton_name: String) -> String:
	var home := OS.get_environment("HOME")
	var candidates := [
		"/".join([home, ".steam/root/compatibilitytools.d", proton_name]),
		"/".join([home, ".local/share/Steam/compatibilitytools.d", proton_name]),
		"/".join([home, ".local/share/Steam/steamapps/common", proton_name]),
	]
	for candidate in candidates:
		if DirAccess.dir_exists_absolute(candidate):
			return candidate
	return ""
