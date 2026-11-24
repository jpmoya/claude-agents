CREATE TABLE gadgets (id int PRIMARY KEY);
ALTER TABLE gadgets ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.gadgets TO authenticated;
GRANT SELECT ON TABLE "gadgets" TO anon, service_role;
GRANT ALL ON gadgets TO service_role;
