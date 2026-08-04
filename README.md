# API-테스트 매핑 자동화 (`claude -p` + 스케줄러)

매일 08:00에 지정 폴더를 확인해, 새로 올라온 `사양서 / 테스트목록 / 주요지침`
3종 세트를 대조하고 일치도(상·중·하)가 매겨진 엑셀 리포트를 만든다.

## 설계 원칙

`claude -p`는 **판단만** 한다. 파일 탐지, 중복 방지, 엑셀 생성은 전부 파이썬이 맡는다.

```
gate.py           결정론  3종 완비 + 미처리 판별 → 없으면 종료 (토큰 0)
  ↓ JSON
claude -p         LLM     주요지침 해석 + 매핑 + 상/중/하 판정
  ↓ structured_output (스키마 강제)
to_excel.py       결정론  4시트 엑셀 생성
  ↓
state.json        성공한 세트만 처리 완료 기록
```

이렇게 나누는 이유:

- **비용** — 새 파일이 없는 날은 LLM을 아예 안 부른다. 게이트가 없으면 매일
  전체 폴더를 읽는 세션이 뜬다.
- **재현성** — `--json-schema`로 출력 구조를 강제해서 "어떤 날은 표로, 어떤
  날은 문단으로" 나오는 문제를 없앤다. 엑셀 서식은 LLM이 손대지 않는다.
- **감사 추적** — 원본 응답(`work/*.raw.json`)에 세션 ID·토큰·비용이 남는다.
- **재시도 안전성** — 세트 단위로 실패가 격리되고, 실패한 세트는 state에
  기록되지 않아 다음 날 자동으로 다시 시도된다.

## 파일

| 파일 | 역할 |
|---|---|
| `config.env` | 폴더 경로, 모델, 타임아웃 |
| `gate.py` | 파일명 파싱, 세트 그룹핑, 내용 해시 기반 미처리 판별 |
| `analysis_rules.md` | `--append-system-prompt-file`로 주입. 상/중/하 기준의 단일 출처 |
| `mapping_schema.json` | `--json-schema`로 주입. LLM 출력 계약 |
| `to_excel.py` | 매핑 JSON → 4시트 xlsx |
| `run_daily.sh` | 오케스트레이터 |
| `com.user.apimapper.plist` | macOS launchd 스케줄 |
| `_sample/` | 동작 확인용 더미 3종 세트 + 예시 결과물 |

## 핵심 호출

```bash
cd "$WATCH_DIR" && claude --bare \
  -p "$PROMPT" \
  --model opus \
  --allowedTools "Read,Glob,Grep" \
  --permission-mode dontAsk \
  --append-system-prompt-file analysis_rules.md \
  --output-format json \
  --json-schema "$(cat mapping_schema.json)"
```

플래그별 의도:

- `--bare` — 호스트의 훅·플러그인·`CLAUDE.md`·MCP 자동 탐색을 건너뛴다.
  다른 프로젝트 설정이 결과에 새어 들어오는 걸 막고 기동도 빨라진다.
  단 구독 로그인을 쓰지 않으므로 `ANTHROPIC_API_KEY`가 필요하다.
  `config.env`에서 키를 비워 두면 bare 없이 구독 자격증명으로 돌아간다.
- `--allowedTools "Read,Glob,Grep"` + `--permission-mode dontAsk` — 읽기만
  허용. 쓰기·Bash가 없으니 문서 폴더를 건드릴 수 없고, 권한 프롬프트에서
  멈춰 크론이 무한 대기하는 사고도 안 난다.
- `cd "$WATCH_DIR"` — cwd를 대상 폴더로 두면 `--add-dir` 없이 상대경로로
  읽히고, 접근 범위도 자연히 그 폴더로 좁혀진다.
- `--json-schema` — 결과가 `.structured_output`에 스키마대로 담긴다.
  파싱이 실패하면 그건 곧 LLM 응답 이상 신호라 로그로 잡힌다.

## 설치

```bash
brew install jq
pip3 install openpyxl

cp -r api-test-mapper ~/api-test-mapper
cd ~/api-test-mapper
chmod +x run_daily.sh gate.py to_excel.py

# 1) 경로 설정
vi config.env            # WATCH_DIR, OUT_DIR, CLAUDE_BIN (= $(which claude))

# 2) 수동 실행으로 검증
./run_daily.sh

# 3) 스케줄 등록
sed -i '' "s|/Users/USERNAME|$HOME|g" com.user.apimapper.plist
cp com.user.apimapper.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.apimapper.plist
```

`cron` 대신 `launchd`를 쓰는 이유는, 08:00에 맥이 자고 있었어도 깨어난 직후
한 번 실행해주기 때문이다. cron은 그 실행을 그냥 건너뛴다.

확인:

```bash
launchctl list | grep apimapper
tail -f logs/*.log
```

## 운영 중 손볼 곳

| 증상 | 고칠 파일 |
|---|---|
| 상/중/하 기준이 감과 다름 | `analysis_rules.md` — 등급 기준 절만 수정 |
| 필요한 컬럼이 없음 | `mapping_schema.json` + `to_excel.py`의 `MAPPING_COLS` |
| 문서 종류가 늘어남 (예: 변경이력) | `gate.py`의 `DOC_KINDS` 딕셔너리 |
| 파일명 규칙이 다름 | `gate.py`의 `FILENAME_RE` |
| 특정 세트를 다시 돌리고 싶음 | `state.json`에서 해당 키 삭제 |

## 검증됨

- `gate.py`: 3종 완비 감지, 미완성 세트 스킵, 동일 digest 재실행 시 0건,
  원본 수정 시 재처리 대상 복귀
- `to_excel.py`: 다대다 전개(API 2건 → 3행), 일치도별 색상, 4시트 생성
- `run_daily.sh` 문법, plist 파싱, 스키마 유효성

`claude -p` 실제 호출은 로컬에서 `./run_daily.sh`로 확인할 것.
`_sample/`을 `WATCH_DIR`로 지정하면 바로 테스트할 수 있다.

## 한계

- LLM 판단이라 같은 입력에도 등급이 흔들릴 수 있다. `rationale` 컬럼을
  근거 삼아 몇 주 돌려보고, 반복해서 틀리는 패턴이 보이면 `analysis_rules.md`의
  기준 문구를 조이는 게 정석이다.
- 문서가 아주 길면 컨텍스트를 넘길 수 있다. 그 시점에는 사양서 파싱을
  파이썬으로 내리고 LLM에는 후보 쌍만 넘기는 A안 하이브리드로 옮겨야 한다.
- 맥이 꺼져 있으면 실행되지 않는다. 상시 실행이 필요하면 리눅스 서버 +
  systemd timer로 같은 스크립트를 그대로 옮기면 된다.
