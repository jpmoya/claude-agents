CREATE INDEX IF NOT EXISTS widgets_label_idx ON widgets (label);
CREATE UNIQUE INDEX widgets_owner_label_uq ON widgets (owner_id, label) WHERE label <> '';
