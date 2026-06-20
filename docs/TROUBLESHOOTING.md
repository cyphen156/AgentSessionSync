# 문제 해결

## 파일은 있는데 앱 목록에 안 보임

Claude와 Codex 앱을 완전히 종료한 뒤 다시 실행합니다. Claude는 본문 JSONL 외에 `claude-code-sessions` 앱 레지스트리를, Codex는 `session_index.jsonl`을 목록 표시에 사용할 수 있습니다. 이 도구는 두 메타데이터도 함께 운반합니다.

Codex의 `state_5.sqlite` 같은 앱 DB는 인증·기기 상태가 섞일 수 있어 복사하지 않습니다. 원본 rollout JSONL이 있으면 `codex://threads/<UUID>`로 직접 열어 확인할 수도 있습니다.

## 다른 PC가 baton을 갖고 있다는 경고

이전 PC에서 Finish를 생략했다는 신호입니다. 스크립트는 경고 후 병합을 시도하지만, 아직 push하지 않은 내용은 가져올 수 없습니다.

## 비밀값 검사에서 push가 중단됨

대화 JSONL 또는 앱 레지스트리에 토큰처럼 보이는 문자열이 포함됐습니다. 검사 우회보다 해당 비밀값을 폐기·교체하고 세션 내용을 정리하는 편이 안전합니다.

## Claude 프로젝트 폴더를 못 찾음

로컬 설정의 `ProjectRoot`가 Claude를 실행한 실제 작업 경로와 같은지 확인합니다. 경로는 PC마다 다르게 설정할 수 있습니다.

