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

- `~/.claude/projects` 전체의 `*.jsonl`과 앱 목록 레지스트리
- Codex rollout `*.jsonl`과 `session_index.jsonl`
- 선택 사항: 대상 프로젝트 Git 저장소

### 전송 단위는 프로젝트가 아니라 앱 인덱스

원본은 운반 저장소가 아니라 에이전트 앱의 내부 인덱스이고, 저장소는 그것을 기기 간에
옮기는 수단입니다. 따라서 `ProjectRoot`는 전송 범위를 정하지 않습니다.
`~/.claude/projects`의 모든 폴더는 이름 그대로 운반합니다. Codex는 로컬 앱의 날짜 트리를
건드리지 않되, 운반 사본에만 rollout 원문의 최초 `session_meta.payload.cwd`를 키로 한 축을
추가합니다.

```text
local   ~/.codex/sessions/YYYY/MM/DD/<rollout>.jsonl
vault   Codex/sessions/<origin-cwd-key>/YYYY/MM/DD/<rollout>.jsonl[.gz]
archive Codex/archive/<origin-cwd-key>/YYYY/MM/DD/<rollout>.jsonl[.gz]
```

Pull은 `<origin-cwd-key>` 축을 제거해 앱의 원래 날짜 트리로 복원합니다. cwd를 읽을 수 없는
원문만 기술적 격리 키 `_no-cwd`에 두며, 이는 의미상 프로젝트 분류가 아닙니다. 날짜로 바로
시작하는 구 저장소 경로도 Pull은 계속 읽지만, 새 Push는 만들지 않습니다. 같은 UUID가 서로
다른 cwd-key 경로에 있으면 임의 선택하지 않고 오류로 중단합니다.

의미상 프로젝트 분류는 물리 경로와 분리한 `Codex/session_projects.jsonl`에 둡니다. 한 세션에
여러 프로젝트를 붙일 수 있고, 재분류해도 대용량 rollout은 이동하지 않습니다.

```powershell
.\Launchers\Set-CodexSessionProjects.ps1 <session-id> -Projects MyEngine,MyWorkbench
.\Launchers\Set-CodexSessionProjects.ps1 <session-id> -Remove
```

프로젝트 단위로 걸러서는 안 되는 이유는 앱 목록 항목과 트랜스크립트가 한 레코드의 양쪽
절반이기 때문입니다. 앱 레지스트리(`local_*.json`)는 항상 전체가 운반되므로, 트랜스크립트만
프로젝트로 거르면 반대편 PC에 반쪽짜리 항목이 남습니다. 그러면 앱이 그 항목을 "대화 없음"으로
판정해 `cliSessionId`를 제거하고, 그 손상본이 다음 Push 때 멀쩡한 쪽을 덮어써 연결이 영구히
사라집니다.

같은 이유로 앱 레지스트리는 통짜 복사가 아니라 항목 단위로 머지합니다
(`Merge-ClaudeAppRegistry`). 연결을 가진 항목이 연결을 잃은 항목을 이기며, 방향은 Push/Pull
양쪽에서 동일합니다. Codex 인덱스가 `Sync-CodexIndex.ps1`로 union 머지하는 것과 같은 규칙입니다.

`Claude/projects/primary`, `worktree*`는 구버전이 쓰던 경로 치환 이름입니다. Pull은
하위호환으로 계속 읽지만 Push는 더 이상 만들지 않습니다.

### 보존은 영구, 작업 집합은 유한

에이전트 앱은 자체 보존 기간이 지난 transcript를 로컬에서 정리합니다. 저장소가 그것을
Pull로 계속 되돌려주면 앱 인덱스는 줄어들 수 없습니다. 늘어나고, 다시 채워지고, 또 늘어납니다.
전부 보존하는 것은 맞지만 전부 작업 집합에 도로 넣는 것은 아닙니다.

그래서 두 계층으로 나눕니다.

| 폴더 | 역할 | Pull 복원 |
|---|---|---|
| `Claude/projects/<key>/` | 활성 작업 집합 | 함 |
| `Claude/archive/<key>/` | 영구 보존 | **안 함** |
| `ClaudeApp/claude-code-sessions/` | 활성 목록 항목 | 함 |
| `ClaudeApp/archive/` | 폐기된 목록 항목 | **안 함** |
| `Codex/sessions/<cwd-key>/YYYY/MM/DD/` | 활성 전송 사본 | cwd-key를 벗겨 복원 |
| `Codex/archive/<cwd-key>/YYYY/MM/DD/` | 영구 보존 | **안 함** |

Push는 로컬 앱 인덱스에서 사라진 세션을 **지우지 않고 옮깁니다.** 되돌리는 경로가 있어야
아카이브이므로 `Launchers\Restore-ArchivedSession.ps1`을 함께 씁니다. 인자 없이 실행하면
아카이브 목록을, 세션 ID나 검색어를 주면 활성 폴더로 되돌립니다.

기준은 두 가지입니다.

- **명시적 폐기** — 앱이 대화를 지울 때 남기는 `deleted_<id>` 마커. "이 설계는 버렸다"는
  사용자의 선언이며, 이 도구가 쓸 수 있는 유일한 삭제 신호입니다. 마커도 함께 운반되고
  Push/Pull 양쪽에서 묘비로 취급되어, 한쪽에서 지운 대화가 반대편에서 되살아나지 않습니다.
  **목록 항목만 물러나고 transcript 원문은 보존됩니다.**
