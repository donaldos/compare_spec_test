#!/usr/bin/env python3
"""3종 세트 완비 여부와 미처리 여부를 판정하는 게이트.

LLM 호출 전에 실행되는 순수 결정론 단계. 처리할 게 없으면 빈 배열을
내보내고 종료하므로, 평소에는 토큰을 한 톨도 쓰지 않는다.

파일명 규약: {종류}_{기기명}_{날짜}.md
  예) 사양서_DEV-A_20260804.md

stdout: JSON array of ready sets
  [{"device": "...", "date": "...", "key": "...", "files": {...}, "digest": "..."}]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

# 파일 종류 → 논리 이름. 새 문서 종류가 늘면 여기만 고친다.
DOC_KINDS: dict[str, str] = {
    "사양서": "spec",
    "테스트목록": "tests",
    "주요지침": "guideline",
}

FILENAME_RE = re.compile(
    r"^(?P<kind>%s)_(?P<device>.+)_(?P<date>\d{6,8})\.md$" % "|".join(DOC_KINDS)
)


@dataclass
class DocSet:
    device: str
    date: str
    files: dict[str, Path] = field(default_factory=dict)

    @property
    def key(self) -> str:
        return f"{self.device}__{self.date}"

    def is_complete(self) -> bool:
        return set(self.files) == set(DOC_KINDS.values())

    def digest(self) -> str:
        """내용 해시. 같은 이름으로 파일이 갱신되면 재처리 대상이 된다."""
        h = hashlib.sha256()
        for logical in sorted(self.files):
            h.update(logical.encode())
            h.update(self.files[logical].read_bytes())
        return h.hexdigest()[:16]


def scan(watch_dir: Path) -> list[DocSet]:
    groups: dict[tuple[str, str], DocSet] = {}
    for path in sorted(watch_dir.glob("*.md")):
        m = FILENAME_RE.match(path.name)
        if not m:
            continue
        device, date = m["device"], m["date"]
        ds = groups.setdefault((device, date), DocSet(device, date))
        ds.files[DOC_KINDS[m["kind"]]] = path
    return list(groups.values())


def load_state(state_path: Path) -> dict:
    if not state_path.exists():
        return {}
    try:
        return json.loads(state_path.read_text())
    except json.JSONDecodeError:
        print(f"[gate] state 파일 손상, 초기화: {state_path}", file=sys.stderr)
        return {}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, type=Path, help="감시 대상 폴더")
    ap.add_argument("--state", required=True, type=Path, help="처리 이력 JSON")
    args = ap.parse_args()

    if not args.dir.is_dir():
        print(f"[gate] 폴더 없음: {args.dir}", file=sys.stderr)
        return 1

    state = load_state(args.state)
    ready: list[dict] = []
    incomplete: list[str] = []

    for ds in scan(args.dir):
        if not ds.is_complete():
            missing = set(DOC_KINDS.values()) - set(ds.files)
            incomplete.append(f"{ds.key} (누락: {','.join(sorted(missing))})")
            continue
        digest = ds.digest()
        if state.get(ds.key, {}).get("digest") == digest:
            continue  # 이미 처리했고 내용도 그대로
        ready.append(
            {
                "device": ds.device,
                "date": ds.date,
                "key": ds.key,
                "digest": digest,
                "files": {k: str(v.name) for k, v in ds.files.items()},
            }
        )

    for line in incomplete:
        print(f"[gate] 미완성 세트 건너뜀: {line}", file=sys.stderr)
    print(f"[gate] 처리 대상 {len(ready)}건", file=sys.stderr)

    json.dump(ready, sys.stdout, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
