-- widgets: a brand new table; ON DELETE / ON UPDATE are foreign key actions, not statements
CREATE TABLE widgets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid REFERENCES owners(id) ON DELETE CASCADE ON UPDATE CASCADE,
  label text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
