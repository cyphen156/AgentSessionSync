# AgentSessionSync

Windows PC 사이에서 Claude Code와 Codex의 프로젝트별 대화 세션을 Git push/pull로 운반하고,  
작업 표시줄의 **Start / Finish 버튼 두 개**로 등록된 에이전트를 함께 열고 닫는 선택형 도구입니다.

AgentSessionSync는 MultiAgentCrossReview의 필수 구성요소가 아닙니다.  
한 대의 머신에서만 작업하거나 대화 세션을 직접 관리한다면 쓰지 않아도 됩니다.  
여러 머신에서 같은 에이전트 대화를 이어가야 할 때만 사용자가 직접 만든 **private session vault**를 대상으로 설정합니다.

## 역할 구분

| 계층 | 역할 |
|---|---|
| `MultiAgentCrossReview` | 공개 검토 워크벤치. `Reviews/` 프레임워크·범용 룰·프로젝트 템플릿을 포함합니다. 상태·세션 동기화는 외부 선택 도구가 담당합니다. |
| `MultiAgentWorkbenchStateSync` | 선택 기능. 개인 설정·프로젝트별 룰·검토 기록을 상태 저장소와 동기화하는 외부 도구입니다. |
| `AgentSessionSync` | 선택 기능. Claude/Codex 세션 JSONL을 private session vault와 동기화합니다. |
| private session vault | 실제 대화 JSONL과 baton을 보관하는 사용자 소유 비공개 저장소입니다. |

상태 동기화와 세션 동기화는 분리합니다.  
워크벤치 상태(룰·설정·검토 기록)는 MultiAgentWorkbenchStateSync가 맡고, 원문 대화 세션은 AgentSessionSync가 맡습니다.

## 핵심 흐름

### Start

1. 선택적으로 대상 프로젝트 `git pull`
2. Claude/Codex 세션 `git pull` 및 로컬 복원
3. Codex rollout을 기준으로 로컬 thread DB 스캔·복구 요청
4. `Agents/*.psd1`에 등록된 데스크톱 에이전트 전부 실행

### Finish

1. 등록된 에이전트 전부 정상 종료 요청
2. 모든 창이 닫혔는지 확인 — 강제 종료하지 않음
3. 선택적으로 대상 프로젝트 commit/push
4. Claude/Codex 세션 검사 후 commit/push

Start/Finish 스크립트 자체는 AI를 호출하지 않으므로 AI 토큰을 사용하지 않습니다.  
주기적 폴링도 하지 않습니다.

## 중요한 보안 구조

이 공개 저장소에는 스크립트와 예제만 있으며 실제 대화는 없습니다.  
실제 운반 저장소는 이 저장소를 템플릿으로 삼아 사용자가 직접 만든 **private repository**여야 합니다.

원문 대화(JSONL)에는 시스템 지침, 도구 출력, 절대경로, 비공개 코드 조각, 계정/환경 정보가 섞일 수 있습니다.  
**session vault는 공개하지 마세요.**

동기화 대상:

- Claude 프로젝트별 `*.jsonl`과 앱 목록 레지스트리
- Codex rollout `*.jsonl`과 `session_index.jsonl`
- 선택 사항: 대상 프로젝트 Git 저장소

제외 대상:

- `auth.json`, 앱 DB, SQLite, 키 파일, 로컬 설정
- Codex `state_5.sqlite`
- MultiAgentWorkbenchStateSync가 담당하는 `UserSettings/**/*.md`, `Projects/<name>/RULES.md`

Push 전 비밀값 패턴 검사도 수행하지만 모든 민감정보를 보장해 찾아내는 도구는 아닙니다.

Codex의 로컬 SQLite DB는 머신·앱 버전 종속 상태이므로 동기화하지 않습니다. Pull 후 설치된
`codex app-server`에 `thread/list` 스캔·복구를 요청해 새 rollout이 사이드바에 등록되도록 합니다.
Codex 업데이트로 이 인터페이스가 달라지면 경고만 내고 세션 Pull 자체는 계속합니다.

## 예시 세션 레이아웃

`examples/session-store/`에 이 도구가 머신 사이로 운반하는 **디렉터리 구조 예시**가 있습니다. 무엇이 동기화되는지를 보여주는 예시이며, 파일 내용은 실제 세션이 아닌 **합성 placeholder**입니다.

```text
examples/session-store/
  ACTIVE_HOST.txt                                  # 단일 기록자 baton(잠금 보유 호스트)
  Claude/projects/<path-neutral-key>/*.jsonl        # Claude Code 프로젝트 세션
  ClaudeApp/claude-code-sessions/**/*.json          # Claude 데스크톱 앱 세션 레지스트리
  Codex/session_index.jsonl                         # Codex 세션 인덱스
  Codex/sessions/YYYY/MM/DD/*.jsonl                 # Codex rollout 세션
```

include/제외 규칙 전체는 [`SESSION_MANIFEST.schema.md`](SESSION_MANIFEST.schema.md)에 정의돼 있습니다. 실제 대화 JSONL은 공개 저장소가 아니라 사용자의 비공개 `AgentSessionVault`에만 둡니다.

## 설치

### 1. Private session vault 생성 및 클론

이 저장소에서 **Use this template**를 누르고 Visibility를 Private으로 지정합니다.  
또는 같은 파일 구조를 가진 사용자 소유 private repository를 직접 만듭니다.

