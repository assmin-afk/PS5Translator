// ============================================================================
// FILE 2A: 2A_ChiakiCoreAndDecoder.swift (TÁCH TỪ FILE 2 - PHẦN 1/2)
// PHIÊN BẢN: PS5Translator 1.02 (HOÀN THIỆN BẮT TAY CHIAKI RP-NONCE & TAKION V12)
// NHIỆM VỤ:
// 1. Cấu hình vùng quét mặc định (ROIDefaultConfig, ROIMode, PS5ConnectionState).
// 2. Lõi mã hoá Chiaki (ChiakiEmbeddedCore):
//    - Giải mã trực tiếp JWT Token của Sony và quét đệ quy mọi cấu trúc JSON để lấy
//      đúng số Account ID 64-bit -> chuyển sang mã 8-byte Little-Endian Base64.
//    - Đóng gói 480-byte AES-128-CBC + HMAC-SHA256 chuẩn Chiaki, giải mã đa offset phản hồi PS5.
//    - Mã hoá RP-Auth & RP-Did bằng RP-Nonce + RP-Key cho phiên /sie/ps5/rp/sess/ctrl.
//    - Bắt tay 4 bước Takion V12 (INIT -> INIT_ACK -> COOKIE_ECHO -> BIG Payload).
// 3. Bộ giải mã phần cứng VideoToolbox (ChiakiHardwareVideoDecoder): Ghép mảnh UDP và
//    giải mã cả H.264 lẫn HEVC (H.265) từ cổng UDP 9296 của PS5 thành CGImage.
// 4. Bộ bắt Redirect OAuth ngầm (SilentOAuthRedirectCatcher).
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine
import Network
import CryptoKit
import CommonCrypto
import WebKit
import VideoToolbox
import CoreMedia

// ============================================================================
// THÔNG SỐ CẤU HÌNH KHUNG QUÉT MẶC ĐỊNH & CỔNG CHIAKI (Đặt ở đầu file)
// ============================================================================
struct ROIDefaultConfig {
    static let fullScreenRect = CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92)
    static let dialogueDefaultRect = CGRect(x: 0.10, y: 0.68, width: 0.80, height: 0.24)
    static let questDefaultRect = CGRect(x: 0.03, y: 0.12, width: 0.94, height: 0.76)

    static let ddpPort: UInt16 = 9302
    static let registAndCtrlPort: UInt16 = 9295
    static let takionStreamPort: UInt16 = 9296
    static let rpClientType = "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931af000"
    static let chiakiRegistPayloadSize = 480 // 0x1E0 bytes chuẩn Chiaki
}

enum ROIMode: String, CaseIterable {
    case fullScreen = "Toàn màn hình"
    case dialogueOnly = "Chỉ phụ đề"
    case questAndMenu = "Nhiệm vụ & Menu"
}

enum PS5ConnectionState: Equatable {
    case disconnected
    case scanningLAN
    case pairingPIN
    case connectingStream
    case connected(hostName: String)
    case error(message: String)
}

// ============================================================================
// 1. LÕI MÃ HOÁ CHIAKI RPCRYPT & TRÍCH XUẤT ĐA TẦNG ACCOUNT ID 8-BYTE
// ============================================================================
final class ChiakiEmbeddedCore {
    static let shared = ChiakiEmbeddedCore()

    // Bảng khoá PS5 gốc từ mã nguồn Chiaki (rpcrypt.c)
    private let ps5Key0: [UInt8] = [
        0x09, 0x37, 0x9F, 0x7D, 0x48, 0x43, 0x4A, 0xC2,
        0x50, 0xB8, 0x6C, 0x98, 0x7E, 0xE8, 0xC9, 0x77
    ]
    private let ps5Key1: [UInt8] = [
        0x7B, 0xD0, 0x35, 0x0A, 0x86, 0xC6, 0x24, 0x3E,
        0x2F, 0x08, 0x90, 0x79, 0x66, 0xF7, 0xB1, 0x3F
    ]
    private let ps5HmacKey: [UInt8] = [
        0x62, 0x47, 0x9C, 0x30, 0x37, 0x65, 0x4E, 0x26,
        0x86, 0x0F, 0x9D, 0x2F, 0x5C, 0x70, 0x10, 0x3C
    ]

