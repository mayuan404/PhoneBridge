import AppKit
import SwiftUI
import UserNotifications

// 菜单栏界面

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right",
                              accessibilityDescription: "PhoneBridge")
            b.image?.isTemplate = true
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp])

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: Panel().environmentObject(Bridge.shared)
        )

        Bridge.shared.onChange = { [weak self] in self?.refreshBadge() }
        Bridge.shared.start()
        Bridge.shared.startWatchdog()
        refreshBadge()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func refreshBadge() {
        let b = statusItem.button
        b?.appearsDisabled = !Bridge.shared.connected
        b?.toolTip = "PhoneBridge · " + Bridge.shared.linkName
    }

    @objc private func togglePopover() {
        Dbg.log("togglePopover called")
        guard let b = statusItem.button else { Dbg.log("no button"); return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // 后台（LSUIElement）应用必须先激活，否则 popover 会「显示失败」且没有任何窗口
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            Dbg.log("popover shown=\(popover.isShown)")
        }
    }
}

// MARK: - 面板

struct Panel: View {
    @EnvironmentObject var bridge: Bridge
    @State private var tab = 0
    @State private var tick = Date()
    /// 展开的分组（默认空 = 全部折叠）
    @State private var expanded: Set<String> = []
    @State private var showPairCode = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == 0 { notesList } else { totpList }
            Divider()
            footer
        }
        .frame(width: 380, height: 520)
        .popover(isPresented: $showPairCode, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("手机配对码").font(.system(size: 12, weight: .semibold))
                Text("把下面这串代码粘到手机 PhoneBridge 的「配对码」输入框里。\n两端一致后，通知内容会用 AES-GCM 加密传输。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(bridge.pairCode)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                HStack {
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bridge.pairCode, forType: .string)
                    }
                    Button("重新生成") { bridge.regeneratePairCode() }
                        .help("重新生成后，手机端需要重新粘贴一次")
                    Spacer()
                }
            }
            .padding(14)
            .frame(width: 300)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(bridge.connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(bridge.linkName).font(.system(size: 11)).foregroundStyle(.secondary)
            if bridge.lastDecryptFailed {
                Text("配对码不一致")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Picker("", selection: $tab) {
                Text("通知").tag(0)
                Text("验证器").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var notesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if bridge.notes.isEmpty {
                    Text("等待手机通知…\n\n确保手机端已授权通知读取，并保持 PhoneBridge 在后台运行。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                }
                ForEach(bridge.groupedNotes(), id: \.0) { group in
                    let isOpen = expanded.contains(group.0)
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
                            if isOpen { expanded.remove(group.0) } else { expanded.insert(group.0) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(group.0)
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Text("\(group.1.count)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isOpen {
                            ForEach(group.1) { n in
                                NoteRow(note: n) { bridge.remove(n) }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(10)
        }
    }

    private var totpList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if bridge.totp.isEmpty {
                    Text("还没有验证器账户。\n\n在设置里粘贴 otpauth:// 链接即可添加。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 60)
                }
                ForEach(bridge.totp) { a in
                    TotpRow(account: a, tick: tick) { bridge.removeTotp(a) }
                }
            }
            .padding(10)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("配对码") { showPairCode.toggle() }
            Button("添加验证器…") { addTotp() }
            Button("导入验证器…") { importTotp() }
            Toggle("自动复制", isOn: Binding(
                get: { bridge.autoCopyCode },
                set: { bridge.setAutoCopy($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Button("清空通知") { bridge.notes.removeAll() }
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func importTotp() {
        let panel = NSOpenPanel()
        panel.title = "选择 Google Authenticator 的转移二维码截图"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .image]
        guard panel.runModal() == .OK else { return }
        let n = bridge.importMigrationImages(panel.urls)
        let alert = NSAlert()
        alert.messageText = n > 0 ? "已导入 \(n) 个验证器账户" : "没有识别到迁移二维码"
        alert.informativeText = n > 0
            ? "在「验证器」页就能看到它们，每 30 秒刷新一次。"
            : "如果截图里确实有二维码，请确认是 Google Authenticator → 转移账号 生成的那一页；也可能是分批导出的多张截图。"
        alert.runModal()
    }

    private func addTotp() {
        let alert = NSAlert()
        alert.messageText = "添加验证器账户"
        alert.informativeText = "粘贴 otpauth://totp/... 链接，或只粘贴 Base32 密钥。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "otpauth://totp/..."
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("otpauth://") {
            bridge.addTotp(uri: text)
        } else if text.count >= 16 {
            bridge.totp.append(TotpAccount(name: "手动添加", issuer: "", secret: text))
            bridge.saveTotp()
        }
    }
}

struct NoteRow: View {
    let note: IncomingNote
    var onDelete: () -> Void = {}
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(note.app.isEmpty ? "通知" : note.app)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeText).font(.system(size: 9)).foregroundStyle(.tertiary)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("删除这条")
            }
            if !note.title.isEmpty {
                Text(note.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            Text(note.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4)
            if let code = note.code {
                HStack(spacing: 6) {
                    Text(code)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Button(copied ? "已复制" : "复制") { copy(code) }
                        .controlSize(.mini)
                }
                .padding(.top, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .onTapGesture { copy(note.code ?? note.text) }
    }

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: note.time))
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

struct TotpRow: View {
    let account: TotpAccount
    let tick: Date
    var onDelete: () -> Void = {}
    @State private var copied = false

    var body: some View {
        let code = TOTP.code(secret: account.secret, digits: account.digits,
                             period: account.period, at: tick) ?? "------"
        let remain = TOTP.remaining(period: account.period)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.issuer.isEmpty ? account.name : account.issuer)
                    .font(.system(size: 11, weight: .semibold))
                if !account.issuer.isEmpty {
                    Text(account.name).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(code)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(remain <= 5 ? Color.orange : Color.primary)
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(remain) / CGFloat(account.period))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("删除这个验证器账户")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
        .contextMenu {
            Button("复制验证码") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
            Button("删除这个账户", role: .destructive) { onDelete() }
        }
    }
}

// 命令行自测：PhoneBridge --enc <pairCode> <text>  /  --dec <pairCode> <E1:...>
if let i = CommandLine.arguments.firstIndex(of: "--enc"), CommandLine.arguments.count > i + 2 {
    let code = CommandLine.arguments[i + 1]
    let text = CommandLine.arguments[i + 2]
    print(Secure.encrypt(Data(text.utf8), code: code) ?? "nil")
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--dec"), CommandLine.arguments.count > i + 2 {
    let code = CommandLine.arguments[i + 1]
    let line = CommandLine.arguments[i + 2]
    if let d = Secure.decrypt(line, code: code) {
        print(String(decoding: d, as: UTF8.self))
    } else {
        print("DECRYPT_FAILED")
    }
    exit(0)
}

// 命令行自测：PhoneBridge --delete-totp <名字包含>（验证删除与持久化）
if let i = CommandLine.arguments.firstIndex(of: "--delete-totp"), CommandLine.arguments.count > i + 1 {
    let needle = CommandLine.arguments[i + 1]
    let b = Bridge.shared
    let hit = b.totp.filter { $0.name.contains(needle) || $0.issuer.contains(needle) }
    for a in hit { b.removeTotp(a) }
    print("deleted=\(hit.count) left=\(b.totp.count) -> \(b.totp.map { $0.name })")
    exit(0)
}

// 命令行自测：PhoneBridge --import-qr <图片> [更多图片…]
if let i = CommandLine.arguments.firstIndex(of: "--import-qr") {
    let urls = CommandLine.arguments[(i + 1)...].map { URL(fileURLWithPath: $0) }
    let b = Bridge.shared
    let n = b.importMigrationImages(urls)
    print("imported=\(n)")
    for a in b.totp { print("\(a.issuer) | \(a.name) | \(a.secret) | \(a.digits)") }
    exit(0)
}

// 命令行自测：PhoneBridge --migration <base64>
if let i = CommandLine.arguments.firstIndex(of: "--migration"), CommandLine.arguments.count > i + 1,
   let data = Data(base64Encoded: CommandLine.arguments[i + 1]) {
    for a in MigrationParser.parse(data) {
        print("\(a.issuer) | \(a.name) | \(a.secret) | \(a.digits)")
    }
    exit(0)
}

// 命令行自测：PhoneBridge --totp JBSWY3DPEHPK3PXP
if let i = CommandLine.arguments.firstIndex(of: "--totp"), CommandLine.arguments.count > i + 1 {
    let secret = CommandLine.arguments[i + 1]
    print(TOTP.code(secret: secret) ?? "invalid")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
