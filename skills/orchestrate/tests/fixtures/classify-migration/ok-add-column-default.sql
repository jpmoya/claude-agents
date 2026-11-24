ALTER TABLE widgets ADD COLUMN archived boolean NOT NULL DEFAULT false;
ALTER TABLE widgets ADD COLUMN size int DEFAULT 0, ADD COLUMN colour text;
