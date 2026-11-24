CREATE FUNCTION widget_cleanup() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  DROP TABLE widgets;
END;
$f$;
