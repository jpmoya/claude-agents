CREATE POLICY p ON existing_tbl FOR ALL USING (owner_id = auth.uid());
