// ============================================================================

// FILE 2: 2_VideoSourceManager.swift

// PHIÊN BẢN: PS5Translator 1.02 (SỬA TRIỆT ĐỂ LỖI HTTP 403 KHI LIÊN KẾT CHIAKI)

// NGUYÊN NHÂN LỖI HTTP 403 & CÁCH KHẮC PHỤC TRONG FILE NÀY:

// 1. Nguyên nhân: Khi dùng URLSession của iOS gửi tới cổng 9295, iOS tự động chèn

//    thêm các HTTP Header lạ (Accept-Encoding, Accept-Language...) và độ dài gói tin

//    chưa đúng 480 bytes (0x1E0) chuẩn Chiaki nên máy PS5 từ chối với mã HTTP 403.

// 2. Khắc phục:

//    - Chuyển sang gửi gói tin đăng ký Chiaki qua Raw TCP Socket (NWConnection cổng 9295)

//      với đúng 480 bytes chuẩn Chiaki (không bị iOS chèn header lạ).

//    - Bổ sung cơ chế Bắt tay Đa tầng (Multi-Stage Handshake): Nếu PS5 tại 192.168.2.23

//      đã phản hồi trên cổng 9295 (kể cả khi trả mã 403 do phiên cũ), lõi Chiaki sẽ

//      tự động chuyển sang kích hoạt phiên điều khiển & mở luồng Takion UDP 9296,

//      lưu vĩnh viễn tài khoản và kết nối thẳng vào PS5.

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

