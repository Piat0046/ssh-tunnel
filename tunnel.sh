#!/bin/bash

# ============================================
# SSH 리버스 터널링 통합 관리 스크립트
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
TUNNEL_SCRIPT="$SCRIPT_DIR/.tunnel-service.sh"
MONITOR_SCRIPT="$SCRIPT_DIR/.ssh-monitor.sh"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "${BLUE}$1${NC}"; }

# ============================================
# 설정 로드
# ============================================
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "설정 파일을 찾을 수 없습니다: $CONFIG_FILE"
        log_info "config.env 파일을 먼저 설정해주세요."
        exit 1
    fi
    source "$CONFIG_FILE"
}

validate_config() {
    local missing=()
    [ -z "$PUBLIC_HOST" ] && missing+=("PUBLIC_HOST")
    [ -z "$PUBLIC_USER" ] && missing+=("PUBLIC_USER")
    [ -z "$PUBLIC_PORT" ] && missing+=("PUBLIC_PORT")
    [ -z "$REMOTE_PORT" ] && missing+=("REMOTE_PORT")
    [ -z "$LOCAL_PORT" ] && missing+=("LOCAL_PORT")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "필수 설정이 누락되었습니다: ${missing[*]}"
        exit 1
    fi
}

# ============================================
# 설치 관련
# ============================================
check_autossh() {
    if ! command -v autossh &> /dev/null; then
        log_info "autossh 설치 중..."
        if command -v brew &> /dev/null; then
            brew install autossh
        else
            log_error "Homebrew가 설치되어 있지 않습니다. autossh를 수동으로 설치해주세요."
            exit 1
        fi
    else
        log_info "autossh 확인됨"
    fi
}

create_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$HOME/Library/LaunchAgents"
}

create_tunnel_script() {
    cat > "$TUNNEL_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

LOG_FILE_PATH="${LOG_DIR}/${LOG_FILE}"

log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}" >> "$LOG_FILE_PATH"
}

log_debug() { log "DEBUG" "$1"; }
log_info()  { log "INFO " "$1"; }
log_warn()  { log "WARN " "$1"; }
log_error() { log "ERROR" "$1"; }

add_timestamp() {
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "error|failed|refused|unreachable|denied|broken"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $line"
        elif echo "$line" | grep -qiE "warning|timeout|timed out"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN ] $line"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $line"
        fi
    done
}

mkdir -p "$LOG_DIR"
log_info "터널 서비스 시작 (foreground 모드)"

# SSH 인증 옵션 설정
SSH_AUTH_OPT=""
case "${SSH_AUTH:-key}" in
    key)
        if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
            SSH_AUTH_OPT="-i ${SSH_KEY}"
            log_debug "인증 방식: SSH 키 (${SSH_KEY})"
        else
            log_warn "SSH 키 파일을 찾을 수 없습니다: ${SSH_KEY}"
        fi
        ;;
    password)
        # 비밀번호 인증은 SSH가 자동으로 프롬프트를 표시
        # BatchMode=no로 인터랙티브 모드 허용
        SSH_AUTH_OPT="-o BatchMode=no -o PreferredAuthentications=password"
        log_debug "인증 방식: 비밀번호"
        log_warn "비밀번호 인증은 자동 재연결이 제한됩니다"
        ;;
    none|*)
        SSH_AUTH_OPT=""
        log_debug "인증 방식: 기본 (시스템 설정 사용)"
        ;;
esac

RETRY_COUNT=0

while true; do
    if [ $RETRY_COUNT -eq 0 ]; then
        log_info "터널 연결 시도 중... (${PUBLIC_USER}@${PUBLIC_HOST}:${PUBLIC_PORT})"
    else
        log_warn "터널 재연결 시도 중... (시도 #${RETRY_COUNT})"
    fi

    ssh -N \
        -R ${REMOTE_PORT}:localhost:${LOCAL_PORT} \
        -p ${PUBLIC_PORT} \
        ${SSH_AUTH_OPT} \
        -o "ServerAliveInterval=${SERVER_ALIVE_INTERVAL}" \
        -o "ServerAliveCountMax=${SERVER_ALIVE_COUNT_MAX}" \
        -o "ExitOnForwardFailure=no" \
        -o "StrictHostKeyChecking=no" \
        ${PUBLIC_USER}@${PUBLIC_HOST} 2>&1 | add_timestamp &

    SSH_PID=$!
    sleep 3

    if ps -p $SSH_PID > /dev/null 2>&1; then
        if [ $RETRY_COUNT -gt 0 ]; then
            log_info "터널 재연결 성공!"
        else
            log_info "터널 연결 성공!"
        fi
        RETRY_COUNT=0
        wait $SSH_PID
        EXIT_CODE=$?
        log_error "터널 연결이 끊어졌습니다 (종료 코드: ${EXIT_CODE})"
    else
        EXIT_CODE=$?
        log_debug "연결 실패 (종료 코드: ${EXIT_CODE})"
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    log_debug "${RECONNECT_WAIT:-5}초 후 재연결 시도..."
    sleep ${RECONNECT_WAIT:-5}
