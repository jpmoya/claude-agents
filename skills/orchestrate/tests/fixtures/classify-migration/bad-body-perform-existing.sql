CREATE FUNCTION g() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM wipe_table(); END $$;
