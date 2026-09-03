# meeting

## 목적 (WHY)

녹음 → 전사 → 요약 → vault 저장 파이프라인의 **정본**. 단독 미팅 앱과 다른 호스트 앱이 같은 패키지를 소비한다 —
두 벌을 따로 고치지 않기 위해 라이브러리로 산다. 실측으로 얻은 규칙(아래 HOW)은 여기서만 고친다.

## 구조 (WHAT)

| 타깃 | 내용 | 의존 |
|---|---|---|
| Sources/MeetingCore | 모델·MeetingCenter·녹음(Core Audio 탭)·전사 2패스·에코 접기·요약 프롬프트·vault 내보내기·통화 감지·`ClaudeSummarizer`·`SQLiteMeetingStore`·`MeetingAssembly`·`Resources/diarize.py` | 시스템 프레임워크만 — 테스트는 전부 여기 |
| Sources/MeetingWhisper | WhisperKit 어댑터 3개(로더·파일 전사·라이브) | WhisperKit |
| Sources/MinimalUI | 디자인 토큰·컴포넌트·markdown 뷰 — 호스트가 자기 사본 대신 쓴다 | SwiftUI |
| Sources/MeetingUI | `MeetingSession`(호스트가 임베드하는 ObservableObject) + 미팅 화면 | MeetingCore, MinimalUI |
| Sources/MeetingApp | 얇은 실행 타깃 — 조립·설정 화면·에셋 | 위 넷 |
| Tests/MeetingCoreTests | swift-testing, 프로토콜 페이크 + `SQLiteMeetingStore.inMemory()` | |
| scripts/ | `package-app.sh`(손조립 .app)·`setup-diarization.sh`·`deploy.sh` | |

호스트 심(seam)은 넷뿐이다: `MeetingStoring`(저장소 6메서드)·`MeetingNotifying`(notice)·`MeetingSummarizing`·`MeetingSettings` 값.
경로·이름은 `MeetingHostProfile(appSupportName:)`에서 전부 유도한다 — 패키지는 호스트가 누구인지 모른다. 호스트 이름·경로·동기화 절차는 호스트 레포가 적는다.

## 작동·규칙 (HOW)

