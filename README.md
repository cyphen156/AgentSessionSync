# AgentSessionSync

Windows PC 사이에서 Claude Code와 Codex의 **프로젝트별 대화 세션**을 Git push/pull로 운반하는 도구입니다.

이 공개 저장소에는 스크립트와 예제만 있습니다. 실제 대화는 들어 있지 않습니다. 공개 저장소를 직접 운반 저장소로 쓰지 말고, GitHub의 **Use this template**로 본인 소유의 **Private 저장소**를 만든 뒤 사용하세요.

## 동기화 대상

- Claude 프로젝트별 `*.jsonl` 세션과 앱 목록 레지스트리
- Codex rollout `*.jsonl`과 `session_index.jsonl`
- 선택 사항: 대상 프로젝트 Git 저장소

`auth.json`, 토큰 설정, 앱 DB, 키 파일은 동기화하지 않습니다. 커밋 전 비밀값 패턴 검사도 수행합니다. 다만 대화 본문에 비밀값이나 비공개 소스가 포함될 수 있으므로 운반 저장소는 Private이 기본입니다.

## 설치

1. 이 저장소에서 **Use this template**를 눌러 Private 저장소를 만듭니다.
2. 두 PC에서 그 Private 저장소를 클론합니다.
3. 각 PC에서 로컬 설정을 만듭니다.

```powershell
git clone https://github.com/<YOU>/<PRIVATE-SYNC-REPO>.git C:\AgentSessionSync
cd C:\AgentSessionSync
.\Initialize-AgentSessionSync.ps1 -ProjectRoot 'C:\Projects\MyProject' -EnableSessionPush
```

프로젝트 자체도 Start/Finish 때 자동 pull/push하려면 `-EnableProjectGitSync`를 추가합니다. 모든 변경을 자동 커밋하므로 기본값은 꺼져 있습니다.

## 사용

```powershell
.\1_Start-Work.cmd
# Claude/Codex 작업
.\2_Finish-Work.cmd
```

세션을 받은 뒤 앱을 완전히 재시작해야 목록이 갱신될 수 있습니다.

## 검증

```powershell
.\Test-AgentSessionSync.ps1
```

실제 사용자 세션을 건드리지 않는 임시 Git 원격과 가짜 사용자 홈으로 두 PC 왕복을 검증합니다.

자세한 설치는 [docs/SETUP_WINDOWS.md](docs/SETUP_WINDOWS.md), 문제 해결은 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)를 참고하세요.

## 지원 범위

- Windows 10/11, Windows PowerShell 5.1 이상, Git
- Claude Code와 Codex의 현재 로컬 JSONL 저장 구조

앱 내부 구조는 버전에 따라 바뀔 수 있습니다. 인증 DB를 복사하지 않고 원본 JSONL을 보존하는 범위로 제한합니다.

## License

MIT
