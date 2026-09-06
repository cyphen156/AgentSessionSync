# AgentSessionSync

여러 Windows PC에서 Codex와 Claude 대화를 이어 쓰는 MIT 공개 도구입니다.
공개 저장소는 배포 원본이고, 사용자가 복사해 **비공개 저장소로 준비한 설치본 자체가 Vault**입니다.
실행할 때 공개 도구 저장소를 별도로 유지할 필요는 없습니다. 실제 대화·설정·측량 원문은 공개 원본에 넣지 않습니다.

2026-09-06 기준 공통 Start/Finish와 두 앱의 실제 구현을 반영했습니다.
실사용 All-Finish 게시 및 이후 All-Start 성공이 확인됐습니다. 이것이 다른 PC의 모든 경로와
앱 UI 동작까지 검증됐다는 뜻은 아닙니다.
완료 범위, 알려진 불일치, 검증 근거와 다음 개선 후보는
[마감 보고](docs/IMPLEMENTATION_CLOSEOUT_2026-09-06.md)에 있습니다.

## 실행

```powershell
# 비공개 설치본에서 환경 준비. Start와 별도 작업입니다.
.\Launchers\Initialize-AgentSessionSync.ps1

# 로컬 대화가 먼저 있고 원격 세션이 비어 있다면 Finish로 처음 게시합니다.
.\Launchers\Finish.ps1

# 원격 상태를 앱에 적용합니다. 미게시 작업 폐기 확인을 읽고 결정하세요.
.\Launchers\Start.ps1
```

Initialize는 디렉터리, Git 바이트 보존 속성, private 추적 규칙, 머신별 설정과 바로가기를 준비합니다.
기존 설정은 덮어쓰지 않습니다. `AgentSessionSync.config.psd1`은 Git에서 제외됩니다.
원격의 공개/비공개 여부를 자동으로 보장하는 도구가 아니므로, **Initialize 전에 비공개 origin을 확인**하세요.

## 처리 기준

| 항목 | 동작 |
|---|---|
| Start | fetch → 폐기 의도 확인 → 앱 정상 종료 → 앱별 검증·적용 → 전 앱 성공 후 기준·바통 게시 → 앱 실행 |
| Finish | fetch·바통 확인 → 전 앱 종료(필요시 강제) → 앱별 검증·백업·정합화 → 전 앱 성공 시 공동 commit/push → 기준 확정 → 백업 정리 → Vault 작업트리 반영 |
| 다른 PC 바통 | Start는 경고 후 성공할 때 인수. Finish는 중단하고 Start 필요를 보고하며, 자동으로 Start하지 않음 |
| 미커밋 변경 | Finish가 Git 추적 대상 변경을 공동 게시에 포함. 사전 수집 커밋을 만들거나 로컬 작업을 원격으로 reset하지 않음 |
| 충돌 | 앱이 실제 기준·로컬·원격 세션을 비교. 같은 세션의 양쪽 변경은 보고하고 공동 게시 중단. 자동 내용 병합 없음 |
| 실패 | 게시 전 실패는 앱별 Cancel로 이번 변경 복구. 게시 여부가 불명확하면 복구·재게시를 단정하지 않고 자료 보존 |
| 버전 변경 | 보조 정보. 버전 번호만으로 차단하지 않으며 실제 구조 불일치는 보고 후 중단 |

Start는 앱 간 일부 적용이 남아도 전체 Failure입니다. 기준·바통을 전진시키지 않고 사용자가 Start를 다시 실행합니다.
Finish는 전 앱이 성공해야 게시합니다. 성공한 Finish는 앱을 다시 실행하지 않습니다.

## Vault 상태와 앱 상태

```text
Codex/Active    Codex/Archived    Codex/Deleted
Claude/Active   Claude/Archived   Claude/Deleted
Surveys/Codex   Surveys/Claude
ACTIVE_HOST.txt
```

- Vault Active는 적용 대상, Archived는 마지막 대화 활동으로부터 30일이 지난 보존 대상입니다.
- Deleted에는 원문이 아닌 최소 삭제 기록만 남습니다. 원문은 Git 과거 이력에 남을 수 있습니다.
- 앱의 보관 기능과 Vault Archived는 다릅니다. Codex native Archived는 이 도구의 운용 규약상 삭제 경유지입니다.
  Finish는 검증된 경유 상태를 백업 후 삭제 완료하고, 게시된 세션에는 Deleted를 남깁니다.
- Codex의 단순 부재는 삭제 증거가 아닙니다. 전에 수신한 Active가 설명 없이 사라지면 보고하고 멈춥니다.
- Claude 삭제는 앱이 남긴 계보 전체와 앱 세션 ID의 묘비를 확인합니다.
- Claude Finish의 Vault Archive는 앱 원본을 직접 바꾸지 않습니다. Start가 Vault 상태를 적용합니다.
- 원격 Deleted인데 로컬에 세션이 남아 있으면 조용히 넘기거나 되살리지 않고 보고합니다.

본문은 바이트 그대로 운송합니다. 95 MiB 초과 원문은 gzip, gzip도 한도를 넘으면 분할 운송합니다.
검증 마커가 같은 자료는 재압축·검증용 압축 해제를 재사용하지만, 모든 전수 읽기가 제거된 것은 아닙니다.

## 진입점과 현재 제한

공통 3개와 앱별 3개씩, 실행 파일은 9개입니다. 별도 공통 Reactivate는 없습니다.
`Launchers/Codex/Reactivate.ps1`와 `Launchers/Claude/Reactivate.ps1`은 구현돼 있지만,
**현재 게시 후 앱별 Start를 내부 호출하는 불일치가 남아 있으므로 사용을 보류합니다.**
확정 요구는 Vault의 Archived → Active 전환만 하고 앱 적용은 별도 Start에서 하는 것입니다.
이 차이는 마감 보고에 후속 수정 대상으로 남겼으며 이번 문서 정리에서 동작을 바꾸지 않았습니다.

프로젝트 소스·워크벤치 상태·에이전트 메모리는 이 도구의 동기화 대상이 아닙니다.
상시 동기화, 자동 측량, 자동 충돌 해결은 제공하지 않습니다.

- [Windows 설치](docs/SETUP_WINDOWS.md)
- [문제 해결](docs/TROUBLESHOOTING.md)
- [구현 계약](docs/IMPLEMENTATION_PLAN.md)
- [Codex 구조](docs/CODEX_SESSION_STRUCTURE.md), [Claude 구조](docs/CLAUDE_SESSION_STRUCTURE.md)
- [측량 기준](docs/SURVEY_GUIDE.md)

구 구현의 지원 스크립트·테스트·Agents 설정·예제는 삭제 승인 대기 상태로 남아 있습니다.
현재 9개 진입점은 이 파일들을 호출하지 않습니다. 구 테스트 결과를 현재 구현 검증으로 사용하지 마세요.
