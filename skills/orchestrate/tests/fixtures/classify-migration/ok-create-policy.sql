CREATE TABLE widgets (id uuid PRIMARY KEY, owner_id uuid);
CREATE POLICY widgets_owner_update ON widgets FOR UPDATE USING (owner_id = auth.uid());
CREATE POLICY widgets_owner_delete ON widgets FOR DELETE USING (owner_id = auth.uid());
