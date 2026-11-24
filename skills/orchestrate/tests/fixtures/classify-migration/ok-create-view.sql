CREATE TABLE widgets (id uuid PRIMARY KEY, label text);
CREATE VIEW widget_labels AS
  SELECT id, label FROM widgets;
CREATE OR REPLACE VIEW widget_labels AS
  SELECT id, lower(label) AS label FROM widgets;