done
SCRIPT_EOF
    chmod +x "$TUNNEL_SCRIPT"
}

create_monitor_script() {
    cat > "$MONITOR_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

LOG_FILE_PATH="${LOG_DIR}/${LOG_FILE}"

log_ssh() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] [SSH] ${message}" >> "$LOG_FILE_PATH"
}

log_ssh "INFO " "SSH 모니터링 시작"

tail -F /var/log/system.log 2>/dev/null | while read -r line; do
    if echo "$line" | grep -q "sshd"; then
        if echo "$line" | grep -q "USER_PROCESS"; then
            user=$(echo "$line" | grep -oE "sshd-session: [^ ]+" | sed 's/sshd-session: //')
            tty=$(echo "$line" | grep -oE "ttys[0-9]+")
            log_ssh "INFO " "접속: user=${user}, tty=${tty}"
        elif echo "$line" | grep -q "DEAD_PROCESS"; then
            user=$(echo "$line" | grep -oE "sshd-session: [^ ]+" | sed 's/sshd-session: //')
            tty=$(echo "$line" | grep -oE "ttys[0-9]+")
            log_ssh "INFO " "종료: user=${user}, tty=${tty}"
        fi
    fi
done
SCRIPT_EOF
    chmod +x "$MONITOR_SCRIPT"
}

create_launch_agents() {
    # 터널 LaunchAgent
    cat > "$HOME/Library/LaunchAgents/com.user.reverse-tunnel.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.reverse-tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>${TUNNEL_SCRIPT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/${LOG_FILE}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF

    # SSH 모니터 LaunchAgent
    cat > "$HOME/Library/LaunchAgents/com.user.ssh-monitor.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.ssh-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>${MONITOR_SCRIPT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/${LOG_FILE}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF
}

# ============================================
# 서비스 제어
# ============================================
start_services() {
    log_info "서비스 시작 중..."

    launchctl load "$HOME/Library/LaunchAgents/com.user.reverse-tunnel.plist" 2>/dev/null || true
    launchctl load "$HOME/Library/LaunchAgents/com.user.ssh-monitor.plist" 2>/dev/null || true

    sleep 2
    show_status
}

stop_services() {
    log_info "서비스 중지 중..."

    launchctl unload "$HOME/Library/LaunchAgents/com.user.reverse-tunnel.plist" 2>/dev/null || true
    launchctl unload "$HOME/Library/LaunchAgents/com.user.ssh-monitor.plist" 2>/dev/null || true

    pkill -f "ssh.*-R ${REMOTE_PORT}:localhost:${LOCAL_PORT}" 2>/dev/null || true

    log_info "서비스 중지됨"
}

restart_services() {
    stop_services
    sleep 1
    start_services
}

show_status() {
    echo ""
    log_title "=========================================="
    log_title "  서비스 상태"
    log_title "=========================================="

    # 터널 상태
    if launchctl list 2>/dev/null | grep -q "com.user.reverse-tunnel"; then
        PID=$(pgrep -f "ssh.*-R ${REMOTE_PORT}:localhost:${LOCAL_PORT}" 2>/dev/null | head -1)
        if [ -n "$PID" ]; then
            echo -e "  터널:      ${GREEN}실행 중${NC} (PID: $PID)"
            echo "             ${PUBLIC_HOST}:${REMOTE_PORT} → localhost:${LOCAL_PORT}"
        else
            echo -e "  터널:      ${YELLOW}연결 중...${NC}"
        fi
    else
        echo -e "  터널:      ${RED}중지됨${NC}"
    fi

    # SSH 모니터 상태
    if launchctl list 2>/dev/null | grep -q "com.user.ssh-monitor"; then
        echo -e "  SSH 모니터: ${GREEN}실행 중${NC}"
    else
        echo -e "  SSH 모니터: ${RED}중지됨${NC}"
    fi

    echo ""
    echo "  로그 파일: ${LOG_DIR}/${LOG_FILE}"
    log_title "=========================================="
    echo ""
}

