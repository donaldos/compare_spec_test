#!/usr/bin/env bash
# 매일 08:00 실행. 결정론 게이트 → claude -p 판단 → 엑셀 생성.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.env"

STATE="$HERE/state.json"
WORK="$HERE/work"
LOG_DIR="$HERE/logs"
mkdir -p "$WORK" "$LOG_DIR" "$OUT_DIR"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
exec > >(tee -a "$LOG_DIR/$RUN_ID.log") 2>&1
echo "=== run $RUN_ID · watch=$WATCH_DIR ==="

command -v jq >/dev/null || { echo "jq 필요: brew install jq"; exit 1; }
[[ -x "$CLAUDE_BIN" ]] || { echo "claude 실행파일 없음: $CLAUDE_BIN"; exit 1; }

# ── 1. 게이트: 처리할 세트가 있는가 ──────────────────────────────
SETS="$(python3 "$HERE/gate.py" --dir "$WATCH_DIR" --state "$STATE")"
COUNT="$(jq 'length' <<<"$SETS")"
if [[ "$COUNT" -eq 0 ]]; then
  echo "처리 대상 없음. 종료 (LLM 호출 0회)"
  exit 0
fi

# --bare: 호스트의 훅·플러그인·CLAUDE.md를 안 읽어 매일 같은 조건으로 돌린다.
BARE_FLAGS=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  export ANTHROPIC_API_KEY
  BARE_FLAGS=(--bare)
  echo "모드: bare (API key)"
else
  echo "모드: 구독 로그인"
fi

FAILED=0

# ── 2. 세트별 처리 ───────────────────────────────────────────────
for i in $(seq 0 $((COUNT - 1))); do
  SET="$(jq -c ".[$i]" <<<"$SETS")"
  KEY="$(jq -r '.key' <<<"$SET")"
  DEVICE="$(jq -r '.device' <<<"$SET")"
  DATE="$(jq -r '.date' <<<"$SET")"
  DIGEST="$(jq -r '.digest' <<<"$SET")"
  SPEC="$(jq -r '.files.spec' <<<"$SET")"
  TESTS="$(jq -r '.files.tests' <<<"$SET")"
  GUIDE="$(jq -r '.files.guideline' <<<"$SET")"

  echo "--- [$((i + 1))/$COUNT] $KEY"

  RAW="$WORK/${KEY}_${RUN_ID}.raw.json"
  MAPPED="$WORK/${KEY}_${RUN_ID}.mapping.json"
  XLSX="$OUT_DIR/매핑테이블_${DEVICE}_${DATE}.xlsx"

  PROMPT="다음 세 파일을 읽고 API-테스트 매핑 테이블을 만들어라.

주요지침: ./${GUIDE}
사양서:   ./${SPEC}
테스트목록: ./${TESTS}

기기명은 '${DEVICE}', 날짜는 '${DATE}'이다.
먼저 주요지침을 끝까지 읽고 비교 기준을 확정한 뒤, 사양서의 API 명세와
테스트목록의 API 테스트 항목을 양방향으로 대조하라.
결과는 지정된 JSON 스키마로만 출력한다."

  # cwd를 WATCH_DIR로 두면 --add-dir 없이 상대경로로 읽을 수 있고,
  # 접근 범위도 그 폴더로 자연히 제한된다.
  if ! (cd "$WATCH_DIR" && timeout "${TIMEOUT_SEC}" "$CLAUDE_BIN" \
        "${BARE_FLAGS[@]+"${BARE_FLAGS[@]}"}" \
        -p "$PROMPT" \
        --model "$MODEL" \
        --allowedTools "Read,Glob,Grep" \
        --permission-mode dontAsk \
        --append-system-prompt-file "$HERE/analysis_rules.md" \
        --output-format json \
        --json-schema "$(cat "$HERE/mapping_schema.json")") > "$RAW"; then
    echo "!! claude 실행 실패: $KEY"
    FAILED=1
    continue
  fi

  COST="$(jq -r '.total_cost_usd // "n/a"' "$RAW")"
  echo "비용: \$${COST}"

  if ! jq -e '.structured_output' "$RAW" > "$MAPPED" 2>/dev/null; then
    echo "!! structured_output 없음 — 원본: $RAW"
    jq -r '.result // .' "$RAW" | head -40
    FAILED=1
    continue
  fi

  if ! python3 "$HERE/to_excel.py" --input "$MAPPED" --output "$XLSX"; then
    echo "!! 엑셀 생성 실패: $KEY"
    FAILED=1
    continue
  fi

  # ── 3. 성공한 세트만 처리 완료로 기록 ──────────────────────────
  python3 - "$STATE" "$KEY" "$DIGEST" "$XLSX" <<'PY'
import json, sys, datetime, pathlib
state_path, key, digest, xlsx = sys.argv[1:5]
p = pathlib.Path(state_path)
state = json.loads(p.read_text()) if p.exists() else {}
state[key] = {
    "digest": digest,
    "processed_at": datetime.datetime.now().isoformat(timespec="seconds"),
    "report": xlsx,
}
p.write_text(json.dumps(state, ensure_ascii=False, indent=2))
PY
  echo "완료 → $XLSX"
done

echo "=== 종료 (failed=$FAILED) ==="
exit "$FAILED"
