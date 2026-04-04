import SwiftUI

struct SidebarEditionCard: View {
    @ObservedObject private var auth = CloudAuthManager.shared
    @ObservedObject private var quota = CloudQuotaManager.shared
    @State private var showSwitchConfirm = false
    @State private var showLoginAlert = false
    @AppStorage("tf_app_edition") private var editionRaw: String?

    private var edition: AppEdition? {
        editionRaw.flatMap { AppEdition(rawValue: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if edition == .member {
                memberContent
            } else {
                byoKeyContent
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TF.settingsCard.opacity(0.6))
        )
        .confirmationDialog(
            L("切换版本", "Switch Edition"),
            isPresented: $showSwitchConfirm,
            titleVisibility: .visible
        ) {
            Button(switchTargetLabel) { performSwitch() }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(switchConfirmMessage)
        }
        .alert(
            L("请先登录", "Please log in first"),
            isPresented: $showLoginAlert
        ) {
            Button("OK") {}
        } message: {
            Text(L(
                "切换到官方会员需要先登录 Type4Me Cloud 账户。请在设置中登录后再试。",
                "Switching to Member requires a Type4Me Cloud account. Please log in first."
            ))
        }
    }

    // MARK: - Member Content

    private var memberContent: some View {
        Group {
            // Avatar + email
            HStack(spacing: 6) {
                avatar
                Text(auth.userEmail ?? L("未登录", "Not signed in"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Status line
            if quota.isPaid {
                Text(L("已订阅", "Subscribed"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsAccentGreen)
            } else {
                Text(L("免费", "Free") + " · \(quota.freeCharsRemaining) / 2000")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            switchLink(
                label: L("切换到自带 API", "Switch to BYO API"),
                target: .byoKey
            )
        }
        .task {
            if auth.isLoggedIn { await quota.refresh() }
        }
    }

    // MARK: - BYO Key Content

    private var byoKeyContent: some View {
        Group {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextSecondary)
                Text(L("自带 API 版", "BYO API"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsText)
            }

            switchLink(
                label: L("切换到官方会员", "Switch to Member"),
                target: .member
            )
        }
    }

    // MARK: - Components

    private var avatar: some View {
        let letter = auth.userEmail?.first.map(String.init)?.uppercased() ?? "?"
        return Text(letter)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(TF.settingsNavActive))
    }

    private func switchLink(label: String, target: AppEdition) -> some View {
        Button {
            if target == .member && !auth.isLoggedIn {
                showLoginAlert = true
            } else {
                showSwitchConfirm = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(label)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
            }
            .font(.system(size: 10))
            .foregroundStyle(TF.settingsTextSecondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    // MARK: - Switch Logic

    private var switchTarget: AppEdition {
        edition == .member ? .byoKey : .member
    }

    private var switchTargetLabel: String {
        switchTarget == .member
            ? L("切换到官方会员", "Switch to Member")
            : L("切换到自带 API", "Switch to BYO API")
    }

    private var switchConfirmMessage: String {
        switchTarget == .member
            ? L("将使用 Type4Me Cloud 服务进行语音识别。", "Voice recognition will use Type4Me Cloud service.")
            : L("将使用你自己配置的 API 进行语音识别。", "Voice recognition will use your own configured API.")
    }

    private func performSwitch() {
        AppEditionMigration.switchTo(switchTarget)
    }
}
