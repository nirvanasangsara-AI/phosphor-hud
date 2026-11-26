# Phosphor 출시 로드맵 (GitHub → 앱스토어)

## 0단계 — 로컬 확인 (오늘)
- [x] `./scripts/build-app.sh --run` 으로 빌드·실행
- [x] `dist/Phosphor.app/Contents/MacOS/Phosphor --demo` 로 5개 테마 확인
- [ ] 실제 데이터: Claude Code / Codex / Gemini CLI 로그인 상태에서 값이 웹 화면과 맞는지 대조 (Claude·Codex는 API 원본과 일치 확인, Gemini는 이 Mac에 CLI 로그인 필요)
- [ ] 키체인 팝업 → "항상 허용"

## 1단계 — GitHub 공개 (반응 보기)
- [ ] `gh repo create nirvanasangsara-AI/phosphor-hud --public --source . --push`
- [x] 테마별 스크린샷 5장 + 테마 전환 GIF 1개 (README 맨 위, `scripts/screenshots.sh`로 재생성)
- [ ] `git tag v0.1.0 && git push --tags` → Actions가 universal 빌드 zip을 Release에 올림
- [ ] 홍보: r/ClaudeAI, r/ChatGPTCoding, r/macapps, Hacker News "Show HN", X, GeekNews
- 지표: 스타 수, 이슈로 들어오는 "이 서비스도 넣어줘" 요청 = 다음 provider 우선순위

## 2단계 — 제대로 된 배포 (Apple Developer Program, 연 $99)
- [ ] Developer ID 인증서로 서명 + notarization → "확인되지 않은 개발자" 경고 제거
- [ ] DMG + Homebrew cask (`brew install --cask phosphor`)
- [ ] Sparkle 자동 업데이트
- [ ] 앱 아이콘

## 3단계 — Mac App Store 버전 (가장 어려운 부분)
앱스토어 앱은 App Sandbox가 필수라서, 지금 구조 그대로는 못 올립니다.

| 기능 | 지금 (직접 배포) | 샌드박스에서 |
|---|---|---|
| `~/.codex`, `~/.gemini` 읽기 | 바로 읽음 | 사용자가 폴더를 한 번 선택 → security-scoped bookmark로 해결 가능 |
| Claude 토큰 (다른 앱의 키체인 항목) | `security` 로 읽음 | **불가**. 사용자가 토큰을 직접 붙여 넣거나 별도 로그인 흐름 필요 |
| CodexBar CLI / 사용자 스크립트 실행 | 바로 실행 | `~/Library/Application Scripts/<bundle id>` 에 둔 스크립트만 `NSUserUnixTask`로 실행 가능 |
| 심사 | 없음 | 비공개 엔드포인트 + 타사 자격증명 사용으로 리젝될 위험 있음 |

권장 순서: 1~2단계로 사용자 반응을 먼저 확인하고, 반응이 있으면 샌드박스 대응 빌드 타깃(`PhosphorStore`)을 따로 만들어 앱스토어에 냅니다. 무료 + 인앱 결제(테마 팩/위젯) 같은 모델을 검토할 수 있습니다.

## 다음 기능 후보
- WidgetKit 데스크탑 위젯
- 사용량 히스토리 스파크라인 / 리셋 전 소진 예측("이 속도면 3시간 뒤 한도")
- 여러 계정 지원
- 테마 SDK (JSON으로 사용자 테마)