- 빌드·테스트: `swift build && scripts/test.sh` — 수정 후 필수. Xcode 없는 머신(CLT만)은 swift-testing의 `_Testing_Foundation` 오버레이가 빠져 `swift test`가 안 돌고, 래퍼가 그 플래그를 채운다(Xcode가 있으면 `swift test`로 위임). 공개 API를 바꿨으면 이 패키지를 경로 의존으로 받는 호스트 앱도 빌드한다(작업 트리가 즉시 반영된다). 커밋은 이 레포 먼저
- `Meeting`의 Codable 키·`"meeting"` kind·`MeetingCenter.summaryFailurePrefix`("요약 실패")는 **변경 금지** — 호스트 DB의 기존 행이 그대로 읽히고 `Meeting.reprocessesSummaryOnly`가 그 접두로 [요약 다시]를 판정한다
- 저장 엔티티에 필드를 더할 때는 수동 `init(from:)` + `decodeIfPresent` — 저장소는 디코드 실패 행을 조용히 버려 기존 데이터가 목록에서 사라진다
- 상태 전이는 `store.mutateMeeting` 한 연산의 test-and-set — 조회 후 따로 upsert하면 삭제된 미팅이 되살아난다
- **공개 저장소다.** 사내 고유명사·실제 회의 발화·동료 실명을 코드·주석·테스트 픽스처에 넣지 마라. 실측에서 얻은 것은 *모양*(끊기는 자리·비율·경계값)만 남기고 내용은 지어낸 것으로 바꾼다
- 요약기(`claude` 경로)와 노트 저장(vault 경로)은 **둘 다 선택**이다 — 설정이 비면 `MeetingAssembly`가 꽂지 않고 `summaryNotice`/`vaultNotice`로 알린다. 끈 것을 실패로 만들지 마라(analyzer가 nil이면 전사까지로 미팅이 정상 완료된다)
- vault를 쓸 때 요약의 정본은 **노트 파일**이고 `Meeting.summary`는 폴백 캐시다(vault가 꺼져 있으면 그게 유일본이다). 쓰는 건 앱(`MeetingVaultExporter`)이지 세션이 아니다. 제목이 바뀌면 파일도 옮기고 링크를 재작성한다. vault 저장·log·인덱스 갱신 실패는 미팅을 실패로 만들지 않는다 — 요약 실패만 `.failed`로 표면화해야 [다시 처리]가 뜬다
- vault 파일명·링크는 **NFC**로 적는다 — `URL.lastPathComponent`·`URL.path`는 NFD를 돌려주고, Foundation의 파일 쓰기·이동은 디스크 엔트리까지 NFD로 만든다(실측). 파일은 `MeetingVaultExporter.place`(unlink + `rename(2)`)로만 놓는다. 테스트는 `unicodeScalars`로 비교(Swift `==`는 정준 동치)
- 포인트 색은 `MNTheme`가 단일 원천이고 `MNColor.secondary`·`bgSecondary`는 거기서 읽는 계산 프로퍼티다 — 호스트가 `MNTheme.configure`로 자기 브랜드 색을 넣는다(안 넣으면 기본 파랑). 이 둘을 다시 `let` 상수로 되돌리지 마라: 임베드한 앱은 시스템 AccentColor만 자기 색으로 남아 한 화면에 액센트가 둘이 된다(실측 2026-09-04, 임베드한 호스트 앱). `MainActor`로 묶지도 마라 — 마크다운 인라인 파싱이 메인 밖에서 링크 색을 읽는다
- 설정 화면의 행은 MinimalUI의 `MNFormSection`/`MNFormRow`/`MNToggleRow`/`MNStatusRow`로 짓는다 — 손으로 `group()`·`labeled()`를 다시 만들면 앱마다 사본이 생겨(세 벌까지 갔다) 같은 설정이 다른 물건처럼 보인다. 설명은 한 줄 힌트 + `.help()` 전문이고, 정상은 침묵한다 — 사람이 일부러 끈 것은 `.missing`이지 `.problem`이 아니다
- 요약은 `claude -p --json-schema`의 `structured_output`으로 받는다(`ClaudeSummarizer`). `--bare` 금지(OAuth 키체인을 건너뛴다). 요약 섹션은 고정이 아니다 — `MeetingSummaryPrompt`가 메뉴를 주고 특정 섹션 이름에 기대는 코드를 만들지 않는다. 화자 실명은 `speakers` 필드로 **제안**만 받고 반영은 사람이 누른다
- 온라인 통화 감지의 판정은 **마이크를 쥔 프로세스**다(`SystemCallSignals.conferencingAppOnMicrophone`). 창 제목은 이름 짓기 전용
- "말이 있는가"는 크기가 아니라 말소리/바닥소음 **비**(`AudioGain.hasSpeech`). 추론 직전 목표 레벨까지 키운다 — 작으면 whisper가 30초 창을 무음으로 건너뛴다
- 마이크 트랙엔 스피커로 나간 상대 목소리가 되돌아온다 — `EchoFilter` 임계 0.8을 낮추지 마라(내 말과 에코가 섞인 줄까지 접힌다)
- 전사는 조용히 부분만 돌아온다 — `TranscriptCoverage`로 시간축을 세고 빈 구간만 짧은 클립으로 2패스(`LocalTranscriptionPipeline.recover`). 달라지는 건 모델이 아니라 **클립 경계**다. 2패스 결과는 `TranscriptRecovery`로 걸러 붙인다(시간 겹침·환각 루프)
- 라이브 전사(`LiveTranscribing`)는 표시용 초벌 — 종료 후 파일 전사가 통째로 갈아끼운다. 탭 콜백에서는 **복사만**
- `MeetingSession`/AppState에 프레임마다 바뀌는 값을 `@Published`로 두지 않는다(마이크 레벨은 `MicLevelMeter`, 라이브 텍스트는 `LiveTranscriptStore`). 목록은 `LazyVStack` + 평평한 `ForEach` 하나(`MeetingList.rows`)
- `Bundle.module`(diarize.py)은 번들이 없으면 fatalError — 손조립 .app은 `meeting_MeetingCore.bundle`을 `Contents/Resources/`에 복사해야 한다. 호스트의 패키징 스크립트도 같다
- Core Audio 프로세스 탭은 Info.plist에 `NSAudioCaptureUsageDescription`이 필요하다(마이크 키만으로는 부족)
- 아이콘 글리프는 `scripts/generate-icons.swift`가 직접 그린다 — SF Symbol을 렌더해 쓰지 마라. Apple 라이선스가 심볼의 앱 아이콘 사용을 금하는데 이 저장소는 렌더 결과까지 배포한다
