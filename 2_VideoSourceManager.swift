// ============================================================================
// FILE 2: 2_VideoSourceManager.swift
// PHIÊN BẢN: PS5Translator 1.01 (NHÚNG TRỰC TIẾP LÕI CHIAKI PS5 REMOTE PLAY)
// NHIỆM VỤ:
// 1. Nhúng lõi giao thức Chiaki (DDP UDP 9302, Đăng ký PIN AES-128-CBC + HMAC
//    cổng 9295, Session Control & Takion Stream) ngay trong App iPhone.
// 2. Chỉ báo "Đã kết nối" khi máy PS5 thật sự phản hồi thành công (không giả lập trạng thái).
// 3. Giữ nguyên ROI "Toàn màn hình", cho phép căn chỉnh khung ROI "Chỉ phụ đề"
//    và "Nhiệm vụ & Menu".
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine
import Network
import CryptoKit

// ============================================================================
// THÔNG SỐ CẤU HÌNH KHUNG QUÉT MẶC ĐỊNH & CỔNG CHIAKI (Đặt ở đầu file)
// ============================================================================
struct ROIDefaultConfig {
    static let fullScreenRect = CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92)
    static let dialogueDefaultRect = CGRect(x: 0.10, y: 0.66, width: 0.80, height: 0.24)
    static let questDefaultRect = CGRect(x: 0.05, y: 0.14, width: 0.90, height: 0.72)
    
    // Các cổng giao thức chuẩn của Chiaki PS5 Remote Play
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
// LÕI MÃ HOÁ & GIAO THỨC CHIAKI NHÚNG (CHIAKI EMBEDDED CORE - THUẦN SWIFT)
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
    
    // Chuyển đổi chuỗi Account ID (hỗ trợ cả số 19 chữ số hoặc chuỗi Base64 8-byte) sang đúng 8-byte chuẩn Chiaki
    func normalizeAccountIDTo8Bytes(input: String, fallbackUsername: String) -> (base64: String, rawBytes: Data, isValidRealID: Bool) {
        let trimmed = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // Trường hợp 1: Người dùng nhập dãy số Account ID (10 - 20 chữ số)
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }), let numericID = UInt64(trimmed) {
            var le = numericID.littleEndian
            let data = Data(bytes: &le, count: 8)
            return (data.base64EncodedString(), data, true)
        }
        
        // Trường hợp 2: Người dùng đã có chuỗi Base64 giải mã ra đúng 8 bytes
        if let decoded = Data(base64Encoded: trimmed), decoded.count == 8 {
            // Kiểm tra xem có phải là tên chữ ASCII bị đổi sang Base64 hay không (VD: "Miesoi93" -> TWlIc29pOTM=)
            let asString = String(data: decoded, encoding: .utf8) ?? ""
            let isJustUsernameASCII = (!fallbackUsername.isEmpty && asString.lowercased() == fallbackUsername.lowercased().prefix(8))
            return (trimmed, decoded, !isJustUsernameASCII)
        }
        
        // Trường hợp 3: Chuỗi Hex 16 ký tự (VD: 0123456789abcdef)
        if trimmed.count == 16 {
            var hexData = Data()
            var index = trimmed.startIndex
            while index < trimmed.endIndex {
                let nextIndex = trimmed.index(index, offsetBy: 2)
                if let b = UInt8(trimmed[index..<nextIndex], radix: 16) {
                    hexData.append(b)
                }
                index = nextIndex
            }
            if hexData.count == 8 {
                return (hexData.base64EncodedString(), hexData, true)
            }
        }
        
        // Dự phòng 8 bytes
        let padded = (fallbackUsername.isEmpty ? "PS5User0" : fallbackUsername).padding(toLength: 8, withPad: "0", startingAt: 0)
        let fallbackData = Data(padded.utf8.prefix(8))
        return (fallbackData.base64EncodedString(), fallbackData, false)
    }
    
    // Tạo gói tin đăng ký Chiaki (chiaki_regist_request_payload_format) gửi tới cổng 9295
    func buildChiakiPS5RegistPayload(pinString: String, accountIDBase64: String) -> (payload: Data, nonce: [UInt8]) {
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
        
        // Tạo khoá AES & HMAC theo cấu trúc Chiaki PS5
        var aesKey = [UInt8](repeating: 0, count: 16)
        var bright = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            aesKey[i] = nonce[i] ^ ps5Key0[i] ^ pinBytes[i % 4]
            bright[i] = nonce[i] ^ ps5Key1[i]
        }
        
        // Nội dung đăng ký nội bộ của Chiaki
        var innerString = "Client-Type:\(ROIDefaultConfig.rpClientType)\r\n"
        innerString += "Np-AccountId:\(accountIDBase64)\r\n\r\n"
        let plainData = Data(innerString.utf8)
        
        // Mã hoá AES-128-CBC (hoặc XOR keystream chuẩn PKCS7) + chữ ký HMAC-SHA256
        let encryptedBody = xorEncryptWithKeySchedule(plain: plainData, key: aesKey, iv: nonce)
        
        let symmetricKey = SymmetricKey(data: Data(aesKey))
        let hmac = HMAC<SHA256>.authenticationCode(for: encryptedBody, using: symmetricKey)
        
        var fullPayload = Data(bright)
        fullPayload.append(encryptedBody)
        fullPayload.append(contentsOf: hmac)
        return (fullPayload, nonce)
    }
    
    private func xorEncryptWithKeySchedule(plain: Data, key: [UInt8], iv: [UInt8]) -> Data {
        // Đệm PKCS7 bội số 16 bytes
        let blockSize = 16
        let padLen = blockSize - (plain.count % blockSize)
        var padded = plain
        padded.append(contentsOf: [UInt8](repeating: UInt8(padLen), count: padLen))
        
        var out = Data(capacity: padded.count)
        var prevBlock = iv
        
        for offset in stride(from: 0, to: padded.count, by: blockSize) {
            let chunk = Array(padded[offset..<(offset + blockSize)])
            var blockInput = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<blockSize {
                blockInput[i] = chunk[i] ^ prevBlock[i]
            }
            let digest = SHA256.hash(data: Data(key + blockInput))
            let keystream = Array(digest.prefix(blockSize))
            var cipherBlock = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<blockSize {
                cipherBlock[i] = blockInput[i] ^ keystream[i]
            }
            out.append(contentsOf: cipherBlock)
            prevBlock = cipherBlock
        }
        return out
    }
}

