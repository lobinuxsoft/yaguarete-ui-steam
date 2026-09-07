# Vendored QR code generator

`qr_code.gd`, `reed_solomon_generator.gd`, `utils.gd` are vendored from
[Greaby/godot-qrcode-generator](https://github.com/Greaby/godot-qrcode-generator)
(MIT, `LICENSE` in this folder), pure GDScript, no native/external
dependency. `Utils` renamed to `QrCodeUtils` to avoid a `class_name`
collision with any other plugin.

Used to render the Aurelia QR login challenge (`aurelia login --qr
--json`) directly on screen, no terminal involved.