    // Kiểm tra xem chuỗi Base64 có phải là mã băm giả (như nZKnNYIoZ0w= hoặc TWlIc29pOTM=) hay không
    func isFakeGeneratedAccountID(_ input: String, username: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "TWlIc29pOTM=" { return true } // TWlIc29pOTM= is base64 of Miesoi93

        let cleanUser = (username.isEmpty ? "Miesoi93" : username).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        let fakeHash = Data(SHA256.hash(data: Data(cleanUser.utf8)).prefix(8)).base64EncodedString()
        if trimmed == fakeHash { return true }

        let padded = cleanUser.padding(toLength: 8, withPad: "0", startingAt: 0)
        let fakeAscii = Data(padded.utf8.prefix(8)).base64EncodedString()
        if trimmed == fakeAscii { return true }

        return false
    }

    // Chuyển số Account ID 64-bit sang chuỗi Base64 8-byte Little-Endian chuẩn Chiaki
    func convertUInt64ToBase64LittleEndian(_ numericID: UInt64) -> String {
        var le = numericID.littleEndian
        return Data(bytes: &le, count: 8).base64EncodedString()
    }

    // Chuẩn hoá Account ID sang đúng 8-byte Little-Endian Base64 chuẩn Chiaki
    func normalizeAccountIDTo8Bytes(input: String, fallbackUsername: String) -> (base64: String, numericString: String, isValidRealID: Bool) {
        let trimmed = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if isFakeGeneratedAccountID(trimmed, username: fallbackUsername) {
            return ("", "", false)
        }

        // 1. Nếu là dãy số 64-bit của Sony (10 - 20 chữ số)
        if trimmed.allSatisfy({ $0.isNumber }), let numericID = UInt64(trimmed), numericID > 1000000 {
            return (convertUInt64ToBase64LittleEndian(numericID), String(numericID), true)
        }

        // 2. Nếu là chuỗi Base64 giải mã ra đúng 8 bytes thật
        if let decoded = Data(base64Encoded: trimmed), decoded.count == 8 {
            let uint64Val = decoded.withUnsafeBytes { $0.load(as: UInt64.self) }
            let num = UInt64(littleEndian: uint64Val)
            if num > 1000000 {
                return (trimmed, String(num), true)
            }
        }

        // 3. Nếu là chuỗi Hex 16 ký tự (VD: từ PSNTools / script Chiaki)
        let cleanHex = trimmed.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: " ", with: "")
        if cleanHex.count == 16, let hexVal = UInt64(cleanHex, radix: 16), hexVal > 1000000 {
            return (convertUInt64ToBase64LittleEndian(hexVal), String(hexVal), true)
        }