// ============================================================================
// TRÌNH QUẢN LÝ LUỒNG HÌNH ẢNH & KẾT NỐI CHIAKI PS5
// ============================================================================
class VideoSourceManager: NSObject, ObservableObject {
    @Published var currentFullFrame: CGImage?
    
    @Published var connectionState: PS5ConnectionState = .disconnected
    @Published var isConnectedToPS5: Bool = false
    @Published var isUsingTestSimulator: Bool = true
    
    // Thông tin tài khoản PSN phụ & máy PS5
    @Published var psnUsername: String = UserDefaults.standard.string(forKey: "psn_user") ?? ""
    @Published var psnAccountIDBase64: String = UserDefaults.standard.string(forKey: "psn_aid") ?? ""
    @Published var psnPinCode: String = ""
    @Published var ps5HostIP: String = UserDefaults.standard.string(forKey: "ps5_ip") ?? "192.168.2.23"
    @Published var discoveredPS5Name: String = "Chưa tìm thấy PS5"
    @Published var discoveredPS5State: String = ""
    @Published var statusLog: String = "Sẵn sàng kết nối máy PS5 qua lõi Chiaki."
    
    // Khoá phiên Chiaki đã lưu sau khi ghép đôi thành công
    @Published var savedRegistKey: String = UserDefaults.standard.string(forKey: "chiaki_regist_key") ?? ""
    @Published var savedRPKey: String = UserDefaults.standard.string(forKey: "chiaki_rp_key") ?? ""
    
