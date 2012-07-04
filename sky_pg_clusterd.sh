#!/bin/bash
# 本程序必须运行在standby节点. 主要用于failover.

# 配置, node1,node2 可能不一致
export PGHOME=/opt/pgsql
export LANG=en_US.utf8
export LD_LIBRARY_PATH=$PGHOME/lib:/lib64:/usr/lib64:/usr/local/lib64:/lib:/usr/lib:/usr/local/lib:$LD_LIBRARY_PATH
export DATE=`date +"%Y%m%d%H%M"`
export PATH=$PGHOME/bin:$PATH:.

# 配置, node1,node2 可能不一致, 并且需配置.pgpass存储以下密码校验信息
# NAGIOS_FILE1 被用于监控sky_pg_clusterd进程本身是否正常.
NAGIOS_FILE1="/tmp/nagios_sky_pg_clusterd_alivetime"
VIP_IF=eth0:1
CLUSTER_VIP=192.168.169.116
LOCAL_IP=127.0.0.1
PGUSER=sky_pg_cluster
PGPORT=1921
PGDBNAME=sky_pg_cluster
VOTE_IP=192.168.101.35
VOTE_PORT=11921
PRIMARY_CONTEXT=primary
STANDBY_CONTEXT=standby
SQL1="set client_min_messages=warning; update cluster_status set last_alive=now();"
SQL2="set client_min_messages=warning; select 'this_is_standby' as cluster_role from ( select pg_is_in_recovery() as std ) t where t.std is true;"
SQL3="set client_min_messages=warning; with t1 as (update cluster_status set last_alive = now() returning last_alive) select to_char(last_alive,'yyyymmddhh24miss') from t1;"
SQL4="set client_min_messages=warning; select to_char(last_alive,'yyyymmddhh24miss') from cluster_status;"
SQL5="set client_min_messages=warning; select 'standby_in_allowed_lag' as cluster_lag from cluster_status where now()-last_alive < interval '3 min';"

# 配置, node1,node2 不一致, 配置主库节点的fence设备地址和用户密码
FENCE_IP=192.168.179.213
FENCE_USER=skyuser
FENCE_PWD=csuN1crxg4As

# pg_failover函数, 用于异常时fence主库, 将standby激活, 启动VIP.
pg_failover() {
echo -e "`date +%F%T` pg_failover fired."
ipmitool -L OPERATOR -H $FENCE_IP -U $FENCE_USER -P $FENCE_PWD power reset
pg_ctl promote -D $PGDATA
if [ $? -eq 0 ]; then
  echo -e "`date +%F%T` promote standby success."
  sudo /sbin/ifup $VIP_IF
  if [ $? -eq 0 ]; then
    echo -e "`date +%F%T` vip upped success."
  else
    echo -e "`date +%F%T` vip upped failed."
  fi
else
  echo -e "`date +%F%T` promote standby failed."
fi
}


# 启动sky_pg_clusterd前的判断条件之一, 通过vip判断master的状态是否正常
echo $SQL1 | psql -h $CLUSTER_VIP -p $PGPORT -U $PGUSER -d $PGDBNAME -f -
if [ $? -ne 0 ]; then
  echo -e "master is not health, please check, exit abnormal."
  exit 1
fi

# 启动sky_pg_clusterd前的判断条件之一, 判断本机是否standby角色
CNT=`echo $SQL2 | psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - | grep -c this_is_standby`
if [ $CNT -ne 1 ]; then
  echo -e "this is not a standby database, exit abormal."
  # 生成第一个NAGIOS_FILE1
  echo "`date +%F%T` this is $PRIMARY_CONTEXT node. " > $NAGIOS_FILE1
  exit 1
fi

# 启动sky_pg_clusterd前的判断条件之一, 判断主库和standby的复制是否正常.
MASTER_TIME=`echo $SQL3 | psql -z -A -q -t -h $CLUSTER_VIP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - `
sleep 2
STANDBY_TIME=`echo $SQL4 | psql -z -A -q -t -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - `
if [ $MASTER_TIME != $STANDBY_TIME ]; then
  echo -e "standby: $STANDBY_TIME is laged far from master: $MASTER_TIME, exit abormal."
  exit 1
fi

# 生成第一个NAGIOS_FILE1
echo "`date +%F%T`  this is $STANDBY_CONTEXT node " > $NAGIOS_FILE1

