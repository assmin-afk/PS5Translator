// ============================================================================
// FILE 6: 6_OverlayAndBroadcaster.swift
// NHIỆM VỤ:
// 1. Giao diện App chuẩn PlayStation 5 (Kèm Logo/Icon từ file icon.png).
// 2. Màn hình Liên kết Tài khoản PS5, Quản lý Hồ sơ Game (Nhập file Việt hoá)
//    và Cài đặt Quét Toàn Màn Hình / Dịch AI Apple.
// 3. Hiển thị chữ dịch đè ngay lên chữ tiếng Anh gốc (không đè lên nút tay cầm)
//    và bắn sang TV Samsung qua WebSocket Port 8080.
// ============================================================================

import SwiftUI
import Network
import Combine
import UniformTypeIdentifiers

// MARK: - 1. Bộ phát tín hiệu WebSocket Server sang TV Samsung (Port 8080)
class TVWebSocketBroadcaster: ObservableObject {
    @Published var connectedTVCount: Int = 0
    @Published var localIPAddress: String = "Đang tìm IP..."
    
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var lastSentJSON: String = ""
    
    init() {
        localIPAddress = Self.getWiFiIPAddress() ?? "Bật Wi-Fi để lấy IP"
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
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleNewTVConnection(conn)
            }
            listener?.start(queue: .main)
        } catch {
            print("Lỗi WebSocket Server: \(error)")
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
    
    func broadcast(boxes: [TranslatedBox]) {
        let payload = TVPayload(status: boxes.isEmpty ? "clear" : "show", boxes: boxes)
        guard let data = try? JSONEncoder().encode(payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        
        guard jsonString != lastSentJSON else { return }
        lastSentJSON = jsonString
        
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "textContext", metadata: [metadata])
        
        for connection in connections {
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
    
    static func getWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
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
    @Published var translator = PredictiveTranslator()
    @Published var broadcaster = TVWebSocketBroadcaster()
    
    @Published var isFullScreenScan: Bool = AppConfig.defaultFullScreenScan
    @Published var roiRect: CGRect = AppConfig.defaultROIRect
    @Published var useAppleAIFallback: Bool = AppConfig.enableAppleAIFallback
    
    @Published var enableDialogue: Bool = true { didSet { ocrEngine.enableDialogueTranslation = enableDialogue } }
    @Published var enableQuest: Bool = true    { didSet { ocrEngine.enableQuestTranslation = enableQuest } }
    @Published var enableMenu: Bool = true     { didSet { ocrEngine.enableMenuTranslation = enableMenu } }
    
    @Published var activeTranslatedBoxes: [TranslatedBox] = []
    
    private let ocrEngine = OCREngine()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        videoManager.$currentFullFrame
            .compactMap { $0 }
            .sink { [weak self] fullImage in
                self?.processFrame(fullImage)
            }
            .store(in: &cancellables)
    }
    
    func processFrame(_ fullImage: CGImage, force: Bool = false) {
        guard let cropped = videoManager.cropFrame(fullImage: fullImage, isFullScreen: isFullScreenScan, roiRect: roiRect) else { return }
        
        guard throttler.shouldPerformOCR(on: cropped.image, forceScan: force) else { return }
        
        ocrEngine.recognizeAndClassifyText(in: cropped.image, effectiveROIRect: cropped.effectiveRect) { [weak self] rawResults in
            guard let self = self else { return }
            let boxes = self.translator.translateRegions(ocrResults: rawResults, useAppleAIFallback: self.useAppleAIFallback)
            
            DispatchQueue.main.async {
                self.activeTranslatedBoxes = boxes
                self.broadcaster.broadcast(boxes: boxes)
            }
        }
    }
    
    func triggerNextScene() {
        videoManager.nextSampleDialogue()
        throttler.resetDiffMemory()
    }
}

// MARK: - 3. Giao diện Chính chuẩn PlayStation 5 trên iPhone
struct MainTranslatorView: View {
    @StateObject private var coordinator = TranslationPipelineCoordinator()
    
    @State private var showPS5LinkSheet = false
    @State private var showGameProfilesSheet = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    // 1. THANH LOGO & TRẠNG THÁI KẾT NỐI PS5 / TV SAMSUNG
                    headerBarView
                    
                    // 2. KHUNG MÀN HÌNH PS5 16:9 + HIỂN THỊ CHỮ ĐÈ TRỰC TIẾP LÊN CHỮ GỐC
                    ps5ViewportView
                    
                    // 3. THANH NÚT CHỨC NĂNG NHANH (LIÊN KẾT PS5, HỒ SƠ GAME, ĐỔI CẢNH TEST)
                    quickActionsBarView
                    
                    // 4. BẢNG ĐIỀU KHIỂN QUÉT TOÀN MÀN HÌNH, PHÂN LOẠI CHỮ & DỊCH AI APPLE
                    scanAndAIConfigPanelView
                }
                .padding(.vertical, 8)
            }
            .background(Color(red: 0.05, green: 0.07, blue: 0.12).ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $showPS5LinkSheet) {
                PS5AccountLinkSheetView(videoManager: coordinator.videoManager)
            }
            .sheet(isPresented: $showGameProfilesSheet) {
                GameProfilesSheetView(translator: coordinator.translator)
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Thành phần 1: Header Logo & IP
    private var headerBarView: some View {
        HStack(spacing: 10) {
            // Hiển thị ảnh icon.png của bạn nếu có trong Bundle, nếu chưa có thì hiện biểu tượng tay cầm PS5
            if let uiImage = UIImage(named: "icon.png") ?? UIImage(named: "icon") {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .cornerRadius(10)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: "gamecontroller.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("PS5 TRANSLATOR")
                        .font(.subheadline.weight(.heavy))
                        .foregroundColor(.white)
                    Text(coordinator.translator.activeProfile?.title ?? "Mặc định")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.35))
                        .foregroundColor(.cyan)
                        .cornerRadius(4)
                }
                
                Text("TV IP: ws://\(coordinator.broadcaster.localIPAddress):\(AppConfig.webSocketPort) • TV kết nối: \(coordinator.broadcaster.connectedTVCount)")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            Spacer()
        }
        .padding(.horizontal)
    }
    
    // MARK: - Thành phần 2: Màn hình 16:9 vẽ đè chữ tiếng Việt đúng toạ độ chữ gốc
    private var ps5ViewportView: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                if let cgImage = coordinator.videoManager.currentFullFrame {
                    Image(uiImage: UIImage(cgImage: cgImage))
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay(
                            GeometryReader { videoGeo in
                                ZStack(alignment: .topLeading) {
                                    // Khung ROI màu vàng (Chỉ hiện khi tắt chế độ Quét Toàn Màn Hình)
                                    if !coordinator.isFullScreenScan {
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
                                    }
                                    
                                    // Vẽ đè từng hộp chữ đã dịch đúng vị trí chữ gốc (không đè lên nút tay cầm)
                                    ForEach(coordinator.activeTranslatedBoxes) { box in
                                        let category = TextRegionCategory(rawValue: box.category) ?? .dialogue
                                        
                                        HStack(spacing: 4) {
                                            if box.isAITranslated {
                                                Image(systemName: "sparkles")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(.cyan)
                                            }
                                            Text(box.text)
                                                .font(.system(size: category == .dialogue ? 14 : 12, weight: .bold))
                                                .foregroundColor(category.textColor)
                                                .multilineTextAlignment(.center)
                                                .lineLimit(2)
                                                .minimumScaleFactor(0.75)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .frame(
                                            width: max(90, box.w * videoGeo.size.width),
                                            height: max(28, box.h * videoGeo.size.height)
                                        )
                                        .background(Color.black.opacity(0.90))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(category.borderColor, lineWidth: 1)
                                        )
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
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.4), lineWidth: 1))
        .padding(.horizontal)
    }
    
    // MARK: - Thành phần 3: Thanh nút bấm chức năng chính
    private var quickActionsBarView: some View {
        HStack(spacing: 8) {
            Button {
                showPS5LinkSheet = true
            } label: {
                Label("Liên kết PS5", systemImage: "link.circle.fill")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.25))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            
            Button {
                showGameProfilesSheet = true
            } label: {
                Label("Hồ sơ Game", systemImage: "folder.fill.badge.plus")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.purple.opacity(0.28))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            
            Button {
                coordinator.triggerNextScene()
            } label: {
                Label("Đổi cảnh Test", systemImage: "forward.frame.fill")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.85))
                    .foregroundColor(.black)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Thành phần 4: Bảng điều khiển Quét thông minh & Dịch AI của Apple
    private var scanAndAIConfigPanelView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Quét Toàn Màn Hình (Tự phân vùng)", isOn: $coordinator.isFullScreenScan)
                    .font(.caption.bold())
                    .tint(.blue)
            }
            
            if !coordinator.isFullScreenScan {
                HStack {
                    Text("Vị trí khung ROI (Cao/Thấp):")
                        .font(.caption2)
                    Slider(value: $coordinator.roiRect.origin.y, in: 0.05...0.80)
                }
            }
            
            Divider().background(Color.white.opacity(0.15))
            
            // Tuỳ chọn các loại chữ muốn dịch trên màn hình
            Text("Phân loại vùng chữ cần dịch (Tự tránh nút bấm & hiệu ứng):")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Toggle("Thoại", isOn: $coordinator.enableDialogue)
                    .font(.caption2)
                    .tint(.yellow)
                Toggle("Nhiệm vụ", isOn: $coordinator.enableQuest)
                    .font(.caption2)
                    .tint(.cyan)
                Toggle("Menu", isOn: $coordinator.enableMenu)
                    .font(.caption2)
                    .tint(.white)
            }
            
            Divider().background(Color.white.opacity(0.15))
            
            // Bật/Tắt Dịch AI của Apple khi câu thoại không có sẵn trong Database Việt hoá
            Toggle(isOn: $coordinator.useAppleAIFallback) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.cyan)
                    Text("Dịch AI của Apple (Cho câu ngoài Database Việt hoá)")
                        .font(.caption.bold())
                }
            }
            .tint(.cyan)
            
            // Thanh trượt FPS chống nóng
            HStack {
                Text("Tốc độ quét: \(Int(coordinator.throttler.targetScanFPS)) FPS")
                    .font(.caption.bold())
                Slider(value: $coordinator.throttler.targetScanFPS, in: 1...15, step: 1)
            }
            
            HStack {
                Text("Đã quét OCR: \(coordinator.throttler.actualOCRScansCount) lần")
                    .font(.caption2)
                    .foregroundColor(.cyan)
                Spacer()
                Text("Nghỉ chống nóng: \(coordinator.throttler.skippedStaticFramesCount) khung hình")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 4. Màn hình Liên kết Tài khoản & Kết nối PS5 Remote Play
struct PS5AccountLinkSheetView: View {
    @ObservedObject var videoManager: VideoSourceManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var accountName: String = ""
    @State private var psnID: String = ""
    @State private var pinCode: String = ""
    @State private var ps5IP: String = ""
    @State private var secondaryMode: Bool = true
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Trạng thái kết nối PS5")) {
                    HStack {
                        Circle()
                            .fill(videoManager.connectionState == .streaming ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                        Text(videoManager.connectionState.rawValue)
                            .font(.caption.bold())
                    }
                }
                
                Section(header: Text("Thông tin Liên kết Tài khoản PSN")) {
                    TextField("Tên gợi nhớ (VD: PSN Phụ Dịch Game)", text: $accountName)
                    TextField("PSN Account ID (Base64 / Hex 8-byte)", text: $psnID)
                    TextField("Mã PIN Remote Play 8 số trên PS5", text: $pinCode)
                        .keyboardType(.numberPad)
                    TextField("Địa chỉ IP máy PS5 (VD: 192.168.1.100)", text: $ps5IP)
                        .keyboardType(.numbersAndPunctuation)
                    
                    Toggle("Chế độ Tài khoản Phụ (Giữ tay cầm DualSense trên PS5)", isOn: $secondaryMode)
                        .font(.caption)
                }
                
                Section {
                    Button {
                        videoManager.saveAndLinkPS5Account(
                            name: accountName,
                            psnID: psnID,
                            pin: pinCode,
                            ip: ps5IP,
                            secondaryMode: secondaryMode
                        )
                        videoManager.connectToPS5RemotePlay()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Lưu & Kết nối PS5 Remote Play", systemImage: "bolt.horizontal.circle.fill")
                                .font(.headline)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Liên kết máy PS5")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
            .onAppear {
                accountName = videoManager.accountConfig.psnAccountName
                psnID = videoManager.accountConfig.psnAccountIDBase64
                pinCode = videoManager.accountConfig.pairingPIN
                ps5IP = videoManager.accountConfig.ps5LocalIP
                secondaryMode = videoManager.accountConfig.useSecondaryAccountMode
            }
        }
    }
}

// MARK: - 5. Màn hình Quản lý Hồ sơ Game & Nạp File Việt hoá (.sqlite / .txt)
struct GameProfilesSheetView: View {
    @ObservedObject var translator: PredictiveTranslator
    @Environment(\.dismiss) private var dismiss
    
    @State private var newGameTitle: String = ""
    @State private var showFileImporter: Bool = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Thêm Hồ sơ Game Việt hoá mới")) {
                    TextField("Nhập tên Game (VD: God of War Ragnarök)", text: $newGameTitle)
                    
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Chọn file Việt hoá (.sqlite hoặc .txt) từ iPhone", systemImage: "square.and.arrow.down.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                    }
                }
                
                Section(header: Text("Danh sách Hồ sơ Game đã lưu trên iPhone")) {
                    ForEach(translator.profiles) { profile in
                        Button {
                            translator.selectProfile(profile)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.title)
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                    Text("Số câu Việt hoá: \(profile.sentenceCount) • Cập nhật: \(profile.updatedAt)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if translator.activeProfile?.id == profile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hồ sơ Game Việt hoá")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data, .plainText, .database, .item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let selectedURL = urls.first {
                    translator.importVietnameseDataFile(from: selectedURL, forGameTitle: newGameTitle)
                    newGameTitle = ""
                }
            }
        }
    }
}

// MARK: - 6. Điểm khởi chạy chính của Ứng dụng (@main)
@main
struct PS5TranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            MainTranslatorView()
        }
    }
}
