-- 新建pg_stat_statements模块
\c postgres postgres
create extension pg_stat_statements;
-- 新建流复制角色用户
create role replica nosuperuser nocreatedb nocreaterole noinherit replication connection limit 32 login encrypted password 'REPLICA321';

-- 新建集群角色
create role sky_pg_cluster nosuperuser nocreatedb nocreaterole noinherit login encrypted password 'SKY_PG_cluster_321';
create database sky_pg_cluster with template template0 encoding 'UTF8' owner sky_pg_cluster;
\c sky_pg_cluster sky_pg_cluster
create schema sky_pg_cluster authorization sky_pg_cluster;
create table cluster_status (id int unique default 1, last_alive timestamp(0) without time zone);
-- 限制cluster_status表有且只有一行 : 
CREATE FUNCTION cannt_delete ()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
   RAISE EXCEPTION 'You can not delete!';
END; $$;

CREATE TRIGGER cannt_delete
BEFORE DELETE ON cluster_status
FOR EACH ROW EXECUTE PROCEDURE cannt_delete();

CREATE TRIGGER cannt_truncate
BEFORE TRUNCATE ON cluster_status
FOR STATEMENT EXECUTE PROCEDURE cannt_delete();

-- 插入初始数据
insert into cluster_status values (1, now());