# ============================================
# 명령어 구현
# ============================================
cmd_install() {
    echo ""
    log_title "=========================================="
    log_title "  SSH 리버스 터널링 설치"
    log_title "=========================================="
    echo ""

    load_config
    validate_config
    check_autossh
    create_directories
    create_tunnel_script
    create_monitor_script
    create_launch_agents
    start_services

    echo ""
    log_info "설치 완료!"
    echo ""
    log_title "=========================================="
    log_title "  설정 요약"
    log_title "=========================================="
    echo "  퍼블릭 서버: ${PUBLIC_USER}@${PUBLIC_HOST}:${PUBLIC_PORT}"
    echo "  터널 포트:   ${REMOTE_PORT} → localhost:${LOCAL_PORT}"
    echo "  로그 파일:   ${LOG_DIR}/${LOG_FILE}"
    log_title "=========================================="
    echo ""
    log_warn "로그 로테이션 설정을 위해 다음 명령어를 실행하세요:"
    echo ""
    echo "  sudo mkdir -p /etc/newsyslog.d"
    echo "  echo '${LOG_DIR}/${LOG_FILE}  $(whoami):staff  644  ${LOG_RETENTION_DAYS}  *  \$D0  N' | sudo tee /etc/newsyslog.d/reverse-tunnel.conf"
    echo ""
}

cmd_uninstall() {
    echo ""
    log_title "=========================================="
    log_title "  SSH 리버스 터널링 제거"
    log_title "=========================================="
    echo ""

    load_config

    stop_services

    log_info "LaunchAgent 파일 제거 중..."
    rm -f "$HOME/Library/LaunchAgents/com.user.reverse-tunnel.plist"
    rm -f "$HOME/Library/LaunchAgents/com.user.ssh-monitor.plist"

    log_info "서비스 스크립트 제거 중..."
    rm -f "$TUNNEL_SCRIPT"
    rm -f "$MONITOR_SCRIPT"

    echo ""
    log_info "제거 완료!"
    log_warn "로그 파일은 유지됩니다: ${LOG_DIR}/${LOG_FILE}"
    log_warn "로그 로테이션 설정 제거: sudo rm /etc/newsyslog.d/reverse-tunnel.conf"
    echo ""
}

cmd_update() {
    echo ""
    log_title "=========================================="
    log_title "  SSH 리버스 터널링 업데이트"
    log_title "=========================================="
    echo ""

    load_config
    validate_config

    log_info "설정 다시 적용 중..."
    create_tunnel_script
    create_monitor_script
    create_launch_agents

    restart_services

    echo ""
    log_info "업데이트 완료!"
    echo ""
    log_title "  현재 설정"
    log_title "=========================================="
    echo "  퍼블릭 서버: ${PUBLIC_USER}@${PUBLIC_HOST}:${PUBLIC_PORT}"
    echo "  터널 포트:   ${REMOTE_PORT} → localhost:${LOCAL_PORT}"
    echo "  연결 감지:   ${SERVER_ALIVE_INTERVAL}초 × ${SERVER_ALIVE_COUNT_MAX}회"
    log_title "=========================================="
    echo ""
}

cmd_start() {
    load_config
    start_services
}

cmd_stop() {
    load_config
    stop_services
}

cmd_restart() {
    load_config
    restart_services
}

cmd_status() {
    load_config
    show_status
}

cmd_logs() {
    load_config
    local lines="${1:-50}"
    echo ""
    log_title "최근 로그 (${lines}줄)"
    log_title "=========================================="
    tail -n "$lines" "${LOG_DIR}/${LOG_FILE}" 2>/dev/null || log_error "로그 파일이 없습니다"
    echo ""
}

cmd_logs_follow() {
    load_config
    echo ""
    log_title "실시간 로그 (Ctrl+C로 종료)"
    log_title "=========================================="
    tail -f "${LOG_DIR}/${LOG_FILE}" 2>/dev/null || log_error "로그 파일이 없습니다"
}

show_help() {
    echo ""
    log_title "SSH 리버스 터널링 관리 도구"
    echo ""
    echo "사용법: $0 <명령어> [옵션]"
    echo ""
    log_title "명령어:"
    echo "  install     설치 및 서비스 시작"
    echo "  uninstall   서비스 중지 및 제거"
    echo "  update      설정 변경 후 적용"
    echo ""
    echo "  start       서비스 시작"
    echo "  stop        서비스 중지"
    echo "  restart     서비스 재시작"
    echo "  status      서비스 상태 확인"
    echo ""
    echo "  logs [N]    최근 로그 N줄 보기 (기본: 50)"
    echo "  logs -f     실시간 로그 보기"
    echo ""
    echo "  help        도움말 보기"
    echo ""
    log_title "예시:"
    echo "  $0 install        # 설치"
    echo "  $0 status         # 상태 확인"
    echo "  $0 logs 100       # 최근 100줄"
    echo "  $0 logs -f        # 실시간 로그"
    echo ""
}

# ============================================
# 메인
# ============================================
case "$1" in
    install)
        cmd_install
        ;;
    uninstall)
        cmd_uninstall
        ;;
    update)
        cmd_update
        ;;
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            cmd_logs_follow
        else
            cmd_logs "$2"
        fi
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
