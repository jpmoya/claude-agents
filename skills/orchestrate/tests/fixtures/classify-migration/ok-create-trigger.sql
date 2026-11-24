CREATE TABLE widgets (id uuid PRIMARY KEY, updated_at timestamptz);
CREATE FUNCTION widget_touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := now(); RETURN NEW; END; $$;
CREATE TRIGGER widgets_touch BEFORE UPDATE OR DELETE ON widgets
  FOR EACH ROW EXECUTE FUNCTION widget_touch();
CREATE OR REPLACE TRIGGER widgets_touch BEFORE UPDATE OR DELETE ON widgets
  FOR EACH ROW EXECUTE FUNCTION public.widget_touch();
