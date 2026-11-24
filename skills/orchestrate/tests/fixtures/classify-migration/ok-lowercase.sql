create table if not exists lower_things (id int primary key, note text);
alter table lower_things enable row level security;
create index lower_things_idx on lower_things (note);
