import SwiftUI
import MeetingCore
import MinimalUI

public struct MeetingDiarizationRow: View {
    let setup: DiarizationSetup?

    public init(setup: DiarizationSetup?) {
        self.setup = setup
    }

    public var body: some View {
        if let setup {
            MNStatusRow(setup.isReady ? .ready : .missing,
                        label: "화자 구분",
                        status: setup.isReady
                            ? "준비됨"
                            : "미설치 — \(setup.missing.joined(separator: ", "))",
                        detail: setup.isReady ? nil : setup.installHint,
                        help: "갖춰지면 상대가 여럿일 때 상대1·상대2로 나뉘고, 대면 미팅도 화자별로"
                            + " 갈립니다. 없으면 온라인 통화의 상대가 한 사람으로 묶이고"
                            + " 대면 미팅은 화자를 나누지 않습니다.")
        }
    }
}