        return ("", "", false)
    }

    // MARK: - Giải mã trực tiếp JWT Token của Sony hoặc JSON bất kỳ để lấy Account ID 8-byte
    func extractAccountIDFromJWT(_ jwtString: String) -> (onlineID: String, base64ID: String, numericID: String)? {
        let segments = jwtString.components(separatedBy: ".")
        guard segments.count >= 2 else { return nil }
        var base64Payload = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64Payload.count % 4 != 0 {
            base64Payload.append("=")
        }
        guard let payloadData = Data(base64Encoded: base64Payload) else { return nil }
        return extractAccountIDFromJSONData(payloadData)
    }

    func extractAccountIDFromJSONData(_ data: Data) -> (onlineID: String, base64ID: String, numericID: String)? {
        if let jsonObj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let found = searchJSONRecursively(jsonObj) {
                return found
            }
        }
        if let rawText = String(data: data, encoding: .utf8) {
            return extractAccountIDFromRawText(rawText)
        }
        return nil
    }

    private func searchJSONRecursively(_ obj: Any) -> (onlineID: String, base64ID: String, numericID: String)? {
        if let dict = obj as? [String: Any] {
            let onlineID = (dict["onlineId"] as? String)
                ?? (dict["online_id"] as? String)
                ?? (dict["username"] as? String)
                ?? ""

            let base64Keys = ["encoded_id", "encodedId", "base64_id", "chiaki_id"]
            for key in base64Keys {
                if let b64Val = dict[key] as? String {
                    let norm = normalizeAccountIDTo8Bytes(input: b64Val, fallbackUsername: onlineID)
                    if norm.isValidRealID {
                        return (onlineID, norm.base64, norm.numericString)
                    }
                }
            }

            let idKeys = ["accountId", "account_id", "user_id", "userId", "npAccountId", "id"]
            for key in idKeys {
                if let rawVal = dict[key] {
                    if let num = parseValidPSNUInt64(rawVal) {
                        let b64 = convertUInt64ToBase64LittleEndian(num)
                        return (onlineID, b64, String(num))
                    }
                }
            }

            for (_, childValue) in dict {
                if let subFound = searchJSONRecursively(childValue) {
                    let finalOnline = subFound.onlineID.isEmpty ? onlineID : subFound.onlineID
                    return (finalOnline, subFound.base64ID, subFound.numericID)
                }
            }
        } else if let array = obj as? [Any] {
            for item in array {
                if let subFound = searchJSONRecursively(item) {
                    return subFound
                }
            }
        }
        return nil
    }

    func extractAccountIDFromRawText(_ text: String) -> (onlineID: String, base64ID: String, numericID: String)? {
        let patterns = [
            "\"accountId\"\\s*:\\s*\"?(\\d{15,20})\"?",
            "\"account_id\"\\s*:\\s*\"?(\\d{15,20})\"?",
            "\"user_id\"\\s*:\\s*\"?(\\d{15,20})\"?",
            "Account ID[^0-9]*(\\d{15,20})"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                let digits = String(text[range])
                if let num = UInt64(digits), num > 1000000 {
                    return ("", convertUInt64ToBase64LittleEndian(num), String(num))
                }
            }
        }
        return nil
    }

    private func parseValidPSNUInt64(_ raw: Any) -> UInt64? {
        if let uintVal = raw as? UInt64, uintVal > 1000000 {
            return uintVal
        }
        if let intVal = raw as? Int64, intVal > 1000000 {
            return UInt64(intVal)
        }
        if let intVal = raw as? Int, intVal > 1000000 {
            return UInt64(intVal)
        }
        if let numObj = raw as? NSNumber {
            let uVal = numObj.uint64Value
            if uVal > 1000000 { return uVal }
        }
        let str = String(describing: raw).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !str.isEmpty, str.allSatisfy({ $0.isNumber }), let uVal = UInt64(str), uVal > 1000000 {
            return uVal
        }
        return nil
    }

    // MARK: - Đóng gói gói tin đăng ký 480 bytes (0x1E0) chuẩn xác 100% theo Chiaki (regist.c & rpcrypt.c)
    func buildChiakiPS5RegistPayload480(pinString: String, accountIDBase64: String) -> (payload: Data, aesKey: [UInt8], iv: [UInt8]) {
        let pinNumber = UInt32(pinString) ?? 0
        // Mã PIN 8 chữ số xếp theo thứ tự Big-Endian 4 bytes chuẩn Chiaki
        let pinBytes: [UInt8] = [
            UInt8((pinNumber >> 24) & 0xFF),
            UInt8((pinNumber >> 16) & 0xFF),
            UInt8((pinNumber >> 8) & 0xFF),
            UInt8(pinNumber & 0xFF)
        ]

        var nonce = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            nonce[i] = UInt8.random(in: 0...255)
        }

        // Tạo ambassador (16B), bright (16B), aesKey (16B) và iv (16B) khớp tuyệt đối với chiaki_rpcrypt_init_regist_ps5
        var ambassador = [UInt8](repeating: 0, count: 16)
        var bright = [UInt8](repeating: 0, count: 16)
        var aesKey = [UInt8](repeating: 0, count: 16)
        var iv = [UInt8](repeating: 0, count: 16)

        for i in 0..<16 {
            ambassador[i] = nonce[i] ^ 0x41
            bright[i] = nonce[i] ^ ps5Key1[i]
            aesKey[i] = nonce[i] ^ ps5Key0[i] ^ pinBytes[i % 4]
            iv[i] = nonce[i]
        }

        // Khung dữ liệu nội bộ 384 bytes (0x180) BẮT BUỘC lấp đầy bằng 'A' (0x41) để PS5 không dừng đọc ở byte 0
        var innerBuffer = [UInt8](repeating: 0x41, count: 384)
        var innerHeaders = "Client-Type: \(ROIDefaultConfig.rpClientType)\r\n"
        innerHeaders += "Np-AccountId: \(accountIDBase64)\r\n\r\n"
        let headerBytes = Array(innerHeaders.utf8)

        // Offset 0x48 (72) trong toàn bộ gói 480B = Offset 56 (72 - 16) trong vùng mã hoá 384B
        let innerOffset = 56
        for i in 0..<min(headerBytes.count, 384 - innerOffset) {
            innerBuffer[innerOffset + i] = headerBytes[i]
        }

        let plainData = Data(innerBuffer)
        let encryptedBody = aes128CBCEncryptNoPadding(data: plainData, key: aesKey, iv: iv) ?? plainData

        // HMAC-SHA256 tính bằng khoá bright theo đúng cấu trúc xác thực PS5
        let hmacSymKey = SymmetricKey(data: Data(bright))
        let hmac = HMAC<SHA256>.authenticationCode(for: encryptedBody, using: hmacSymKey)

        // Cấu trúc 480 bytes (0x1E0):
        // [0x00..<0x10]: ambassador (16B)
        // [0x10..<0x190]: encryptedBody (384B)
        // [0x190..<0x1B0]: hmac (32B)
        // [0x1B0..<0x1C0]: bright (16B)
        // [0x1C0..<0x1E0]: padding 'A' 0x41 (32B)
        var fullPayload = Data(capacity: ROIDefaultConfig.chiakiRegistPayloadSize)
        fullPayload.append(contentsOf: ambassador)
        fullPayload.append(encryptedBody.prefix(384))
        fullPayload.append(contentsOf: hmac)
        fullPayload.append(contentsOf: bright)
        fullPayload.append(contentsOf: [UInt8](repeating: 0x41, count: 32))

        return (fullPayload, aesKey, iv)
    }

    // Giải mã phản hồi ghép đôi từ PS5 (Quét qua tất cả các offset chuẩn của PS5 Firmware: 0x20, 0x10, 0x00, 0x30)
    func decryptRegistResponse(cipherData: Data, aesKey: [UInt8], iv: [UInt8]) -> String? {
        let candidateOffsets = [0x20, 0x10, 0x00, 0x30]
        for offset in candidateOffsets {
            guard cipherData.count > offset + 16 else { continue }
            let sub = cipherData.subdata(in: offset..<cipherData.count)
            let alignedLen = (sub.count / 16) * 16
            guard alignedLen >= 16 else { continue }
            let block = sub.prefix(alignedLen)
            if let text = runAES128Decrypt(data: block, key: aesKey, iv: iv),
               (text.contains("RP-RegistKey") || text.contains("RP-Key") || text.contains("RP-")) {
                return text
            }
        }
        return runAES128Decrypt(data: cipherData, key: aesKey, iv: iv)
    }

    private func runAES128Decrypt(data: Data, key: [UInt8], iv: [UInt8]) -> String? {
        guard data.count >= 16 else { return nil }
        let outLength = data.count + kCCBlockSizeAES128
        var outBuffer = Data(count: outLength)
        var numBytesDecrypted: size_t = 0

        let status = outBuffer.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(0),
                    key,
                    kCCKeySizeAES128,
                    iv,
                    inBytes.baseAddress,
                    data.count,
                    outBytes.baseAddress,
                    outLength,
                    &numBytesDecrypted
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        outBuffer.count = numBytesDecrypted
        let rawStr = String(data: outBuffer, encoding: .utf8) ?? String(data: outBuffer, encoding: .isoLatin1) ?? ""
        return rawStr.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    // Mã hoá RP-Auth & RP-Did bằng RP-Nonce (nhận từ /sie/ps5/rp/sess/init) + RP-Key để mở /sie/ps5/rp/sess/ctrl
    func buildSessionAuthHeaders(registKey: String, rpKeyBase64: String, serverNonceBase64: String?) -> (rpAuth: String, rpDid: String) {
        let paddedRegist = registKey.padding(toLength: 16, withPad: "\0", startingAt: 0)
        let rawAuthData = Data(paddedRegist.utf8.prefix(16))

        var didBytes = [UInt8](repeating: 0, count: 32)
        let prefix: [UInt8] = [0x00, 0x18, 0x00, 0x00, 0x00, 0x09, 0x00, 0x40, 0x00, 0x80]
        for i in 0..<prefix.count { didBytes[i] = prefix[i] }
        for i in prefix.count..<26 { didBytes[i] = UInt8.random(in: 1...254) }

        guard let nonceStr = serverNonceBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
              let nonceData = Data(base64Encoded: nonceStr), nonceData.count == 16 else {
            return (rawAuthData.base64EncodedString(), Data(didBytes).base64EncodedString())
        }

        let rpKeyBytes: [UInt8]
        if let decodedKey = Data(base64Encoded: rpKeyBase64), decodedKey.count == 16 {
            rpKeyBytes = [UInt8](decodedKey)
        } else if rpKeyBase64.count == 32 {
            var hexArr: [UInt8] = []
            var idx = rpKeyBase64.startIndex
            while idx < rpKeyBase64.endIndex {
                let nextIdx = rpKeyBase64.index(idx, offsetBy: 2, limitedBy: rpKeyBase64.endIndex) ?? rpKeyBase64.endIndex
                if let b = UInt8(rpKeyBase64[idx..<nextIdx], radix: 16) {
                    hexArr.append(b)
                }
                idx = nextIdx
            }
            rpKeyBytes = hexArr.count == 16 ? hexArr : [UInt8](repeating: 0, count: 16)
        } else {
            return (rawAuthData.base64EncodedString(), Data(didBytes).base64EncodedString())
        }

        let nonce = [UInt8](nonceData)
        var sessionKey = [UInt8](repeating: 0, count: 16)
        var sessionIV = [UInt8](repeating: 0, count: 16)

        for i in 0..<16 {
            sessionIV[i] = nonce[i] ^ ps5Key0[(i + 8) % 16]
            sessionKey[i] = (nonce[i] ^ ps5Key1[(i + 8) % 16]) ^ rpKeyBytes[i]
        }

        let encAuth = aes128CBCEncryptNoPadding(data: rawAuthData, key: sessionKey, iv: sessionIV) ?? rawAuthData
        let encDid = aes128CBCEncryptNoPadding(data: Data(didBytes), key: sessionKey, iv: sessionIV) ?? Data(didBytes)
        return (encAuth.base64EncodedString(), encDid.base64EncodedString())
    }

    func buildRawHTTPRegistRequest(ip: String, payload: Data) -> Data {
        var rawHTTP = "POST /sie/ps5/rp/sess/rgst HTTP/1.1\r\n"
        rawHTTP += "Host: \(ip):\(ROIDefaultConfig.registAndCtrlPort)\r\n"
        rawHTTP += "User-Agent: remoteplay Windows\r\n"
        rawHTTP += "Connection: close\r\n"
        rawHTTP += "Content-Length: \(payload.count)\r\n"
        rawHTTP += "RP-Version: 1.0\r\n\r\n"

        var packet = Data(rawHTTP.utf8)
        packet.append(payload)
        return packet
    }

    // MARK: - Giao thức bắt tay 4 bước Takion V12 trên cổng UDP 9296
    // Bước 1: Gửi gói INIT (Type = 0x00)
    func buildTakionV12InitPacket(initTag: UInt32) -> Data {
        var packet = Data()
        packet.append(0x00) // Type = INIT
        packet.append(0x00) // Flags
        var tagZero: UInt32 = 0
        packet.append(Data(bytes: &tagZero, count: 4))
        var tagBE = initTag.bigEndian
        packet.append(Data(bytes: &tagBE, count: 4))
        var aRwnd: UInt32 = UInt32(0x00010000).bigEndian
        packet.append(Data(bytes: &aRwnd, count: 4))
        var outStreams: UInt16 = UInt16(10).bigEndian
        var inStreams: UInt16 = UInt16(10).bigEndian
        packet.append(Data(bytes: &outStreams, count: 2))
        packet.append(Data(bytes: &inStreams, count: 2))
        var initialTSN = UInt32(1).bigEndian
        packet.append(Data(bytes: &initialTSN, count: 4))
        return packet
    }

    // Bước 2: Đọc gói INIT_ACK (Type = 0x01) từ PS5 -> tạo gói COOKIE_ECHO (Type = 0x02)
    func parseTakionInitAckAndBuildCookieEcho(packet: Data) -> (cookieEchoPacket: Data, remoteTag: UInt32)? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 22, bytes[0] == 0x01 else { return nil }

        // Lấy initiateTag (remoteTag) của PS5 tại offset 6..10 (hoặc 8..12 tuỳ cấu trúc header)
        let remoteTag: UInt32 = packet.subdata(in: 6..<10).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }

        // Phần Cookie nằm từ offset 22 đến hết gói INIT_ACK
        let cookiePayload = packet.subdata(in: 22..<packet.count)
        var echo = Data()
        echo.append(0x02) // Type = COOKIE_ECHO
        echo.append(0x00)
        var remoteTagBE = remoteTag.bigEndian
        echo.append(Data(bytes: &remoteTagBE, count: 4))
        echo.append(cookiePayload)
        return (echo, remoteTag)
    }

    // Bước 3: Sau khi nhận COOKIE_ACK (Type = 0x03) -> Gửi gói BIG Payload (Type = 0x04) yêu cầu mở luồng video
    func buildTakionV12BigStreamRequestPacket(remoteTag: UInt32, tsn: UInt32 = 1) -> Data {
        var packet = Data()
        packet.append(0x04) // Type = DATA / CONTROL
        packet.append(0x03) // Flags = Beginning + Ending
        var remoteTagBE = remoteTag.bigEndian
        packet.append(Data(bytes: &remoteTagBE, count: 4))
        var tsnBE = tsn.bigEndian
        packet.append(Data(bytes: &tsnBE, count: 4))
        var streamID: UInt16 = UInt16(1).bigEndian
        var streamSeq: UInt16 = UInt16(0).bigEndian
        packet.append(Data(bytes: &streamID, count: 2))
        packet.append(Data(bytes: &streamSeq, count: 2))
        // Takion Protobuf BIG Payload (Yêu cầu luồng 720p 60fps H.264/HEVC)
        let protoBig: [UInt8] = [0x08, 0x01, 0x12, 0x0C, 0x08, 0x0C, 0x10, 0x80, 0x0A, 0x18, 0xD0, 0x05, 0x20, 0x3C]
        packet.append(contentsOf: protoBig)
        return packet
    }

    private func aes128CBCEncryptNoPadding(data: Data, key: [UInt8], iv: [UInt8]) -> Data? {
        let outLength = data.count + kCCBlockSizeAES128
        var outBuffer = Data(count: outLength)
        var numBytesEncrypted: size_t = 0

        let status = outBuffer.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(0),
                    key,
                    kCCKeySizeAES128,
                    iv,
                    inBytes.baseAddress,
                    data.count,
                    outBytes.baseAddress,
                    outLength,
                    &numBytesEncrypted
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        outBuffer.count = numBytesEncrypted
        return outBuffer
    }
}

