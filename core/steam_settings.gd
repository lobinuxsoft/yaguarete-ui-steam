extends Control

const AureliaClient := preload("res://plugins/steam/core/aurelia_client.gd")
var settings_manager := load("res://core/global/settings_manager.tres") as SettingsManager
var notification_manager := load("res://core/global/notification_manager.tres") as NotificationManager
const icon := preload("res://plugins/steam/assets/steam.svg")

@onready var logged_in_status := $%LoggedInStatus
@onready var qr_status := $%QrStatus
@onready var qr_texture_rect := $%QrTextureRect
@onready var login_button := $%LoginButton

var aurelia := AureliaClient.new()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	add_child(aurelia)
	aurelia.qr_ready.connect(_on_qr_ready)
	aurelia.qr_scanned.connect(_on_qr_scanned)
	aurelia.login_succeeded.connect(_on_login_succeeded)
	aurelia.login_failed.connect(_on_login_failed)

	# Connect the login button
	login_button.pressed.connect(_on_login_button)


# Called when the login button is pressed
func _on_login_button() -> void:
	qr_status.description = "Waiting for the QR code..."
	qr_status.color = "gray"
	qr_texture_rect.visible = false
	aurelia.login_qr()


func _on_qr_ready(url: String) -> void:
	var qr_code := QrCode.new()
	qr_code.error_correct_level = QrCode.ErrorCorrectionLevel.LOW
	qr_texture_rect.texture = qr_code.get_texture(url)
	qr_code.queue_free()
	qr_texture_rect.visible = true
	qr_status.description = "Scan with the Steam Mobile app"
	qr_status.color = "gray"


func _on_qr_scanned() -> void:
	qr_status.description = "Scanned — confirm on your phone"
	qr_status.color = "gray"


func _on_login_succeeded(account: String) -> void:
	qr_texture_rect.visible = false
	qr_status.description = "Logged in as " + account
	qr_status.color = "green"
	logged_in_status.status = logged_in_status.STATUS.CLOSED
	logged_in_status.color = "green"
	settings_manager.set_value("plugin.steam", "user", account)

	var notify := Notification.new("Successfully logged in to Steam")
	notify.icon = icon
	notification_manager.show(notify)


func _on_login_failed(reason: String) -> void:
	qr_texture_rect.visible = false
	qr_status.description = "Login failed: " + reason
	qr_status.color = "red"

	var notify := Notification.new("Failed to login to Steam")
	notify.icon = icon
	notification_manager.show(notify)
