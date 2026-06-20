# Windows 설치

## 1. Private 운반 저장소 만들기

공개 `AgentSessionSync` 저장소의 **Use this template**를 선택하고 Visibility를 **Private**으로 지정합니다. 템플릿에는 실제 세션이나 개인 저장소의 과거 Git 이력이 없습니다.

## 2. 두 PC에 클론하기

```powershell
git clone https://github.com/<YOU>/<PRIVATE-REPO>.git C:\AgentSessionSync
```

클론과 프로젝트 경로는 PC마다 달라도 됩니다.

## 3. PC별 설정 만들기

```powershell
cd C:\AgentSessionSync
.\Initialize-AgentSessionSync.ps1 -ProjectRoot 'D:\Work\MyProject' -EnableSessionPush
```

로컬 `AgentSessionSync.config.psd1`은 Git에서 제외됩니다. 프로젝트 자체도 자동 동기화하려면 `-EnableProjectGitSync`를 추가합니다.

## 4. 등록된 앱 확인

기본 `Agents\Codex.psd1`, `Agents\Claude.psd1`의 `AppId`와 `ProcessName`을 확인합니다.

```powershell
Get-StartApps | Where-Object Name -Match 'Codex|Claude'
```

사용하지 않는 앱은 해당 파일의 `Enabled = $false`로 변경합니다.

## 5. 작업 표시줄 바로가기 만들기

```powershell
.\Create-Shortcuts.ps1
```

`Shortcuts\Start.lnk`, `Shortcuts\Finish.lnk`를 작업 표시줄에 고정합니다.

## 6. 매일 사용

Start를 눌러 Pull과 에이전트 실행을 완료하고, 작업을 넘기기 전에 Finish를 눌러 정상 종료와 Push를 완료합니다.

같은 세션 UUID를 두 PC에서 동시에 수정하지 않는 것을 권장합니다. 서로 다른 새 대화는 UUID가 달라 함께 보존됩니다.
