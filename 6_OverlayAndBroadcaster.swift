// ============================================================================
// FILE 6: 6_OverlayAndBroadcaster.swift
// NHIỆM VỤ:
// 1. Tạo WebSocket Server (Port 8080) phát bản dịch sang TV Samsung qua Wi-Fi.
// 2. Hiển thị màn hình điều khiển chính trên iPhone: Vẽ chữ tiếng Việt đè lên
//    chữ gốc, cho phép chỉnh thanh trượt FPS chống nóng và kéo khung quét ROI.
// ============================================================================

import SwiftUI
import Network
import Combine

// MARK: - 1. Bộ phát tín hiệu WebSocket Server sang TV Samsung (Port 8080)
class TVWebSocketBroadcaster: ObservableObject {
    @Published var connectedTVCount: Int = 0
    @Published var localIPAddress: String = "Đang tìm IP..."
    
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var lastSentJSON: String = ""
    
    init() {
        localIPAddress = Self.getWiFiIPAddress() ?? "Không tìm thấy Wi-Fi"
        startServer()
    }
    
    func startServer() {
        do {
            let parameters = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            
            guard let port = NWEndpoint.Port(rawValue: AppConfig.webSocketPort) else { return }
            listener = try NWListener(using: parameters, on: port)
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleNewTVConnection(newConnection)
            }
            listener?.start(queue: .main)
        } catch {
            print("Lỗi khởi tạo WebSocket Server: \(error)")
        }
    }
    
    private func handleNewTVConnection(_ connection: NWConnection) {
        connections.append(connection)
        connectedTVCount = connections.count
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeAll { $0 === connection }
                self?.connectedTVCount = self?.connections.count ?? 0
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
    
    /// Bắn gói tin JSON chuẩn sang TV Samsung (Chỉ bắn khi nội dung chữ có thay đổi)
    func broadcast(boxes: [TranslatedBox]) {
        let payload = TVPayload(status: boxes.isEmpty ? "clear" : "show", boxes: boxes)
        guard let data = try? JSONEncoder().encode(payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        
        // Không bắn lặp lại cùng 1 gói tin để tiết kiệm băng thông Wi-Fi
        guard jsonString != lastSentJSON else { return }
        lastSentJSON = jsonString
        
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "textContext", metadata: [metadata])
        
        for connection in connections {
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
    
    /// Tự động lấy địa chỉ IP Wi-Fi của iPhone để hiển thị lên màn hình cho bạn nhập vào TV
    static func getWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}

// MARK: - 2. Bộ điều phối trung tâm kết nối cả 6 File
class TranslationPipelineCoordinator: ObservableObject {
    @Published var videoManager = VideoSourceManager()
    @Published var throttler = SmartThrottler()
    @Published var broadcaster = TVWebSocketBroadcaster()
    
    @Published var roiRect: CGRect = AppConfig.defaultROIRect
    @Published var activeTranslatedBoxes: [TranslatedBox] = []
    
    private let ocrEngine = OCREngine()
    private let translator = PredictiveTranslator()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Mỗi khi có khung hình mới từ File 2 -> Đưa qua File 3 (Chống nóng) -> File 4 (OCR) -> File 5 (Đoán câu) -> File 6 (Hiển thị & Bắn sang TV)
        videoManager.$currentFullFrame
            .compactMap { $0 }
            .sink { [weak self] fullImage in
                self?.processFrame(fullImage)
            }
            .store(in: &cancellables)
    }
    
    private func processFrame(_ fullImage: CGImage, force: Bool = false) {
        guard let croppedROI = videoManager.cropFrameToROI(fullImage: fullImage, roiRect: roiRect) else { return }
        
        // Bước 1: Hỏi bộ điều tiết chống nóng (File 3) xem có cần quét không
        guard throttler.shouldPerformOCR(on: croppedROI, forceScan: force) else { return }
        
        // Bước 2: Chạy OCR siêu tốc (File 4)
        ocrEngine.recognizeTextFast(in: croppedROI, roiRect: roiRect) { [weak self] rawResults in
            guard let self = self else { return }
            
            // Bước 3: Đưa từ khoá vào Bộ đoán câu Việt hoá (File 5)
            let boxes = self.translator.translateAndPredict(ocrResults: rawResults)
            
            DispatchQueue.main.async {
                self.activeTranslatedBoxes = boxes
                // Bước 4: Bắn kết quả sang TV Samsung qua Wi-Fi
                self.broadcaster.broadcast(boxes: boxes)
            }
        }
    }
    
    func triggerNextSampleAndScan() {
        videoManager.nextSampleDialogue()
        throttler.resetDiffMemory()
    }
}

// MARK: - 3. Giao diện chính trên màn hình iPhone
struct MainTranslatorView: View {
    @StateObject private var coordinator = TranslationPipelineCoordinator()
    
    var body: some View {
        VStack(spacing: 12) {
            // Thanh trạng thái kết nối TV Samsung
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("IP iPhone (nhập vào TV): ws://\(coordinator.broadcaster.localIPAddress):\(AppConfig.webSocketPort)")
                        .font(.caption.bold())
                        .foregroundColor(.green)
                    Text("Số TV Samsung đang kết nối: \(coordinator.broadcaster.connectedTVCount) thiết bị")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Đổi câu thoại mẫu (Test)") {
                    coordinator.triggerNextSampleAndScan()
                }
                .buttonStyle(.borderedProminent)
                .font(.caption.bold())
            }
            .padding(.horizontal)
            
            // Khung màn hình 16:9 hiển thị hình ảnh PS5 + Lớp đè chữ Tiếng Việt + Khung ROI
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if let cgImage = coordinator.videoManager.currentFullFrame {
                        Image(uiImage: UIImage(cgImage: cgImage))
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fit)
                            .overlay(
                                GeometryReader { videoGeo in
                                    ZStack(alignment: .topLeading) {
                                        // Khung giới hạn vùng quét (ROI) màu vàng nét đứt
                                        Rectangle()
                                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                                            .foregroundColor(.yellow)
                                            .frame(
                                                width: coordinator.roiRect.width * videoGeo.size.width,
                                                height: coordinator.roiRect.height * videoGeo.size.height
                                            )
                                            .position(
                                                x: (coordinator.roiRect.origin.x + coordinator.roiRect.width / 2) * videoGeo.size.width,
                                                y: (coordinator.roiRect.origin.y + coordinator.roiRect.height / 2) * videoGeo.size.height
                                            )
                                        
                                        // Vẽ đè câu Tiếng Việt đã dịch lên đúng vị trí chữ gốc
                                        ForEach(coordinator.activeTranslatedBoxes) { box in
                                            Text(box.text)
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundColor(.yellow)
                                                .multilineTextAlignment(.center)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .frame(
                                                    width: max(120, box.w * videoGeo.size.width),
                                                    height: max(36, box.h * videoGeo.size.height)
                                                )
                                                .background(Color.black.opacity(0.88))
                                                .cornerRadius(6)
                                                .position(
                                                    x: (box.x + box.w / 2) * videoGeo.size.width,
                                                    y: (box.y + box.h / 2) * videoGeo.size.height
                                                )
                                        }
                                    }
                                }
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(16/9, contentMode: .fit)
            .background(Color.black)
            .cornerRadius(10)
            .padding(.horizontal)
            
            // Bảng điều khiển Chống nóng máy & Điều chỉnh vùng quét ROI
            VStack(spacing: 8) {
                HStack {
                    Text("Tốc độ quét tối đa: \(Int(coordinator.throttler.targetScanFPS)) FPS")
                        .font(.caption.bold())
                    Slider(value: $coordinator.throttler.targetScanFPS, in: 1...15, step: 1)
                }
                
                HStack {
                    Text("Vị trí khung quét (Cao/Thấp):")
                        .font(.caption)
                    Slider(value: $coordinator.roiRect.origin.y, in: 0.1...0.85)
                }
                
                HStack {
                    Text("Đã quét OCR: \(coordinator.throttler.actualOCRScansCount) lần")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    Spacer()
                    Text("Đã nghỉ chống nóng: \(coordinator.throttler.skippedStaticFramesCount) khung hình tĩnh")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 4. Điểm khởi chạy chính của Ứng dụng (@main)
@main
struct PS5TranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            MainTranslatorView()
        }
    }
}