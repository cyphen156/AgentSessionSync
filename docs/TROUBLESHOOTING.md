# 문제 해결

## Start를 눌러도 앱이 열리지 않음

`Get-StartApps`로 실제 App ID를 확인하고 `Agents\*.psd1`의 `AppId`와 비교합니다. Store 설치판과 일반 설치판은 실행 식별자가 다를 수 있습니다. CLI만 사용하는 에이전트는 Store App ID 방식 대신 별도 실행 전략이 필요합니다.

## Finish가 Push 전에 중단됨

등록된 앱이 제한 시간 안에 정상 종료되지 않았거나 다른 등록 에이전트 창이 남아 있습니다. 데이터 기록을 보호하기 위한 동작이며 강제 종료는 수행하지 않습니다. 앱을 직접 종료한 뒤 Finish를 다시 실행하세요.

## Codex 파일은 있는데 사이드바에 안 보임

Pull은 rollout JSONL과 `session_index.jsonl`을 복원한 뒤 `Repair-CodexThreadVisibility.ps1`을 자동
실행합니다. 진단기는 앱 패키지와 CLI 버전을 비교하고, 호환되는 실행 파일을 찾은 경우에만 인덱스에는
있지만 앱 목록에는 없는 ID를 `thread/read`로 등록합니다.

`state_5.sqlite`는 복사하거나 직접 수정하지 않습니다. 호환되는 자동 등록 경로가 없으면 세션 Pull은
계속 진행하고 아래 머신 로컬 로그에 원인을 남깁니다. Codex 앱이 이미 열려 있었다면 진단 후 앱을
다시 열어 표시를 갱신합니다.

Claude는 별도 구조이므로 기존처럼 본문 JSONL과 `claude-code-sessions` 앱 레지스트리를 복원합니다.

## Codex 진단 로그 확인

사이드바 항목이 다르면 먼저 다음 파일을 확인합니다.

```powershell
Get-Content "$env:LOCALAPPDATA\AgentSessionSync\Logs\latest.json" -Raw
```

`version-mismatch`는 복원된 rollout보다 실행 가능한 Codex CLI가 오래됐다는 뜻입니다.
`partial`은 일부 ID의 `thread/read` 등록만 성공했다는 뜻이며 `visibility.repairFailed`에 ID와
앱 서버 오류가 기록됩니다. `no-compatible-cli` 또는 `failed`이면 `cliCandidates`, `appPackages`,
`appServer`, `errors`를 함께 확인합니다.

로그에는 대화 본문을 넣지 않으므로 원인 분석용으로 전달할 수 있지만, 사용자 경로와 세션 UUID는
포함됩니다.

## 다른 PC가 baton을 갖고 있다는 경고

이전 PC에서 Finish를 생략했다는 신호입니다. baton은 경고용이며 Start를 막지 않습니다. 스크립트는
원격이 앞서 있으면 명시적으로 pull/merge를 시도하지만, 아직 push하지 않은 내용은 가져올 수 없습니다.

## 비밀값 검사에서 push가 중단됨

대화 JSONL 또는 앱 레지스트리에 토큰처럼 보이는 문자열이 포함됐습니다. 검사 우회보다 해당 비밀값을 폐기·교체하고 세션 내용을 정리하는 편이 안전합니다.

## Claude 프로젝트 폴더를 못 찾음

로컬 설정의 `ProjectRoot`가 Claude를 실행한 실제 작업 경로와 같은지 확인합니다. 경로는 PC마다 다르게 설정할 수 있습니다.