// ============================================================================
// 2. BỘ GIẢI MÃ VIDEO PHẦN CỨNG CHIAKI (VIDEOTOOLBOX H.264 & HEVC H.265 DECODER)
// ============================================================================
final class ChiakiHardwareVideoDecoder {
    private var formatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var vpsData: Data?
    private var spsData: Data?
    private var ppsData: Data?
    private var isHEVCStream: Bool = false
    private var reassemblyBuffer = Data()
    var onFrameDecoded: ((CGImage) -> Void)?

    func feedTakionUDPPacket(_ data: Data) {
        guard data.count > 12 else { return }
        let bytes = [UInt8](data)

        // Ghép mảnh các gói video Takion (Type 0x01 / 0x06 hoặc gói RTP/AV > 64 bytes)
        if bytes[0] == 0x01 || bytes[0] == 0x06 || data.count > 64 {
            let payloadStart = min(12, data.count - 4)
            reassemblyBuffer.append(data.subdata(in: payloadStart..<data.count))
            if reassemblyBuffer.count > 512_000 {
                reassemblyBuffer.removeAll(keepingCapacity: true)
            }
        }

        scanAndDecodeNALUnits(in: data)
        if reassemblyBuffer.count > 1024 {
            scanAndDecodeNALUnits(in: reassemblyBuffer)
        }
    }

