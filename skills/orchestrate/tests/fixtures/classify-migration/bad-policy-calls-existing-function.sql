CREATE TABLE t2 (a int);
CREATE POLICY p ON t2 FOR SELECT USING (is_admin_somewhere());
