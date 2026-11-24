/* nested /* comment */ with DROP TABLE widgets; still a comment */
CREATE TABLE doodads (id int PRIMARY KEY, note text, owner_id uuid); -- DROP COLUMN note
ALTER TABLE doodads ENABLE ROW LEVEL SECURITY;
CREATE INDEX doodads_note_idx ON doodads (note);
CREATE POLICY doodads_read ON doodads FOR SELECT USING (owner_id = auth.uid());
GRANT SELECT ON doodads TO authenticated;
ALTER TABLE widgets ADD COLUMN doodad_id int;
