sky_postgresql_cluster
======================

sky_postgresql_cluster is a PostgreSQL HA module write in shell, HA via three host, include two postgresql 

(primary and stream replication standby) and one vote host. Applicatoin connect to sky_postgresql_cluster via a virtual 

ip address.

Requirement : 

1. three host

2. the two postgresql host must have fence device.

3. the two PostgreSQL host, one is master, another is standby. standby build with PostgreSQL's stream replication.

4. sky_postgresql_cluster's status monitor use nagios.


# Author : Digoal.zhou
# Email : digoal@126.com
# Blog : http://blog.163.com/digoal@126/
# 请使用另一个项目 https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip
