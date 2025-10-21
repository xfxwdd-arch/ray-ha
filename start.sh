#!/bin/bash

# === 配置变量 ===
# 其中，redis的ipport为负载均衡VIP, 将流量转发到group.bdrp-image-shixiao-proxy.redis.all
app_env="${APPSPACE_ENV:-offline}"
REDIS_HOST="${REDIS_HOST:-10.11.9.166}"
REDIS_PORT="${REDIS_PORT:-6257}"

# Ray配置
# 其中RAY_OBJECT_STORE_MEMORY设置为总内存的30%
DASHBOARD_PORT="${DASHBOARD_PORT:-8265}"
GCS_PORT="${GCS_PORT:-8009}"
RAY_OBJECT_STORE_MEMORY=$(( ${MATRIX_RESOURCE_MEMORY_SIZE:-0} > 0 ? MATRIX_RESOURCE_MEMORY_SIZE * 1024 * 1024 * 3 / 10 : 104857600 ))

# HA配置
LEADER_KEY="${app_env}:ray:leader"
LEADER_TTL=30
CHECK_INTERVAL=10
CONNECTION_TIMEOUT=10

# HTTP健康检查接口配置
HEALTH_CHECK_PORT="${APPSPACE_MAIN_PORT:-8080}"

# 节点信息
POD_NAME="${HOSTNAME:-$(hostname)}"
POD_IP="${POD_IP:-$(hostname -i | awk '{print $1}')}"
NODE_ROLE=""  # 从命令行参数获取

# === 公共函数 ===
log_msg() {
    local level=$1
    local msg=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] [$NODE_ROLE:$POD_NAME] $msg" >&2
}

# Redis 命令函数
redis_cmd() {
    redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} "$@"
}

# 等待 Redis 可用
wait_for_redis() {
    log_msg "INFO" "Wait for Redis cluster available..."
    local retries=0
    local max_retries=30

    while [ $retries -lt $max_retries ]; do
        if redis_cmd ping >/dev/null 2>&1; then
            log_msg "INFO" "Redis cluster connect succ"
            return 0
        fi
        retries=$((retries + 1))
        sleep 2
    done

    log_msg "ERROR" "Redis connection timeout after $((max_retries * 2)) seconds"
    exit 1
}

