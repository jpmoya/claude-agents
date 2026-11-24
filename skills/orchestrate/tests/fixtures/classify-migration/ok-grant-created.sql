CREATE TABLE gadgets (id int PRIMARY KEY);
GRANT SELECT, INSERT, UPDATE ON public.gadgets TO authenticated;
GRANT SELECT ON TABLE "gadgets" TO anon, service_role;
