CREATE FUNCTION g() RETURNS int LANGUAGE sql AS $$ SELECT wipe_table() $$;
