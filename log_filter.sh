#!/bin/bash
# Get the aliases and functions
if [ -f ~/.bashrc ]; then
        . ~/.bashrc
fi
# User specific environment and startup programs
PATH=$PATH:$HOME/bin
export PATH
unset USERNAME

# 以下必须与启动sky_pg_clusterd.sh时指定的日志文件一致.
SKY_PG_CLUSTERD_LOGFILE=/tmp/sky_pg_clusterd.log
SKY_PG_CLUSTERD_LOGFILE1=/tmp/sky_pg_clusterd.log.1

cat $SKY_PG_CLUSTERD_LOGFILE | grep -v "cluster_keepalive_test"|grep -v "SET"|grep -v "\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-"|grep -v "(1 row)"|grep -v "UPDATE 1"|grep -v "^ \$"|grep -v "^\$" >>$SKY_PG_CLUSTERD_LOGFILE1
echo "" >$SKY_PG_CLUSTERD_LOGFILE

# Author : Digoal zhou
# Email : digoal@126.com
# Blog : http://blog.163.com/digoal@126/
