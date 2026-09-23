# ChatGPT 보정 제안

Framepick은 선택한 사진을 분석해 편집기의 노출·색상·선명도·노이즈·비네트·얼굴 피부 보정값을 제안받는다. 결과는 JSON으로 검증한 수치와 한국어 설명이며, 실제 픽셀 보정은 Mac에서 실행된다. 생성형 이미지 편집, 얼굴 형태 변경, 인물 식별, Photoshop 전체 기능을 제공하는 연결은 아니다.

## 인증 방식과 이용 조건

공식 Codex CLI의 `app-server`가 제공하는 **관리형 ChatGPT OAuth**를 사용한다. `account/login/start`에 `type: chatgpt`를 보내면 Codex가 로그인 주소와 로컬 콜백을 제공한다. 브라우저는 사용자가 로그인 버튼을 눌렀을 때만 열며, 토큰 발급·저장·갱신은 Codex가 처리한다. Framepick은 OAuth 클라이언트 ID를 복제하거나 기존 Codex 인증 파일을 읽지 않는다. 이는 일반 OpenAI API에 임의로 ChatGPT 구독 토큰을 붙이는 방식과 다르다. [공식 app-server 인증 문서](https://learn.chatgpt.com/docs/app-server), [Codex 인증 안내](https://learn.chatgpt.com/docs/auth).

공식 Codex CLI를 별도로 설치해야 하며 계정의 Codex 이용 권한, 정책과 사용 한도가 적용된다. 특정 모델을 고정하지 않고 계정에서 사용할 수 있는 기본 모델을 따른다. 모델이 사진 입력 또는 구조화 응답을 지원하지 않으면 오류를 표시하고 편집값은 변경하지 않는다. [CLI 설치 안내](https://learn.chatgpt.com/docs/cli).

## 구현

- `CodexAIService.shared`: 연결, 계정 확인, 로그인·취소·로그아웃, 사진 분석, 분석 취소를 관리한다.
- `AISettingsView`: CLI 탐지와 직접 선택, 계정 상태, 로그인, 사진 전송 설명을 제공한다.
- `suggest(imageURL:instructions:)`: 최대 1,600px JPEG를 새로 인코딩한다. 원본 이름·GPS·EXIF는 전송용 이미지에 복사하지 않는다. 요청 내용과 선택 이미지 한 장을 `localImage` 입력으로 보낸다.
- `outputSchema`는 허용된 15개 보정 항목과 설명만 받는다. 응답을 다시 검사해 추가 키, 누락, 범위를 벗어난 수치, Boolean 값을 거부한다. 수치는 원본 기준 절대값이다. 따라서 편집기는 원본 사진을 분석 대상으로 전달해야 한다.
- stdio NDJSON에서 응답 ID, UTF-8 분할 입력, 최종 메시지와 완료 이벤트를 처리한다. RPC는 기본 25초, 분석은 180초, 로그인은 300초로 제한한다.

앱 데이터의 `~/Library/Application Support/Framepick/AI`를 전용 `CODEX_HOME`으로 사용한다. 사용자 기존 `~/.codex` 세션·설정과 분리되며, 인증 저장도 이 공간에 Codex가 관리한다. 환경 변수는 운영체제 실행에 필요한 항목만 전달해 부모 프로세스의 API 키를 상속하지 않는다. 선택 사진의 전송용 파일은 전용 Scratch 하위 UUID 폴더에 저장하고 요청이 끝나면 삭제한다. 디렉터리 권한은 0700, 전송 이미지 권한은 0600이다. 비정상 종료 시 남은 Scratch 파일은 다음 실행에서 자동 전송하지 않는다.

## 도구 접근 제한

전용 작업 디렉터리와 임시 스레드를 사용한다. `approvalPolicy: never`, 읽기 전용 sandbox, 도구의 네트워크 접근 금지를 설정하고 shell, code mode, 브라우저, computer use, 이미지 생성, view-image, 앱·플러그인, 서브에이전트, hooks, 메모리·스킬 탐색 기능을 명시적으로 끈다. 웹 검색도 비활성화한다.

`--strict-config`로 알 수 없는 설정을 거부하고, 초기화 후 `config/read` 결과에서 기능 비활성화를 재확인한다. 활성 MCP 서버가 발견되면 연결을 중단한다. 서버가 보내는 명령 실행·승인·도구·외부 토큰 요청은 모두 거절하며, Framepick에 임의 명령 실행 기능은 없다. 앱은 인증 URL, 토큰 또는 이미지 내용이 포함될 수 있는 stdout/stderr를 로그로 기록하지 않는다. CLI 오류는 일반화된 안내와 오류 코드로 표시한다.

이 설정은 Codex CLI 0.155.1의 생성된 JSON 스키마와 설정 스키마에서 확인했다. 프로토콜 변경이나 관리자의 강제 정책으로 필요한 제한을 설정할 수 없으면 연결이 실패한다. CLI 업데이트 후 호환성 확인이 필요할 수 있다.

## 검증 범위

`swift test --filter CodexAITests`는 실제 로그인·모델 요청 없이 다음을 검증한다.

- 분할 NDJSON/UTF-8와 크기 제한, 응답 ID 대응, 서버 요청 거부
- RPC 취소, 타임아웃과 연결 종료
- 구조화 제안값 검증, 공식 HTTPS 로그인 주소 제한, 도구 제한 설정 확인
- 전송본 크기 제한·GPS 제거·원본 보존

별도 빈 임시 `CODEX_HOME`에서 설치된 CLI로 `initialize → initialized → config/read → account/read`를 실행해 연결 형식, 비활성 도구 설정과 비로그인 상태를 확인했다. 이 검증은 로그인이나 사진 전송을 수행하지 않았다. 실제 OAuth 완료 및 사용자 계정의 온라인 분석은 사용자가 앱에서 로그인한 후 확인해야 한다.
