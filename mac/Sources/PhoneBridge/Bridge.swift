import Foundation
import AppKit
import CoreBluetooth
import Network
import CryptoKit
import UserNotifications
import Vision

// PhoneBridge —— Mac 端
//
// 作用：接收安卓手机推来的通知（短信、微信、验证码…），在菜单栏里看，
// 不用碰手机；顺带内置 TOTP（Google Authenticator 那类验证码）生成。
//
// 传输：优先 BLE（手机做 GATT server 广播，Mac 做 central 订阅），
// 不经过任何服务器、不依赖同一网段，绕开 AP 隔离。
// 备选：TCP 127.0.0.1:8765（配合 adb reverse，用于联调）。

enum Dbg {
    static let file = Paths.support + "/debug.log"
    static let lock = NSLock()
    static func log(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "[\(Date())] \(s)\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: file)) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: file))
        }
    }
}

// MARK: - 模型

struct IncomingNote: Codable, Identifiable {
    var id = UUID()
    var pkg: String
    var app: String
    var title: String
    var text: String
    var time: Double
    var code: String?      // 服务端提取过就用它的，否则本地再提
    var msgId: String?     // 手机端生成，用于回执

    // 本地 id 自动生成，不参与解码
    private enum CodingKeys: String, CodingKey { case pkg, app, title, text, time, code, msgId = "id" }
}

struct TotpAccount: Codable, Identifiable {
    var id = UUID()
    var name: String
    var issuer: String
    var secret: String      // base32
    var digits: Int = 6
    var period: Int = 30
}

// MARK: - 存储

enum Paths {
    static let support: String = {
        let p = NSHomeDirectory() + "/Library/Application Support/PhoneBridge"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }()
    static var totpFile: String { support + "/totp.json" }
    static var historyFile: String { support + "/history.json" }
}

// MARK: - Base32 / TOTP

enum Base32 {
    static func decode(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var map: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        var bits = 0, value = 0
        var out = [UInt8]()
        for ch in s.uppercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "") {
            guard let v = map[ch] else { continue }
            value = (value << 5) | Int(v)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return Data(out)
    }
}

enum TOTP {
    static func code(secret: String, digits: Int = 6, period: Int = 30, at date: Date = Date()) -> String? {
        guard let key = Base32.decode(secret), !key.isEmpty else { return nil }
        let counter = UInt64(date.timeIntervalSince1970 / Double(period))
        var msg = counter.bigEndian
        let data = Data(bytes: &msg, count: 8)
        let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key))
        let bytes = Array(hmac)
        let off = Int(bytes[bytes.count - 1] & 0x0F)
        let bin = (UInt32(bytes[off] & 0x7F) << 24)
            | (UInt32(bytes[off + 1]) << 16)
            | (UInt32(bytes[off + 2]) << 8)
            | UInt32(bytes[off + 3])
        let mod = UInt32(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)d", bin % mod)
    }

    static func remaining(period: Int = 30) -> Int {
        period - Int(Date().timeIntervalSince1970) % period
    }
}

/// 从通知正文里抠验证码：连续 4–8 位数字（排除明显是时间/金额的）
func extractCode(_ text: String) -> String? {
    let patterns = [
        #"(?i)(?:验证码|校验码|动态码|code|otp)[^\d]{0,12}(\d{4,8})"#,
        #"(?i)(\d{4,8})[^\d]{0,6}(?:是|为)?[^\d]{0,4}(?:验证码|校验码|code)"#
    ]
    for p in patterns {
        if let re = try? NSRegularExpression(pattern: p),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges > 1,
           let r = Range(m.range(at: 1), in: text) {
            return String(text[r])
        }
    }
    // 兜底：整条里只有一组 4–8 位数字
    if let re = try? NSRegularExpression(pattern: #"\b\d{4,8}\b"#) {
        let all = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if all.count == 1, let r = Range(all[0].range, in: text) { return String(text[r]) }
    }
    return nil
}

// MARK: - 服务

final class Bridge: NSObject, ObservableObject {
    static let shared = Bridge()