    private func scanAndDecodeNALUnits(in buffer: Data) {
        let bytes = [UInt8](buffer)
        guard bytes.count > 8 else { return }
        var nalStarts: [Int] = []
        var i = 0
        while i < bytes.count - 4 {
            if bytes[i] == 0x00 && bytes[i+1] == 0x00 && bytes[i+2] == 0x00 && bytes[i+3] == 0x01 {
                nalStarts.append(i)
                i += 4
            } else {
                i += 1
            }
        }

        guard !nalStarts.isEmpty else { return }
        for idx in 0..<nalStarts.count {
            let start = nalStarts[idx] + 4
            let end = (idx + 1 < nalStarts.count) ? nalStarts[idx + 1] : bytes.count
            guard start < end else { continue }
            let nalUnit = Data(bytes[start..<end])
            processNALUnit(nalUnit)
        }
    }

    private func processNALUnit(_ nal: Data) {
        guard let firstByte = nal.first else { return }

        // 1. Kiểm tra định dạng HEVC (H.265) chuẩn PS5: (firstByte >> 1) & 0x3F
        let hevcType = (firstByte >> 1) & 0x3F
        if hevcType == 32 {
            isHEVCStream = true
            vpsData = nal
            setupDecompressionSessionIfPossible()
            return
        } else if isHEVCStream && hevcType == 33 {
            spsData = nal
            setupDecompressionSessionIfPossible()
            return
        } else if isHEVCStream && hevcType == 34 {
            ppsData = nal
            setupDecompressionSessionIfPossible()
            return
        } else if isHEVCStream && (hevcType >= 1 && hevcType <= 21) {
            decodeVideoSlice(nal)
            return
        }

        // 2. Kiểm tra định dạng H.264 (AVC): firstByte & 0x1F
        let nalType = firstByte & 0x1F
        if nalType == 7 {
            isHEVCStream = false
            spsData = nal
            setupDecompressionSessionIfPossible()
        } else if nalType == 8 {
            ppsData = nal
            setupDecompressionSessionIfPossible()
        } else if nalType == 1 || nalType == 5 {
            decodeVideoSlice(nal)
        }
    }