# 进入循环检测, 每隔1秒检测一次.
for ((i=0;i<10;i=0))
do
  # 输出信息到状态文件, 用于给nagios检测sky_pg_clusterd是否存活. 通过Modify time和文件内容来判断. 这里可以改成其他状态报告方式, 如向其他pg数据库发送一个更新消息.
  echo "`date +%F%T` recheck. this is $STANDBY_CONTEXT node. " > $NAGIOS_FILE1
  STD_TO_MASTER_STATUS=0
  VOTEHOST_STATUS=0
  VOTE_TO_MASTER_STATUS=0
  for ((j=0;j<100;j++))
  do
    sleep 1
    # 从standby主机到master vip获取主节点数据库状态. 0正常.
    echo $SQL1 | psql -h $CLUSTER_VIP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - 
    STD_TO_MASTER_STATUS=$?
    # 如果从standby主机到master vip获取主节点数据库状态 结果正常, 后面两个判断就省略了.
    if [ $STD_TO_MASTER_STATUS -eq 0 ]; then
      break
    fi
    # 从standby主机到仲裁机获取主节点数据库状态. 0正常.
    echo $SQL1 | psql -h $VOTE_IP -p $VOTE_PORT -U $PGUSER -d $PGDBNAME -f - 
    VOTE_TO_MASTER_STATUS=$?
    # 确保standby机器到仲裁机的跳转端口网络正常. 0正常.
    (echo -e "q"|telnet -e "q" $VOTE_IP $VOTE_PORT) || VOTEHOST_STATUS=$?
    # 当满足1.standby认为master数据库不正常, 2.仲裁认为master数据库不正常, 3.standby到仲裁的跳转端口正常 时发生failover.
    if [ $STD_TO_MASTER_STATUS -ne 0 ] && [ $VOTE_TO_MASTER_STATUS -ne 0 ] && [ $VOTEHOST_STATUS -eq 0 ]; then
      echo -e "`date +%F%T` STD_TO_MASTER_STATUS is $STD_TO_MASTER_STATUS , master is not health count $j .\n"
      echo -e "`date +%F%T` VOTE_TO_MASTER_STATUS is $VOTE_TO_MASTER_STATUS , master is not health count $j .\n"
      echo -e "`date +%F%T` VOTEHOST_STATUS is $VOTEHOST_STATUS , master is not health count $j ."
      # 第一次发生异常时生成 lag和standby 是否正常的标记.
      if [ $j -eq 0 ]; then
        # standby是否正常的标记(is in recovery), CNT=1 表示正常.
        CNT=`echo $SQL2 | psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - | grep -c this_is_standby`
        # standby lag 在接受范围内的标记, LAG=1 表示正常.
        LAG=`echo $SQL5 | psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - | grep -c standby_in_allowed_lag`
      fi
      # 连续10次检测到不正常状态后, 触发failover.
      if [ $j -gt 10 ]; then
        # standby是否正常的标记(is in recovery), CNT=1 表示正常.
        # standby lag 在接受范围内的标记, LAG=1 表示正常.
        # 以上条件都正常则触发failover, 否则告知nagios, 并break
        if [ $CNT -eq 1 ] && [ $LAG -eq 1 ]; then
          pg_failover
          echo "`date +%F%T` failover fired. this is $PRIMARY_CONTEXT node now. " > $NAGIOS_FILE1
	  exit 0
        else
          echo -e "`date +%F%T` cluster must be failover, but condition is not allowed: standby is not in recovery or standby is laged too much. "
          break
        fi
      fi
    else
      break
    fi
  done
done


# thanks http://www.inlab.de/

# author : Digoal.zhou
# readme

# 判断是否要进入failover过程
# 1. master 数据库不正常 (通过update来判断)
# 2. standby 正常 (is in recovery)
# 3. standby lag 在接受范围内 (update的时间和当前时间的比较)
# 4. 如何 避免因 standby 自身问题导致的failover (例如standby与主库网络的故障), 
#    (加入VOTE_HOST, 1. 确保standby到VOTE_HOST(如网关或其他仲裁主机)的连通性, 2. standby通过VOTE_HOST去判断master的状态是否正常)
#    只有当standby和VOTE_HOST都认为master不正常时可以发生failover .

# failover过程
# 1. fence主服务器
# 2. 激活standby数据库
# 3. 起VIP
# 4. 结束sky_pg_clusterd进程, 通知 nagios 发生 failover(持续warning).

# nagios 根据/tmp/nagios_sky_pg_clusterd_alivetime 修改时间和内容(grep $PRIMARY_CONTEXT | $STANDBY_CONTEXT )监控 sky_pg_clusterd 进程存活.


