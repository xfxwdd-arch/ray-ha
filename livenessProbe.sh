#!/bin/bash
app_env="${APPSPACE_ENV:-offline}"

REDIS_HOST="10.11.9.166"
REDIS_PORT="6257" 

LEADER_KEY="${app_env}:ray:leader"
DASHBOARD_PORT="8265"

POD_IP="${POD_IP:-$(hostname -i | awk '{print $1}')}"
GCS_PORT="${GCS_PORT:-8009}"

# 等待Leader选举完成
LEADER=$(redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} GET ${LEADER_KEY} 2>/dev/null)
if [ -z "$LEADER" ] || [ "$LEADER" = "(nil)" ]; then
    # Leader选举还未完成
    exit 1
fi

if [ "$LEADER" = "$POD_IP:$GCS_PORT" ]; then
    # 是Leader, 检查Ray服务
    curl -f http://localhost:${DASHBOARD_PORT}/api/cluster_status 2>/dev/null && exit 0
    exit 1
else
    # 是Standby, 返回0即可
    exit 0 
fi
