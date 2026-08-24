# AgentSessionSync

AgentSessionSync는 여러 Windows PC에서 Claude와 Codex의 대화를 이어 쓰기 위한 공개 MIT 도구입니다.
실제 대화 원문은 사용자가 소유한 비공개 `AgentSessionVault`에만 저장합니다.

이 도구는 대화 세션만 다룹니다. 프로젝트 소스, 워크벤치 상태, 에이전트 메모리는 동기화하지 않습니다.

아래 상태 전이와 테스트의 이번 개정 범위는 Codex입니다. Claude의 원문과 앱 목록 매핑은 Claude 측
검수·개정에서 별도로 확정하며, Codex 판정을 Claude 데이터에 추측 적용하지 않습니다.

## 보장하는 동작

- 한 PC에서 Finish한 활성 대화를 다른 PC의 Start에서 이어서 사용할 수 있습니다.
- 마지막 활동 후 30일이 지난 대화는 활성 목록에서 내려가고 Vault의 Archived에 보관됩니다.
- 앱에서 최종 삭제한 대화는 Vault의 현재 트리와 각 PC의 로컬 저장소에서 제거되어 다시 나타나지 않습니다.
- Vault에 없던 로컬 신규 대화는 삭제하지 않고 다음 Finish에서 추가합니다.
- 알려지지 않은 앱 데이터 형식을 만나면 로컬 데이터와 Vault를 변경하지 않고 중단합니다.

다음 동작은 보장하지 않습니다.

- Codex 사이드바의 즉시 갱신. 앱 재시작 또는 업데이트가 필요할 수 있습니다.
- 복원했지만 새 활동을 남기지 않은 오래된 대화의 30일 유지. 다음 Finish에서 다시 Archived로 내려갈 수 있습니다.
- 과거 Git 이력에서 삭제된 원문까지 제거하는 완전 파기.

## 저장 위치와 상태

현재 checkout된 private Vault가 동기화 기준입니다.

| 상태 | Vault | 로컬 앱 저장소 |
|---|---|---|
| Active | `Claude/sessions`, `Codex/sessions` | 존재 |
| Archived | `Claude/archive`, `Codex/archive` | 활성 저장소에서 제거 |
| Deleted | 현재 트리에 없음 | 제거 |

Active와 Archived는 동시에 존재할 수 없습니다. Deleted 원문은 과거 Git commit에는 남지만 최신
트리에는 없으므로 다른 PC에서 Pull하면 동일하게 삭제됩니다. 별도 tombstone으로 원문을 보존하지
않습니다.

Codex의 `~/.codex/archived_sessions`는 앱의 2단계 삭제 절차를 확인하기 위한 존재 위치일 뿐,
Vault의 Archived 상태를 결정하는 신호나 보관 장소가 아닙니다.

## Start

1. Vault를 `git pull --ff-only`로 갱신합니다.
2. 지원하는 세션 형식인지 검사합니다.
3. Vault Active를 로컬 활성 저장소에 배치합니다.
4. Vault Archived와 최신 트리에서 삭제된 기존 세션을 로컬 활성 저장소에서 제거합니다.
5. Vault에 아직 없는 로컬 신규 세션은 보존합니다.
6. 로컬 체크포인트를 갱신하고 등록된 앱을 실행합니다.

로컬 체크포인트는 `%LOCALAPPDATA%\AgentSessionSync\State`에 저장합니다. 대화 원문이나 공유 상태가
아니며, 마지막으로 이 PC에 반영한 Vault commit과 Active ID 집합만 기록합니다.

## Finish

1. 등록된 앱에 정상 종료를 요청하고 완전히 닫혔는지 확인합니다.
2. 종료되지 않으면 강제 종료하지 않고 중단합니다.
3. 앱 형식과 현재 로컬 원문을 다시 검사합니다.
4. 각 앱 adapter가 앱별 삭제 신호와 현재 로컬 존재 집합을 판정합니다.
5. 최종 삭제로 확인된 대화만 Vault 최신 트리에서 제거합니다.
6. 현재 활성 저장소에 새로 나타난 ID는 Vault Archived를 먼저 조회합니다.
   - Archived에 있으면 Active로 이동합니다.
   - 없으면 신규 대화로 추가합니다.
7. 계속 활성인 대화의 원문을 갱신합니다.
8. 마지막 timestamp가 30일 기준을 넘은 Active 대화를 Archived로 이동합니다.
9. Active/Archived 배타성과 원문 형식을 검증한 뒤 commit/push합니다.
10. fetch 후 `HEAD == origin`을 확인한 다음에만 로컬 정리와 체크포인트 갱신을 수행합니다.

Codex에서 `C`는 `sessions ∪ archived_sessions`입니다. 보관함에 있는 동안에는 아직 삭제된 것이
아니며, 보관함에서 최종 삭제되어 두 위치 모두에서 사라졌을 때만 삭제로 판정합니다.