```powershell
git clone https://github.com/<YOU>/<PRIVATE-SESSION-VAULT>.git C:\AgentSessionVault
cd C:\AgentSessionVault
```

### 2. PC별 설치 실행

```powershell
.\Launchers\Initialize-AgentSessionSync.ps1 `
  -ProjectRoot 'C:\Projects\MyProject' `
  -EnableSessionPush
```

이 명령은 로컬 `AgentSessionSync.config.psd1`과 Start/Finish 바로가기를 함께 생성합니다.
설정과 `.lnk`는 절대경로를 포함하므로 Git에 올라가지 않습니다.
두 PC의 프로젝트 경로가 달라도 Claude 세션 폴더를 경로 중립 이름으로 운반한 뒤 각 PC의 경로로 재매핑합니다.

대상 프로젝트도 Start/Finish에 포함하려면 `-EnableProjectGitSync`를 추가합니다.  
여기서 대상 프로젝트는 `-ProjectRoot`에 지정한 Git 저장소입니다. MultiAgentCrossReview를 지정하면
워크벤치 자체를 pull/commit/push하며, CyphenEngine이나 FindJobProject 원본 저장소를 자동으로 뜻하지 않습니다.
모든 변경을 자동 커밋하므로 기본값은 꺼져 있습니다.

### 3. 에이전트 등록 확인

기본 등록:

```text
Agents/
├─ Codex.psd1
└─ Claude.psd1
```

Microsoft Store 패키지 식별자가 다른 경우 다음 명령으로 확인한 뒤 해당 파일의 `AppId`를 수정합니다.

```powershell
Get-StartApps | Where-Object Name -Match 'Codex|ChatGPT|Claude'
```

### 4. Start / Finish 바로가기

설치 명령이 `Launchers\Shortcuts\` 아래에 바로가기를 자동 생성합니다. 경로 변경 뒤 다시 만들 때만
`.\Launchers\Create-Shortcuts.ps1`을 별도로 실행합니다. 생성된 Start/Finish 바로가기를 작업 표시줄에 고정합니다.
Windows 정책상 작업 표시줄 고정과 위치 이동은 사용자가 직접 수행합니다.

## 사용

```powershell
.\Launchers\Start.ps1
# 두 PC 중 한 곳에서 작업
.\Launchers\Finish.ps1
```

Finish는 에이전트가 제한 시간 안에 정상 종료되지 않으면 Push를 중단합니다.  
마지막 기록을 보호하기 위해 강제 종료하지 않습니다.

`ACTIVE_HOST.txt` baton은 동시 작업 위험을 알리는 소유권 경고입니다. 다른 호스트가 baton을 가진
상태여도 Start를 막지 않으며, 원격이 앞선 경우 명시적으로 pull/merge하여 합류합니다.

## 새 에이전트 추가

`Agents`에 다음 형식의 `.psd1` 파일을 한 장 추가합니다.

```powershell
@{
    Name = 'FutureAgent'
    AppId = 'PackageFamilyName!ApplicationId'
    ProcessName = 'FutureAgent'
    Enabled = $true
    Order = 30
}
```

Start는 `Order` 오름차순으로 실행하고 Finish는 역순으로 종료합니다.

## 검증

```powershell
.\Launchers\tests\Test-AgentSessionSync.ps1
.\Launchers\tests\Test-AgentLauncher.ps1
```

첫 테스트는 임시 bare Git 원격과 가짜 사용자 홈 두 개로 실제 세션 왕복을 검증합니다.  
두 번째 테스트는 앱을 열거나 닫지 않고 에이전트 레지스트리와 바로가기 생성을 검증합니다.

자세한 설치는 [docs/SETUP_WINDOWS.md](docs/SETUP_WINDOWS.md),  
문제 해결은 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)를 참고하세요.

## Codex 사이드바 진단 기록

Pull은 세션 복원 후 `%LOCALAPPDATA%\AgentSessionSync\Logs`에 머신 로컬 JSON 진단 기록을 남깁니다.
`latest.json`은 가장 최근 실행이고, `Pull-<HOST>-<TIMESTAMP>.json`은 실행별 기록입니다.

진단기는 앱 패키지와 Codex CLI 후보·버전, rollout 형식 버전, 인덱스 항목 수, 앱 서버 등록 전후의
누락 ID와 오류를 기록합니다. 대화 본문과 인증 정보는 기록하지 않으며 로그는 Vault에 push하지 않습니다.

호환되는 Codex 실행 파일을 찾은 경우에만 누락 ID를 `thread/read`로 등록합니다. 실행 파일이
rollout보다 오래됐거나 앱 서버 규격이 달라지면 세션 Pull은 유지하고 `version-mismatch`,
`no-compatible-cli`, `partial`, `failed` 등의 상태와 오류를 로그에 남깁니다. SQLite 파일은 직접
복사하거나 수정하지 않습니다.

## 지원 범위

- Windows 10/11
- Windows PowerShell 5.1 이상
- Git
- Claude Code와 Codex의 현재 로컬 JSONL 저장 구조

앱 내부 저장 구조와 패키지 ID는 버전에 따라 바뀔 수 있습니다.

## License

MIT. 자유롭게 사용·수정·배포할 수 있으며 저작권 고지와 라이선스는 유지해야 합니다.
