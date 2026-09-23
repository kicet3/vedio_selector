import SwiftUI

struct AISettingsView: View {
    @ObservedObject private var ai = CodexAIService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Palette.accent)
                Text("ChatGPT 보정 제안").font(.title2.weight(.semibold))
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("사진의 빛과 색, 인물 피부 보정값을 제안받고 편집기에서 확인하세요.")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(ai.isSignedIn ? "ChatGPT 연결됨" : "ChatGPT 로그인 필요",
                          systemImage: ai.isSignedIn ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.headline)
                    if let label = ai.accountLabel, !label.isEmpty { Text(label).font(.callout).textSelection(.enabled) }
                    if ai.executablePath == nil {
                        Text("공식 Codex CLI 설치가 필요합니다. 설치 후 ‘연결 확인’을 누르세요.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("Codex 설치 안내 열기", destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
                    }
                    HStack {
                        if ai.isSigningIn {
                            ProgressView().controlSize(.small)
                            Text("브라우저에서 로그인을 완료해 주세요.").font(.callout)
                            Button("취소") { Task { await ai.cancelSignIn() } }
                        } else if ai.isSignedIn {
                            Button("로그아웃") { Task { await ai.signOut() } }.disabled(ai.isBusy)
                        } else {
                            Button("ChatGPT로 로그인") { Task { await ai.signIn() } }
                                .buttonStyle(.borderedProminent).disabled(ai.executablePath == nil || ai.isBusy)
                        }
                        Spacer()
                        Button("연결 확인") { Task { await ai.refreshAccount() } }.disabled(ai.isBusy || ai.isSigningIn)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("사진 전송은 제안을 요청할 때만", systemImage: "photo.badge.checkmark")
                    .font(.headline)
                Text("편집기에서 AI 제안을 요청하면 선택한 사진의 축소본(최대 1,600px)과 요청 내용이 OpenAI로 전송됩니다. 위치·촬영 메타데이터는 제거됩니다. 폴더 전체를 전송하지 않습니다.")
                Text("ChatGPT 계정의 Codex 이용 권한과 사용 한도가 적용됩니다. 이미지 생성이나 얼굴 형태 변경은 지원하지 않으며, 제안된 수치를 로컬 편집기에 적용합니다.")
                Text("로그인은 공식 Codex가 처리하며 Framepick 전용 공간에 보관됩니다. 기존 Codex 로그인과는 별개입니다.")
            }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = ai.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(ai.executablePath == nil ? "Codex CLI를 찾지 못했습니다." : "Codex CLI 감지됨")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("실행 파일 선택…") { ai.chooseExecutable() }.disabled(ai.isBusy || ai.isSigningIn)
            }
        }.padding(26).frame(width: 540).task { await ai.refreshAccount() }
    }
}
