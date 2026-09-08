# Windows 설치

2026-09-06 구현 기준입니다. 기존 도구의 `Agents/*.psd1`과
Pull/Push-Sessions 진입점은 현재 배포본에서 제거했습니다. 체크포인트 파일과
`-EnableSessionPush` 옵션도 사용하지 않습니다.

## 1. 비공개 설치본 준비

공개 AgentSessionSync의 사본을 사용자의 비공개 Git 저장소로 준비합니다.
그 사본 안에 실행 파일과 Vault 데이터가 함께 존재합니다. 공개 원본에서는 Initialize를 실행하지 마세요.
원격에는 `origin/main`을 준비하고, 첫 앱 게시 전에 비공개 저장소인지와 Git 인증을 확인합니다.
Initialize는 원격을 만들거나 저장소 공개 여부를 변경하지 않습니다.

```powershell
git remote -v
git status
.\Launchers\Initialize-AgentSessionSync.ps1
```

Windows PowerShell 5.1 이상, Git for Windows와 대상 데스크톱 앱이 필요합니다.
Codex는 설치된 앱 backend와 측량된 SQLite 구조를 사용합니다.
Claude의 필요한 영구 배치 정리는 Edge의 격리 저장소 처리를 사용하며,
앱이 닫혀 있고 원본 저장소가 변하지 않았음을 확인합니다. 미확인 구조는 추측해서 쓰지 않습니다.

## 2. 머신 설정 확인

Initialize가 만드는 `AgentSessionSync.config.psd1`을 확인합니다.
`Codex`와 `Claude` 블록의 `Enabled`, `Home`, `AppId`, `ProcessNames`, Claude의 `AppData`가
이 PC의 실제 설치를 가리켜야 합니다. `VaultRoot` 설정은 없습니다.
설정은 Git에서 제외되며 다른 PC는 자기 설정을 생성합니다.
기존 설정·바통은 Initialize 재실행으로 초기화하지 않습니다.

기본 정책은 대화 활동 30일, 운송 한도 99,614,720바이트, 정상 종료 대기 8초입니다.
임의의 앱 버전 허용 목록을 설정하지 않습니다.
`AcknowledgedMissingLineage`는 기본 빈 맵이며, 사용자가 확인한 과거 계보 손실만 명시합니다.
일반 결손을 통과시키기 위해 자동으로 채우면 안 됩니다.

## 3. 첫 게시와 수신

현재 PC에 보존할 대화가 있고 원격 세션이 비어 있으면 **Initialize → Finish**로 처음 게시합니다.
먼저 Start해서 기존 대화를 폐기하지 마세요. 최초 Finish는 정상적인 신규 게시입니다.
Finish 전 사용자가 미리 커밋할 필요는 없습니다. Git 추적 대상 미커밋 변경은 함께 수집합니다.

다른 PC는 같은 private Vault를 clone하고 **Initialize → Start → 작업 → Finish** 순서로 사용합니다.
처음부터 앱 저장소를 수동으로 전부 지우라는 요구는 없습니다.
Start의 미게시 작업 폐기 확인과 앱별 매핑·구조 검사 결과를 읽고 처리합니다.
프로젝트 경로나 앱 매핑 차이가 보고되면 임의로 경로를 바꾸거나 자료를 삭제하지 않습니다.

Finish → 추가 작업 → Finish도 가능합니다. 다른 PC가 바통을 소유하면 Finish는 중단합니다.
Start는 원격을 받는 동작이므로 미게시 작업을 살릴 필요가 있으면 **바로 Start하지 말고**
보고를 바탕으로 보존·충돌 처리 지시를 먼저 정합니다.

## 4. All-Start / All-Finish 연결

외부 워크벤치 어댑터가 가리킬 toolRoot는 공개 배포 원본이 아닌 **private Vault 설치본**입니다.
등록 스크립트는 `Launchers/Start.ps1`, `Launchers/Finish.ps1`입니다.
Initialize는 다른 워크벤치 저장소의 등록부를 수정하지 않습니다.
설치본 업데이트는 사용자가 정한 시점에 코드·문서를 복사하는 작업이지 자동 업데이트가 아닙니다.

이 대화에서 사용한 All 실행기는 로그를 남기고 실패 시 엽니다. 독립 사용자의 직접 스크립트 실행에도
같은 로그 UI가 자동 제공된다고 가정하면 안 됩니다. 직접 실행 시에는 콘솔 결과를 보존하세요.

Reactivate는 [마감 보고](IMPLEMENTATION_CLOSEOUT_2026-09-06.md)의 호출 범위 불일치를 수정하기 전까지 보류합니다.
