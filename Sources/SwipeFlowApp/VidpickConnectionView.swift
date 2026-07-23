import SwiftUI

struct VidpickConnectionInput: Sendable {
    let serverAddress: String
    let username: String
    let password: String
    let folderPath: String
    let recursive: Bool
}

struct VidpickConnectionView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var serverAddress: String
    @State private var username: String
    @State private var password = ""
    @State private var folderPath: String
    @State private var recursive: Bool
    @State private var isConnecting = false
    @State private var errorMessage: String?

    let connect: @MainActor (VidpickConnectionInput) async throws -> Void

    init(
        connect: @escaping @MainActor (VidpickConnectionInput) async throws -> Void
    ) {
        let saved = VidpickProfileStore.load()
        _serverAddress = State(initialValue: saved?.serverAddress ?? "")
        _username = State(initialValue: saved?.username ?? "")
        _folderPath = State(initialValue: saved?.folderPath ?? "/")
        _recursive = State(initialValue: saved?.recursive ?? true)
        self.connect = connect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("连接 Vidpick")
                .font(.title2.bold())

            Form {
                TextField(
                    "HTTPS 地址",
                    text: $serverAddress,
                    prompt: Text("https://vidpick.example.invalid")
                )
                .textContentType(.URL)

                TextField("用户名", text: $username)
                    .textContentType(.username)

                SecureField(
                    "密码",
                    text: $password,
                    prompt: Text("留空使用钥匙串中已保存的密码")
                )
                .textContentType(.password)

                TextField("媒体目录", text: $folderPath, prompt: Text("/"))

                Toggle("包含子目录", isOn: $recursive)
            }
            .formStyle(.grouped)

            Text("密码只保存在 macOS 钥匙串中。SwipeFlow 只向 Vidpick 发送登录信息，不会转发给媒体存储主机。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .disabled(isConnecting)

                Button("连接") {
                    beginConnection()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isConnecting ||
                    serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func beginConnection() {
        isConnecting = true
        errorMessage = nil
        let input = VidpickConnectionInput(
            serverAddress: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            folderPath: folderPath.trimmingCharacters(in: .whitespacesAndNewlines),
            recursive: recursive
        )
        Task {
            do {
                try await connect(input)
                password = ""
                dismiss()
            } catch {
                password = ""
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }
}
