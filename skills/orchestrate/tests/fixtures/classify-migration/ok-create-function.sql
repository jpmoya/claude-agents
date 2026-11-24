CREATE FUNCTION widget_touch() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
  -- the word update in a string or a comment is not a statement
  IF TG_OP = 'UPDATE' THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$body$;
-- replacing a function this same file created is still additive
CREATE OR REPLACE FUNCTION widget_touch() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$body$;