- **자동 노화** — `ActiveWindowDays`(기본 30). Claude는 로컬 앱 인덱스에서 사라지고 git 최근
  변경 보호기간도 지난 원문을, Codex는 원문 최상위 마지막 이벤트 timestamp가 기간을 넘긴
  원문을 아카이브합니다. 파일 mtime·파일명 시작일·현재 호스트 cwd는 판정에 쓰지 않습니다.

Claude 아카이브 판정에는 git 기준 최근 변경 검사가 걸려 있습니다(rename 제외). 상대 PC가 방금
올린 세션을 여기서 노화된 것으로 오인해 내리지 않기 위한 안전장치입니다. Codex는 원문 내용의
마지막 활동 시각을 사용하므로 이 git 기준을 쓰지 않습니다.

원문을 어느 계층에서도 찾지 못한 목록/인덱스 항목은 자동으로 지우거나 아카이브하지 않습니다.
반대편 PC에만 원문이 있을 수 있기 때문이며, 경고만 내고 활성 인덱스에 남깁니다.

제외 대상:

- `auth.json`, 앱 DB, SQLite, 키 파일, 로컬 설정
- Codex `state_5.sqlite`
- 에이전트 메모리 파일(`~/.claude/**/memory/*.md`, `~/.codex/memories`) — 머신 로컬 자산입니다
- MultiAgentWorkbenchStateSync가 담당하는 `UserSettings/**/*.md`, `Projects/<name>/RULES.md`

비밀값 패턴 검사는 운반 저장소로 복사하기 **전에** 로컬 원본에서 수행합니다. 복사한 뒤에 검사하면
차단하더라도 민감한 원본이 이미 워킹트리에 남기 때문입니다. 다만 모든 민감정보를 보장해 찾아내는
도구는 아닙니다.

Codex의 로컬 SQLite DB는 머신·앱 버전 종속 상태이므로 동기화하지 않습니다. Pull 후 설치된
`codex app-server`에 `thread/list` 스캔·복구를 요청해 새 rollout이 사이드바에 등록되도록 합니다.
Codex 업데이트로 이 인터페이스가 달라지면 경고만 내고 세션 Pull 자체는 계속합니다.

## 예시 세션 레이아웃

`examples/session-store/`에 이 도구가 머신 사이로 운반하는 **디렉터리 구조 예시**가 있습니다. 무엇이 동기화되는지를 보여주는 예시이며, 파일 내용은 실제 세션이 아닌 **합성 placeholder**입니다.

```text
examples/session-store/
  ACTIVE_HOST.txt                                       # 단일 기록자 baton(잠금 보유 호스트)
  Claude/projects/<cwd-key>/*.jsonl                     # Claude Code 프로젝트 세션(활성)
  Claude/archive/<cwd-key>/*.jsonl                      # Claude 세션 영구 보존(Pull 복원 안 함)
  ClaudeApp/claude-code-sessions/**/*.json              # Claude 데스크톱 앱 세션 레지스트리
  ClaudeApp/claude-code-sessions/**/deleted_<id>        # 앱이 남긴 삭제 마커(묘비)
  ClaudeApp/archive/**/*.json                           # 폐기된 목록 항목(Pull 복원 안 함)
  Codex/session_index.jsonl                             # Codex 활성 세션 인덱스
  Codex/archive_index.jsonl                             # Codex 아카이브 세션 인덱스
  Codex/session_projects.jsonl                          # Codex 세션의 의미상 프로젝트 태그
  Codex/sessions/<cwd-key>/YYYY/MM/DD/*.jsonl[.gz]      # Codex rollout 세션(활성)
  Codex/archive/<cwd-key>/YYYY/MM/DD/*.jsonl[.gz]       # Codex rollout 영구 보존(Pull 복원 안 함)
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

`-ProjectRoot`는 Start/Finish의 기준 프로젝트를 지정할 뿐 전송 범위가 아닙니다. 대화는 프로젝트와
무관하게 전부 따라오므로 새 프로젝트를 시작할 때 설정을 고칠 필요가 없습니다. 다만 앱 목록 항목이
`cwd` 절대경로를 그대로 들고 다니므로, **두 PC에서 프로젝트 경로를 같게 두는 것을 권장합니다.**
경로가 다르면 세션 파일 위치와 앱 목록이 가리키는 위치가 어긋납니다.

대상 프로젝트도 Start/Finish에 포함하려면 `-EnableProjectGitSync`를 추가합니다.  
여기서 대상 프로젝트는 `-ProjectRoot`에 지정한 Git 저장소입니다. MultiAgentCrossReview를 지정하면
워크벤치 자체를 pull/commit/push하며, 거기서 참조하는 원본 프로젝트 저장소를 자동으로 뜻하지 않습니다.
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

Codex 세션 JSONL이 GitHub 파일당 100MiB 제한에 근접하면 Push는 원본 앱 파일을
건드리지 않고 전송 사본만 `.jsonl.gz`로 압축합니다. Pull은 이를 원래 JSONL 경로로
복원한 뒤 인덱스 병합과 대화목록 등록 절차를 계속합니다.

정리·복구용 보조 스크립트도 함께 제공합니다.

| 스크립트 | 용도 |
|---|---|
| `Restore-ArchivedSession.ps1` | 아카이브 목록 조회 및 활성 폴더로 복원 |
| `Set-CodexSessionProjects.ps1` | Codex 세션의 의미상 프로젝트 태그 수정(파일 이동 없음) |
| `Repair-ClaudeEntryBinding.ps1` | 앱 목록 항목을 실재하는 transcript에 다시 연결 |
| `Remove-AdoptedSessionEntries.ps1` | 앱 스캔이 자동 생성한 빈 목록 항목 정리 |

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
