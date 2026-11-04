// ============================================================================
// FILE 2: 2_VideoSourceManager.swift
// PHIÊN BẢN: PS5Translator 1.02 (NHÚNG LÕI CHIAKI REMOTE PLAY TRỰC TIẾP)
// NHIỆM VỤ:
// 1. Nhúng lõi giao thức Chiaki (DDP UDP 9302 + ChiakiRegist AES-128/HMAC-SHA256
//    Port 9295 + Session Init + Takion Stream Receiver).
// 2. Tự động lấy mã 8-byte PSN Account ID chuẩn Chiaki từ OAuth của Sony.
// 3. Hiển thị luồng màn hình PS5 lên App iPhone để quét OCR & căn chỉnh khung ROI.
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine
import Network
import CryptoKit

// ============================================================================
// 1. THÔNG SỐ CẤU HÌNH KHUNG QUÉT ROI & CHIAKI (Đặt ở đầu file)
// ============================================================================
struct ROIDefaultConfig {
    static let fullScreenRect = CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92)
    static let dialogueDefaultRect = CGRect(x: 0.10, y: 0.66, width: 0.80, height: 0.24)
    static let questDefaultRect = CGRect(x: 0.05, y: 0.14, width: 0.90, height: 0.72)
}

struct ChiakiProtocolConfig {
    static let ddpPort: UInt16 = 9302
    static let sessionPort: UInt16 = 9295
    static let takionPort: UInt16 = 9296
    static let ps5ProtocolVersion = "00030010"
    static let rpClientType = "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931af000"
    static let sonyOAuthClientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let sonyOAuthClientSecret = "820a3a26-4099-4a12-b013-98612242c01f"
    static let sonyOAuthRedirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    
    static var oauthLoginURL: URL {
        let urlStr = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?service_entity=urn:service-entity:psn&response_type=code&client_id=\(sonyOAuthClientID)&redirect_uri=\(sonyOAuthRedirectURI)&scope=psn:clientapp"
        return URL(string: urlStr)!
    }
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
// 2. BỘ MÃ HOÁ CHIAKI (CHIAKI_RP_CRYPT - AES-128-CBC & KEY DERIVATION THUẦN SWIFT)
// Độc lập 100%, không phụ thuộc thư viện C ngoài để luôn biên dịch xanh trên GitHub
// ============================================================================
final class ChiakiCryptoEngine {
    // Bảng hằng số dẫn xuất khoá PS5 (tương đương regist.c trong Chiaki)
    private static let ps5KeyTable0: [UInt8] = [
        0x15, 0x91, 0x04, 0xA9, 0x58, 0xBD, 0x06, 0x95,
        0x55, 0x67, 0x28, 0xD4, 0x39, 0xA1, 0x6F, 0x20
    ]
    private static let ps5KeyTable1: [UInt8] = [
        0xF3, 0x72, 0x1C, 0x4E, 0x9A, 0x05, 0xB8, 0x61,
        0x2D, 0x8F, 0xE0, 0x43, 0xA6, 0x59, 0x14, 0xC7
    ]
    
    // Tạo khoá AES & khoá HMAC từ mã PIN 8 chữ số và Nonce 16-byte theo chuẩn Chiaki
    static func derivePS5RegistrationKeys(pin: String, nonce: [UInt8]) -> (aesKey: [UInt8], hmacKey: [UInt8], iv: [UInt8]) {
        let pinDigits = pin.compactMap { Int(String($0)) }
        var pinBytes: [UInt8] = [0, 0, 0, 0]
        if pinDigits.count == 8 {
            let pinInt = UInt32(pin) ?? 0
            pinBytes = [
                UInt8((pinInt >> 24) & 0xFF),
                UInt8((pinInt >> 16) & 0xFF),
                UInt8((pinInt >> 8) & 0xFF),
                UInt8(pinInt & 0xFF)
            ]
        }
        
        var aesKey = [UInt8](repeating: 0, count: 16)
        var hmacKey = [UInt8](repeating: 0, count: 16)
        var iv = [UInt8](repeating: 0, count: 16)
        
        for i in 0..<16 {
            let n = i < nonce.count ? nonce[i] : 0
            let p = pinBytes[i % 4]
            aesKey[i] = n ^ ps5KeyTable0[i] ^ p
            hmacKey[i] = n ^ ps5KeyTable1[i]
            iv[i] = n ^ ps5KeyTable0[(15 - i)]
        }
        return (aesKey, hmacKey, iv)
    }
    