    @Published var notes: [IncomingNote] = []
    @Published var connected = false
    @Published var linkName = "未连接"
    @Published var totp: [TotpAccount] = []
    /// 收到验证码时自动写进剪贴板
    @Published var autoCopyCode: Bool = UserDefaults.standard.bool(forKey: "autoCopyCode")
    /// 应用层加密的配对码（Mac 生成，手机粘贴一次）
    @Published var pairCode: String = Secure.loadOrCreateCode()
    @Published var lastDecryptFailed = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var buffer = Data()
    private var listener: NWListener?

    // BLE UUID：手机端必须一致
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    var onChange: (() -> Void)?

    override init() {
        super.init()
        loadHistory()
        loadTotp()
    }

    func start() {
        startTCP()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: 数据

    private func loadHistory() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.historyFile)),
              let list = try? JSONDecoder().decode([IncomingNote].self, from: d) else { return }
        notes = list
    }

    private func saveHistory() {
        let list = Array(notes.suffix(100))
        if let d = try? JSONEncoder().encode(list) {
            try? d.write(to: URL(fileURLWithPath: Paths.historyFile), options: .atomic)
        }
    }

    func loadTotp() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.totpFile)),
              let list = try? JSONDecoder().decode([TotpAccount].self, from: d) else { return }
        totp = list
    }

    func saveTotp() {
        if let d = try? JSONEncoder().encode(totp) {
            try? d.write(to: URL(fileURLWithPath: Paths.totpFile), options: .atomic)
        }
    }

    func setAutoCopy(_ on: Bool) {
        autoCopyCode = on
        UserDefaults.standard.set(on, forKey: "autoCopyCode")
    }

    /// 删除单条
    func remove(_ note: IncomingNote) {
        notes.removeAll { $0.id == note.id }
        saveHistory()
        onChange?()
    }

    /// 按 App 分组（最近的在上面）
    func groupedNotes() -> [(String, [IncomingNote])] {
        let sorted = notes.sorted { $0.time > $1.time }
        var order: [String] = []
        var buckets: [String: [IncomingNote]] = [:]
        for n in sorted {
            let key = n.app.isEmpty ? "其他" : n.app
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(n)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// 删除一个验证器账户
    func removeTotp(_ account: TotpAccount) {
        totp.removeAll { $0.id == account.id }
        saveTotp()
        onChange?()
    }

    func addTotp(uri: String) {
        // otpauth://totp/Issuer:name?secret=BASE32&digits=6&period=30
        guard let u = URL(string: uri), u.scheme == "otpauth" else { return }
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        let secret = comps?.queryItems?.first(where: { $0.name == "secret" })?.value ?? ""
        guard !secret.isEmpty else { return }
        var label = u.path.replacingOccurrences(of: "/", with: "")
        if label.isEmpty { label = "未命名" }
        let issuer = comps?.queryItems?.first(where: { $0.name == "issuer" })?.value ?? ""
        let digits = Int(comps?.queryItems?.first(where: { $0.name == "digits" })?.value ?? "6") ?? 6
        let period = Int(comps?.queryItems?.first(where: { $0.name == "period" })?.value ?? "30") ?? 30
        totp.append(TotpAccount(name: label, issuer: issuer, secret: secret, digits: digits, period: period))
        saveTotp()
        onChange?()
    }

    // MARK: 收到一条通知

    private var lastDataAt = Date()
    private var watchdog: Timer?

    func startWatchdog() {
        lastDataAt = Date()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.connected else { return }
            // 60 秒没有任何数据：链路名存实亡，断开重扫
            if Date().timeIntervalSince(self.lastDataAt) > 60 {
                Dbg.log("watchdog: 60s 无数据，断开重连")
                self.lastDataAt = Date()
                if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            }
        }
    }

    func ingest(_ json: Data) {
        guard let note = try? JSONDecoder().decode(IncomingNote.self, from: json) else {
            // 兼容：旧版手机端偶发把两条 JSON 粘在一起（"}{"），拆开逐条解析
            if let text = String(data: json, encoding: .utf8), text.contains("}{") {
                let parts = text.components(separatedBy: "}{")
                Dbg.log("ingest: 粘连报文，拆成 \(parts.count) 段")
                for (i, p) in parts.enumerated() {
                    var piece = p
                    if i > 0 { piece = "{" + piece }
                    if i < parts.count - 1 { piece += "}" }
                    if let d = piece.data(using: .utf8) { ingest(d) }
                }
                return
            }
            Dbg.log("ingest decode failed: \(String(data: json, encoding: .utf8) ?? "?")")
            return
        }
        var n = note
        lastDataAt = Date()
        if n.pkg == "__hb" {
            if let id = n.msgId { sendAck(id) }
            return
        }
        if n.code == nil { n.code = extractCode(n.title + " " + n.text) }
        DispatchQueue.main.async {
            self.notes.append(n)
            // 只当提示用：每个 App 最多留 5 条，超出丢最老的
            var perApp: [String: [UUID]] = [:]
            for note in self.notes {
                perApp[note.app, default: []].append(note.id)
            }
            for (_, ids) in perApp where ids.count > 5 {
                let drop = Set(ids.prefix(ids.count - 5))
                self.notes.removeAll { drop.contains($0.id) }
            }
            if self.notes.count > 100 { self.notes.removeFirst(self.notes.count - 100) }
            self.saveHistory()
            self.onChange?()
            self.postBanner(n)
            if let id = n.msgId { self.sendAck(id) }
            if self.autoCopyCode, let code = n.code {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
        }
    }

    /// 回执：写 RX 特征，手机端据此停止重发
    func sendAck(_ id: String) {
        guard let p = peripheral, let rx = rxChar else {
            Dbg.log("ack skipped (no rx char) id=\(id)")
            return
        }
        let data = Data(("ACK \(id)\n").utf8)
        p.writeValue(data, for: rx, type: .withResponse)
        Dbg.log("ack sent \(id)")
    }

    private func postBanner(_ n: IncomingNote) {
        let content = UNMutableNotificationContent()
        content.title = n.app.isEmpty ? n.title : "\(n.app) · \(n.title)"
        content.body = n.code.map { "\(n.text)\n验证码：\($0)" } ?? n.text
        content.sound = .default
        let req = UNNotificationRequest(identifier: n.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 从截图里识别 Google Authenticator 的迁移二维码（otpauth-migration://）
    @discardableResult
    func importMigrationImages(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            guard let img = NSImage(contentsOf: url),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let req = VNDetectBarcodesRequest()
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            for obs in req.results ?? [] {
                guard let payload = obs.payloadStringValue else { continue }
                added += importMigrationURI(payload)
            }
        }
        if added > 0 { saveTotp(); onChange?() }
        return added
    }

    @discardableResult
    func importMigrationURI(_ uri: String) -> Int {
        guard let url = URL(string: uri), url.scheme == "otpauth-migration",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dataStr = comps.queryItems?.first(where: { $0.name == "data" })?.value,
              let data = Data(base64Encoded: dataStr) else { return 0 }
        let accounts = MigrationParser.parse(data)
        var added = 0
        for a in accounts {
            guard !a.secret.isEmpty else { continue }
            if totp.contains(where: { $0.name == a.name && $0.issuer == a.issuer }) { continue }
            totp.append(TotpAccount(name: a.name, issuer: a.issuer, secret: a.secret,
                                    digits: a.digits, period: 30))
            added += 1
        }
        return added
    }

    // MARK: TCP（adb reverse 联调用）

    private func startTCP() {
        guard let port = NWEndpoint.Port(rawValue: 8765) else { return }
        do {
            let l = try NWListener(using: .tcp, on: port)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                self?.receive(on: conn)
            }
            l.start(queue: .main)
            listener = l
        } catch {
            NSLog("PhoneBridge TCP 监听失败: %@", String(describing: error))
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            NSLog("PhoneBridge recv %d bytes done=%d err=%@", data?.count ?? -1, done ? 1 : 0,
                  error.map { String(describing: $0) } ?? "-")
            if let data, !data.isEmpty {
                Dbg.log("recv \(data.count) bytes")
                self.buffer.append(data)
                self.drainBuffer()
            }
            if done { conn.cancel() } else { self.receive(on: conn) }
        }
    }

    private func drainBuffer() {
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<idx], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = buffer[(idx + 1)...]
            guard !line.isEmpty else { continue }
            if line.hasPrefix("E1:") {
                if let plain = Secure.decrypt(line, code: pairCode) {
                    lastDecryptFailed = false
                    ingest(plain)
                } else {
                    // 可能是配对码不一致，或者有人伪造了报文
                    lastDecryptFailed = true
                    Dbg.log("decrypt failed（配对码不一致？）")
                    onChange?()
                }
            } else {
                // 明文（老版本手机端 / 联调）：照收，但在日志里标记
                Dbg.log("plaintext note accepted (unencrypted)")
                ingest(Data(line.utf8))
            }
        }
    }

    func regeneratePairCode() {
        pairCode = Secure.resetCode()
        onChange?()
    }

    // MARK: BLE 数据

    private func receiveBLE(_ data: Data) {
        buffer.append(data)
        drainBuffer()
    }

    func send(_ text: String) {
        guard let p = peripheral, let tx = txChar, let d = text.data(using: .utf8) else { return }
        p.writeValue(d, for: tx, type: .withResponse)
    }
}

