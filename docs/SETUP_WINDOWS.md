# Windows 설치

## 1. 실행환경을 맞춥니다

두 PC에서 같은 설치 방식과 프로젝트 절대경로를 사용합니다. 앱은 Start 이후 업데이트될 수 있으므로
세션 데이터 형식은 매 Start와 Finish에서 다시 검사합니다.

## 2. Private Vault를 clone합니다

```powershell
git clone https://github.com/<YOU>/<PRIVATE-REPO>.git C:\Project\MultiAgent\AgentSessionVault
```

실제 대화가 들어가는 저장소는 반드시 private이어야 합니다. Git 이력에는 삭제 전 원문이 남습니다.

## 3. 기존 앱 데이터를 정리합니다

첫 Start 전에 동기화 대상 앱의 세션 저장소가 비어 있어야 합니다. 남길 대화를 선별해야 한다면 먼저
별도 백업하고, 초기 정리 절차로 삭제 범위를 확정합니다. 새 도구는 첫 실행에서 출처를 모르는 기존
원문을 임의로 Vault에 흡수하지 않습니다.

Codex는 `sessions`, `archived_sessions`, 세션 인덱스를 함께 확인합니다. 앱 DB를 직접 수정하지
않습니다.

Claude는 `~/.claude/projects`의 원문뿐 아니라 앱 목록의 `local_*.json`과 `deleted_*` 마커까지
비어 있어야 합니다. 삭제 마커만 남아 있어도 이전 설치의 삭제 판정을 안전하게 복구할 수 없으므로
첫 Start를 중단합니다.

## 4. PC별 설정을 만듭니다

```powershell
cd C:\Project\MultiAgent\AgentSessionVault
.\Launchers\Initialize-AgentSessionSync.ps1 `
  -EnableSessionPush
```

머신별 설정과 바로가기는 Git에 넣지 않습니다. 대화는 프로젝트별이 아니라 앱 전체 단위로
동기화합니다. 프로젝트 소스 동기화는 이 도구의 범위가 아닙니다.

## 5. 등록 앱과 바로가기를 확인합니다

`Agents\*.psd1`에서 사용하지 않는 앱은 `Enabled = $false`로 바꿉니다. 설치 중 생성된 Start와
Finish 바로가기를 작업 표시줄에 고정합니다. Restore는 필요할 때 PowerShell에서 실행합니다.

## 6. 운용합니다

- 작업 시작: Start
- 작업 종료 및 전달: Finish
- 오래된 대화 복원: `Restore-ArchivedSession.ps1`

Finish는 사전검사를 통과한 뒤 정상 종료를 요청하고, 트레이 상주 프로세스가 남으면 등록된 앱의
검증된 루트 프로세스 트리만 강제 종료합니다. Restore는 정상 종료만 요청하며 실패하면 중단합니다.

baton과 checkpoint는 보조 정보입니다. 소유권 또는 HEAD 불일치는 경고하지만 Finish를 막지 않습니다.
Push가 거부되면 최대 3회 원격과 merge로 합류하며, 같은 경로가 겹치면 현재 호스트 사본이 우선됩니다.

지원 앱은 Claude와 Codex입니다. 다른 에이전트를 자동 등록하는 구조는 제공하지 않습니다. 필요하면
MIT 라이선스에 따라 별도 포크에서 저장 형식과 삭제 판정을 구현해야 합니다.
