#!/bin/bash                                                                                                                         
# 本程序必须运行在standby节点. 用于failover.                                                                                        
                                                                                                                                    
# 配置, node1,node2 可能不一致, psql, pg_ctl等命令必须包含在PATH中.                                                                 
export PGHOME=/opt/pgsql                                                                                                            
export LANG=en_US.utf8                                                                                                              
export LD_LIBRARY_PATH=$PGHOME/lib:/lib64:/usr/lib64:/usr/local/lib64:/lib:/usr/lib:/usr/local/lib:$LD_LIBRARY_PATH
export DATE=`date +"%Y%m%d%H%M"`                                                                                                    
export PATH=$PGHOME/bin:$PATH:.                                                                                                     
                                                                                                                                    
# 配置, node1,node2 可能不一致, 并且需配置.pgpass存储以下密码校验信息                                                               
# NAGIOS_FILE1 被nagios用于监控sky_pg_clusterd进程本身是否正常.                                                                     
NAGIOS_FILE1="/tmp/nagios_sky_pg_clusterd_alivetime"                                                                                
VIP_IF1=eth0:2
VIP_IF2=eth0:3
CLUSTER_VIP=192.168.xx.xx
LOCAL_IP=127.0.0.1
PGUSER=sky_pg_cluster
PGPORT=1921
PGDBNAME=sky_pg_cluster
VOTE_IP=192.168.xx.xx
VOTE_PORT=xxxx
PRIMARY_CONTEXT=primary
STANDBY_CONTEXT=standby
SQL1="select cluster_keepalive_test();"
SQL2="set client_min_messages=warning; select 'this_is_standby' as cluster_role from ( select pg_is_in_recovery() as std ) t where t.std is true;"
SQL3="set client_min_messages=warning; update cluster_status set last_alive = now() returning to_char(last_alive,'yyyymmddhh24miss');"
SQL4="set client_min_messages=warning; select to_char(last_alive,'yyyymmddhh24miss') from cluster_status;"
SQL5="set client_min_messages=warning; select 'standby_in_allowed_lag' as cluster_lag from cluster_status where now()-last_alive < interval '3 min';"

# 配置, node1,node2 不一致, 配置当前主库(对方)节点的fence设备地址和用户密码
FENCE_IP=192.168.xx.xx
FENCE_USER=xxx
FENCE_PWD=xxx

# 9.0 使用触发器文件
# TRIG_FILE='/data01/pgdata/pg_root/.1921.trigger'

# pg_failover函数, 用于异常时fence主库, 将standby激活, 启动VIP.
pg_failover() {
FENCE_STATUS=1
PROMOTE_STATUS=1
echo -e "`date +%F%T` pg_failover fired."
# 1. fence primary host
echo -e "`date +%F%T` fence primary host fired."
for ((k=0;k<60;k++))
do
  # fence命令, 设备不同的话, fence命令可能不一样.
  # /usr/bin/ipmitool -L OPERATOR -H $FENCE_IP -U $FENCE_USER -P $FENCE_PWD power reset
  # 不要使用绝对路径, 路径在不同的linux版本中可能不一样.
  fence_ilo -a $FENCE_IP -l $FENCE_USER -p $FENCE_PWD -o reboot
  if [ $? -eq 0 ]; then
    echo -e "`date +%F%T` fence primary db host success."
    FENCE_STATUS=0
    break
  fi
  sleep 1
done
if [ $FENCE_STATUS -ne 0 ]; then
  echo -e "`date +%F%T` fence failed. Standby will not promote, please fix it manual."
  return $FENCE_STATUS
fi
# 2. 激活standby
echo -e "`date +%F%T` promote standby fired."
for ((l=0;l<60;l++))
do
  # 9.0 使用触发文件激活
  # touch $TRIG_FILE
  pg_ctl promote -D $PGDATA
  if [ $? -eq 0 ]; then
    echo -e "`date +%F%T` promote standby success."
    PROMOTE_STATUS=0
    break
  fi
  sleep 1
done
if [ $PROMOTE_STATUS -ne 0 ]; then
  echo -e "`date +%F%T` promote standby failed."
  return $PROMOTE_STATUS
fi
# 3. 起vip接口, 需要配置/etc/sudoers, 注释Defaults    requiretty
# vip1
IFUP_STATUS=1
echo -e "`date +%F%T` ifup vip1 fired."
for ((m=0;m<60;m++))
do
  sudo /sbin/ifup $VIP_IF1
  if [ $? -eq 0 ]; then
    echo -e "`date +%F%T` vip1 upped success."
    IFUP_STATUS=0
    break
  fi
  sleep 1
done
if [ $IFUP_STATUS -ne 0 ]; then
  echo -e "`date +%F%T` standby host ifup vip1 failed."
  return $IFUP_STATUS
fi

# vip2
IFUP_STATUS=1
echo -e "`date +%F%T` ifup vip2 fired."
for ((m=0;m<60;m++))
do
  sudo /sbin/ifup $VIP_IF2
  if [ $? -eq 0 ]; then
    echo -e "`date +%F%T` vip2 upped success."
    IFUP_STATUS=0
    break
  fi
  sleep 1
done
if [ $IFUP_STATUS -ne 0 ]; then
  echo -e "`date +%F%T` standby host ifup vip2 failed."
  return $IFUP_STATUS
fi

echo -e "`date +%F%T` pg_failover() function call success."
return 0
}


