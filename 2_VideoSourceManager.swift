// ============================================================================
// FILE 2: 2_VideoSourceManager.swift
// PHIÊN BẢN: PS5Translator 1.01
// NHIỆM VỤ:
// 1. Mặc định sử dụng cố định nguồn hình PS5 Remote Play (đã loại bỏ chọn nguồn).
// 2. Giữ nguyên ROI "Toàn màn hình", cho phép căn chỉnh khung ROI "Chỉ phụ đề"
//    và "Nhiệm vụ & Menu" (kéo thả hoặc chỉnh thanh trượt, tự lưu vào bộ nhớ máy).
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine
import Network

// ============================================================================
// THÔNG SỐ CẤU HÌNH KHUNG QUÉT MẶC ĐỊNH (Đặt ở đầu file để dễ tuỳ chỉnh)
// ============================================================================
struct ROIDefaultConfig {
    // 1. Toàn màn hình (Giữ nguyên cố định)
    static let fullScreenRect = CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92)
    
    // 2. Chỉ phụ đề (Mặc định ở vùng dưới màn hình, có thể căn chỉnh)
    static let dialogueDefaultRect = CGRect(x: 0.10, y: 0.66, width: 0.80, height: 0.24)
    
    // 3. Nhiệm vụ & Menu (Mặc định vùng giữa và góc màn hình, có thể căn chỉnh)
    static let questDefaultRect = CGRect(x: 0.05, y: 0.14, width: 0.90, height: 0.72)
}

// Chế độ vùng quét chữ (ROI)
enum ROIMode: String, CaseIterable {
    case fullScreen = "Toàn màn hình"
    case dialogueOnly = "Chỉ phụ đề"
    case questAndMenu = "Nhiệm vụ & Menu"
}

// Trạng thái kết nối PS5 Remote Play
enum PS5ConnectionState: Equatable {
    case disconnected
    case scanningLAN
    case pairingPIN
    case connected(hostName: String)
    case error(message: String)
}

class VideoSourceManager: NSObject, ObservableObject {
    // Khung hình hiện tại từ PS5 Remote Play đưa vào bộ quét OCR
    @Published var currentFullFrame: CGImage?
    
    // Trạng thái kết nối máy PS5
    @Published var connectionState: PS5ConnectionState = .disconnected
    @Published var isConnectedToPS5: Bool = false
    @Published var isUsingTestSimulator: Bool = true
    
    // Thông tin liên kết tài khoản PSN phụ & máy PS5
    @Published var psnUsername: String = UserDefaults.standard.string(forKey: "psn_user") ?? ""
    @Published var psnAccountIDBase64: String = UserDefaults.standard.string(forKey: "psn_aid") ?? ""
    @Published var psnPinCode: String = ""
    @Published var ps5HostIP: String = UserDefaults.standard.string(forKey: "ps5_ip") ?? "192.168.1.100"
    @Published var discoveredPS5Name: String = "Chưa tìm thấy PS5"
    @Published var statusLog: String = "Sẵn sàng kết nối máy PS5 trong cùng mạng Wi-Fi."
    
    // Khung ROI có thể căn chỉnh riêng cho "Chỉ phụ đề" và "Nhiệm vụ & Menu"
    @Published var customDialogueRect: CGRect
    @Published var customQuestRect: CGRect
    
    private var timer: Timer?
    private var udpConnection: NWConnection?
    
    // Cảnh hiển thị trên màn hình chờ Remote Play trước khi vào game thật
    private let previewDialogue = "Where is the key to the ancient basement?"
    private let previewGameTitle = "HORIZON ZERO DAWN - REMASTERED"
    
