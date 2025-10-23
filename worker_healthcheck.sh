#!/bin/bash

# ===================================================
# Ray Worker 节点健康检查脚本（精简版）
# ===================================================

# 配置
REDIS_HOST="${REDIS_HOST:-10.11.9.166}"
REDIS_PORT="${REDIS_PORT:-6257}"
app_env="${APPSPACE_ENV:-offline}"
LEADER_KEY="${app_env}:ray:leader"

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
        echo "✗ Worker: Raylet 进程未运行" >&2
        return 1
    fi
    
    if ! check_plasma_store; then
        echo "✗ Worker: Plasma Store 进程未运行" >&2
        return 1
    fi
    
    # 检查 Ray 状态（容忍 Leader 切换期间的短暂失败）
    if ! check_ray_status; then
        echo "⚠ Worker: Ray 状态异常（可能 Leader 切换中）" >&2
        # 不立即返回失败，给予容忍时间
        return 0
    fi
    
    echo "✓ Worker: 健康" >&2
    return 0
}

# ===================================================
# Readiness 检查
# ===================================================
readiness_check() {
    # Worker 就绪检查：Ray 进程 + Ray 状态正常 + 有 Leader
    if ! check_ray_process; then
        echo "✗ Worker: Raylet 进程未运行" >&2
        return 1
    fi
    
    if ! check_plasma_store; then
        echo "✗ Worker: Plasma Store 进程未运行" >&2
        return 1
    fi
    
    if ! check_ray_status; then
        echo "✗ Worker: Ray 集群连接异常" >&2
        return 1
    fi
    
    if ! check_leader_exists; then
        echo "⏳ Worker: 等待 Leader 选举" >&2
        return 1
    fi
    
    echo "✓ Worker: 就绪" >&2
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