# === HTTP健康检查服务 ===
start_health_check_server() {
    log_msg "INFO" "Starting health check server on port $HEALTH_CHECK_PORT"

    # 创建临时目录用于存放脚本
    local temp_dir=$(mktemp -d)
    local server_script="$temp_dir/health_server.py"

    # 生成Python HTTP服务器脚本
    cat > "$server_script" << 'EOF'
#!/usr/bin/env python3
import json
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading
import os

class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # 禁用默认日志

    def do_GET(self):
        if self.path == '/health':
            self.handle_health()
        elif self.path == '/leader':
            self.handle_leader()
        elif self.path == '/status':
            self.handle_status()
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')

    def handle_health(self):
        """基础健康检查"""
        try:
            response = {
                'status': 'healthy',
                'pod_name': os.environ.get('POD_NAME', 'unknown'),
                'pod_ip': os.environ.get('POD_IP', 'unknown'),
                'role': os.environ.get('NODE_ROLE', 'unknown'),
                'timestamp': subprocess.check_output(['date', '+%Y-%m-%d %H:%M:%S']).decode().strip()
            }
            self.send_json_response(200, response)
        except Exception as e:
            self.send_json_response(500, {'error': str(e)})

    def handle_leader(self):
        """获取当前leader信息"""
        try:
            # 获取当前leader
            result = subprocess.run([
                'redis-cli', '-h', os.environ.get('REDIS_HOST', '10.11.9.166'),
                '-p', os.environ.get('REDIS_PORT', '6257'),
                'GET', os.environ.get('LEADER_KEY', 'offline:ray:leader')
            ], capture_output=True, text=True, timeout=5)

            current_leader = result.stdout.strip() if result.returncode == 0 else None

            # 检查自己是否是leader
            my_address = f"{os.environ.get('POD_IP', 'unknown')}:{os.environ.get('GCS_PORT', '8009')}"
            is_leader = current_leader == my_address

            # 检查Ray状态
            ray_status = 'unknown'
            try:
                ray_result = subprocess.run(['ray', 'status'], capture_output=True, timeout=3)
                ray_status = 'active' if ray_result.returncode == 0 else 'inactive'
            except:
                ray_status = 'inactive'

            response = {
                'current_leader': current_leader,
                'is_leader': is_leader,
                'my_address': my_address,
                'ray_status': ray_status,
                'pod_name': os.environ.get('POD_NAME', 'unknown'),
                'timestamp': subprocess.check_output(['date', '+%Y-%m-%d %H:%M:%S']).decode().strip()
            }
            self.send_json_response(200, response)
        except Exception as e:
            self.send_json_response(500, {'error': str(e)})

    def handle_status(self):
        """详细状态信息"""
        try:
            # 获取Ray详细状态
            ray_info = {}
            try:
                ray_result = subprocess.run(['ray', 'status'], capture_output=True, text=True, timeout=5)
                ray_info = {
                    'status': 'active' if ray_result.returncode == 0 else 'inactive',
                    'output': ray_result.stdout if ray_result.returncode == 0 else ray_result.stderr
                }
            except Exception as e:
                ray_info = {'status': 'error', 'error': str(e)}

            # 获取leader信息
            leader_info = {}
            try:
                result = subprocess.run([
                    'redis-cli', '-h', os.environ.get('REDIS_HOST', '10.11.9.166'),
                    '-p', os.environ.get('REDIS_PORT', '6257'),
                    'GET', os.environ.get('LEADER_KEY', 'offline:ray:leader')
                ], capture_output=True, text=True, timeout=5)
                leader_info['current_leader'] = result.stdout.strip() if result.returncode == 0 else None

                # 获取TTL
                ttl_result = subprocess.run([
                    'redis-cli', '-h', os.environ.get('REDIS_HOST', '10.11.9.166'),
                    '-p', os.environ.get('REDIS_PORT', '6257'),
                    'TTL', os.environ.get('LEADER_KEY', 'offline:ray:leader')
                ], capture_output=True, text=True, timeout=5)
                leader_info['ttl'] = int(ttl_result.stdout.strip()) if ttl_result.returncode == 0 else -1
            except Exception as e:
                leader_info['error'] = str(e)

            response = {
                'pod_info': {
                    'name': os.environ.get('POD_NAME', 'unknown'),
                    'ip': os.environ.get('POD_IP', 'unknown'),
                    'role': os.environ.get('NODE_ROLE', 'unknown'),
                    'gcs_port': os.environ.get('GCS_PORT', '8009'),
                    'dashboard_port': os.environ.get('DASHBOARD_PORT', '8265')
                },
                'ray_info': ray_info,
                'leader_info': leader_info,
                'timestamp': subprocess.check_output(['date', '+%Y-%m-%d %H:%M:%S']).decode().strip()
            }
            self.send_json_response(200, response)
        except Exception as e:
            self.send_json_response(500, {'error': str(e)})

    def send_json_response(self, status_code, data):
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

def run_server():
    port = int(os.environ.get('HEALTH_CHECK_PORT', '8080'))
    server = HTTPServer(('0.0.0.0', port), HealthHandler)
    server.serve_forever()

if __name__ == '__main__':
    run_server()
EOF

    # 设置环境变量并启动服务器
    export POD_NAME NODE_ROLE POD_IP GCS_PORT DASHBOARD_PORT REDIS_HOST REDIS_PORT LEADER_KEY HEALTH_CHECK_PORT
    python3 "$server_script" &
    local server_pid=$!

    # 等待服务器启动
    sleep 2
    if kill -0 $server_pid 2>/dev/null; then
        log_msg "INFO" "Health check server started successfully (PID: $server_pid)"
        echo $server_pid > /tmp/health_server.pid
    else
        log_msg "ERROR" "Failed to start health check server"
    fi
}

stop_health_check_server() {
    if [ -f /tmp/health_server.pid ]; then
        local pid=$(cat /tmp/health_server.pid)
        if kill -0 $pid 2>/dev/null; then
            log_msg "INFO" "Stopping health check server (PID: $pid)"
            kill $pid 2>/dev/null || true
            rm -f /tmp/health_server.pid
        fi
    fi
}

# === Leader节点函数 ===
try_acquire_leadership() {
    if redis_cmd SET "$LEADER_KEY" "$POD_IP:$GCS_PORT" NX EX $LEADER_TTL | grep -q "OK"; then
        return 0
    fi
    return 1
}

# 续约Leader锁  
renew_leadership() {
    local script='if redis.call("GET", KEYS[1]) == ARGV[1] then redis.call("EXPIRE", KEYS[1], ARGV[2]) return 1 else return 0 end'
    [ "$(redis_cmd EVAL "$script" 1 "$LEADER_KEY" "$POD_IP:$GCS_PORT" $LEADER_TTL)" = "1" ]
}

# 启动Ray Head
# enable-object-reconstruction: 用于对象级别的容错, 启用对象血缘跟踪, 支持对象重建, 提高容错能力
# num-cpus=0: head节点不分配任务，只做调度
start_ray_head() {
    log_msg "INFO" "Start Ray Head: ${POD_NAME}"
    if ray start --head \
        --port=$GCS_PORT \
        --dashboard-host=0.0.0.0 \
        --dashboard-port=$DASHBOARD_PORT \
        --include-dashboard=true \
        --object-store-memory=$RAY_OBJECT_STORE_MEMORY \
        --num-cpus=0 ; then
        
        if ray status >/dev/null 2>&1; then
            log_msg "INFO" "Ray Head start success"
            return 0
        fi
    fi
    log_msg "ERROR" "Ray Head start fail"
    return 1
}

# 停止Ray Head
stop_ray_head() {
    log_msg "INFO" "Stop Ray Head: ${POD_NAME}"
    ray stop --force 2>/dev/null || true
}