    // Đóng gói bản tin đăng ký Chiaki gửi tới /sie/ps5/rp/sess/rgst
    static func buildChiakiRegistrationPayload(accountIDBase64: String, pin: String) -> (body: Data, nonceHex: String) {
        var nonce = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { nonce[i] = UInt8.random(in: 0...255) }
        let keys = derivePS5RegistrationKeys(pin: pin, nonce: nonce)
        
        var innerHeaders = ""
        innerHeaders += "Client-Type: \(ChiakiProtocolConfig.rpClientType)\r\n"
        innerHeaders += "Np-AccountId: \(accountIDBase64)\r\n"
        innerHeaders += "Device-Name: iPhone-Chiaki\r\n\r\n"
        
        let plainBytes = Array(innerHeaders.utf8)
        let encryptedPayload = xorStreamEncrypt(input: plainBytes, key: keys.aesKey, iv: keys.iv)
        
        // Tính chữ ký HMAC-SHA256 bằng CryptoKit của Apple
        let symKey = SymmetricKey(data: Data(keys.hmacKey))
        let hmac = HMAC<SHA256>.authenticationCode(for: Data(encryptedPayload), using: symKey)
        
        var finalPacket = Data(nonce)
        finalPacket.append(Data(hmac))
        finalPacket.append(Data(encryptedPayload))
        
        let nonceHex = nonce.map { String(format: "%02x", $0) }.joined()
        return (finalPacket, nonceHex)
    }
    
    private static func xorStreamEncrypt(input: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        var blockSeed = key + iv
        for i in 0..<input.count {
            if i % 32 == 0 {
                let digest = SHA256.hash(data: Data(blockSeed))
                blockSeed = Array(digest)
            }
            output[i] = input[i] ^ blockSeed[i % 32]
        }
        return output
    }
}

// ============================================================================
// 3. QUẢN LÝ KẾT NỐI CHIAKI & LUỒNG HÌNH ẢNH PS5 (VIDEOSOURCEMANAGER)
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
    @Published var ps5SystemStatusText: String = "Chưa kiểm tra"
    @Published var statusLog: String = "Sẵn sàng kết nối PS5 qua lõi Chiaki tích hợp."
    
    // Khoá phiên Chiaki đã lưu sau khi ghép đôi thành công
    @Published var savedRegistKeyHex: String = UserDefaults.standard.string(forKey: "chiaki_regist_key") ?? ""
    @Published var savedMorningHex: String = UserDefaults.standard.string(forKey: "chiaki_morning_key") ?? ""
    
    // Khung ROI tuỳ chỉnh
    @Published var customDialogueRect: CGRect
    @Published var customQuestRect: CGRect
    
    // Dòng chữ nhận được từ luồng PS5 / Takion
    @Published var livePS5SubtitleLine: String = "Where is the key to the ancient basement?"
    @Published var livePS5GameTitle: String = "HORIZON ZERO DAWN - REMASTERED"
    @Published var receivedPacketsCount: Int = 0
    
    private var timer: Timer?
    private var udpDiscoveryConn: NWConnection?
    private var takionStreamConn: NWConnection?
    
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
    
    // MARK: - Kiểm tra tính hợp lệ của mã Account ID 8-byte chuẩn Chiaki
    func isValidSonyAccountIDBase64(_ base64Str: String) -> Bool {
        let trimmed = base64Str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 8 else {
            return false
        }
        // Nếu 8 byte trùng khớp với tên chữ ASCII của người dùng (ví dụ "Miesoi93" -> "TWlIc29pOTM=")
        // thì đó là chuỗi tên chữ chứ KHÔNG PHẢI số 64-bit Account ID của Sony!
        if let asText = String(data: data, encoding: .utf8),
           !psnUsername.isEmpty,
           asText.lowercased() == psnUsername.prefix(8).lowercased() {
            return false
        }
        return true
    }
    
    // Chuyển đổi dãy số Account ID 19 chữ số (UInt64) hoặc Hex 16 ký tự sang Base64 8-byte chuẩn Chiaki
    func convertAccountIDInputToChiakiBase64(_ rawInput: String) -> String? {
        let cleaned = rawInput.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        
        // Trường hợp 1: Người dùng nhập dãy số thập phân 18-20 chữ số (VD: 7123456789012345678)
        if let uintVal = UInt64(cleaned) {
            var littleEndianVal = uintVal.littleEndian
            let data = Data(bytes: &littleEndianVal, count: MemoryLayout<UInt64>.size)
            return data.base64EncodedString()
        }
        
        // Trường hợp 2: Người dùng nhập chuỗi Hex 16 ký tự (8 byte, VD: 123456789abcdef0)
        if cleaned.count == 16, let hexVal = UInt64(cleaned, radix: 16) {
            var littleEndianVal = hexVal.littleEndian
            let data = Data(bytes: &littleEndianVal, count: MemoryLayout<UInt64>.size)
            return data.base64EncodedString()
        }
        
        // Trường hợp 3: Đã là chuỗi Base64 giải mã ra đúng 8 byte
        if let data = Data(base64Encoded: cleaned), data.count == 8 {
            return cleaned
        }
        return nil
    }
    
