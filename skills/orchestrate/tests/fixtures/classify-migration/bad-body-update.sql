CREATE FUNCTION g() RETURNS void LANGUAGE sql AS $$ UPDATE some_table SET a = 1 $$;
