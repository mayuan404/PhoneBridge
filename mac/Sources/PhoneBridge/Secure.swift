import Foundation
import CryptoKit

// 应用层加密：Mac 生成一段配对码，用户把它粘到手机上一次。
// 两边用同一个派生函数得到 32 字节密钥，之后每条通知体都用 AES-GCM 加密。
// 即便有人能连上蓝牙（链路层已要求配对），没有配对码也解不开内容。

enum Secure {
    static let keyDefaultsKey = "pairCode"

    /// 16 个 base32 字符，约 80 bit 熵
    static func newPairCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // 去掉易混字符
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func loadOrCreateCode() -> String {
        if let s = UserDefaults.standard.string(forKey: keyDefaultsKey), !s.isEmpty { return s }
        let code = newPairCode()
        UserDefaults.standard.set(code, forKey: keyDefaultsKey)
        return code
    }

    static func resetCode() -> String {
        let code = newPairCode()
        UserDefaults.standard.set(code, forKey: keyDefaultsKey)
        return code
    }

    /// 归一化：去掉空格、横线，统一大写
    static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func key(from code: String) -> SymmetricKey? {
        let norm = normalize(code)
        guard norm.count >= 8 else { return nil }
        let material = Data((norm + "|PhoneBridge|v1").utf8)
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: Data(digest))
    }

    /// 手机端格式： "E1:" + base64( nonce(12) + ciphertext + tag )
    static func decrypt(_ line: String, code: String) -> Data? {
        guard line.hasPrefix("E1:"), let key = key(from: code) else { return nil }
        let b64 = String(line.dropFirst(3))
        guard let combined = Data(base64Encoded: b64) else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }

    /// 也给 Mac 自己用（以后做双向消息时）
    static func encrypt(_ data: Data, code: String) -> String? {
        guard let key = key(from: code), let box = try? AES.GCM.seal(data, using: key),
              let combined = box.combined else { return nil }
        return "E1:" + combined.base64EncodedString()
    }
}