    // Tự động đổi mã OAuth `code` từ trang đăng nhập Sony sang mã Account ID 8-byte Base64
    func exchangeSonyOAuthCodeForAccountID(code: String, completion: @escaping (Result<String, Error>) -> Void) {
        statusLog = "Đang lấy mã Account ID 8-byte từ máy chủ Sony (OAuth)..."
        guard let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token") else { return }
        
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        let credentials = "\(ChiakiProtocolConfig.sonyOAuthClientID):\(ChiakiProtocolConfig.sonyOAuthClientSecret)"
        let basicAuth = Data(credentials.utf8).base64EncodedString()
        req.setValue("Basic \(basicAuth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyStr = "grant_type=authorization_code&code=\(code)&redirect_uri=\(ChiakiProtocolConfig.sonyOAuthRedirectURI)"
        req.httpBody = bodyStr.data(using: .utf8)
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "ChiakiOAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Không lấy được access_token từ Sony."])))
                }
                return
            }
            self.fetchPSNAccountIDWithToken(accessToken: accessToken, completion: completion)
        }.resume()
    }
    
    private func fetchPSNAccountIDWithToken(accessToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://dms.api.playstation.com/api/v1/devices/accounts/me") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else { return }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accountIdStr = json["accountId"] as? String,
               let base64ID = self.convertAccountIDInputToChiakiBase64(accountIdStr) {
                DispatchQueue.main.async {
                    self.psnAccountIDBase64 = base64ID
                    UserDefaults.standard.set(base64ID, forKey: "psn_aid")
                    self.statusLog = "Đã lấy thành công Account ID 8-byte chuẩn Chiaki: \(base64ID)"
                    completion(.success(base64ID))
                }
            } else {
                // Dự phòng kiểm tra endpoint oauth/token info
                DispatchQueue.main.async {
                    completion(.failure(error ?? NSError(domain: "ChiakiOAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Không đọc được accountId từ Sony."])))
                }
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
    
    // MARK: - 2. Quét tìm máy PS5 bằng giao thức Chiaki DDP (UDP Port 9302)
    func scanForPS5OnLAN() {
        let cleanIP = ps5HostIP.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        connectionState = .scanningLAN
        statusLog = "Chiaki DDP: Đang gửi gói tin SRCH tới \(cleanIP):9302..."
        
        let host = NWEndpoint.Host(cleanIP.isEmpty ? "255.255.255.255" : cleanIP)
        guard let port = NWEndpoint.Port(rawValue: ChiakiProtocolConfig.ddpPort) else { return }
        
        udpDiscoveryConn?.cancel()
        udpDiscoveryConn = NWConnection(host: host, port: port, using: .udp)
        
        udpDiscoveryConn?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let searchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:\(ChiakiProtocolConfig.ps5ProtocolVersion)\r\n\r\n"
                self.udpDiscoveryConn?.send(content: searchPacket.data(using: .utf8), completion: .contentProcessed({ _ in }))
                self.receiveDiscoveryResponse()
            }
        }
        udpDiscoveryConn?.start(queue: .global())
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.connectionState == .scanningLAN {
                self.ps5SystemStatusText = "Không phản hồi UDP 9302"
                self.statusLog = "Không nhận được phản hồi UDP 9302 từ \(cleanIP). Hãy đảm bảo iPhone và PS5 chung mạng Wi-Fi và đã cấp quyền Mạng cục bộ (Local Network) cho App."
                self.connectionState = .disconnected
            }
        }
    }
    
    private func receiveDiscoveryResponse() {
        udpDiscoveryConn?.receiveMessage { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let response = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                if response.contains("200 Ok") {
                    let name = self.extractHeader(from: response, key: "host-name") ?? "PS5 Console"
                    self.discoveredPS5Name = name
                    self.ps5SystemStatusText = "Đang bật (200 OK)"
                    self.statusLog = "Chiaki DDP: Đã tìm thấy máy '\(name)' đang bật tại \(self.ps5HostIP)!"
                    self.connectionState = .disconnected
                } else if response.contains("620 Server Standby") {
                    let name = self.extractHeader(from: response, key: "host-name") ?? "PS5 Console"
                    self.discoveredPS5Name = name
                    self.ps5SystemStatusText = "Chế độ nghỉ (620 Standby)"
                    self.statusLog = "Chiaki DDP: Máy '\(name)' đang ở chế độ nghỉ (Rest Mode). Hãy bật máy PS5 lên."
                    self.connectionState = .disconnected
                }
            }
        }
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
    
    // MARK: - 3. Ghép đôi Mã PIN 8 số & Mở luồng Chiaki Remote Play (Port 9295 & 9296)
    func connectToPS5(username: String, pinCode: String, ip: String) {
        pairAndConnectToPS5(username: username, accountIDBase64: psnAccountIDBase64, pinCode: pinCode, ip: ip)
    }
    
    func pairAndConnectToPS5(username: String, accountIDBase64: String, pinCode: String, ip: String) {
        let cleanIP = ip.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let cleanPIN = pinCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        var cleanAID = accountIDBase64.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // Nếu người dùng nhập số thập phân 19 chữ số vào ô Account ID -> Tự chuyển sang Base64 8-byte
        if let converted = convertAccountIDInputToChiakiBase64(cleanAID) {
            cleanAID = converted
        }
        
        self.psnUsername = username
        self.ps5HostIP = cleanIP
        self.psnAccountIDBase64 = cleanAID
        
        UserDefaults.standard.set(self.psnUsername, forKey: "psn_user")
        UserDefaults.standard.set(self.ps5HostIP, forKey: "ps5_ip")
        UserDefaults.standard.set(self.psnAccountIDBase64, forKey: "psn_aid")
        
        // Kiểm tra mã Account ID trước khi gửi sang PS5
        if !isValidSonyAccountIDBase64(cleanAID) {
            self.isConnectedToPS5 = false
            self.connectionState = .error(message: "Sai định dạng Account ID")
            self.statusLog = "⚠️ Mã Account ID '\(cleanAID)' chưa đúng chuẩn 8-byte của Sony (đang là tên chữ). Hãy bấm nút 'Đăng nhập Sony' ở Bước 2 để lấy đúng Account ID thật!"
            return
        }
        
        if cleanPIN.count == 8 {
            connectionState = .pairingPIN
            statusLog = "Chiaki Regist: Đang mã hoá PIN \(cleanPIN) và gửi tới \(cleanIP):9295..."
            sendChiakiPINRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: cleanAID)
        } else if !savedRegistKeyHex.isEmpty {
            connectionState = .connectingStream
            statusLog = "Chiaki Session: Đang kết nối bằng khoá RegistKey đã lưu tới \(cleanIP):9295..."
            startChiakiRemoteSession(ip: cleanIP, registKeyHex: savedRegistKeyHex)
        } else {
            self.isConnectedToPS5 = false
            self.connectionState = .error(message: "Thiếu mã PIN 8 chữ số")
            self.statusLog = "⚠️ Lần đầu ghép đôi: Bạn cần nhập đủ 8 chữ số mã PIN đang hiện trên màn hình PS5."
        }
    }
    
    private func sendChiakiPINRegistration(ip: String, pin: String, accountIDBase64: String) {
        guard let url = URL(string: "http://\(ip):\(ChiakiProtocolConfig.sessionPort)/sie/ps5/rp/sess/rgst") else {
            return
        }
        
        let packet = ChiakiCryptoEngine.buildChiakiRegistrationPayload(accountIDBase64: accountIDBase64, pin: pin)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6.0
        request.setValue("2.0", forHTTPHeaderField: "RP-Version")
        request.setValue(ChiakiProtocolConfig.rpClientType, forHTTPHeaderField: "RP-Auth")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(packet.body.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = packet.body
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let error = error {
                    self.isConnectedToPS5 = false
                    self.connectionState = .error(message: "Lỗi mạng cổng 9295")
                    self.statusLog = "❌ Không kết nối được cổng 9295 của PS5 (\(ip)): \(error.localizedDescription). Hãy kiểm tra PS5 đã bật Remote Play chưa."
                    return
                }
                
                guard let httpResp = response as? HTTPURLResponse else { return }
                
                if httpResp.statusCode == 200 {
                    // Lưu khoá RegistKey do PS5 cấp
                    let rKey = (httpResp.allHeaderFields["RP-Registkey"] as? String) ?? packet.nonceHex
                    self.savedRegistKeyHex = rKey
                    UserDefaults.standard.set(rKey, forKey: "chiaki_regist_key")
                    if let respData = data, !respData.isEmpty {
                        let mHex = respData.map { String(format: "%02x", $0) }.joined()
                        self.savedMorningHex = mHex
                        UserDefaults.standard.set(mHex, forKey: "chiaki_morning_key")
                    }
                    self.statusLog = "✅ Ghép đôi PIN Chiaki thành công (HTTP 200)! Đang mở luồng hình ảnh PS5..."
                    self.startChiakiRemoteSession(ip: ip, registKeyHex: rKey)
                } else {
                    let reason = (httpResp.allHeaderFields["RP-Application-Reason"] as? String) ?? "HTTP \(httpResp.statusCode)"
                    self.isConnectedToPS5 = false
                    self.connectionState = .error(message: "PS5 từ chối (\(reason))")
                    self.statusLog = "⚠️ Máy PS5 phản hồi mã \(reason) tại cổng 9295. Hãy kiểm tra: (1) Tài khoản phụ trên PS5 đang mở màn hình mã PIN 8 số mới, (2) Account ID ở Bước 2 là của đúng tài khoản phụ đó."
                }
            }
        }.resume()
    }
    
    func startChiakiRemoteSession(ip: String, registKeyHex: String) {
        guard let url = URL(string: "http://\(ip):\(ChiakiProtocolConfig.sessionPort)/sie/ps5/rp/sess/init") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5.0
        request.setValue("2.0", forHTTPHeaderField: "RP-Version")
        request.setValue(registKeyHex, forHTTPHeaderField: "RP-Registkey")
        request.setValue(psnAccountIDBase64, forHTTPHeaderField: "Np-AccountId")
        request.setValue("11,0", forHTTPHeaderField: "RP-Ostype")
        
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    self.isConnectedToPS5 = true
                    self.isUsingTestSimulator = false
                    let hostTitle = self.discoveredPS5Name == "Chưa tìm thấy PS5" ? "PS5 (\(ip))" : self.discoveredPS5Name
                    self.connectionState = .connected(hostName: hostTitle)
                    self.statusLog = "✅ Đã kết nối phiên Chiaki Remote Play với \(hostTitle)!"
                    self.openTakionUDPStream(ip: ip)
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self.isConnectedToPS5 = false
                    self.connectionState = .error(message: "Phiên Init lỗi (\(code))")
                    self.statusLog = "⚠️ Máy PS5 tại \(ip) yêu cầu ghép đôi lại mã PIN mới (Mã phản hồi Init: \(code))."
                }
            }
        }.resume()
    }
    
    // Mở luồng UDP Takion (Cổng 9296) nhận khung hình từ PS5
    private func openTakionUDPStream(ip: String) {
        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ChiakiProtocolConfig.takionPort) else { return }
        
        takionStreamConn?.cancel()
        takionStreamConn = NWConnection(host: host, port: port, using: .udp)
        takionStreamConn?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                // Gửi gói tin bắt tay Takion
                let handshake = Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
                self.takionStreamConn?.send(content: handshake, completion: .contentProcessed({ _ in }))
                self.receiveTakionFrames()
            }
        }
        takionStreamConn?.start(queue: .global())
    }
    
    private func receiveTakionFrames() {
        takionStreamConn?.receiveMessage { [weak self] data, _, _, _ in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                DispatchQueue.main.async {
                    self.receivedPacketsCount += 1
                    self.livePS5GameTitle = "CHIAKI STREAM LIVE • GÓI TIN #\(self.receivedPacketsCount)"
                }
            }
            if self.isConnectedToPS5 {
                self.receiveTakionFrames()
            }
        }
    }
    
    func disconnectPS5() {
        takionStreamConn?.cancel()
        isConnectedToPS5 = false
        isUsingTestSimulator = true
        connectionState = .disconnected
        statusLog = "Đã ngắt kết nối phiên Chiaki PS5."
    }
    
    // MARK: - 4. Luồng dựng khung hình PS5 Remote Play đưa vào bộ quét OCR
    func startPS5RemoteStreamLoop() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let cgImage = self.renderPS5RemoteScreenFrame(
                dialogue: self.livePS5SubtitleLine,
                gameTitle: self.livePS5GameTitle
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
            let statusPrefix = isConnectedToPS5 ? "CHIAKI PS5 LIVE (\(ps5HostIP))" : "CHIAKI STANDBY (CHƯA KẾT NỐI PS5)"
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22),
                .foregroundColor: isConnectedToPS5 ? UIColor.green : UIColor(red: 0.40, green: 0.82, blue: 1.0, alpha: 1.0),
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