## Codex Restore

`Restore-ArchivedSession.ps1`은 선택한 대화를 Vault Archived에서 Active로 즉시 이동하고 별도
commit/push로 확정합니다.

```powershell
.\Launchers\Restore-ArchivedSession.ps1
.\Launchers\Restore-ArchivedSession.ps1 <세션-ID-일부>
```

복원 상태를 Vault에 commit/push한 뒤 앱이 열려 있으면 정상 종료를 요청합니다. 제한시간 안에
닫히지 않으면 강제 종료하거나 로컬 파일을 쓰지 않습니다. 이때 Vault의 Active 전환은 이미
유효하며 다음 Start가 로컬 배치를 완료합니다. 정상 종료가 확인되면 로컬 파일을 배치하고 앱을
다시 실행합니다.

복원은 데이터와 Vault 상태 전환을 보장하지만 Codex 사이드바의 즉시 표시는 보장하지 않습니다.
표시되지 않으면 앱을 다시 실행하고, 그래도 표시되지 않으면 앱을 업데이트한 뒤 Start를 다시
실행합니다. `restoredAt` 같은 별도 유예 필드는 만들지 않습니다.

## Codex 판정 기준

- canonical ID는 파일명이 아니라 첫 `session_meta.payload.id` 또는 `session_id`에서 읽습니다.
- 같은 thread의 여러 page 파일은 canonical ID 하나로 묶습니다.
- 마지막 활동 시각은 모든 page의 최상위 레코드 중 timestamp가 있는 마지막 레코드로 판정합니다.
- 파일 mtime, 파일명 날짜, Git commit 시각은 활동 시각으로 쓰지 않습니다.
- `state_5.sqlite`를 복사하거나 직접 수정하지 않습니다.
- 지원하지 않는 `session_meta` 구조나 상충하는 ID가 발견되면 변경 전에 중단합니다.

Codex 데이터 형식은 Start와 Finish마다 원문에서 다시 확인합니다. 앱이 열린 뒤 업데이트될 수
있으므로 Start의 판정 결과를 Finish에서 재사용하지 않습니다. 오래된 지원 형식은 adapter로 읽을
수 있지만, 알 수 없는 형식을 추측해서 변환하지 않습니다.

## Git 실패 처리

- Push가 거부되면 자동 merge, `-X ours`, 자동 재시도를 수행하지 않습니다.
- 로컬 commit이 이미 만들어졌다면 원격이 변하지 않은 경우 같은 commit을 다시 Push합니다.
- 로컬과 원격이 모두 진행된 분기 상태라면 중단하고 사용자가 판단합니다.
- Push 실패 전에는 로컬 세션 정리와 체크포인트 갱신을 하지 않습니다.

## 설치

private Vault를 두 PC에 clone하고 각 PC에서 초기화합니다.

```powershell
git clone https://github.com/<YOU>/<PRIVATE-SESSION-VAULT>.git C:\Project\MultiAgent\AgentSessionVault
cd C:\Project\MultiAgent\AgentSessionVault
.\Launchers\Initialize-AgentSessionSync.ps1 `
  -EnableSessionPush
```

두 PC의 원본 프로젝트 절대경로는 같게 유지합니다. 최초 Start 전에는 동기화 대상 앱 저장소를
정리해 비어 있는 상태로 시작해야 합니다. 기존 세션이 남아 있으면 자동 흡수하지 않고 초기 정리
절차를 먼저 수행합니다.

자세한 설치 과정은 [Windows 설치](docs/SETUP_WINDOWS.md), 실패 대응은
[문제 해결](docs/TROUBLESHOOTING.md)을 참고하세요.

## Vault 예시

`examples/session-store`는 실제 대화가 아닌 합성 placeholder입니다.

```text
Claude/sessions/<cwd-key>/<session-id>.jsonl
Claude/sessions/<cwd-key>/<session-id>.entry.json
Claude/archive/<cwd-key>/*.jsonl
Claude/archive/<cwd-key>/*.entry.json
Codex/session_index.jsonl
Codex/session_projects.jsonl
Codex/sessions/<cwd-key>/YYYY/MM/DD/*.jsonl[.gz]
Codex/archive/<cwd-key>/YYYY/MM/DD/*.jsonl[.gz]
```

공개 저장소나 예제에 실제 대화, 자격 증명, 앱 DB, 에이전트 메모리를 넣지 마세요.

## 검사

```powershell
.\Launchers\tests\Test-AgentLauncher.ps1
.\Launchers\tests\Test-AgentSessionSync.ps1
```

테스트는 임시 Git 저장소와 임시 프로필을 사용하며 실제 사용자 세션을 수정하지 않아야 합니다.
