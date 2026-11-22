# aiui — 안경 에이전트 '내메모'

> 이 폴더는 공개 저장소 [naeric-crypto/memex-aiui](https://github.com/naeric-crypto/memex-aiui) 로 자동 복사된다(10분 안, `test/` 제외).
> Studio 는 그 공개 저장소를 가져간다. 여기에 비밀·서버 경로·실명을 넣지 않는다. 고치는 곳은 원본(비공개) 저장소뿐이다.

AIUI Studio Global 이 가져오는 폴더. 이 폴더만으로 완결된다(`test/` 만 `../gateway` 를 불러 쓰고 패키지에서는 빠진다).

| 파일 | 내용 |
|---|---|
| `AGENTS.md` | AIX 에이전트 신원 파일(코딩 규칙 아님): 하는 일, 지키는 것 |
| `app.json` | 이름 `내메모`, 페이지 1개, 권한 `RECORD_AUDIO`·`INTERNET` |
| `app.js` | 앱 수준 오류 기록만 |
| `config.js` | 게이트웨이 주소(한 곳), 토큰 저장 키. 비밀 없음 |
| `lib/api.js` | 게이트웨이 HTTP 클라이언트(`docs/contract.md` 그대로) |
| `lib/flow.js` | 조회 반복·문구·음성 결과 해석 등 런타임 없이 시험되는 로직 |
| `pages/index/index.ink` | 화면 하나: 페어링 → 대기 → 듣기 → 찾기 → 답 / 오류 |
| `test/` | Node 시험 48개. `node --test "aiui/test/*.test.mjs"` |
| `.aixignore` | 패키지에서 뺄 파일 |

## 동작

- 열릴 때 시스템 비서가 `question` 을 넘기면 바로 찾는다(`schema.data.question`). 500자를 넘으면 자르지 않고 알린다.
- 없으면 "탭하고 질문하세요" → 관자놀이 탭(`Enter`) 또는 화면 탭 → `SpeechRecognition`(`ko-KR`, 확정 결과만) → 말을 마치면 자동 전송.
  인식 오류·무매치면 보내지 않는다. 종료 이벤트가 오지 않아도 결과 뒤 1.5초, 멈춤 요청 뒤 3초, 듣기 시작 뒤 15초에 스스로 끝낸다.
- 토큰이 없으면 페어링: 연결 창이 닫혀 있으면 5초마다 다시 신청하며 안내하고, 열리면 6자리 코드를 크게 띄운 뒤 3초마다 승인을 확인한다(안경 쪽 만료 뒤 130초까지, 서버가 404 로 확정할 때까지).
  401 이 오면 토큰을 지우고 다시 페어링한다. 이번 실행에서 받은·지운 토큰이 저장소보다 앞선다(저장소 쓰기가 막혀도 동작).
- 질문마다 `request_id` 를 만든다. 보내기 단계에서 실패하면 같은 값으로 다시 보내고, 접수 뒤 조회가 끊기면 같은 작업을 다시 조회한다(중복 실행 없음).
- 음성은 듣기마다 세션을 만들고, 가리거나 새로 들으면 이전 세션의 콜백을 떼어 낸다(늦은 이벤트가 질문을 보내지 못한다).
- 답은 1초마다(`Retry-After` 가 있으면 그만큼) 조회, 처음 보낸 시각부터 120초가 절대 마감. 위아래(쓸기)는 기본 스크롤에 맡긴다.
- 화면이 가려지면 조회를 멈추고, 보내던 요청의 결과는 보관했다가 다시 보일 때 이어 간다.
- 상태는 글자와 기호 둘 다로 보인다(○ 대기 · ● 듣는 중 · … 찾는 중 · ✓ 완료 · ▲ 오류 · ◇ 연결), 오류는 점선 테두리도.

## 검사

```bash
node --test "aiui/test/*.test.mjs"
npx -y @yodaos-pkg/aix-cli@0.13.0 check aiui --format json      # 진단 0건
npx -y @yodaos-pkg/aix-cli@0.13.0 pack aiui -o /tmp/memex-aix/naememo.aix
npx -y @yodaos-pkg/aix-cli@0.13.0 show /tmp/memex-aix/naememo.aix
node scripts/preview-shots.mjs /tmp/memex-shots                  # 공식 Ink 런타임으로 렌즈 화면 PNG
```

## 근거 문서 (`.ref/AIUI/` 기준)

| 쓴 것 | 근거 |
|---|---|
| `export default`, `.ink` 네 블록, `setData` | `skills/aiui-dev/references/framework.md`, `apis/framework.md` |
| `description` + `schema.data` 로 질문 받기, `onLoad(query)` | `documentation/1-framework/open-agent-format/page-definition.en-US.md`, `0-guide/quickstart/first-chat.en-US.md` |
| `agentName`·`agentDesc`(app.json) | 공식 샘플 `samples/realtime-voice-intelligence/app.json`, `aix show` 로 반영 확인(앱 문서엔 없음) |
| `onLoad`/`onShow`/`onHide`/`onUnload`, `onKeyUp` `Enter`(확인), 위아래·뒤로 기본 동작 | `references/events.md`(GlobalHook 은 확인/뒤로를 구분하지 못한다고 해 쓰지 않음) |
| `SpeechRecognition`(`lang`, `interimResults=false`, `continuous`, `maxAlternatives`, 이벤트) | `references/apis/ai.md` §SpeechRecognition("final result delivery"), 공식 샘플 `samples/capabilities/pages/speech/index.ink` |
| 권한 `RECORD_AUDIO`, `INTERNET` | `references/framework.md` §Permissions, `documentation/1-framework/open-agent-format/app-json.en-US.md` |
| `fetch`(`method`·`headers`·`body`·`timeout`), `Response.json()`, `headers.get` | `documentation/3-api/network/https.en-US.md`, `references/apis/web.md` §Headers |
| `crypto.getRandomValues`(요청 식별자) | `references/apis/web.md` §Web Crypto |
| 미리보기에서 질문 넘기기(`openBundle` 의 `query`) | `@yodaos-pkg/ink@0.20.1` `index.d.ts` — 시험 도구에서만 씀 |
| `localStorage` | `references/apis/web.md` §localStorage |
| 프로젝트 ES 모듈 상대 경로 import | `references/framework.md` §Modules, 샘플 `realtime-voice-intelligence/pages/realtime/index.ink` |
| `<view>`·`<text>`, `ink:if`/`ink:else`/`ink:for`/`ink:key`, `bindtap` | `references/components.md`, `framework.md`, `events.md` |
| 스타일 속성·선택자(클래스 선택자만) | `references/wxss.md`, 색·크기는 `references/design/monochrome-green.md`(글자 22·14·12px 세 단계, 본문 72%·핵심 100%) |
| `.aixignore` | `documentation/7-tools/cli.en-US.md` §aix pack |

## 확인 못 한 것

`docs/status.md` 의 B·C 표. 특히 한국어 음성 인식, 시스템 비서의 `question` 전달, 템플 탭 = `Enter`·쓸기 = 위아래 키 여부는 실기기에서만 확인된다.
