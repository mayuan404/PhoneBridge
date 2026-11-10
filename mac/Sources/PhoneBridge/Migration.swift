import Foundation

// Google Authenticator 的「转移账号」二维码是 otpauth-migration://offline?data=<base64 protobuf>。
// 这里手写一个最小的 protobuf 解析器，只解 MigrationPayload 需要的字段。

enum MigrationParser {
    struct Account {
        var secret: String   // base32
        var name: String
        var issuer: String
        var digits: Int
    }

    // 只读需要的部分
    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        var done: Bool { i >= bytes.count }

        mutating func varint() -> UInt64 {
            var shift: UInt64 = 0
            var out: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                out |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }
            return out
        }

        mutating func bytesField(_ len: Int) -> [UInt8] {
            let end = min(i + len, bytes.count)
            let out = Array(bytes[i..<end])
            i = end
            return out
        }

        /// 读一个 key，返回 (fieldNumber, wireType)
        mutating func key() -> (Int, Int) {
            let k = varint()
            return (Int(k >> 3), Int(k & 7))
        }

        mutating func skip(_ wire: Int) {
            switch wire {
            case 0: _ = varint()
            case 1: i = min(i + 8, bytes.count)
            case 2:
                let n = Int(varint()); i = min(i + n, bytes.count)
            case 5: i = min(i + 4, bytes.count)
            default: i = bytes.count
            }
        }
    }

    static func parse(_ data: Data) -> [Account] {
        var r = Reader(bytes: Array(data))
        var out: [Account] = []
        while !r.done {
            let (field, wire) = r.key()
            if field == 1 && wire == 2 {            // repeated OtpParameters
                let len = Int(r.varint())
                let payload = r.bytesField(len)
                if let a = parseOtp(payload) { out.append(a) }
            } else {
                r.skip(wire)
            }
        }
        return out
    }

    private static func parseOtp(_ bytes: [UInt8]) -> Account? {
        var r = Reader(bytes: bytes)
        var secret = "", name = "", issuer = ""
        var digits = 6
        var type = 2   // 2 = TOTP
        while !r.done {
            let (field, wire) = r.key()
            switch (field, wire) {
            case (1, 2):  // secret（原始字节）
                let n = Int(r.varint())
                let raw = r.bytesField(n)
                secret = base32Encode(Data(raw))
            case (2, 2):
                let n = Int(r.varint())
                name = String(decoding: r.bytesField(n), as: UTF8.self)
            case (3, 2):
                let n = Int(r.varint())
                issuer = String(decoding: r.bytesField(n), as: UTF8.self)
            case (5, 0):  // DigitCount: 1 -> 6 位, 2 -> 8 位
                digits = r.varint() == 2 ? 8 : 6
            case (6, 0):  // OtpType
                type = Int(r.varint())
            default:
                r.skip(wire)
            }
        }
        guard type == 2 else { return nil }   // 只收 TOTP，HOTP 不支持
        return Account(secret: secret, name: name.isEmpty ? "未命名" : name,
                       issuer: issuer, digits: digits)
    }

    static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var bits = 0, value = 0
        for b in data {
            value = (value << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 0x1F])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[(value << (5 - bits)) & 0x1F])
        }
        return out
    }
}
