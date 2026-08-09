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

## 지운 적 없는 대화가 목록에서 사라짐

`ActiveWindowDays`(기본 30)가 지난 세션은 Push가 `archive/` 계층으로 **옮깁니다.** 지우지
않으므로 언제든 되돌릴 수 있습니다.

```powershell
.\Launchers\Restore-ArchivedSession.ps1                 # 아카이브 목록
.\Launchers\Restore-ArchivedSession.ps1 <세션ID 일부>    # 활성 폴더로 복원
```

복원 후 이 PC에 내려받으려면 `Pull-Sessions.ps1`을 실행합니다. 앱 목록에도 다시 띄우려면 해당
대화의 `deleted_` 마커를 지워야 할 수 있습니다.

## 지운 대화가 다시 살아남

앱이 남긴 `deleted_<id>` 마커가 운반되지 않은 경우입니다. 두 PC 모두에서 최신 Pull을 받았는지
확인하세요. 마커는 Push/Pull 양쪽에서 묘비로 취급되며, 목록 항목만 물러나고 대화 원문은
`archive/`에 보존됩니다. 반대로 **원문이 어느 계층에도 없는 항목**은 자동으로 지우지도
아카이브하지도 않습니다. 반대편 PC에만 원문이 있을 수 있기 때문이며, 이 경우 Push가 경고만
남기고 활성 인덱스에 그대로 둡니다.

## 대화 목록에 같은 제목이 여러 번 뜸

앱이 `~/.claude/projects`를 스캔해 CLI로 생긴 transcript마다 목록 항목을 자동 생성한 결과입니다.
이런 항목은 `sessionId`와 `cliSessionId`가 같고 `completedTurns`가 0이라 실제 대화와 구분됩니다.
Claude 앱을 완전히 종료한 뒤 정리합니다.

```powershell
.\Launchers\Remove-AdoptedSessionEntries.ps1            # 대상만 확인
.\Launchers\Remove-AdoptedSessionEntries.ps1 -Apply     # 실제 정리
```

목록 항목만 걷어내며 대화 원문은 건드리지 않습니다. 반대로 원문은 있는데 목록 항목이 연결을 잃은
경우에는 `Repair-ClaudeEntryBinding.ps1`로 다시 묶습니다.

## Codex 세션 파일이 `.jsonl.gz`로 보임

GitHub 파일당 100MiB 제한에 근접한 rollout은 전송 사본만 압축합니다. 로컬 앱 파일은 그대로이며
Pull이 원래 JSONL 경로로 되돌린 뒤 인덱스 병합을 계속합니다.

## Claude 프로젝트 폴더를 못 찾음

`ProjectRoot`는 Start/Finish의 기준일 뿐 전송 범위가 아닙니다. `~/.claude/projects`의 모든 폴더는
이름 그대로 운반되므로, 프로젝트가 설정에 없다는 이유로 대화가 빠지지는 않습니다.

목록 항목과 세션 파일이 서로 다른 곳을 가리킨다면 두 PC의 **프로젝트 절대경로가 다른 것**이
원인입니다. 앱 목록 항목은 `cwd`를 그대로 들고 다니므로 두 PC에서 경로를 같게 두는 편이 안전합니다.