# Leader选举和维护
run_head_node() {
    log_msg "INFO" "Begin Ray Head HA controller: ${POD_NAME}"

        # 启动健康检查服务器
    start_health_check_server

    while true; do
        if try_acquire_leadership; then
            log_msg "INFO" "Acquired Leadership ${POD_NAME}"

            # 启动Ray Head
            if start_ray_head; then
                # 维护Leader状态
                while renew_leadership && ray status >/dev/null 2>&1; do
                    log_msg "INFO" "Leadership renew succ: ${POD_NAME}"
                    sleep $CHECK_INTERVAL
                done
            fi

                        # 启动失败，或者续约失败，或者状态异常，释放自己的锁
                        log_msg "WARNING" "Lose Leadership，stop Ray Head: ${POD_NAME}"
                        local script='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end'
                        redis_cmd EVAL "$script" 1 "$LEADER_KEY" "$POD_IP:$GCS_PORT" 2>/dev/null || true

                        # 这里强制stop一下, 避免变成standby模式后，又启动成功了, 导致出现多个head运行
                        stop_ray_head
        else
            # Standby模式
            current_leader=$(redis_cmd GET "$LEADER_KEY" 2>/dev/null || echo "none")
            log_msg "INFO" "Standby mod, current Leader: ${current_leader}"
        fi
        sleep $CHECK_INTERVAL
    done
}

# === Worker节点函数 ===
get_current_leader() {
    redis_cmd GET "$LEADER_KEY" 2>/dev/null || echo ""
}

connect_to_ray() {
    local head_address=$1
    log_msg "INFO" "Connect to Ray Head: $head_address"
    
    # 停止现有连接
    ray stop 2>/dev/null || true
    sleep 2
    
    # 尝试连接
    local retries=0
    while [ $retries -lt 5 ]; do
        if timeout $CONNECTION_TIMEOUT ray start \
            --address="$head_address" \
            --object-store-memory=$RAY_OBJECT_STORE_MEMORY ; then
            
            if ray status >/dev/null 2>&1; then
                log_msg "INFO" "Connect to Ray Head success"
                return 0
            fi
        fi
        
        retries=$((retries + 1))
        log_msg "WARNING" "Connect to Ray Head fail retry $retries/5"
        sleep 3
    done
    
    log_msg "ERROR" "Connect to Ray Head: $head_address finally fail after 5 retries"
    return 1
}

# worker循环
run_worker_node() {
    local current_head=""
    local connected=false

    while true; do
        local leader=$(get_current_leader)

        if [ -n "$leader" ]; then
            # 检查是否需要连接/重连
            if [ "$leader" != "$current_head" ] || [ "$connected" = "false" ] || ! ray status >/dev/null 2>&1; then
                [ "$leader" != "$current_head" ] && log_msg "INFO" "Detect new Ray Head Leader: $leader"
                [ "$connected" = "true" ] && log_msg "WARNING" "Ray status abnormal, try to reconnect"

                if connect_to_ray "$leader"; then
                    current_head="$leader"
                    connected=true
                else
                    connected=false
                fi
            fi
        else
            # 没有领导者，断开连接
            if [ "$connected" = "true" ]; then
                log_msg "WARNING" "No Leader, stop connection"
                ray stop 2>/dev/null || true
                connected=false
                current_head=""
            fi
        fi

        sleep $CHECK_INTERVAL
    done
}

# === 清理函数 ===
cleanup() {
    log_msg "INFO" "Received shutdown signal, cleaning up: ${POD_NAME}"
    if [ "$NODE_ROLE" = "head" ]; then
        log_msg "INFO" "Releasing leadership and stopping Ray Head"
        local script='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end'
        redis_cmd EVAL "$script" 1 "$LEADER_KEY" "$POD_IP:$GCS_PORT" >/dev/null 2>&1 || true
        stop_ray_head
                stop_health_check_server
    else
        log_msg "INFO" "Stopping Ray worker"
        ray stop 2>/dev/null || true
    fi
    log_msg "INFO" "Cleanup completed"
    exit 0
}

# === 主程序 ===
main() {
    # 检查参数
    if [ $# -eq 0 ] || [ -z "$1" ]; then
        echo "Usage: $0 <head|worker>" >&2
        echo "  head   - Run as Ray head node" >&2
        echo "  worker - Run as Ray worker node" >&2
        exit 1
    fi

    NODE_ROLE="$1"
    case "$NODE_ROLE" in
        "head"|"worker")
            ;;
        *)
            echo "Error: Invalid role '$NODE_ROLE'. Must be 'head' or 'worker'" >&2
            exit 1
            ;;
    esac

    log_msg "INFO" "Start Ray HA cluster, role: $NODE_ROLE"
    log_msg "INFO" "env: $app_env, pod: $POD_NAME ($POD_IP)"
    log_msg "INFO" "Using leader key: $LEADER_KEY"
    
    wait_for_redis

    # 注册信号处理
    trap cleanup TERM INT
    
    case "$NODE_ROLE" in
        "head")
            run_head_node
            ;;
        "worker")
            run_worker_node
            ;;
        *)
            log_msg "ERROR" "Uknown role: $NODE_ROLE"
            exit 1
            ;;
    esac
}

main "$@"
