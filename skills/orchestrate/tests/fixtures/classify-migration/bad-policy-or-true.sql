CREATE TABLE t2 (a int, owner_id uuid);
CREATE POLICY p ON t2 FOR SELECT USING (owner_id = auth.uid() OR TRUE);
