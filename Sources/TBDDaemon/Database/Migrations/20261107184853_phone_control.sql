-- Phone control (docs/specs/2026-11-07-phone-control-design.md, section 11).
-- No DEFAULT on phone_control_enabled: NULL means nobody has chosen, and the
-- shipped default lives only in Config.phoneControlEnabledDefault.
-- phone_relay_url NULL means not set up; phone_loader_url NULL means the default loader.
ALTER TABLE config ADD COLUMN phone_control_enabled INTEGER;
ALTER TABLE config ADD COLUMN phone_relay_url TEXT;
ALTER TABLE config ADD COLUMN phone_loader_url TEXT;
-- One row per paired phone, created only on Allow. room_id is that phone's
-- permanent relay room. Revoke deletes the row.
CREATE TABLE IF NOT EXISTS phone_device (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    public_key BLOB NOT NULL,
    room_id TEXT NOT NULL,
    paired_at DATETIME NOT NULL,
    last_seen_at DATETIME
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_phone_device_room_id ON phone_device (room_id);