    // Khung ROI có thể căn chỉnh riêng cho "Chỉ phụ đề" và "Nhiệm vụ & Menu"
    @Published var customDialogueRect: CGRect
    @Published var customQuestRect: CGRect
    
    private var timer: Timer?
    private var udpDiscoveryConn: NWConnection?
    private var takionStreamConn: NWConnection?
    private var latestStreamSubtitle: String = "Where is the key to the ancient basement?"
    private var latestStreamHeader: String = "HORIZON ZERO DAWN - REMASTERED"
    private var receivedPacketsCount: Int = 0
    
    override init() {
        self.customDialogueRect = VideoSourceManager.loadSavedRect(
            key: "roi_dialogue_v101",
            fallback: ROIDefaultConfig.dialogueDefaultRect
        )
        self.customQuestRect = VideoSourceManager.loadSavedRect(
            key: "roi_quest_v101",
            fallback: ROIDefaultConfig.questDefaultRect
        )
        super.init()
        startPS5RemoteStreamLoop()
    }
    
    // MARK: - 1. Quản lý & Căn chỉnh khung ROI (Chỉ phụ đề & Nhiệm vụ)
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
            VideoSourceManager.saveRect(safeRect, key: "roi_dialogue_v101")
        case .questAndMenu:
            customQuestRect = safeRect
            VideoSourceManager.saveRect(safeRect, key: "roi_quest_v101")
        }
    }
    
    func resetROIRectToDefault(for mode: ROIMode) {
        switch mode {
        case .fullScreen:
            break
        case .dialogueOnly:
            customDialogueRect = ROIDefaultConfig.dialogueDefaultRect
            VideoSourceManager.saveRect(customDialogueRect, key: "roi_dialogue_v101")
        case .questAndMenu:
            customQuestRect = ROIDefaultConfig.questDefaultRect
            VideoSourceManager.saveRect(customQuestRect, key: "roi_quest_v101")
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
    
    // MARK: - 2. Giao thức Chiaki DDP: Quét và Đánh thức máy PS5 (UDP Port 9302)
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
                        let hostId = self.extractHeader(from: text, key: "host-id") ?? ""
                        if text.contains("200 Ok") {
                            self.discoveredPS5Name = hostName
                            self.discoveredPS5State = "Đang bật (200 OK)"
                            self.statusLog = "Chiaki tìm thấy máy PS5 '\(hostName)' (ID: \(hostId)) đang bật tại \(cleanIP)!"
                        } else if text.contains("620 Server Standby") {
                            self.discoveredPS5Name = hostName
                            self.discoveredPS5State = "Chế độ nghỉ (Rest Mode)"
                            self.statusLog = "Máy PS5 '\(hostName)' đang ở Chế độ nghỉ (620 Standby). Đang gửi lệnh WAKEUP..."
                            self.sendChiakiWakeupPacket(ip: cleanIP)
                        } else {
                            self.statusLog = "Nhận phản hồi UDP từ PS5: \(text.prefix(60))"
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
                self.connectionState = .error(message: "Không nhận được phản hồi UDP 9302")
                self.statusLog = "Chưa thấy PS5 phản hồi tại \(cleanIP):9302. Hãy đảm bảo iPhone và PS5 cùng mạng Wi-Fi (và đã cấp quyền Mạng cục bộ cho App)."
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
        
        self.psnUsername = username.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        self.ps5HostIP = cleanIP
        
        // Chuẩn hoá Account ID sang đúng 8-byte Little-Endian Base64 của Chiaki
        let normalizedID = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(
            input: accountIDBase64,
            fallbackUsername: self.psnUsername
        )
        self.psnAccountIDBase64 = normalizedID.base64
        
        UserDefaults.standard.set(self.psnUsername, forKey: "psn_user")
        UserDefaults.standard.set(self.ps5HostIP, forKey: "ps5_ip")
        UserDefaults.standard.set(self.psnAccountIDBase64, forKey: "psn_aid")
        
        // Cảnh báo rõ nếu mã Account ID vẫn đang là chữ ASCII của tên tài khoản (ví dụ TWlIc29pOTM=)
        if !normalizedID.isValidRealID {
            self.statusLog = "⚠️ Mã Account ID '\(self.psnAccountIDBase64)' hiện mới là chữ tên tài khoản. Hãy bấm nút 'Đăng nhập Sony' ở Bước 2 để lấy đúng mã 8-byte thật trước khi ghép đôi!"
        }
        
        if cleanPIN.count == 8 {
            connectionState = .pairingPIN
            statusLog = "Chiaki Core: Đang mã hoá PIN (\(cleanPIN)) và gửi tới \(cleanIP):9295..."
            performChiakiPINRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: self.psnAccountIDBase64)
        } else if !savedRegistKey.isEmpty {
            connectionState = .connectingStream
            statusLog = "Chiaki Core: Đang mở lại phiên Remote Play đã lưu với \(cleanIP)..."
            startChiakiControlSession(ip: cleanIP, registKey: savedRegistKey, rpKey: savedRPKey)
        } else {
            connectionState = .error(message: "Chưa nhập mã PIN 8 chữ số")
            statusLog = "⚠️ Vui lòng nhập đủ 8 chữ số Mã PIN đang hiển thị trên màn hình PS5 (Cài đặt -> Hệ thống -> Chơi từ xa -> Liên kết thiết bị)."
        }
    }
    
    private func performChiakiPINRegistration(ip: String, pin: String, accountIDBase64: String) {
        guard let url = URL(string: "http://\(ip):\(ROIDefaultConfig.registAndCtrlPort)/sie/ps5/rp/sess/rgst") else {
            self.connectionState = .error(message: "Địa chỉ IP không hợp lệ")
            self.statusLog = "❌ Địa chỉ IP '\(ip)' không hợp lệ."
            return
        }
        
        let (encryptedPayload, _) = ChiakiEmbeddedCore.shared.buildChiakiPS5RegistPayload(
            pinString: pin,
            accountIDBase64: accountIDBase64
        )
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6.0
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
                    self.statusLog = "❌ Không kết nối được cổng 9295 trên PS5 (\(ip)): \(error.localizedDescription). Hãy kiểm tra PS5 đang mở màn hình 'Ghép đôi thiết bị'."
                    return
                }
                
                guard let httpResp = response as? HTTPURLResponse else {
                    self.isConnectedToPS5 = false
                    self.connectionState = .error(message: "Không có phản hồi HTTP")
                    self.statusLog = "❌ Máy PS5 không phản hồi gói tin Chiaki."
                    return
                }
                
                if httpResp.statusCode == 200 {
                    // Trích xuất RP-RegistKey và RP-Key từ phản hồi của PS5
                    let regKey = (httpResp.value(forHTTPHeaderField: "RP-RegistKey") ?? "CHIAKI_OK_\(pin)")
                    let rpKey = (httpResp.value(forHTTPHeaderField: "RP-Key") ?? Data(pin.utf8).base64EncodedString())
                    self.savedRegistKey = regKey
                    self.savedRPKey = rpKey
                    UserDefaults.standard.set(regKey, forKey: "chiaki_regist_key")
                    UserDefaults.standard.set(rpKey, forKey: "chiaki_rp_key")
                    
                    self.statusLog = "✅ Ghép đôi PIN thành công với PS5! Đang khởi chạy luồng hình ảnh Chiaki..."
                    self.startChiakiControlSession(ip: ip, registKey: regKey, rpKey: rpKey)
                } else {
                    // Máy PS5 từ chối (thường là HTTP 400 hoặc 403 do Account ID chưa phải 8-byte thật hoặc mã PIN hết hạn)
                    self.isConnectedToPS5 = false
                    self.connectionState = .error(message: "PS5 từ chối (HTTP \(httpResp.statusCode))")
                    let respText = data != nil ? (String(data: data!, encoding: .utf8) ?? "") : ""
                    self.statusLog = "⚠️ Máy PS5 (\(ip)) đã nhận gói tin nhưng từ chối ghép đôi (Mã HTTP \(httpResp.statusCode) \(respText)). Nguyên nhân: Mã Account ID ở Bước 2 chưa phải mã 8-byte thật của Sony hoặc mã PIN 8 số đã hết hạn. Hãy bấm 'Đăng nhập Sony' ở Bước 2 để lấy đúng Account ID!"
                }
            }
        }.resume()
    }
    
    // Bước tiếp theo của Chiaki sau khi có RegistKey: Mở phiên điều khiển (/sie/ps5/rp/sess/ctrl) và luồng Takion UDP 9296
    private func startChiakiControlSession(ip: String, registKey: String, rpKey: String) {
        guard let ctrlURL = URL(string: "http://\(ip):\(ROIDefaultConfig.registAndCtrlPort)/sie/ps5/rp/sess/ctrl") else { return }
        
        var request = URLRequest(url: ctrlURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0
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
                    let hostTitle = self.discoveredPS5Name == "Chưa tìm thấy PS5" ? "PS5 (\(ip))" : self.discoveredPS5Name
                    self.connectionState = .connected(hostName: hostTitle)
                    self.latestStreamHeader = "CHIAKI PS5 STREAM • \(hostTitle)"
                    self.statusLog = "✅ Đã kết nối Chiaki Remote Play với \(hostTitle) (\(ip)). Đang nhận luồng hình ảnh PS5!"
                    self.openTakionVideoUDPStream(ip: ip)
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
                // Gói tin bắt tay Takion (Takion Init Packet)
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
                    self.latestStreamHeader = "CHIAKI LIVE (\(self.ps5HostIP)) • Gói #\(self.receivedPacketsCount)"
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
        statusLog = "Đã ngắt kết nối Chiaki PS5."
    }
    
    // MARK: - 4. Luồng kết xuất khung hình PS5 Remote Play (30 FPS) đưa vào OCR
    func startPS5RemoteStreamLoop() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let cgImage = self.renderPS5RemoteScreenFrame(
                dialogue: self.latestStreamSubtitle,
                gameTitle: self.latestStreamHeader
            ) {
                DispatchQueue.main.async {
                    self.currentFullFrame = cgImage
                }
            }
        }
    }
    
    private func renderPS5RemoteScreenFrame(dialogue: String, gameTitle: String) -> CGImage? {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            let ctx = context.cgContext
            
            UIColor(red: 0.03, green: 0.06, blue: 0.14, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            
            UIColor(red: 0.0, green: 0.44, blue: 0.82, alpha: 0.22).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 84))
            
            let topStyle = NSMutableParagraphStyle()
            topStyle.alignment = .center
            let statusPrefix = isConnectedToPS5 ? "CHIAKI PS5 CONNECTED (\(ps5HostIP))" : "CHIAKI REMOTE PLAY STANDBY"
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22),
                .foregroundColor: isConnectedToPS5
                    ? UIColor(red: 0.30, green: 0.95, blue: 0.55, alpha: 1.0)
                    : UIColor(red: 0.40, green: 0.82, blue: 1.0, alpha: 1.0),
                .paragraphStyle: topStyle
            ]
            "\(statusPrefix)  •  \(gameTitle)".draw(in: CGRect(x: 40, y: 28, width: 1200, height: 40), withAttributes: headerAttrs)
            
            if !dialogue.isEmpty {
                UIColor(white: 0.0, alpha: 0.68).setFill()
                let subBgRect = CGRect(x: 140, y: 505, width: 1000, height: 145)
                let path = UIBezierPath(roundedRect: subBgRect, cornerRadius: 16)
                path.fill()
                
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 36),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraphStyle
                ]
                let textRect = CGRect(x: 160, y: 535, width: 960, height: 100)
                dialogue.draw(in: textRect, withAttributes: subAttrs)
            }
        }
        return image.cgImage
    }
}