# 启动sky_pg_clusterd前的判断条件之一, 通过vip判断master的状态是否正常
psql -h $CLUSTER_VIP -p $PGPORT -U $PGUSER -d $PGDBNAME -c "$SQL1"
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
# 间隔5秒后查询前面这条SQL的更新在standby上是否已经恢复, 从而判断standby是否正常, 延时是否在接受范围内.
sleep 5
STANDBY_TIME=`echo $SQL4 | psql -z -A -q -t -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - `
if [ $MASTER_TIME != $STANDBY_TIME ]; then
  echo -e "standby: $STANDBY_TIME is laged far from master: $MASTER_TIME, exit abormal."
  exit 1
fi

# 生成第一个NAGIOS_FILE1
echo "`date +%F%T`  this is $STANDBY_CONTEXT node " > $NAGIOS_FILE1

# 进入循环检测, sleep 2, 每隔2秒检测一次.
for ((i=0;i<10;i=0))
do
  # 输出信息到状态文件, 用于给nagios检测sky_pg_clusterd是否存活. 通过Modify time和文件内容来判断. 这里也可以改成其他状态报告方式, 如向其他pg数据库发送一个更新消息.
  echo "`date +%F%T` sky_pg_cluster daemon process keepalive check. this is $STANDBY_CONTEXT node. " > $NAGIOS_FILE1
  STD_TO_MASTER_STATUS=0
  VOTEHOST_STATUS=0
  VOTE_TO_MASTER_STATUS=0
  for ((j=0;j<100;j++))
  do
    sleep 2
    # 从standby主机到master vip获取主节点数据库状态. 0正常.
    psql -h $CLUSTER_VIP -p $PGPORT -U $PGUSER -d $PGDBNAME -c "$SQL1"
    STD_TO_MASTER_STATUS=$?
    # 如果从standby主机到master vip获取主节点数据库状态, 0正常. 如果结果正常, 后面两个判断就省略了.
    if [ $STD_TO_MASTER_STATUS -eq 0 ]; then
      break
    fi
    # 判断从standby机器到仲裁机的跳转端口网络是否正常. 0正常. 如果结果不正常, 后面判断就省略了.
    /usr/local/bin/port_probe $VOTE_IP $VOTE_PORT
    VOTEHOST_STATUS=$?
    if [ $VOTEHOST_STATUS -ne 0 ]; then
      break
      echo -e "`date +%F%T` It looks like a standby's network problem, standby host cann't connect to primary and vote host."
    fi
    # 从standby主机到仲裁机获取主节点数据库状态. 0正常.
    psql -h $VOTE_IP -p $VOTE_PORT -U $PGUSER -d $PGDBNAME -c "$SQL1"
    VOTE_TO_MASTER_STATUS=$?
    # 当满足 1.standby认为master数据库不正常, 2.仲裁认为master数据库不正常, 3.standby到仲裁的跳转端口正常 时发生failover.
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
      if [ $j -ge 9 ]; then
        # 判断 standby是否正常的标记(is in recovery), CNT=1 表示正常.
        # 判断 standby lag 在接受范围内的标记, LAG=1 表示正常.
        # 以上条件都满足则触发failover, 否则告知nagios, 并break跳出循环
        if [ $CNT -eq 1 ] && [ $LAG -eq 1 ]; then
          pg_failover
          if [ $? -ne 0 ]; then
            echo -e "`date +%F%T` pg_failover failed." > $NAGIOS_FILE1
            exit 1
          else
            echo "`date +%F%T` failover fired. this is $PRIMARY_CONTEXT node now. " > $NAGIOS_FILE1
            exit 0
          fi
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

# nagios 根据/tmp/nagios_sky_pg_clusterd_alivetime 修改时间监控 sky_pg_clusterd 进程存活, 内容(grep $PRIMARY_CONTEXT | $STANDBY_CONTEXT)判断角色.

# fence 命令 : 
# /usr/bin/ipmitool -L OPERATOR -H $FENCE_IP -U $FENCE_USER -P $FENCE_PWD power reset
# /sbin/fence_rsa -a $FENCE_IP -l $FENCE_USER -p $FENCE_PWD -o reboot
# /sbin/fence_ilo -a $FENCE_IP -l $FENCE_USER -p $FENCE_PWD -o reboo

# Thanks http://www.inlab.de/

# Author : Digoal zhou
# Email : digoal@126.com
# Blog : http://blog.163.com/digoal@126/