// MARK: - BLE central

extension Bridge: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            linkName = "蓝牙不可用"
            onChange?()
            return
        }
        Dbg.log("central poweredOn, start scan")
        central.scanForPeripherals(withServices: [Bridge.serviceUUID], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Dbg.log("discovered \(peripheral.name ?? "?") rssi=\(RSSI)")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
        linkName = "连接中…"
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Dbg.log("connected \(peripheral.name ?? "?")")
        connected = true
        linkName = "已连接（BLE）"
        peripheral.discoverServices([Bridge.serviceUUID])
        onChange?()
        // 4 秒内没拿到可订阅的特征，说明这条连接没用了，断开重扫
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.connected, self.txChar == nil else { return }
            Dbg.log("connected but not subscribed → force rescan")
            self.connected = false
            self.linkName = "连接无效，重新扫描…"
            self.onChange?()
            self.central?.cancelPeripheralConnection(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Dbg.log("disconnected \(error.map { String(describing: $0) } ?? "-")")
        connected = false
        linkName = "已断开，重连中…"
        txChar = nil
        rxChar = nil
        onChange?()
        let p = peripheral
        central.connect(p, options: nil)
        // 3 秒还没连上就退回扫描：手机端可能重启了广播
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.connected else { return }
            Dbg.log("reconnect timed out → rescan")
            self.peripheral = nil
            central.cancelPeripheralConnection(p)
            central.scanForPeripherals(withServices: [Bridge.serviceUUID], options: nil)
        }
    }

    /// 连接失败（例如手机端广播被停、配对信息不一致导致 133）时必须回到扫描，
    /// 否则会停在「已断开，重连中…」再也不动。
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Dbg.log("connect failed \(error.map { String(describing: $0) } ?? "-")")
        connected = false
        txChar = nil
        rxChar = nil
        linkName = "连接失败，重新扫描…"
        onChange?()
        central.cancelPeripheralConnection(peripheral)
        self.peripheral = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard central.state == .poweredOn else { return }
            Dbg.log("rescan after connect failure")
            central.scanForPeripherals(withServices: [Bridge.serviceUUID], options: nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Dbg.log("services=\(peripheral.services?.count ?? -1) err=\(error.map { String(describing: $0) } ?? "-")")
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([Bridge.txUUID, Bridge.rxUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let names = (service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ",")
        Dbg.log("chars=\(names) err=\(error.map { String(describing: $0) } ?? "-")")
        for c in service.characteristics ?? [] {
            if c.uuid == Bridge.rxUUID {
                rxChar = c
                Dbg.log("rx characteristic ready")
            }
            if c.uuid == Bridge.txUUID {
                txChar = c
                peripheral.setNotifyValue(true, for: c)
                Dbg.log("subscribe tx …")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Dbg.log("notify state=\(characteristic.isNotifying) err=\(error.map { String(describing: $0) } ?? "-")")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let d = characteristic.value {
            Dbg.log("ble data \(d.count) bytes")
            receiveBLE(d)
        }
    }
}
