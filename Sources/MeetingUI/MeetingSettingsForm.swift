import SwiftUI
import MeetingCore
import MinimalUI

public struct MeetingSettingsForm: View {
    @Binding var settings: MeetingSettings

    public init(settings: Binding<MeetingSettings>) {
        self._settings = settings
    }

    public var body: some View {
        MNFormSection("녹음") {
            MNToggleRow("입력 볼륨 올리기",
                        hint: "통화 중이면 상대에게 들리는 크기도 커집니다.",
                        help: "녹음하는 동안만 시스템 마이크 입력을 최대로 올리고, 종료하면 원래 값으로"
                            + " 되돌립니다. 통화 중이라면 상대에게 들리는 크기도 함께 커집니다.",
                        isOn: $settings.boostInputVolume)
        }

        MNFormSection("전사") {
            MNFormRow("언어", help: "전사 디코더와 요약 프롬프트가 같은 언어를 씁니다.") {
                Picker("", selection: $settings.transcriptionLanguage) {
                    Text("한국어").tag("ko")
                    Text("영어").tag("en")
                    Text("일본어").tag("ja")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            MNFormRow("용어집",
                      hint: "쉼표로 나열합니다. 회의 제목·참석자는 자동으로 더해집니다.",
                      help: "제품명·팀 용어를 쉼표로 나열해 주십시오. 전사가 시작되기 전에 읽혀"
                          + " 같은 소리를 아는 낱말로 적습니다.") {
                MNTextField("제품명, 팀 용어, …", text: $settings.transcriptionGlossary)
            }
            MNToggleRow("라이브 전사",
                        hint: "종료 후 정본으로 다시 만듭니다.",
                        help: "녹음 화면과 플로팅 위젯에 초벌 전사가 흐릅니다. 정확한 전사는"
                            + " 종료 후에 다시 만들어 대체합니다.",
                        isOn: $settings.liveTranscription)
            Text("전사는 기기 안에서 돕니다 — 음성이 밖으로 나가지 않습니다.")
                .font(MNFont.caption1)
                .foregroundStyle(MNColor.contents200)
                .padding(.top, MNSpacing.s4)
        }
    }
}
