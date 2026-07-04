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
3. `Agents/*.psd1`에 등록된 데스크톱 에이전트 전부 실행

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

## 설치

### 1. Private session vault 생성 및 클론

이 저장소에서 **Use this template**를 누르고 Visibility를 Private으로 지정합니다.  
또는 같은 파일 구조를 가진 사용자 소유 private repository를 직접 만듭니다.

```powershell
git clone https://github.com/<YOU>/<PRIVATE-SESSION-VAULT>.git C:\AgentSessionVault
cd C:\AgentSessionVault
```

### 2. PC별 로컬 설정 생성

```powershell
.\Initialize-AgentSessionSync.ps1 `
  -ProjectRoot 'C:\Projects\MyProject' `
  -EnableSessionPush
```

`AgentSessionSync.config.psd1`은 Git에 올라가지 않습니다.  
두 PC의 프로젝트 경로가 달라도 Claude 세션 폴더를 경로 중립 이름으로 운반한 뒤 각 PC의 경로로 재매핑합니다.

대상 프로젝트도 Start/Finish에 포함하려면 `-EnableProjectGitSync`를 추가합니다.  
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
Get-StartApps | Where-Object Name -Match 'Codex|Claude'
```

### 4. Start / Finish 바로가기 생성

```powershell
.\Create-Shortcuts.ps1
```

생성된 `Shortcuts\Start.lnk`와 `Shortcuts\Finish.lnk`를 작업 표시줄에 고정합니다.  
Windows 정책상 작업 표시줄 고정과 위치 이동은 사용자가 직접 수행합니다.

## 사용

```powershell
.\Start.cmd
# 두 PC 중 한 곳에서 작업
.\Finish.cmd
```

Finish는 에이전트가 제한 시간 안에 정상 종료되지 않으면 Push를 중단합니다.  
마지막 기록을 보호하기 위해 강제 종료하지 않습니다.

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
.\Test-AgentSessionSync.ps1
.\Test-AgentLauncher.ps1
```

첫 테스트는 임시 bare Git 원격과 가짜 사용자 홈 두 개로 실제 세션 왕복을 검증합니다.  
두 번째 테스트는 앱을 열거나 닫지 않고 에이전트 레지스트리와 바로가기 생성을 검증합니다.

자세한 설치는 [docs/SETUP_WINDOWS.md](docs/SETUP_WINDOWS.md),  
문제 해결은 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)를 참고하세요.

## 지원 범위

- Windows 10/11
- Windows PowerShell 5.1 이상
- Git
- Claude Code와 Codex의 현재 로컬 JSONL 저장 구조

앱 내부 저장 구조와 패키지 ID는 버전에 따라 바뀔 수 있습니다.

## License

MIT. 자유롭게 사용·수정·배포할 수 있으며 저작권 고지와 라이선스는 유지해야 합니다.
