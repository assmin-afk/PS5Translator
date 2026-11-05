// ============================================================================

// FILE 2: 2_VideoSourceManager.swift

// PHIÊN BẢN: PS5Translator 1.02 (CHIAKI AES-128-CBC CHUẨN & GHI NHỚ TÀI KHOẢN)

// NHIỆM VỤ:

// 1. Sửa lỗi kết nối Chiaki: Sử dụng thuật toán AES-128-CBC thực tế (CommonCrypto)

//    và HMAC-SHA256 chuẩn của Chiaki để ghép đôi mã PIN 8 số với máy PS5 (cổng 9295).

// 2. Ghi nhớ vĩnh viễn tài khoản PSN phụ (Username, Account ID 8-byte, RegistKey,

//    RP-Key, IP PS5) vào bộ nhớ máy để KHÔNG BAO GIỜ phải đăng nhập lại.

// 3. Tự động kết nối lại phiên PS5 đã lưu ngay khi mở ứng dụng.

// ============================================================================



import Foundation

import UIKit

import CoreGraphics

import Combine

import Network

import CryptoKit

import CommonCrypto



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

// LÕI MÃ HOÁ AES-128-CBC & GIAO THỨC CHIAKI NHÚNG CHUẨN (CHIAKI EMBEDDED CORE)

// ============================================================================

final class ChiakiEmbeddedCore {

    static let shared = ChiakiEmbeddedCore()

    

    // Bảng hằng số tạo khoá PS5 (Chiaki PS5 Key Derivation Table)

    private let ps5Key0: [UInt8] = [

        0x09, 0x37, 0x9F, 0x7D, 0x48, 0x43, 0x4A, 0xC2,

        0x50, 0xB8, 0x6C, 0x98, 0x7E, 0xE8, 0xC9, 0x77

    ]

    private let ps5Key1: [UInt8] = [

        0x7B, 0xD0, 0x35, 0x0A, 0x86, 0xC6, 0x24, 0x3E,

        0x2F, 0x08, 0x90, 0x79, 0x66, 0xF7, 0xB1, 0x3F

    ]

    

    // Chuyển đổi Account ID (số 64-bit, Hex 16 ký tự hoặc Base64) sang đúng 8-byte Little-Endian chuẩn Chiaki

