create extension ltree;
create extension btree_gist;
CREATE EXTENSION cstore_fdw;
CREATE SERVER cstore_server FOREIGN DATA WRAPPER cstore_fdw;

create table "metric-data-names" (
  id serial primary key,
  name varchar(255) not null,
  path ltree unique not null
);

create table "metric-data-scopes" (
  id serial primary key,
  name varchar(255) not null,
  path ltree unique not null
);

CREATE FOREIGN TABLE "metric-data"
(
  "time" timestamp without time zone not null,
  "scope-id" int not null,
  "name-id"  int not null,

  "call-count"           real not null,
  "total-call-time"      real not null,
  "total-exclusive-time" real not null,
  "min-call-time"        real not null,
  "max-call-time"        real not null,
  "sum-of-squares"       real not null
)
SERVER cstore_server
OPTIONS(compression 'none');

INSERT INTO "metric-data-scopes" (name, path)
SELECT i,
       concat_ws('.', i,
                      floor(random() * 5),
                      floor(random() * 5000))::ltree
FROM generate_series(0, 10000) AS g (i);

INSERT INTO "metric-data-names" (name, path)
SELECT i,
       concat_ws('.', i,
                      floor(random() * 5),
                      floor(random() * 5000))::ltree
FROM generate_series(0, 30000) AS g (i);


INSERT INTO "metric-data" (
  "time",
  "scope-id",
  "name-id",
  "call-count",
  "total-call-time",
  "total-exclusive-time",
  "min-call-time",
  "max-call-time",
  "sum-of-squares"
)
SELECT to_timestamp(floor( 1555523785 - (i / 300) * 60 ))::timestamp without time zone,
       floor(random() * 10000) + 1,
       floor(random() * 30000) + 1,
       random() * 10000,
       random() * 10000,
       random() * 10000,
       random() * 10000,
       random() * 10000,
       random() * 10000
FROM generate_series(300 * 60 * 24 * 7 * 2, 0, -1) AS g (i);

-- insert into "metric-data-scopes" (name, path)
-- values ('', '')
-- returning id;

-- insert into "metric-data-names" (name, path)
-- values ('db/mysql/web', 'db.mysql.web'),
--        ('db/pg/web',    'db.pg.web'),
--        ('db/redis/web', 'db.redis.web')
-- returning id;

-- INSERT INTO "metric-data" (
--   "time",
--   "scope-id",
--   "name-id",
--   "call-count",
--   "total-call-time",
--   "total-exclusive-time",
--   "min-call-time",
--   "max-call-time",
--   "sum-of-squares"
-- ) values
-- (
-- '2019-04-02 17:00:00',
-- 10002,
-- 30004,
-- 0, 0, 0, 0, 0, 0
-- )
-- ;


create index on "metric-data-scopes" using gist (path, id);
create index on "metric-data-names"  using gist (path, id);















explain analyze
select *
from "metric-data"
join "metric-data-names"  as names on names.id = "name-id"
join "metric-data-scopes" as scopes on scopes.id = "scope-id"
where
time >= '2019-04-10 17:00:00' and time < '2019-04-10 17:02:00'
and names.path ? array['*{1}.1.*{1}']::lquery[]
and scopes.path ~ '*{1}.1.*{1}'
;



explain analyze
with
names as (
  select id, name
  from "metric-data-names"
  where path ? array['*{1}.1.*{1}']::lquery[]
  limit 2
),
scopes as (
  select id
  from "metric-data-scopes"
  where path ~ '*{1}.1.*{1}'
  limit 1
),
data as (
  select *
  from "metric-data"
  where time >= '2019-04-10 17:00:00' and
        time <  '2019-04-10 17:03:00' and
        "name-id" in  (select id from names) and
        "scope-id" in (select id from scopes)
)
select * from data;


explain analyze
  select *
  from "metric-data"
  where time >= '2019-04-10 17:00:00' and
        time <  '2019-04-10 17:03:00' and
        "name-id" in  (6133, 17799) and
        "scope-id" in (1805, 9732)









/*+ Leading(("metric-data" ("intervals" ("metric-data-names" "metric-data-scopes")))) */
explain analyze
select *
from "metric-data"
join
    (values
      (tsrange('2019-04-10 17:00:00', '2019-04-10 17:01:00')),
      (tsrange('2019-04-10 17:01:00', '2019-04-10 17:02:00')),
      (tsrange('2019-04-10 17:02:00', '2019-04-10 17:03:00')))
    as intervals(interval)
    on time >= lower(interval) and time < upper(interval)
