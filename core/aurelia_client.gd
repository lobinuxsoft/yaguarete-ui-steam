extends Node
class_name AureliaClient

## Godot interface for the Aurelia CLI (github.com/Drackrath/Aurelia)
##
## Aurelia speaks Steam's real network protocol (steam-vent) and exposes
## every command as streamed JSON lines, so it can drive the whole login
## flow without a terminal — perfect for a gamepad-native login screen.
## Event shapes come straight from Aurelia's own source
## (src/commands/auth.rs), not guessed: most lines carry an "event" key
## ("qr_challenge", "qr_scanned"), but the final success line does not —
## it's `{"logged_in": true, "account": "..."}`.

signal qr_ready(url: String)
signal qr_scanned
signal login_succeeded(account: String)
signal login_failed(reason: String)

## Spawned by absolute path — the PTY's child process doesn't inherit a
## PATH that includes ~/.local/bin (where `aurelia` is typically installed),
## so a bare "aurelia" fails with ENOENT even when it's on the user's own
## shell PATH.
var aurelia_bin := "/".join([OS.get_environment("HOME"), ".local", "bin", "aurelia"])

var pty: Pty
var registry := load("res://core/systems/resource/resource_registry.tres") as ResourceRegistry
var logger := Log.get_logger("AureliaClient", Log.LEVEL.INFO)
var _resolved := false


## Starts a QR login challenge. Emits [signal qr_ready] with a URL to
## render as a QR code once Steam issues the challenge, [signal qr_scanned]
## once the mobile app scans it, and [signal login_succeeded] or
## [signal login_failed] once the flow resolves.
func login_qr() -> void:
	if pty and pty.get_running():
		logger.warn("Login already in progress")
		return
	_resolved = false
	pty = Pty.new()
	pty.line_written.connect(_on_line_written)
	pty.finished.connect(_on_finished)
	registry.add_child(pty)
	pty.exec(aurelia_bin, ["login", "--qr", "--json"])


func _on_line_written(line: String) -> void:
	logger.debug("aurelia: " + line)
	var parsed: Variant = JSON.parse_string(line)
	if not parsed is Dictionary:
		return
	var data: Dictionary = parsed

	# The final success line has no "event" key.
	if data.get("logged_in", false):
		_resolved = true
		login_succeeded.emit(data.get("account", ""))
		return

	match data.get("event", ""):
		"qr_challenge":
			qr_ready.emit(data.get("url", ""))
		"qr_scanned":
			qr_scanned.emit()
		"error":
			_resolved = true
			login_failed.emit(data.get("message", "unknown error"))


## `aurelia login` hands off to a background daemon the moment it succeeds,
## and that handoff can close its stdout before the final `{"logged_in":
## true, ...}` line reaches us — live-caught: the CLI-level login was real
## (`aurelia account` showed the right account) but the streamed event
## never arrived. Falling back to a direct `aurelia account` check on exit
## makes success detection depend on Aurelia's actual state, not on
## catching one specific line before a process teardown races it.
func _on_finished(exit_code: int) -> void:
	if pty:
		registry.remove_child(pty)
	pty = null
	if _resolved:
		return
	if exit_code != 0:
		login_failed.emit("aurelia exited with code %d" % exit_code)
		return
	_check_account_fallback()


func _check_account_fallback() -> void:
	var output: Array = []
	if OS.execute(aurelia_bin, ["account", "--json"], output) != OK:
		login_failed.emit("could not verify login state")
		return
	var parsed: Variant = JSON.parse_string(output[0] if not output.is_empty() else "")
	if not parsed is Dictionary or not "account_name" in parsed:
		login_failed.emit("could not verify login state")
		return
	login_succeeded.emit((parsed as Dictionary).get("account_name", ""))