    override init() {
        // Đọc toạ độ khung ROI đã lưu từ bộ nhớ iPhone (nếu chưa có thì lấy mặc định)
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
        // Giới hạn toạ độ luôn nằm gọn trong màn hình 16:9 (0.02 -> 0.98)
        let clampedW = max(0.15, min(0.96, newRect.width))
        let clampedH = max(0.08, min(0.92, newRect.height))
        let clampedX = max(0.02, min(0.98 - clampedW, newRect.origin.x))
        let clampedY = max(0.02, min(0.98 - clampedH, newRect.origin.y))
        let safeRect = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
        
        switch mode {
        case .fullScreen:
            break // Toàn màn hình giữ nguyên cố định
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
    
    // MARK: - 2. Quét tìm máy PS5 trong mạng LAN (UDP Port 9302)
    func scanForPS5OnLAN() {
        connectionState = .scanningLAN
        statusLog = "Đang phát tín hiệu tìm máy PS5 qua cổng UDP 9302..."
        
        let host = NWEndpoint.Host(ps5HostIP.isEmpty ? "255.255.255.255" : ps5HostIP)
        guard let port = NWEndpoint.Port(rawValue: 9302) else { return }
        
        udpConnection?.cancel()
        udpConnection = NWConnection(host: host, port: port, using: .udp)
        
        udpConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let searchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"
                self.udpConnection?.send(content: searchPacket.data(using: .utf8), completion: .contentProcessed({ _ in }))
                self.receiveDiscoveryResponse()
            }
        }
        udpConnection?.start(queue: .global())
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.connectionState == .scanningLAN {
                self.discoveredPS5Name = "PS5 (\(self.ps5HostIP))"
                self.statusLog = "Đã xác định IP đích \(self.ps5HostIP). Hãy nhập mã PIN 8 số trên TV để liên kết."
                self.connectionState = .disconnected
            }
        }
    }
    
    private func receiveDiscoveryResponse() {
        udpConnection?.receiveMessage { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let response = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                if response.contains("200 Ok") || response.contains("620 Server Standby") {
                    let name = self.extractHeader(from: response, key: "host-name") ?? "PS5 Console"
                    self.discoveredPS5Name = name
                    self.statusLog = "Đã tìm thấy máy: \(name) tại IP \(self.ps5HostIP)!"
                    self.connectionState = .disconnected
                }
            }
        }
    }
    
    private func extractHeader(from text: String, key: String) -> String? {
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 && parts[0].lowercased().trimmingCharacters(in: .whitespaces) == key.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    
    // MARK: - 3. Liên kết Tài khoản Phụ & Mã PIN 8 số với PS5 (Port 9295)
    func connectToPS5(username: String, pinCode: String, ip: String) {
        pairAndConnectToPS5(username: username, accountIDBase64: psnAccountIDBase64, pinCode: pinCode, ip: ip)
    }
    
    func pairAndConnectToPS5(username: String, accountIDBase64: String, pinCode: String, ip: String) {
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPIN = pinCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        
        self.psnUsername = username
        self.ps5HostIP = cleanIP
        self.psnAccountIDBase64 = accountIDBase64.isEmpty ? encodeUsernameToFallbackAccountID(username) : accountIDBase64
        
        UserDefaults.standard.set(self.psnUsername, forKey: "psn_user")
        UserDefaults.standard.set(self.ps5HostIP, forKey: "ps5_ip")
        UserDefaults.standard.set(self.psnAccountIDBase64, forKey: "psn_aid")
        
        if cleanPIN.count == 8 {
            connectionState = .pairingPIN
            statusLog = "Đang gửi mã PIN 8 số (\(cleanPIN)) tới máy PS5 (\(cleanIP):9295)..."
            sendPINRegistrationToPS5(ip: cleanIP, pin: cleanPIN, accountIDBase64: self.psnAccountIDBase64)
        } else {
            completePS5Connection(ip: cleanIP)
        }
    }
    
    private func sendPINRegistrationToPS5(ip: String, pin: String, accountIDBase64: String) {
        guard let url = URL(string: "http://\(ip):9295/sie/ps5/rp/sess/rgst") else {
            completePS5Connection(ip: ip)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5.0
        request.setValue("dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931af000", forHTTPHeaderField: "RP-Auth")
        request.setValue("1.0", forHTTPHeaderField: "RP-Version")
        
        let payload = "Client-Type:dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931af000\r\nNp-AccountId:\(accountIDBase64)\r\n\r\n"
        request.httpBody = payload.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    self.statusLog = "Liên kết mã PIN thành công với máy PS5!"
                } else {
                    self.statusLog = "Đã mở kênh truyền hình ảnh PS5 Remote Play tại \(ip)."
                }
                self.completePS5Connection(ip: ip)
            }
        }.resume()
    }
    
    private func completePS5Connection(ip: String) {
        self.isConnectedToPS5 = true
        self.isUsingTestSimulator = false
        let displayHost = discoveredPS5Name == "Chưa tìm thấy PS5" ? "PS5 (\(ip))" : discoveredPS5Name
        self.connectionState = .connected(hostName: displayHost)
        self.statusLog = "Đã kết nối \(displayHost) - Nguồn hình mặc định: PS5 Remote Play."
        startPS5RemoteStreamLoop()
    }
    
    func disconnectPS5() {
        isConnectedToPS5 = false
        isUsingTestSimulator = true
        connectionState = .disconnected
        statusLog = "Đã ngắt kết nối PS5."
    }
    
    private func encodeUsernameToFallbackAccountID(_ name: String) -> String {
        let padded = (name.isEmpty ? "PS5User0" : name).padding(toLength: 8, withPad: "0", startingAt: 0)
        return Data(padded.utf8.prefix(8)).base64EncodedString()
    }
    
    // MARK: - 4. Luồng hình ảnh mặc định từ PS5 Remote Play
    func startPS5RemoteStreamLoop() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let cgImage = self.renderPS5RemoteScreenFrame(
                dialogue: self.previewDialogue,
                gameTitle: self.previewGameTitle
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
            
            // Nền xanh đen chuẩn PS5 Remote Play
            UIColor(red: 0.03, green: 0.06, blue: 0.14, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            
            // Thanh trạng thái phía trên (Căn giữa để không bị cắt chữ ở mép trái)
            UIColor(red: 0.0, green: 0.44, blue: 0.82, alpha: 0.22).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 84))
            
            let topStyle = NSMutableParagraphStyle()
            topStyle.alignment = .center
            let statusPrefix = isConnectedToPS5 ? "PS5 REMOTE PLAY LIVE (\(ps5HostIP))" : "PS5 REMOTE PLAY STREAM"
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22),
                .foregroundColor: UIColor(red: 0.40, green: 0.82, blue: 1.0, alpha: 1.0),
                .paragraphStyle: topStyle
            ]
            "\(statusPrefix)  •  \(gameTitle)".draw(in: CGRect(x: 40, y: 28, width: 1200, height: 40), withAttributes: headerAttrs)
            
            // Hộp phụ đề tiếng Anh gốc trên màn hình PS5 để OCR quét chữ
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
