# SSH Reverse Tunnel

macOS에서 리버스 SSH 터널을 자동으로 관리하는 도구입니다.

## 구조

```
[A: 외부 PC] ---> [B: 퍼블릭 서버:REMOTE_PORT] ==터널==> [C: 내부망 PC:LOCAL_PORT]
```

- **A**: 외부에서 접속하려는 PC
- **B**: 퍼블릭 IP를 가진 중계 서버
- **C**: 내부망에 있는 PC (이 스크립트를 실행)

## 기능

- 자동 재연결: 네트워크 끊김 시 자동 복구
- 부팅 시 자동 시작: macOS LaunchAgent 사용
- SSH 접속 로깅: 누가 언제 접속했는지 기록
- 로그 로테이션: 자동 로그 관리 (기본 7일 보관)

## 설치

### 1. 저장소 클론

```bash
git clone git@github.com:Piat0046/ssh-tunnel.git
cd ssh-tunnel
```

### 2. 설정 파일 생성

```bash
cp config.env.example config.env
nano config.env  # 설정 수정
```

### 3. 설치 및 시작

```bash
./tunnel.sh install
```

### 4. 로그 로테이션 설정 (선택)

```bash
sudo mkdir -p /etc/newsyslog.d
echo '/Users/YOUR_USER/Library/Logs/reverse-tunnel.log  YOUR_USER:staff  644  7  *  $D0  N' | sudo tee /etc/newsyslog.d/reverse-tunnel.conf
```

## 사용법

```bash
./tunnel.sh install     # 설치
./tunnel.sh uninstall   # 제거
./tunnel.sh update      # 설정 변경 후 적용

./tunnel.sh start       # 시작
./tunnel.sh stop        # 중지
./tunnel.sh restart     # 재시작
./tunnel.sh status      # 상태 확인

./tunnel.sh logs        # 최근 50줄
./tunnel.sh logs 100    # 최근 100줄
./tunnel.sh logs -f     # 실시간 로그

./tunnel.sh help        # 도움말
```

## A에서 C로 접속하는 방법

### 방법 1: B를 거쳐서 접속

```bash
# A에서 B로 접속
ssh -p PUBLIC_PORT user@PUBLIC_HOST

# B에서 C로 접속
ssh -p REMOTE_PORT user@localhost
```

### 방법 2: ProxyJump 사용 (한 번에 접속)

```bash
ssh -J user@PUBLIC_HOST:PUBLIC_PORT -p REMOTE_PORT user@localhost
```

## 설정 항목

| 항목 | 설명 | 기본값 |
|------|------|--------|
| `PUBLIC_HOST` | B 서버 주소 | - |
| `PUBLIC_USER` | B 서버 사용자명 | - |
| `PUBLIC_PORT` | B 서버 SSH 포트 | 22 |
| `REMOTE_PORT` | B에서 열릴 포트 | 22 |
| `LOCAL_PORT` | C의 SSH 포트 | 22 |
| `SSH_AUTH` | 인증 방식 (key/password/none) | key |
| `SSH_KEY` | SSH 키 경로 (SSH_AUTH=key일 때) | ~/.ssh/id_rsa |
| `SERVER_ALIVE_INTERVAL` | 연결 확인 주기 (초) | 10 |
| `SERVER_ALIVE_COUNT_MAX` | 연결 확인 횟수 | 3 |
| `LOG_RETENTION_DAYS` | 로그 보관 기간 (일) | 7 |

### SSH 인증 방식

- **key**: SSH 키 파일 사용 (권장, 자동 재연결 지원)
- **password**: 비밀번호 인증 (최초 실행 시 입력 필요, 자동 재연결 제한)
- **none**: 시스템 기본 설정 사용 (ssh-agent 등 이미 설정된 경우)

## 요구사항

- macOS
- Homebrew
- autossh (자동 설치됨)

## 라이센스

MIT