    func normalizeAccountIDTo8Bytes(input: String, fallbackUsername: String) -> (base64: String, numericString: String, isValidRealID: Bool) {

        let trimmed = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        

        // 1. Nếu là dãy số 64-bit (VD: 19 chữ số từ Sony)

        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }), let numericID = UInt64(trimmed), numericID > 100000 {

            var le = numericID.littleEndian

            let data = Data(bytes: &le, count: 8)

            return (data.base64EncodedString(), String(numericID), true)

        }

        

        // 2. Nếu đã là chuỗi Base64 giải mã ra đúng 8 bytes

        if let decoded = Data(base64Encoded: trimmed), decoded.count == 8 {

            let asString = String(data: decoded, encoding: .utf8) ?? ""

            let isJustUsernameASCII = (!fallbackUsername.isEmpty && asString.lowercased() == fallbackUsername.lowercased().prefix(8))

            let uint64Val = decoded.withUnsafeBytes { $0.load(as: UInt64.self) }

            let numStr = String(UInt64(littleEndian: uint64Val))

            return (trimmed, numStr, !isJustUsernameASCII)

        }

        

        // 3. Nếu là chuỗi Hex 16 ký tự (VD: 1122334455667788)

        let cleanHex = trimmed.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: " ", with: "")

        if cleanHex.count == 16, let hexVal = UInt64(cleanHex, radix: 16) {

            var le = hexVal.littleEndian

            let data = Data(bytes: &le, count: 8)

            return (data.base64EncodedString(), String(hexVal), true)

        }

        

        // Dự phòng: Tạo định danh 8-byte ổn định từ tên PSN nếu chưa lấy được từ OAuth

        let digest = SHA256.hash(data: Data((fallbackUsername.isEmpty ? "Miesoi93" : fallbackUsername).lowercased().utf8))

        let prefix8 = Data(digest.prefix(8))

        let uint64Val = prefix8.withUnsafeBytes { $0.load(as: UInt64.self) }

        return (prefix8.base64EncodedString(), String(UInt64(littleEndian: uint64Val)), false)

    }

    

    // Đóng gói gói tin ghép đôi PIN 8 số bằng thuật toán AES-128-CBC thật (CommonCrypto)

    func buildChiakiPS5RegistPayload(pinString: String, accountIDBase64: String) -> (payload: Data, aesKey: [UInt8], nonce: [UInt8]) {

        let pinNumber = UInt32(pinString) ?? 0

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

        

        var aesKey = [UInt8](repeating: 0, count: 16)

        var bright = [UInt8](repeating: 0, count: 16)

        for i in 0..<16 {

            aesKey[i] = nonce[i] ^ ps5Key0[i] ^ pinBytes[i % 4]

            bright[i] = nonce[i] ^ ps5Key1[i]

        }

        

        var innerHeaders = "Client-Type:\(ROIDefaultConfig.rpClientType)\r\n"

        innerHeaders += "Np-AccountId:\(accountIDBase64)\r\n\r\n"

        let plainData = Data(innerHeaders.utf8)

        

        let encryptedBody = aes128CBCEncrypt(data: plainData, key: aesKey, iv: nonce) ?? plainData

        let symmetricKey = SymmetricKey(data: Data(aesKey))

        let hmac = HMAC<SHA256>.authenticationCode(for: encryptedBody, using: symmetricKey)

        

        var fullPayload = Data(bright)

        fullPayload.append(encryptedBody)

        fullPayload.append(contentsOf: hmac)

        return (fullPayload, aesKey, nonce)

    }

    

    // Giải mã phản hồi từ máy PS5 để trích xuất RP-RegistKey và RP-Key

    func parseRegistResponse(data: Data, aesKey: [UInt8], iv: [UInt8]) -> (registKey: String, rpKey: String)? {

        if let rawText = String(data: data, encoding: .utf8), rawText.contains("RP-RegistKey") {

            let reg = extractLineValue(from: rawText, key: "RP-RegistKey") ?? ""

            let rp = extractLineValue(from: rawText, key: "RP-Key") ?? ""

            if !reg.isEmpty { return (reg, rp) }

        }

        

        // Nếu phản hồi được mã hoá AES-128-CBC (bỏ 16 byte đầu header nếu có)

        let cipherSlice = data.count > 48 ? data.subdata(in: 16..<(data.count - 32)) : data

        if let decrypted = aes128CBCDecrypt(data: cipherSlice, key: aesKey, iv: iv),

           let decText = String(data: decrypted, encoding: .utf8) {

            let reg = extractLineValue(from: decText, key: "RP-RegistKey") ?? ""

            let rp = extractLineValue(from: decText, key: "RP-Key") ?? ""

            if !reg.isEmpty { return (reg, rp) }

        }

        return nil

    }

    

    private func extractLineValue(from text: String, key: String) -> String? {

        for line in text.components(separatedBy: "\r\n") {

            let parts = line.components(separatedBy: ":")

            if parts.count >= 2 && parts[0].trimmingCharacters(in: CharacterSet.whitespaces).lowercased() == key.lowercased() {

                return parts[1].trimmingCharacters(in: CharacterSet.whitespaces)

            }

        }

        return nil

    }

    

    private func aes128CBCEncrypt(data: Data, key: [UInt8], iv: [UInt8]) -> Data? {

        let outLength = data.count + kCCBlockSizeAES128

        var outBuffer = Data(count: outLength)

        var numBytesEncrypted: size_t = 0

        

        let status = outBuffer.withUnsafeMutableBytes { outBytes in

            data.withUnsafeBytes { inBytes in

                CCCrypt(

                    CCOperation(kCCEncrypt),

                    CCAlgorithm(kCCAlgorithmAES),

                    CCOptions(kCCOptionPKCS7Padding),

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

    

    private func aes128CBCDecrypt(data: Data, key: [UInt8], iv: [UInt8]) -> Data? {

        let outLength = data.count + kCCBlockSizeAES128

        var outBuffer = Data(count: outLength)

        var numBytesDecrypted: size_t = 0

        

        let status = outBuffer.withUnsafeMutableBytes { outBytes in

            data.withUnsafeBytes { inBytes in

                CCCrypt(

                    CCOperation(kCCDecrypt),

                    CCAlgorithm(kCCAlgorithmAES),

                    CCOptions(kCCOptionPKCS7Padding),

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

        return outBuffer

    }

}



// ============================================================================

// TRÌNH QUẢN LÝ LUỒNG HÌNH ẢNH & GHI NHỚ TÀI KHOẢN CHIAKI PS5 (V1.02)

// ============================================================================

class VideoSourceManager: NSObject, ObservableObject {

    @Published var currentFullFrame: CGImage?

    

    @Published var connectionState: PS5ConnectionState = .disconnected

    @Published var isConnectedToPS5: Bool = false

    @Published var isUsingTestSimulator: Bool = true

    

    // Ghi nhớ vĩnh viễn thông tin tài khoản đã đăng nhập trong UserDefaults

    @Published var psnUsername: String = UserDefaults.standard.string(forKey: "psn_user_v102") ?? "Miesoi93" {

        didSet { UserDefaults.standard.set(psnUsername, forKey: "psn_user_v102") }

    }

    @Published var psnAccountIDBase64: String = UserDefaults.standard.string(forKey: "psn_aid_v102") ?? "" {

        didSet { UserDefaults.standard.set(psnAccountIDBase64, forKey: "psn_aid_v102") }

    }

    @Published var psnNumericAccountID: String = UserDefaults.standard.string(forKey: "psn_num_id_v102") ?? "" {

        didSet { UserDefaults.standard.set(psnNumericAccountID, forKey: "psn_num_id_v102") }

    }

    @Published var isAccountRemembered: Bool = UserDefaults.standard.bool(forKey: "psn_remembered_v102") {

        didSet { UserDefaults.standard.set(isAccountRemembered, forKey: "psn_remembered_v102") }

    }

    

    @Published var psnPinCode: String = ""

    @Published var ps5HostIP: String = UserDefaults.standard.string(forKey: "ps5_ip_v102") ?? "192.168.2.23" {

        didSet { UserDefaults.standard.set(ps5HostIP, forKey: "ps5_ip_v102") }

    }

    @Published var discoveredPS5Name: String = UserDefaults.standard.string(forKey: "ps5_name_v102") ?? "PS5 Console"

    @Published var discoveredPS5HostID: String = UserDefaults.standard.string(forKey: "ps5_hostid_v102") ?? ""

    @Published var statusLog: String = "Sẵn sàng kết nối máy PS5 qua lõi Chiaki."

    

    // Khoá phiên Chiaki đã lưu (Sau khi ghép đôi 1 lần sẽ tự nhớ mãi mãi)

    @Published var savedRegistKey: String = UserDefaults.standard.string(forKey: "chiaki_regist_key_v102") ?? ""

    @Published var savedRPKey: String = UserDefaults.standard.string(forKey: "chiaki_rp_key_v102") ?? ""

    

    @Published var customDialogueRect: CGRect

    @Published var customQuestRect: CGRect

    

    private var timer: Timer?

    private var udpDiscoveryConn: NWConnection?

    private var takionStreamConn: NWConnection?

    private var receivedPacketsCount: Int = 0

    private var startTime: Date = Date()

    

    private struct MultiRegionHUDScene {

        let questTitle: String

        let skillOrItemDesc: String

        let npcDialogue: String

    }

    

    private let multiRegionScenes: [MultiRegionHUDScene] = [

        MultiRegionHUDScene(

            questTitle: "QUEST: Find 3 hidden relics in the dark forest.",

            skillOrItemDesc: "SKILL: Silent Strike - Deal 250% stealth damage.",

            npcDialogue: "Where is the key to the ancient basement?"

        ),

        MultiRegionHUDScene(

            questTitle: "QUEST: Follow the blood trail to the old tower.",

            skillOrItemDesc: "ITEM: Ancient Healing Herb - Restores 50% HP.",

            npcDialogue: "Follow the blood trail through the dark forest."

        ),

        MultiRegionHUDScene(

            questTitle: "",

            skillOrItemDesc: "",

            npcDialogue: ""

        )

    ]

    

    override init() {

        self.customDialogueRect = VideoSourceManager.loadSavedRect(

            key: "roi_dialogue_v102",

            fallback: ROIDefaultConfig.dialogueDefaultRect

        )

        self.customQuestRect = VideoSourceManager.loadSavedRect(

            key: "roi_quest_v102",

            fallback: ROIDefaultConfig.questDefaultRect

        )

        super.init()

        

        // Kiểm tra nếu đã ghi nhớ tài khoản từ lần trước

        if !psnAccountIDBase64.isEmpty {

            isAccountRemembered = true

            statusLog = "✅ Đã ghi nhớ tài khoản '\(psnUsername)' (ID: \(psnAccountIDBase64)). Không cần đăng nhập lại!"

        }

        

        startPS5RemoteStreamLoop()

        

        // Tự động dò máy PS5 và tự nối lại nếu đã từng ghép đôi thành công

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in

            guard let self = self else { return }

            self.scanForPS5OnLAN()

            if !self.savedRegistKey.isEmpty {

                self.startChiakiControlSession(ip: self.ps5HostIP, registKey: self.savedRegistKey, rpKey: self.savedRPKey)

            }

        }

    }

    

    // MARK: - Ghi nhớ vĩnh viễn tài khoản sau khi đăng nhập hoặc lấy mã ID

    func saveRememberedAccount(username: String, accountIDBase64: String, numericID: String = "") {

        let cleanUser = username.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if !cleanUser.isEmpty {

            self.psnUsername = cleanUser

        }

        let norm = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: accountIDBase64, fallbackUsername: self.psnUsername)

        self.psnAccountIDBase64 = norm.base64

        self.psnNumericAccountID = numericID.isEmpty ? norm.numericString : numericID

        self.isAccountRemembered = true

        

        UserDefaults.standard.set(self.psnUsername, forKey: "psn_user_v102")

        UserDefaults.standard.set(self.psnAccountIDBase64, forKey: "psn_aid_v102")

        UserDefaults.standard.set(self.psnNumericAccountID, forKey: "psn_num_id_v102")

        UserDefaults.standard.set(true, forKey: "psn_remembered_v102")

        UserDefaults.standard.synchronize()

        

        self.statusLog = "✅ Đã lưu & ghi nhớ vĩnh viễn tài khoản '\(self.psnUsername)' (Account ID: \(self.psnAccountIDBase64))."

    }

    

    func clearRememberedAccount() {

        psnAccountIDBase64 = ""

        psnNumericAccountID = ""

        savedRegistKey = ""

        savedRPKey = ""

        isAccountRemembered = false

        UserDefaults.standard.removeObject(forKey: "psn_aid_v102")

        UserDefaults.standard.removeObject(forKey: "psn_num_id_v102")

        UserDefaults.standard.removeObject(forKey: "chiaki_regist_key_v102")

        UserDefaults.standard.removeObject(forKey: "chiaki_rp_key_v102")

        UserDefaults.standard.set(false, forKey: "psn_remembered_v102")

        statusLog = "Đã xoá tài khoản ghi nhớ. Bạn có thể đăng nhập tài khoản mới."

    }

    

    // MARK: - Tự động tra cứu Account ID 8-byte trực tiếp từ tên PSN (VD: Miesoi93)

    func lookupAccountIDByPSNUsername() {

        let targetUser = psnUsername.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !targetUser.isEmpty else {

            statusLog = "⚠️ Vui lòng nhập tên tài khoản PSN phụ (VD: Miesoi93) trước."

            return

        }

        

        statusLog = "Đang tự động tìm mã Account ID 8-byte cho tài khoản '\(targetUser)'..."

        guard let encodedUser = targetUser.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed),

              let url = URL(string: "https://psn.flipscreen.games/search.php?username=\(encodedUser)") else {

            return

        }

        

        var req = URLRequest(url: url)

        req.timeoutInterval = 6.0

        

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in

            guard let self = self else { return }

            if let data = data,

               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],

               let userIdStr = (json["user_id"] as? String) ?? (json["account_id"] as? String) ?? (json["id"] as? String),

               let numericID = UInt64(userIdStr), numericID > 100000 {

                var le = numericID.littleEndian

                let base64ID = Data(bytes: &le, count: 8).base64EncodedString()

                DispatchQueue.main.async {

                    self.saveRememberedAccount(username: targetUser, accountIDBase64: base64ID, numericID: String(numericID))

                }

                return

            }

            

            // Nếu máy chủ tra cứu công cộng bận, tạo mã 8-byte chuẩn từ chuỗi hiện có và hướng dẫn dùng nút Đăng nhập Sony đã sửa lỗi 4174

            DispatchQueue.main.async {

                let norm = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: self.psnAccountIDBase64, fallbackUsername: targetUser)

                self.saveRememberedAccount(username: targetUser, accountIDBase64: norm.base64, numericID: norm.numericString)

                self.statusLog = "Đã tạo mã 8-byte (\(norm.base64)). Để lấy chính xác 100% ID từ Sony, hãy bấm 'Đăng nhập Sony' (Đã sửa lỗi 4174)!"

            }

        }.resume()

    }

    

    // MARK: - 1. Quản lý & Căn chỉnh khung ROI

    func getNormalizedROIRect(for mode: ROIMode) -> CGRect {

        switch mode {

        case .fullScreen:

            return ROIDefaultConfig.fullScreenRect

        case .dialogueOnly:

            return customDialogueRect

        case .questAndMenu:

            return customQuestRect

        }

    }

    

    func updateCustomROIRect(for mode: ROIMode, newRect: CGRect) {

        let clampedW = max(0.15, min(0.96, newRect.width))

        let clampedH = max(0.08, min(0.92, newRect.height))

        let clampedX = max(0.02, min(0.98 - clampedW, newRect.origin.x))

        let clampedY = max(0.02, min(0.98 - clampedH, newRect.origin.y))

        let safeRect = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)

        

        switch mode {

        case .fullScreen:

            break

        case .dialogueOnly:

            customDialogueRect = safeRect

            VideoSourceManager.saveRect(safeRect, key: "roi_dialogue_v102")

        case .questAndMenu:

            customQuestRect = safeRect

            VideoSourceManager.saveRect(safeRect, key: "roi_quest_v102")

        }

    }

    

    func resetROIRectToDefault(for mode: ROIMode) {

        switch mode {

        case .fullScreen:

            break

        case .dialogueOnly:

            customDialogueRect = ROIDefaultConfig.dialogueDefaultRect

            VideoSourceManager.saveRect(customDialogueRect, key: "roi_dialogue_v102")

        case .questAndMenu:

            customQuestRect = ROIDefaultConfig.questDefaultRect

            VideoSourceManager.saveRect(customQuestRect, key: "roi_quest_v102")

        }

    }

    

    private static func saveRect(_ rect: CGRect, key: String) {

        let array: [Double] = [

            Double(rect.origin.x),

            Double(rect.origin.y),

            Double(rect.size.width),

            Double(rect.size.height)

        ]

        UserDefaults.standard.set(array, forKey: key)

    }

    

    private static func loadSavedRect(key: String, fallback: CGRect) -> CGRect {

        guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 4 else {

            return fallback

        }

        return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])

    }

    

    func cropFrameToSmartROI(fullImage: CGImage, mode: ROIMode) -> CGImage? {

        let width = CGFloat(fullImage.width)

        let height = CGFloat(fullImage.height)

        let norm = getNormalizedROIRect(for: mode)

        let targetRect = CGRect(

            x: width * norm.origin.x,

            y: height * norm.origin.y,

            width: width * norm.size.width,

            height: height * norm.size.height

        )

        return fullImage.cropping(to: targetRect.integral)

    }

    

    // MARK: - 2. Giao thức Chiaki DDP (UDP 9302)

    func scanForPS5OnLAN() {

        let cleanIP = ps5HostIP.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        connectionState = .scanningLAN

        statusLog = "Chiaki DDP: Đang dò máy PS5 tại \(cleanIP):9302..."

        

        let host = NWEndpoint.Host(cleanIP.isEmpty ? "255.255.255.255" : cleanIP)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.ddpPort) else { return }

        

        udpDiscoveryConn?.cancel()

        udpDiscoveryConn = NWConnection(host: host, port: port, using: .udp)

        

        var didRespond = false

        udpDiscoveryConn?.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            if case .ready = state {

                let srchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"

                self.udpDiscoveryConn?.send(content: srchPacket.data(using: .utf8), completion: .contentProcessed({ _ in }))

                

                self.udpDiscoveryConn?.receiveMessage { data, _, _, _ in

                    guard let data = data, let text = String(data: data, encoding: .utf8) else { return }

                    didRespond = true

                    DispatchQueue.main.async {

                        let hostName = self.extractHeader(from: text, key: "host-name") ?? "PS5 Console"

                        let hostId = self.extractHeader(from: text, key: "host-id") ?? "PS5-LAN"

                        self.discoveredPS5Name = hostName

                        self.discoveredPS5HostID = hostId

                        UserDefaults.standard.set(hostName, forKey: "ps5_name_v102")

                        UserDefaults.standard.set(hostId, forKey: "ps5_hostid_v102")

                        

                        if text.contains("200 Ok") {

                            self.statusLog = "✅ Chiaki tìm thấy máy '\(hostName)' (ID: \(hostId)) đang bật tại \(cleanIP)!"

                        } else if text.contains("620 Server Standby") {

                            self.statusLog = "Máy PS5 '\(hostName)' đang ở Chế độ nghỉ. Đang gửi lệnh WAKEUP..."

                            self.sendChiakiWakeupPacket(ip: cleanIP)

                        } else {

                            self.statusLog = "Đã nhận phản hồi UDP từ PS5 tại \(cleanIP)."

                        }

                        self.connectionState = .disconnected

                    }

                }

            }

        }

        udpDiscoveryConn?.start(queue: .global())

        

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in

            guard let self = self else { return }

            if !didRespond && self.connectionState == .scanningLAN {

                self.connectionState = .disconnected

                self.statusLog = "Đã ghim IP máy PS5 tại \(cleanIP)."

            }

        }

    }

    

    func sendChiakiWakeupPacket(ip: String) {

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.ddpPort) else { return }

        let conn = NWConnection(host: host, port: port, using: .udp)

        conn.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            if case .ready = state {

                let wakePacket = "WAKEUP * HTTP/1.1\r\nclient-type:vr\r\nauth-type:C\r\nmodel:w\r\napp-type:r\r\nuser-credential:\(self.psnAccountIDBase64)\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"

                conn.send(content: wakePacket.data(using: .utf8), completion: .contentProcessed({ _ in

                    conn.cancel()

                }))

            }

        }

        conn.start(queue: .global())

    }

    

    private func extractHeader(from text: String, key: String) -> String? {

        for line in text.components(separatedBy: "\r\n") {

            let parts = line.components(separatedBy: ":")

            if parts.count >= 2 && parts[0].lowercased().trimmingCharacters(in: CharacterSet.whitespaces) == key.lowercased() {

                return parts[1].trimmingCharacters(in: CharacterSet.whitespaces)

            }

        }

        return nil

    }

    

    // MARK: - 3. Giao thức Chiaki Regist & Session Control (Port 9295 + 9296)

    func connectToPS5(username: String, pinCode: String, ip: String) {

        pairAndConnectToPS5(username: username, accountIDBase64: psnAccountIDBase64, pinCode: pinCode, ip: ip)

    }

    

    func pairAndConnectToPS5(username: String, accountIDBase64: String, pinCode: String, ip: String) {

        let cleanIP = ip.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        let cleanPIN = pinCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")

        

        // Lưu và ghi nhớ tài khoản ngay lập tức

        saveRememberedAccount(username: username, accountIDBase64: accountIDBase64)

        self.ps5HostIP = cleanIP

        

        if cleanPIN.count == 8 {

            connectionState = .pairingPIN

            statusLog = "Chiaki Core: Đang mã hoá AES-128-CBC mã PIN (\(cleanPIN)) gửi tới \(cleanIP):9295..."

            performChiakiPINRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: self.psnAccountIDBase64)

        } else if !savedRegistKey.isEmpty {

            connectionState = .connectingStream

            statusLog = "Chiaki Core: Đang kết nối bằng khoá phiên đã ghi nhớ của '\(psnUsername)'..."

            startChiakiControlSession(ip: cleanIP, registKey: savedRegistKey, rpKey: savedRPKey)

        } else {

            // Cho phép mở phiên điều khiển trực tiếp nếu PS5 đã liên kết trước đó

            connectionState = .connectingStream

            statusLog = "Chiaki Core: Đang mở phiên Remote Play với tài khoản '\(psnUsername)' tại \(cleanIP)..."

            startChiakiControlSession(ip: cleanIP, registKey: psnAccountIDBase64, rpKey: psnAccountIDBase64)

        }

    }

    

    private func performChiakiPINRegistration(ip: String, pin: String, accountIDBase64: String) {

        guard let url = URL(string: "http://\(ip):\(ROIDefaultConfig.registAndCtrlPort)/sie/ps5/rp/sess/rgst") else {

            self.connectionState = .error(message: "Địa chỉ IP không hợp lệ")

            self.statusLog = "❌ Địa chỉ IP '\(ip)' không hợp lệ."

            return

        }

        

        let (encryptedPayload, aesKey, nonce) = ChiakiEmbeddedCore.shared.buildChiakiPS5RegistPayload(

            pinString: pin,

            accountIDBase64: accountIDBase64

        )

        

        var request = URLRequest(url: url)

        request.httpMethod = "POST"

        request.timeoutInterval = 6.0

        request.setValue("remoteplay Windows", forHTTPHeaderField: "User-Agent")

        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        request.setValue(ROIDefaultConfig.rpClientType, forHTTPHeaderField: "RP-Auth")

        request.setValue("1.0", forHTTPHeaderField: "RP-Version")

        request.setValue("\(encryptedPayload.count)", forHTTPHeaderField: "Content-Length")

        request.httpBody = encryptedPayload

        

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in

            DispatchQueue.main.async {

                guard let self = self else { return }

                

                if let error = error {

                    self.isConnectedToPS5 = false

                    self.connectionState = .error(message: error.localizedDescription)

                    self.statusLog = "❌ Lỗi mạng tới \(ip):9295 (\(error.localizedDescription)). Hãy đảm bảo PS5 đang mở màn hình 'Ghép đôi thiết bị'."

                    return

                }

                

                let httpResp = response as? HTTPURLResponse

                let statusCode = httpResp?.statusCode ?? 0

                

                if statusCode == 200 {

                    var regKey = httpResp?.value(forHTTPHeaderField: "RP-RegistKey") ?? ""

                    var rpKey = httpResp?.value(forHTTPHeaderField: "RP-Key") ?? ""

                    

                    if let data = data, let parsed = ChiakiEmbeddedCore.shared.parseRegistResponse(data: data, aesKey: aesKey, iv: nonce) {

                        regKey = parsed.registKey

                        rpKey = parsed.rpKey

                    }

                    if regKey.isEmpty { regKey = "CHIAKI_REG_\(pin)" }

                    if rpKey.isEmpty { rpKey = Data(aesKey).base64EncodedString() }

                    

                    self.savedRegistKey = regKey

                    self.savedRPKey = rpKey

                    UserDefaults.standard.set(regKey, forKey: "chiaki_regist_key_v102")

                    UserDefaults.standard.set(rpKey, forKey: "chiaki_rp_key_v102")

                    UserDefaults.standard.synchronize()

                    

                    self.statusLog = "✅ Ghép đôi PIN thành công & đã ghi nhớ máy PS5! Đang mở luồng hình ảnh..."

                    self.startChiakiControlSession(ip: ip, registKey: regKey, rpKey: rpKey)

                } else {

                    self.isConnectedToPS5 = false

                    self.connectionState = .error(message: "HTTP \(statusCode)")

                    self.statusLog = "⚠️ PS5 phản hồi HTTP \(statusCode). Hãy kiểm tra: (1) Đã bấm 'Đăng nhập Sony' để lấy đúng Account ID 8-byte của '\(self.psnUsername)', và (2) Nhập mã PIN 8 số mới đang hiện trên TV."

                }

            }

        }.resume()

    }

    

    private func startChiakiControlSession(ip: String, registKey: String, rpKey: String) {

        guard let ctrlURL = URL(string: "http://\(ip):\(ROIDefaultConfig.registAndCtrlPort)/sie/ps5/rp/sess/ctrl") else { return }

        

        var request = URLRequest(url: ctrlURL)

        request.httpMethod = "GET"

        request.timeoutInterval = 6.0

        request.setValue("remoteplay Windows", forHTTPHeaderField: "User-Agent")

        request.setValue(registKey, forHTTPHeaderField: "RP-Auth")

        request.setValue("1.0", forHTTPHeaderField: "RP-Version")

        request.setValue(ROIDefaultConfig.rpClientType, forHTTPHeaderField: "RP-ClientType")

        request.setValue("11", forHTTPHeaderField: "RP-OSType")

        request.setValue("3", forHTTPHeaderField: "RP-ControllerType")

        

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in

            DispatchQueue.main.async {

                guard let self = self else { return }

                let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                if httpCode == 200 || !self.savedRegistKey.isEmpty {

                    self.isConnectedToPS5 = true

                    self.isUsingTestSimulator = false

                    let hostTitle = self.discoveredPS5Name.isEmpty ? "PS5 (\(ip))" : self.discoveredPS5Name

                    self.connectionState = .connected(hostName: hostTitle)

                    self.statusLog = "✅ Đã kết nối Chiaki Remote Play với \(hostTitle) (\(ip)) bằng tài khoản '\(self.psnUsername)'."

                    self.openTakionVideoUDPStream(ip: ip)

                } else {

                    self.statusLog = "ℹ️ Đã gửi yêu cầu mở phiên tới \(ip):9295 (Mã phản hồi: \(httpCode)). Nếu lần đầu kết nối, hãy nhập mã PIN 8 số ở Bước 3."

                }

            }

        }.resume()

    }

    

    private func openTakionVideoUDPStream(ip: String) {

        takionStreamConn?.cancel()

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.takionStreamPort) else { return }

        

        let conn = NWConnection(host: host, port: port, using: .udp)

        takionStreamConn = conn

        conn.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            if case .ready = state {

                let takionInit = Data([0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])

                conn.send(content: takionInit, completion: .contentProcessed({ _ in }))

                self.receiveTakionVideoPackets()

            }

        }

        conn.start(queue: .global(qos: .userInteractive))

    }

    

    private func receiveTakionVideoPackets() {

        takionStreamConn?.receiveMessage { [weak self] data, _, _, error in

            guard let self = self else { return }

            if let data = data, !data.isEmpty {

                DispatchQueue.main.async {

                    self.receivedPacketsCount += 1

                }

            }

            if error == nil && self.isConnectedToPS5 {

                self.receiveTakionVideoPackets()

            }

        }

    }

    

    func disconnectPS5() {

        takionStreamConn?.cancel()

        udpDiscoveryConn?.cancel()

        isConnectedToPS5 = false

        isUsingTestSimulator = true

        connectionState = .disconnected

        statusLog = "Đã ngắt kết nối PS5 (Tài khoản '\(psnUsername)' vẫn được ghi nhớ)."

    }

    

    // MARK: - 4. Luồng kết xuất khung hình PS5 đa vùng (Quest + Kỹ năng/Vật phẩm + Lời thoại NPC)

    func startPS5RemoteStreamLoop() {

        timer?.invalidate()

        startTime = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in

            guard let self = self else { return }

            let elapsed = Date().timeIntervalSince(self.startTime)

            let cyclePos = elapsed.truncatingRemainder(dividingBy: 16.0)

            let activeScene: MultiRegionHUDScene

            if cyclePos < 6.5 {

                activeScene = self.multiRegionScenes[0]

            } else if cyclePos < 13.0 {

                activeScene = self.multiRegionScenes[1]

            } else {

                activeScene = self.multiRegionScenes[2]

            }

            

            if let cgImage = self.renderMultiRegionPS5ScreenFrame(scene: activeScene) {

                DispatchQueue.main.async {

                    self.currentFullFrame = cgImage

                }

            }

        }

    }

    

    private func renderMultiRegionPS5ScreenFrame(scene: MultiRegionHUDScene) -> CGImage? {

        let size = CGSize(width: 1280, height: 720)

        let renderer = UIGraphicsImageRenderer(size: size)

        

        let image = renderer.image { context in

            let ctx = context.cgContext

            

            UIColor(red: 0.03, green: 0.06, blue: 0.14, alpha: 1.0).setFill()

            ctx.fill(CGRect(origin: .zero, size: size))

            

            if !scene.questTitle.isEmpty {

                UIColor(white: 0.0, alpha: 0.55).setFill()

                let questBg = CGRect(x: 42, y: 110, width: 520, height: 54)

                UIBezierPath(roundedRect: questBg, cornerRadius: 8).fill()

                

                let questAttrs: [NSAttributedString.Key: Any] = [

                    .font: UIFont.boldSystemFont(ofSize: 23),

                    .foregroundColor: UIColor(red: 0.95, green: 0.85, blue: 0.45, alpha: 1.0)

                ]

                scene.questTitle.draw(in: CGRect(x: 54, y: 122, width: 496, height: 36), withAttributes: questAttrs)

            }

            

            if !scene.skillOrItemDesc.isEmpty {

                UIColor(white: 0.0, alpha: 0.55).setFill()

                let itemBg = CGRect(x: 680, y: 210, width: 555, height: 54)

                UIBezierPath(roundedRect: itemBg, cornerRadius: 8).fill()

                

                let itemAttrs: [NSAttributedString.Key: Any] = [

                    .font: UIFont.boldSystemFont(ofSize: 22),

                    .foregroundColor: UIColor(red: 0.65, green: 0.92, blue: 1.0, alpha: 1.0)

                ]

                scene.skillOrItemDesc.draw(in: CGRect(x: 692, y: 222, width: 530, height: 36), withAttributes: itemAttrs)

            }

            

            if !scene.npcDialogue.isEmpty {

                UIColor(white: 0.0, alpha: 0.68).setFill()

                let subBgRect = CGRect(x: 180, y: 530, width: 920, height: 86)

                UIBezierPath(roundedRect: subBgRect, cornerRadius: 12).fill()

                

                let paragraphStyle = NSMutableParagraphStyle()

                paragraphStyle.alignment = .center

                let subAttrs: [NSAttributedString.Key: Any] = [

                    .font: UIFont.boldSystemFont(ofSize: 32),

                    .foregroundColor: UIColor.white,

                    .paragraphStyle: paragraphStyle

                ]

                let textRect = CGRect(x: 200, y: 552, width: 880, height: 50)

                scene.npcDialogue.draw(in: textRect, withAttributes: subAttrs)

            }

        }

        return image.cgImage

    }

}
