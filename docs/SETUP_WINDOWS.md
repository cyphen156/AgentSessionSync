# Windows 설치

## 1. Private 운반 저장소 만들기

공개 `AgentSessionSync` 저장소의 **Use this template**를 선택하고 Visibility를 **Private**으로 지정합니다. 템플릿에는 실제 세션이나 개인 저장소의 과거 Git 이력이 없습니다.

## 2. 두 PC에 클론하기

```powershell
git clone https://github.com/<YOU>/<PRIVATE-REPO>.git C:\AgentSessionSync
```

클론 경로는 PC마다 달라도 됩니다.

## 3. PC별 설정 만들기

```powershell
cd C:\AgentSessionSync
.\Initialize-AgentSessionSync.ps1 -ProjectRoot 'D:\Work\MyProject' -EnableSessionPush
```

`AgentSessionSync.config.psd1`은 Git에서 제외됩니다. 두 PC의 프로젝트 경로가 달라도 각자 실제 경로를 지정할 수 있으며, 스크립트가 Claude 프로젝트 키를 자동 계산합니다.

- `-EnableSessionPush`: 본인의 Private 운반 저장소에서만 켭니다.
- `-EnableProjectGitSync`: Start/Finish가 대상 프로젝트도 pull/add/commit/push합니다.

## 4. 매일 사용

```powershell
.\1_Start-Work.cmd
# 작업
.\2_Finish-Work.cmd
```

한 세션 UUID를 두 PC에서 동시에 수정하지 않는 것을 권장합니다. 서로 다른 새 대화는 UUID가 달라 함께 보존됩니다.