;












explain analyze
select
  interval,
  json_object_agg(name, metrics) as metrics
from (

  select
    intervals.interval,
    names.name,
    json_build_object(
      'total-call-time',       sum( factor * "total-call-time" ),
      'total-exclusive-time',  sum( factor * "total-exclusive-time" ),
      'call-count',            sum( factor * "call-count" )
    ) as metrics
  from "metric-data" as data
  join
    (values
      (tsrange('2019-04-02 17:00:00', '2019-04-02 17:01:00')),
      (tsrange('2019-04-02 17:01:00', '2019-04-02 17:02:00')),
      (tsrange('2019-04-02 17:02:00', '2019-04-02 17:03:00')))
    as intervals(interval)
    on data.interval && intervals.interval
  join "metric-data-names"  as names  on data."name-id"  = names.id
  join "metric-data-scopes" as scopes on data."scope-id" = scopes.id
  ,
  lateral (select data.interval * intervals.interval
                  as intersection) intersection,
  lateral (select extract(epoch from (upper(intersection) - lower(intersection)))
                  as intersection_time) intersection_time,
  lateral (select extract(epoch from (upper(data.interval) - lower(data.interval)))
                  as interval_time) interval_time,
  lateral (select intersection_time / interval_time
                  as factor) factor
  where
    -- без этой штуки не правильно делает join и не использует индекс.
    data.interval && tsrange('2019-04-02 17:00:00', '2019-04-02 17:03:00')
    and scopes.path = ''
    and names.path ? array['db.*{1}.web']::lquery[]
  group by intervals.interval, names.name

) as res
group by interval
order by 1;









explain analyze

with intervals(interval) as (
  values
    (tsrange('2019-04-02 17:00:00', '2019-04-02 17:01:00')),
    (tsrange('2019-04-02 17:01:00', '2019-04-02 17:02:00')),
    (tsrange('2019-04-02 17:02:00', '2019-04-02 17:03:00'))
), data as (
  select
    interval,
    "scope-id",
    "name-id",
    "total-call-time",
    "total-exclusive-time",
    "call-count"
  from "metric-data"
  where interval && tsrange('2019-04-02 17:00:00', '2019-04-02 17:03:00')
), scopes as (
  select id
  from "metric-data-scopes"
  where path = ''
), names as (
  select id, name
  from "metric-data-names"
  where path ? array['db.*{1}.web']::lquery[]
), res as (
   select
    intervals.interval,
    names.name,
    json_build_object(
      'total-call-time',       sum( factor * "total-call-time" ),
      'total-exclusive-time',  sum( factor * "total-exclusive-time" ),
      'call-count',            sum( factor * "call-count" )
    ) as metrics
  from intervals
  join data   on data.interval && intervals.interval
  join scopes on data."scope-id" = scopes.id
  join names  on data."name-id"  = names.id
  ,
  lateral (select data.interval * intervals.interval
                  as intersection) intersection,
  lateral (select extract(epoch from (upper(intersection) - lower(intersection)))
                  as intersection_time) intersection_time,
  lateral (select extract(epoch from (upper(data.interval) - lower(data.interval)))
                  as interval_time) interval_time,
  lateral (select intersection_time / interval_time
                  as factor) factor
  group by intervals.interval, names.name
)
select
  interval,
  json_object_agg(name, metrics) as metrics
from res
group by interval
order by 1;


/*+ BitmapScan("metric-data" "metric-data_interval_idx") */
explain analyze
select * from "metric-data" where interval && tsrange('2019-04-10 17:00:00', '2019-04-10 17:01:00');


explain analyze
select * from "metric-data" where
(finish > '2019-04-10 17:00:00' and finish < '2019-04-10 17:01:00')

union all
select * from "metric-data" where
(start >= '2019-04-10 17:00:00' and start < '2019-04-10 17:01:00')

union all
select * from "metric-data" where
(start <= '2019-04-10 17:00:00' and finish > '2019-04-10 17:01:00')
;



explain analyze
select
  "name-id"
from "metric-data"
where
time >= '2019-04-10 17:00:00' and time < '2019-04-10 17:02:00'
and "scope-id" = 5483

group by "name-id";
