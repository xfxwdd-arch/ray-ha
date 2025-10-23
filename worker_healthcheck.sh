#!/bin/bash

# ===================================================
# Ray Worker 节点健康检查脚本
# ===================================================

# 配置
REDIS_HOST="${REDIS_HOST:-10.11.9.166}"
REDIS_PORT="${REDIS_PORT:-6257}"
app_env="${APPSPACE_ENV:-offline}"
LEADER_KEY="${app_env}:ray:leader"

# 容忍时间（秒）
RAY_STATUS_GRACE_PERIOD=60
RAY_STATUS_FAIL_FLAG="/tmp/ray_liveness_failed"

# ===================================================
# 核心函数
# ===================================================

# 检查 Ray 进程
check_ray_process() {
    pgrep -f "raylet" >/dev/null 2>&1
}

# 检查 Ray 服务状态
check_ray_status() {
    timeout 5 ray status >/dev/null 2>&1
}

# 检查 Plasma Store
check_plasma_store() {
    pgrep -f "plasma_store" >/dev/null 2>&1
}

# 检查是否有 Leader
check_leader_exists() {
    local leader=$(redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} GET ${LEADER_KEY} 2>/dev/null)
    [ -n "$leader" ] && [ "$leader" != "(nil)" ]
}

# ===================================================
# Liveness 检查
# ===================================================
liveness_check() {
    # Worker 存活检查：Ray 进程 + Plasma Store
    if ! check_ray_process; then
        echo "Worker Raylet process not running" >&2
        rm -f "$RAY_STATUS_FAIL_FLAG"
        return 1
    fi

    if ! check_plasma_store; then
        echo "Worker Plasma Store process not running" >&2
        rm -f "$RAY_STATUS_FAIL_FLAG"
        return 1
    fi

    # 检查 Ray 状态，带短暂容忍
    if ! check_ray_status; then
        echo "Worker Ray status abnormal possibly leader switching" >&2
        if [ ! -f "$RAY_STATUS_FAIL_FLAG" ]; then
            # 第一次失败，记录时间
            date +%s > "$RAY_STATUS_FAIL_FLAG"
            return 0
        else
            local start_time=$(cat "$RAY_STATUS_FAIL_FLAG" 2>/dev/null || echo 0)
            local now=$(date +%s)
            if (( now - start_time < RAY_STATUS_GRACE_PERIOD )); then
                # 容忍期内
                return 0
            else
                echo "Worker Ray status abnormal for >${RAY_STATUS_GRACE_PERIOD}s, unhealthy" >&2
                return 1
            fi
        fi
    else
        # 状态正常，清除异常记录
        rm -f "$RAY_STATUS_FAIL_FLAG"
    fi

    echo "Worker healthy" >&2
    return 0
}

# ===================================================
# Readiness 检查
# NOTE: 由于存活探针依赖Redis连接，而redis白名单通过bns来添加，因此就绪探针直接返回0即可
# ===================================================
readiness_check() {
    return 0
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
