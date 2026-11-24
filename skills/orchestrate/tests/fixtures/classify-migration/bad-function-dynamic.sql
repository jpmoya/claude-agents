CREATE FUNCTION widget_cleanup(t text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('select 1 from %I', t);
END;
$$;