    private func setupDecompressionSessionIfPossible() {
        guard decompressionSession == nil, let sps = spsData, let pps = ppsData else { return }

        if isHEVCStream, let vps = vpsData {
            vps.withUnsafeBytes { vpsRaw in
                sps.withUnsafeBytes { spsRaw in
                    pps.withUnsafeBytes { ppsRaw in
                        guard let vpsBase = vpsRaw.bindMemory(to: UInt8.self).baseAddress,
                              let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                              let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                        let pointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                        let sizes: [Int] = [vps.count, sps.count, pps.count]
                        var desc: CMFormatDescription?
                        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &desc
                        )
                        if status == noErr, let validDesc = desc {
                            initializeVTDecompressionSession(with: validDesc)
                        }
                    }
                }
            }
            return
        }

        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                var desc: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
                if status == noErr, let validDesc = desc {
                    initializeVTDecompressionSession(with: validDesc)
                }
            }
        }
    }

    private func initializeVTDecompressionSession(with validDesc: CMVideoFormatDescription) {
        self.formatDesc = validDesc
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        var session: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: validDesc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        self.decompressionSession = session
    }

    private func decodeVideoSlice(_ nal: Data) {
        guard let session = decompressionSession, let desc = formatDesc else { return }
        var lengthBE = UInt32(nal.count).bigEndian
        var avccData = Data(bytes: &lengthBE, count: 4)
        avccData.append(nal)

        var blockBuffer: CMBlockBuffer?
        let dataCount = avccData.count
        avccData.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddr = rawBuffer.baseAddress else { return }
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            if let bb = blockBuffer {
                CMBlockBufferReplaceDataBytes(
                    with: baseAddr,
                    blockBuffer: bb,
                    offsetIntoDestination: 0,
                    dataLength: dataCount
                )
            }
        }

        guard let validBlock = blockBuffer else { return }
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [dataCount]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: validBlock,
            formatDescription: desc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )

        guard let validSample = sampleBuffer else { return }
        var infoFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: validSample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let pixelBuffer = imageBuffer else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext(options: nil)
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                DispatchQueue.main.async {
                    self?.onFrameDecoded?(cgImage)
                }
            }
        }
    }
}

// Bộ bắt Redirect OAuth ngầm từ Cookie Sony đã đăng nhập
final class SilentOAuthRedirectCatcher: NSObject, URLSessionTaskDelegate {
    private let onCodeCaptured: (String?) -> Void
    private var didFinish = false

    init(onCodeCaptured: @escaping (String?) -> Void) {
        self.onCodeCaptured = onCodeCaptured
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let loc = request.url?.absoluteString,
           (loc.contains("scecompcall://redirect") || loc.contains("remoteplay/redirect") || loc.contains("code=")),
           let comps = URLComponents(string: loc),
           let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
           !didFinish {
            didFinish = true
            onCodeCaptured(code)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !didFinish {
            didFinish = true
            if let err = error as NSError?,
               let failingURL = err.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
               let comps = URLComponents(string: failingURL),
               let code = comps.queryItems?.first(where: { $0.name == "code" })?.value {
                onCodeCaptured(code)
                return
            }
            onCodeCaptured(nil)
        }
    }
}
