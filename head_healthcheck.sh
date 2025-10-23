#!/bin/bash

# ===================================================
# Ray Head 节点健康检查
# ===================================================

# 配置
REDIS_HOST="${REDIS_HOST:-10.11.9.166}"
REDIS_PORT="${REDIS_PORT:-6257}"
app_env="${APPSPACE_ENV:-offline}"
LEADER_KEY="${app_env}:ray:leader"
DASHBOARD_PORT="${DASHBOARD_PORT:-8265}"
GCS_PORT="${GCS_PORT:-8009}"
POD_IP="${POD_IP:-$(hostname -i | awk '{print $1}')}"
MAX_GCS_RECOVERY_TIME=60  # GCS 恢复允许的最大时间（秒）

# ===================================================
# 核心函数
# ===================================================

# 获取当前节点角色
get_node_role() {
    local current_leader=$(redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} GET ${LEADER_KEY} 2>/dev/null)
    local my_address="$POD_IP:$GCS_PORT"
    
    if [ -z "$current_leader" ] || [ "$current_leader" = "(nil)" ]; then
        echo "ELECTING"
        return 2
    elif [ "$current_leader" = "$my_address" ]; then
        echo "LEADER"
        return 0
    else
        echo "STANDBY"
        return 1
    fi
}

# 检查 Redis 连接
check_redis() {
    timeout 5 redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} ping >/dev/null 2>&1
}

# 检查 GCS 服务（Leader 专用）
check_gcs() {
    # 方法1: Dashboard API
    if timeout 5 curl -sf "http://localhost:${DASHBOARD_PORT}/api/cluster_status" >/dev/null 2>&1; then
        return 0
    fi
    
    # 方法2: GCS 端口
    timeout 3 nc -z localhost ${GCS_PORT} 2>/dev/null
}

# 检查 Ray 进程（Leader 专用）
check_ray_process() {
    pgrep -f "gcs_server" >/dev/null 2>&1 && pgrep -f "raylet" >/dev/null 2>&1
}

# 检查 GCS 是否在恢复中（Leader 专用）
check_gcs_recovery() {
    local gcs_start_file="/tmp/ray_gcs_start_time"
    local current_time=$(date +%s)
    
    if [ -f "$gcs_start_file" ]; then
        local gcs_start_time=$(cat "$gcs_start_file")
        local elapsed=$((current_time - gcs_start_time))
        
        if [ $elapsed -lt $MAX_GCS_RECOVERY_TIME ]; then
            echo "⏳ GCS 恢复中 (${elapsed}s/${MAX_GCS_RECOVERY_TIME}s)" >&2
            return 0
        else
            echo "✗ GCS 恢复超时" >&2
            return 1
        fi
    else
        echo "$current_time" > "$gcs_start_file"
        echo "⏳ GCS 启动中" >&2
        return 0
    fi
}

# 清除恢复标记（Leader 专用）
clear_recovery_marker() {
    rm -f /tmp/ray_gcs_start_time
}

# ===================================================
# Liveness 检查
# ===================================================
liveness_check() {
    local role=$(get_node_role)
    
    case "$role" in
        LEADER)
            # Leader 必须检查: Redis + Leader 身份 + GCS 服务
            if ! check_redis; then
                echo "✗ Leader: Redis 连接失败" >&2
                return 1
            fi
            
            # 再次确认 Leader 身份
            local current_leader=$(redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} GET ${LEADER_KEY} 2>/dev/null)
            if [ "$current_leader" != "$POD_IP:$GCS_PORT" ]; then
                echo "✗ Leader: 已失去 Leader 身份" >&2
                return 1
            fi
            
            # 检查 Ray 进程
            if ! check_ray_process; then
                if ! check_gcs_recovery; then
                    echo "✗ Leader: Ray 进程异常且恢复超时" >&2
                    return 1
                fi
                return 0  # 恢复中，暂不标记失败
            fi
            
            # 检查 GCS 服务
            if ! check_gcs; then
                if ! check_gcs_recovery; then
                    echo "✗ Leader: GCS 服务不可用且恢复超时" >&2
                    return 1
                fi
                return 0  # 恢复中，暂不标记失败
            fi
            
            # GCS 正常，清除恢复标记
            clear_recovery_marker
            echo "✓ Leader: 健康" >&2
            return 0
            ;;
            
        STANDBY)
            # Standby 只需检查: Redis 连接 + 确认不持有 Leader 锁
            if ! check_redis; then
                echo "✗ Standby: Redis 连接失败" >&2
                return 1
            fi
            
            # 如果持有 Leader 锁但 Ray 没运行，说明异常
            local current_leader=$(redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} GET ${LEADER_KEY} 2>/dev/null)
            if [ "$current_leader" = "$POD_IP:$GCS_PORT" ]; then
                if ! check_ray_process; then
                    echo "✗ Standby: 持有 Leader 锁但 Ray 未运行" >&2
                    return 1
                fi
            fi
            
            echo "✓ Standby: 健康" >&2
            return 0
            ;;
            
        ELECTING)
            # 选举中只需 Redis 连接正常
            if check_redis; then
                echo "⏳ 选举中: 等待 Leader 选举" >&2
                return 0
            else
                echo "✗ 选举中: Redis 连接失败" >&2
                return 1
            fi
            ;;
            
        *)
            echo "✗ 无法确定节点角色" >&2
            return 1
            ;;
    esac
}

# ===================================================
# Readiness 检查
# ===================================================
readiness_check() {
    local role=$(get_node_role)
    
    case "$role" in
        LEADER)
            # Leader 就绪需要: Redis + Leader 身份 + Ray 进程 + GCS 服务
            check_redis || return 1
            
            local current_leader=$(redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} GET ${LEADER_KEY} 2>/dev/null)
            [ "$current_leader" = "$POD_IP:$GCS_PORT" ] || return 1
            
            check_ray_process || return 1
            check_gcs || return 1
            
            echo "✓ Leader: 就绪" >&2
            return 0
            ;;
            
        STANDBY)
            # Standby 就绪需要: Redis 连接 + 确认 Standby 身份
            check_redis || return 1
            
            local current_leader=$(redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} GET ${LEADER_KEY} 2>/dev/null)
            if [ "$current_leader" = "$POD_IP:$GCS_PORT" ]; then
                echo "⚠ Standby: 持有 Leader 锁（可能正在切主）" >&2
                return 1
            fi
            
            echo "✓ Standby: 就绪" >&2
            return 0
            ;;
            
        ELECTING)
            # 选举中标记为未就绪
            echo "⏳ 选举中: 未就绪" >&2
            return 1
            ;;
            
        *)
            echo "✗ 无法确定节点角色" >&2
            return 1
            ;;
    esac
}

# ===================================================
# 主函数
# ===================================================
main() {
    case "${1:-liveness}" in
        liveness|live|l)
            liveness_check
            ;;
        readiness|ready|r)
            readiness_check
            ;;
        *)
            echo "Usage: $0 {liveness|readiness}" >&2
            exit 1
            ;;
    esac
}

main "$@"