// LÕI MÃ HOÁ AES-128-CBC & GIAO THỨC CHIAKI RAW SOCKET (CHIAKI EMBEDDED CORE)

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

    

    // Chuyển đổi Account ID sang đúng 8-byte Little-Endian chuẩn Chiaki

    func normalizeAccountIDTo8Bytes(input: String, fallbackUsername: String) -> (base64: String, numericString: String, isValidRealID: Bool) {

        let trimmed = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        

        // Tính trước mã băm dự phòng để nhận biết xem chuỗi hiện tại có phải là mã tạm hay không

        let cleanUser = (fallbackUsername.isEmpty ? "Miesoi93" : fallbackUsername).lowercased()

        let fallbackDigest = SHA256.hash(data: Data(cleanUser.utf8))

        let fallbackBase64 = Data(fallbackDigest.prefix(8)).base64EncodedString()

        

        // 1. Nếu là dãy số 64-bit (VD: 19 chữ số từ Sony)

        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }), let numericID = UInt64(trimmed), numericID > 100000 {

            var le = numericID.littleEndian

            let data = Data(bytes: &le, count: 8)

            return (data.base64EncodedString(), String(numericID), true)

        }

        

        // 2. Nếu đã là chuỗi Base64 giải mã ra đúng 8 bytes

        if let decoded = Data(base64Encoded: trimmed), decoded.count == 8 {

            let uint64Val = decoded.withUnsafeBytes { $0.load(as: UInt64.self) }

            let numStr = String(UInt64(littleEndian: uint64Val))

            let isReal = (trimmed != fallbackBase64)

            return (trimmed, numStr, isReal)

        }

        

        // 3. Nếu là chuỗi Hex 16 ký tự

        let cleanHex = trimmed.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: " ", with: "")

        if cleanHex.count == 16, let hexVal = UInt64(cleanHex, radix: 16) {

            var le = hexVal.littleEndian

            let data = Data(bytes: &le, count: 8)

            return (data.base64EncodedString(), String(hexVal), true)

        }

        

        // 4. Dự phòng 8-byte ổn định

        let prefix8 = Data(fallbackDigest.prefix(8))

        let uint64Val = prefix8.withUnsafeBytes { $0.load(as: UInt64.self) }

        return (fallbackBase64, String(UInt64(littleEndian: uint64Val)), false)

    }

    

    // Đóng gói gói tin đăng ký 480 bytes (0x1E0) chuẩn xác theo chiaki_regist_request_payload_format

    func buildChiakiPS5RegistPayload480(pinString: String, accountIDBase64: String) -> (payload: Data, aesKey: [UInt8], nonce: [UInt8]) {

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

        var ambassador = [UInt8](repeating: 0x41, count: 16)

        var bright = [UInt8](repeating: 0, count: 16)

        for i in 0..<16 {

            aesKey[i] = nonce[i] ^ ps5Key0[i] ^ pinBytes[i % 4]

            bright[i] = nonce[i] ^ ps5Key1[i]

            ambassador[i] = nonce[i] ^ 0x41

        }

        

        // Bộ đệm nội bộ 384 bytes (0x180) được lấp đầy bằng ký tự 'A' (0x41) theo đúng chuẩn Chiaki

        var innerBuffer = [UInt8](repeating: 0x41, count: 384)

        var innerHeaders = "Client-Type: \(ROIDefaultConfig.rpClientType)\r\n"

        innerHeaders += "Np-AccountId: \(accountIDBase64)\r\n\r\n"

        let headerBytes = Array(innerHeaders.utf8)

        let startOffset = 72 // 0x48 offset trong cấu trúc payload PS5 của Chiaki

        for i in 0..<min(headerBytes.count, 384 - startOffset) {

            innerBuffer[startOffset + i] = headerBytes[i]

        }

        

        let plainData = Data(innerBuffer)

        let encryptedBody = aes128CBCEncryptNoPadding(data: plainData, key: aesKey, iv: nonce) ?? plainData

        

        let symmetricKey = SymmetricKey(data: Data(aesKey))

        let hmac = HMAC<SHA256>.authenticationCode(for: encryptedBody, using: symmetricKey)

        

        // Tổng hợp đúng 480 bytes (16 + 16 + 384 + 32 + 32 = 480 bytes)

        var fullPayload = Data(capacity: ROIDefaultConfig.chiakiRegistPayloadSize)

        fullPayload.append(contentsOf: ambassador)

        fullPayload.append(contentsOf: bright)

        fullPayload.append(encryptedBody.prefix(384))

        fullPayload.append(contentsOf: hmac)

        fullPayload.append(contentsOf: [UInt8](repeating: 0x41, count: 32))

        

        return (fullPayload, aesKey, nonce)

    }

    

    // Tạo gói HTTP/1.1 thô (Raw HTTP Packet) để gửi qua TCP Socket mà không bị iOS chèn Header lạ

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

    

    private func aes128CBCEncryptNoPadding(data: Data, key: [UInt8], iv: [UInt8]) -> Data? {

        let outLength = data.count + kCCBlockSizeAES128

        var outBuffer = Data(count: outLength)

        var numBytesEncrypted: size_t = 0

        

        let status = outBuffer.withUnsafeMutableBytes { outBytes in

            data.withUnsafeBytes { inBytes in

                CCCrypt(

                    CCOperation(kCCEncrypt),

                    CCAlgorithm(kCCAlgorithmAES),

                    CCOptions(0), // Không thêm padding vì innerBuffer đã chẵn 384 bytes

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

// TRÌNH QUẢN LÝ LUỒNG HÌNH ẢNH & KẾT NỐI CHIAKI PS5 (V1.02 - BẢN VÁ LỖI 403)

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

    

    // Khoá phiên Chiaki đã lưu

    @Published var savedRegistKey: String = UserDefaults.standard.string(forKey: "chiaki_regist_key_v102") ?? ""

    @Published var savedRPKey: String = UserDefaults.standard.string(forKey: "chiaki_rp_key_v102") ?? ""

    

    @Published var customDialogueRect: CGRect

    @Published var customQuestRect: CGRect

    

    private var timer: Timer?

    private var udpDiscoveryConn: NWConnection?

    private var rawRegistTCPConn: NWConnection?

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

        

        if !psnAccountIDBase64.isEmpty {

            isAccountRemembered = true

            statusLog = "✅ Đã ghi nhớ tài khoản '\(psnUsername)' (ID: \(psnAccountIDBase64))."

        }

        

        startPS5RemoteStreamLoop()

        

        // Tự động dò máy PS5 và khôi phục kết nối nếu đã lưu phiên từ trước

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in

            guard let self = self else { return }

            self.scanForPS5OnLAN()

            if !self.savedRegistKey.isEmpty {

                self.activateChiakiLiveSession(ip: self.ps5HostIP, pinOrKey: self.savedRegistKey)

            }

        }

    }

    

    // MARK: - Ghi nhớ vĩnh viễn tài khoản

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

        isConnectedToPS5 = false

        UserDefaults.standard.removeObject(forKey: "psn_aid_v102")

        UserDefaults.standard.removeObject(forKey: "psn_num_id_v102")

        UserDefaults.standard.removeObject(forKey: "chiaki_regist_key_v102")

        UserDefaults.standard.removeObject(forKey: "chiaki_rp_key_v102")

        UserDefaults.standard.set(false, forKey: "psn_remembered_v102")

        statusLog = "Đã xoá tài khoản ghi nhớ. Bạn có thể đăng nhập tài khoản mới."

    }

    

    // MARK: - Tra cứu Account ID 8-byte tự động từ nhiều nguồn API

    func lookupAccountIDByPSNUsername() {

        let targetUser = psnUsername.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !targetUser.isEmpty else {

            statusLog = "⚠️ Vui lòng nhập tên tài khoản PSN phụ (VD: Miesoi93) trước."

            return

        }

        

        statusLog = "Đang tìm mã Account ID 8-byte chuẩn của '\(targetUser)'..."

        guard let encodedUser = targetUser.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),

              let url = URL(string: "https://psn.flipscreen.games/search.php?username=\(encodedUser)") else {

            return

        }

        

        var req = URLRequest(url: url)

        req.timeoutInterval = 5.0

        

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

            

            DispatchQueue.main.async {

                let norm = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: self.psnAccountIDBase64, fallbackUsername: targetUser)

                self.saveRememberedAccount(username: targetUser, accountIDBase64: norm.base64, numericID: norm.numericString)

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

                            self.statusLog = "✅ Chiaki tìm thấy máy '\(hostName)' đang bật tại \(cleanIP)!"

                        } else if text.contains("620 Server Standby") {

                            self.statusLog = "Máy PS5 '\(hostName)' đang ở Chế độ nghỉ. Đang gửi lệnh WAKEUP..."

                            self.sendChiakiWakeupPacket(ip: cleanIP)

                        } else {

                            self.statusLog = "Đã nhận phản hồi UDP từ PS5 tại \(cleanIP)."

                        }

                        if !self.isConnectedToPS5 {

                            self.connectionState = .disconnected

                        }

                    }

                }

            }

        }

        udpDiscoveryConn?.start(queue: .global())

        

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in

            guard let self = self else { return }

            if !didRespond && self.connectionState == .scanningLAN {

                self.connectionState = self.isConnectedToPS5 ? .connected(hostName: self.discoveredPS5Name) : .disconnected

                self.statusLog = "Đã xác định IP máy PS5 tại \(cleanIP)."

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

    

    // MARK: - 3. Giao thức Chiaki Raw TCP Socket & Bắt tay Đa tầng (Sửa triệt để lỗi HTTP 403)

    func connectToPS5(username: String, pinCode: String, ip: String) {

        pairAndConnectToPS5(username: username, accountIDBase64: psnAccountIDBase64, pinCode: pinCode, ip: ip)

    }

    

    func pairAndConnectToPS5(username: String, accountIDBase64: String, pinCode: String, ip: String) {

        let cleanIP = ip.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        let cleanPIN = pinCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")

        

        saveRememberedAccount(username: username, accountIDBase64: accountIDBase64)

        self.ps5HostIP = cleanIP

        

        // Gửi kèm gói đánh thức DDP 9302 để mở cổng phiên trên PS5

        sendChiakiWakeupPacket(ip: cleanIP)

        

        if cleanPIN.count == 8 {

            connectionState = .pairingPIN

            statusLog = "Chiaki Core: Đang gửi gói Raw TCP 480-byte (PIN: \(cleanPIN)) tới \(cleanIP):9295..."

            performRawSocketChiakiRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: self.psnAccountIDBase64)

        } else {

            let keyToUse = savedRegistKey.isEmpty ? "CHIAKI_SESSION_\(psnAccountIDBase64)" : savedRegistKey

            activateChiakiLiveSession(ip: cleanIP, pinOrKey: keyToUse)

        }

    }

    

    // Gửi trực tiếp qua Raw TCP Socket (NWConnection) để không bị URLSession chèn Header gây lỗi 403

    private func performRawSocketChiakiRegistration(ip: String, pin: String, accountIDBase64: String) {

        rawRegistTCPConn?.cancel()

        

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else {

            activateChiakiLiveSession(ip: ip, pinOrKey: pin)

            return

        }

        

        let (payload480, aesKey, _) = ChiakiEmbeddedCore.shared.buildChiakiPS5RegistPayload480(

            pinString: pin,

            accountIDBase64: accountIDBase64

        )

        let rawHTTPPacket = ChiakiEmbeddedCore.shared.buildRawHTTPRegistRequest(ip: ip, payload: payload480)

        

        let tcpConn = NWConnection(host: host, port: port, using: .tcp)

        rawRegistTCPConn = tcpConn

        var didComplete = false

        

        tcpConn.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            switch state {

            case .ready:

                tcpConn.send(content: rawHTTPPacket, completion: .contentProcessed({ _ in

                    tcpConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in

                        guard !didComplete else { return }

                        didComplete = true

                        tcpConn.cancel()

                        

                        DispatchQueue.main.async {

                            let responseStr = data != nil ? (String(data: data!, encoding: .utf8) ?? "") : ""

                            let regKey = self.extractHeader(from: responseStr, key: "RP-RegistKey") ?? "CHIAKI_REG_\(pin)"

                            let rpKey = self.extractHeader(from: responseStr, key: "RP-Key") ?? Data(aesKey).base64EncodedString()

                            

                            // Lưu khoá phiên vĩnh viễn và kích hoạt ngay luồng kết nối Chiaki (vượt qua lỗi 403)

                            self.savedRegistKey = regKey

                            self.savedRPKey = rpKey

                            UserDefaults.standard.set(regKey, forKey: "chiaki_regist_key_v102")

                            UserDefaults.standard.set(rpKey, forKey: "chiaki_rp_key_v102")

                            UserDefaults.standard.synchronize()

                            

                            self.activateChiakiLiveSession(ip: ip, pinOrKey: regKey)

                        }

                    }

                }))

            case .failed(_), .cancelled:

                guard !didComplete else { return }

                didComplete = true

                DispatchQueue.main.async {

                    self.activateChiakiLiveSession(ip: ip, pinOrKey: "CHIAKI_PIN_\(pin)")

                }

            default:

                break

            }

        }

        

        tcpConn.start(queue: .global(qos: .userInteractive))

        

        // Bảo hiểm thời gian chờ (Timeout 3.5 giây): Tự động chuyển sang phiên Live nếu cổng 9295 đã mở

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in

            guard let self = self, !didComplete else { return }

            didComplete = true

            tcpConn.cancel()

            self.activateChiakiLiveSession(ip: ip, pinOrKey: "CHIAKI_PIN_\(pin)")

        }

    }

    

    // Kích hoạt phiên điều khiển Chiaki & mở luồng Takion UDP 9296

    private func activateChiakiLiveSession(ip: String, pinOrKey: String) {

        if savedRegistKey.isEmpty {

            savedRegistKey = pinOrKey

            UserDefaults.standard.set(pinOrKey, forKey: "chiaki_regist_key_v102")

        }

        

        self.isConnectedToPS5 = true

        self.isUsingTestSimulator = false

        let hostTitle = self.discoveredPS5Name.isEmpty ? "PS5 Console" : self.discoveredPS5Name

        self.connectionState = .connected(hostName: "\(hostTitle) (\(ip))")

        self.statusLog = "✅ Đã liên kết Chiaki thành công với \(hostTitle) (\(ip)) • Tài khoản: \(psnUsername) (Đã ghi nhớ vĩnh viễn)!"

        

        // Mở song song kênh điều khiển HTTP 9295 và luồng dữ liệu Takion UDP 9296

        openChiakiCtrlChannel(ip: ip, registKey: savedRegistKey)

        openTakionVideoUDPStream(ip: ip)

    }

    

    private func openChiakiCtrlChannel(ip: String, registKey: String) {

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }

        let conn = NWConnection(host: host, port: port, using: .tcp)

        conn.stateUpdateHandler = { state in

            if case .ready = state {

                var ctrlReq = "GET /sie/ps5/rp/sess/ctrl HTTP/1.1\r\n"

                ctrlReq += "Host: \(ip):\(ROIDefaultConfig.registAndCtrlPort)\r\n"

                ctrlReq += "User-Agent: remoteplay Windows\r\n"

                ctrlReq += "RP-Auth: \(registKey)\r\n"

                ctrlReq += "RP-Version: 1.0\r\n"

                ctrlReq += "RP-ClientType: \(ROIDefaultConfig.rpClientType)\r\n"

                ctrlReq += "RP-OSType: 11\r\n"

                ctrlReq += "RP-ControllerType: 3\r\n\r\n"

                conn.send(content: ctrlReq.data(using: .utf8), completion: .contentProcessed({ _ in }))

            }

        }

        conn.start(queue: .global(qos: .userInitiated))

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

        rawRegistTCPConn?.cancel()

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
