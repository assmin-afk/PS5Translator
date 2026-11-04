// ============================================================================
// FILE 6: 6_OverlayAndBroadcaster.swift (BẢN CHUẨN TƯƠNG HỢP OCR HOÀN TOÀN)
// ============================================================================

import SwiftUI
import Network
import Combine
import WebKit
import UniformTypeIdentifiers

class TVWebSocketServer: ObservableObject {
    @Published var connectedCount: Int = 0
    @Published var ipAddress: String = "Đang lấy IP..."
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    
    init() {
        ipAddress = getIP() ?? "192.168.1.15"
        start()
    }
    
    private func start() {
        do {
            let params = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            
            guard let port = NWEndpoint.Port(rawValue: AppConfig.webSocketPort) else { return }
            listener = try NWListener(using: params, on: port)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.connections.append(conn)
                DispatchQueue.main.async { self?.connectedCount = self?.connections.count ?? 0 }
                conn.start(queue: .main)
            }
            listener?.start(queue: .main)
        } catch {}
    }
    
    func broadcast(boxes: [TranslatedBox]) {
        let payload = TVPayload(status: boxes.isEmpty ? "clear" : "show", boxes: boxes)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        for conn in connections {
            conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
    
    private func getIP() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                if let interface = ptr?.pointee,
                   interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                   String(cString: interface.ifa_name) == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    addr = String(cString: hostname)
                }
                ptr = ptr?.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return addr
    }
}

class PipelineCoordinator: ObservableObject {
    @Published var videoMgr = VideoSourceManager()
    @Published var throttler = SmartThrottler()
    @Published var server = TVWebSocketServer()
    @Published var roiMode: ROIMode = .dialogueOnly
    @Published var activeGameProfile: String = "game_data.sqlite (Mặc định)"
    @Published var savedProfiles: [String] = []
    @Published var translatedBoxes: [TranslatedBox] = []
    @Published var lastRecognizedEnglish: String = "Đang chờ chữ trên màn hình PS5..."
    @Published var showROIGuideBox: Bool = true
    
    private let ocr = OCREngine()
    private var translator = PredictiveTranslator()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        refreshProfileList()
        videoMgr.$currentFullFrame
            .compactMap { $0 }
            .sink { [weak self] frame in
                self?.process(frame)
            }
            .store(in: &cancellables)
    }
    
    func refreshProfileList() {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        if let files = try? fm.contentsOfDirectory(atPath: docsURL.path) {
            savedProfiles = files.filter { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") }.sorted()
        }
    }
    
    func importSQLiteFromFilesApp(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileName = url.lastPathComponent
        let destURL = docsURL.appendingPathComponent(fileName)
        let activeDBURL = docsURL.appendingPathComponent("game_data.sqlite")
        
        try? fm.removeItem(at: destURL)
        try? fm.copyItem(at: url, to: destURL)
        try? fm.removeItem(at: activeDBURL)
        try? fm.copyItem(at: url, to: activeDBURL)
        
        activeGameProfile = fileName
        translator = PredictiveTranslator()
        refreshProfileList()
    }
    
    func selectSavedProfile(_ name: String) {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let srcURL = docsURL.appendingPathComponent(name)
        let activeDBURL = docsURL.appendingPathComponent("game_data.sqlite")
        if srcURL.path != activeDBURL.path {
            try? fm.removeItem(at: activeDBURL)
            try? fm.copyItem(at: srcURL, to: activeDBURL)
        }
        activeGameProfile = name
        translator = PredictiveTranslator()
    }
    
    private func process(_ frame: CGImage) {
        guard let cropped = videoMgr.cropFrameToSmartROI(fullImage: frame, mode: roiMode) else { return }
        guard throttler.shouldPerformOCR(on: cropped) else { return }
        
        let roiRect = videoMgr.getNormalizedROIRect(for: roiMode)
        
        // Sử dụng phản hồi trực tiếp qua hàm dịch sẵn có của OCREngine mà không ép kiểu cứng
        ocr.detectText(in: cropped) { [weak self] rawResults in
            guard let self = self else { return }
            
            // Ép kiểu mảng linh hoạt để tránh lỗi scope
            let tokens = (rawResults as? [Any]) ?? []
            var formattedTokens: [OCRToken] = []
            
            for item in tokens {
                if let token = item as? OCRToken {
                    formattedTokens.append(token)
                } else if let dict = item as? [String: Any],
                          let text = dict["text"] as? String,
                          let x = dict["x"] as? CGFloat,
                          let y = dict["y"] as? CGFloat,
                          let w = dict["w"] as? CGFloat,
                          let h = dict["h"] as? CGFloat {
                    formattedTokens.append(OCRToken(rawText: text, x: x, y: y, w: w, h: h))
                }
            }
            
            let englishPreview = formattedTokens.map { $0.rawText }.joined(separator: " ")
            
            self.translator.translate(ocrResults: formattedTokens) { boxes in
                let mappedBoxes = boxes.map { b in
                    TranslatedBox(
                        text: b.text,
                        x: roiRect.origin.x + b.x * roiRect.size.width,
                        y: roiRect.origin.y + b.y * roiRect.size.height,
                        w: b.w * roiRect.size.width,
                        h: b.h * roiRect.size.height
                    )
                }
                DispatchQueue.main.async {
                    if !englishPreview.isEmpty {
                        self.lastRecognizedEnglish = englishPreview
                    }
                    self.translatedBoxes = mappedBoxes
                    self.server.broadcast(boxes: mappedBoxes)
                }
            }
        }
    }
}

struct MainTranslatorView: View {
    @StateObject private var coord = PipelineCoordinator()
    @State private var showPS5ConnectSheet = false
    @State private var showDatabaseSheet = false
    
    private let psDarkBg = Color(red: 0.02, green: 0.04, blue: 0.09)
    private let psBluePrimary = Color(red: 0.0, green: 0.26, blue: 0.61)
    private let psNeonAccent = Color(red: 0.0, green: 0.44, blue: 0.82)
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [psDarkBg, Color(red: 0.04, green: 0.09, blue: 0.20), psDarkBg]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 12) {
                topPlayStationBar
                ps5ScreenViewport
                liveOCRStatusStrip
                bottomDualSenseControlBar
                Spacer(minLength: 4)
            }
            .padding(.top, 6)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPS5ConnectSheet) {
            PS5ConnectionWizardView(coord: coord)
        }
        .sheet(isPresented: $showDatabaseSheet) {
            DatabaseAndTVSettingsView(coord: coord)
        }
    }
    
    private var topPlayStationBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(psNeonAccent)
                    .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("PS5 Remote Translator")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(coord.videoMgr.isConnectedToPS5 ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(coord.videoMgr.isConnectedToPS5 ? "Đã nối: \(coord.videoMgr.ps5HostIP)" : "Chưa liên kết PS5 (Chế độ mẫu)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Image(systemName: "tv.fill")
                    .font(.caption2)
                Text("TV: \(coord.server.connectedCount)")
                    .font(.caption.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(coord.server.connectedCount > 0 ? Color.green.opacity(0.25) : Color.white.opacity(0.1))
            .foregroundColor(coord.server.connectedCount > 0 ? .green : .white)
            .clipShape(Capsule())
            
            Button(action: { showPS5ConnectSheet = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "link.badge.plus")
                    Text(coord.videoMgr.isConnectedToPS5 ? "Đổi PS5" : "Kết nối PS5")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(psNeonAccent)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
    }
    
    private var ps5ScreenViewport: some View {
        ZStack {
            if let img = coord.videoMgr.currentFullFrame {
                Image(uiImage: UIImage(cgImage: img))
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        GeometryReader { geo in
                            ZStack {
                                if coord.showROIGuideBox {
                                    let roi = coord.videoMgr.getNormalizedROIRect(for: coord.roiMode)
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(style: StrokeStyle(lineWidth: 1.8, dash: [6, 4]))
                                        .foregroundColor(.cyan.opacity(0.85))
                                        .frame(
                                            width: roi.size.width * geo.size.width,
                                            height: roi.size.height * geo.size.height
                                        )
                                        .position(
                                            x: (roi.origin.x + roi.size.width / 2) * geo.size.width,
                                            y: (roi.origin.y + roi.size.height / 2) * geo.size.height
                                        )
                                }
                                
                                ForEach(coord.translatedBoxes) { box in
                                    Text(box.text)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.yellow)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.88))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(psNeonAccent.opacity(0.8), lineWidth: 1)
                                        )
                                        .cornerRadius(8)
                                        .position(
                                            x: (box.x + box.w / 2) * geo.size.width,
                                            y: (box.y + box.h / 2) * geo.size.height
                                        )
                                }
                            }
                        }
                    )
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Đang khởi tạo khung hình PS5...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .background(Color.black)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    LinearGradient(
                        colors: [psNeonAccent.opacity(0.9), Color.cyan.opacity(0.3), psBluePrimary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
        )
        .shadow(color: psNeonAccent.opacity(0.35), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 12)
    }
    
    private var liveOCRStatusStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "viewfinder")
                .foregroundColor(.cyan)
            Text("Quét OCR: \(coord.lastRecognizedEnglish)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Spacer()
            Button(action: { coord.videoMgr.nextSampleScene() }) {
                Label("Đổi cảnh mẫu", systemImage: "forward.frame.fill")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.cyan)
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
    }
    
    private var bottomDualSenseControlBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Vùng quét chữ:")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.8))
                Picker("Chế độ quét ROI", selection: $coord.roiMode) {
                    ForEach(ROIMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                
                Toggle("", isOn: $coord.showROIGuideBox)
                    .labelsHidden()
            }
            
            HStack(spacing: 8) {
                Text("Nguồn hình:")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.8))
                ForEach(VideoFeedSource.allCases, id: \.self) { src in
                    Button(action: {
                        coord.videoMgr.setVideoFeedSource(src)
                    }) {
                        Text(src.rawValue)
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(coord.videoMgr.feedSource == src ? psNeonAccent : Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                }
                Spacer()
            }
            
            HStack(spacing: 10) {
                Button(action: { showPS5ConnectSheet = true }) {
                    HStack {
                        Image(systemName: "play.tv.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Liên kết máy PS5")
                                .font(.system(size: 13, weight: .bold))
                            Text("Tài khoản phụ & Mã PIN")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.75))
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(psBluePrimary.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                
                Button(action: { showDatabaseSheet = true }) {
                    HStack {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Database Việt Hoá")
                                .font(.system(size: 13, weight: .bold))
                            Text(coord.activeGameProfile)
                                .font(.system(size: 10))
                                .foregroundColor(.cyan)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.10))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.05, green: 0.10, blue: 0.22).opacity(0.92))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}

struct PS5ConnectionWizardView: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var showPSNWebLogin = false
    
    private let psBlue = Color(red: 0.0, green: 0.44, blue: 0.82)
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .padding(14)
                            .background(psBlue)
                            .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Liên kết Chơi Từ Xa (PS5 Remote Play)")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text(coord.videoMgr.statusLog)
                                .font(.caption)
                                .foregroundColor(.cyan)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.06, green: 0.13, blue: 0.28))
                    .cornerRadius(14)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Label("BƯỚC 1: Địa chỉ IP của máy PS5", systemImage: "1.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                        
                        Text("Vào PS5 -> Cài đặt -> Mạng -> Trạng thái kết nối -> Xem địa chỉ IPv4, hoặc bấm nút Quét tự động:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        HStack {
                            TextField("VD: 192.168.1.100", text: $coord.videoMgr.ps5HostIP)
                                .keyboardType(.numbersAndPunctuation)
                                .padding(10)
                                .background(Color.black.opacity(0.35))
                                .cornerRadius(8)
                                .foregroundColor(.white)
                            
                            Button(action: { coord.videoMgr.scanForPS5OnLAN() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                    Text("Quét tìm PS5")
                                        .font(.caption.bold())
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(psBlue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(14)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Label("BƯỚC 2: Tài khoản PSN Phụ (Dùng để lấy hình ảnh)", systemImage: "2.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                        
                        TextField("Tên tài khoản PSN phụ (VD: Player2_VN)", text: $coord.videoMgr.psnUsername)
                            .padding(10)
                            .background(Color.black.opacity(0.35))
                            .cornerRadius(8)
                            .foregroundColor(.white)
                        
                        HStack {
                            TextField("Mã Account ID Base64 (Không bắt buộc)", text: $coord.videoMgr.psnAccountIDBase64)
                                .font(.caption)
                                .padding(10)
                                .background(Color.black.opacity(0.35))
                                .cornerRadius(8)
                                .foregroundColor(.white)
                            
                            Button(action: { showPSNWebLogin = true }) {
                                Text("Đăng nhập Sony")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.15))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(14)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Label("BƯỚC 3: Mã PIN 8 số liên kết thiết bị", systemImage: "3.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                        
                        Text("Trên PS5 (ở tài khoản phụ): Cài đặt -> Hệ thống -> Chơi từ xa -> Liên kết thiết bị:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        TextField("Nhập 8 chữ số (VD: 1234 5678)", text: $coord.videoMgr.psnPinCode)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .keyboardType(.numberPad)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(psBlue, lineWidth: 1.5)
                            )
                            .cornerRadius(10)
                            .foregroundColor(.yellow)
                    }
                    .padding()
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(14)
                    
                    Button(action: {
                        coord.videoMgr.pairAndConnectToPS5(
                            username: coord.videoMgr.psnUsername,
                            accountIDBase64: coord.videoMgr.psnAccountIDBase64,
                            pinCode: coord.videoMgr.psnPinCode,
                            ip: coord.videoMgr.ps5HostIP
                        )
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Spacer()
                            Image(systemName: "link.circle.fill")
                                .font(.title3)
                            Text("LIÊN KẾT & HIỂN THỊ MÀN HÌNH PS5")
                                .font(.system(size: 15, weight: .bold))
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(psBlue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    
                    if coord.videoMgr.isConnectedToPS5 {
                        Button(action: {
                            coord.videoMgr.disconnectPS5()
                        }) {
                            HStack {
                                Spacer()
                                Text("Ngắt kết nối PS5 hiện tại")
                                    .font(.subheadline.bold())
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.25))
                            .foregroundColor(.red)
                            .cornerRadius(10)
                        }
                    }
                }
                .padding()
            }
            .background(Color(red: 0.03, green: 0.05, blue: 0.12).ignoresSafeArea())
            .navigationTitle("Kết nối PS5 Remote Play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPSNWebLogin) {
                PSNWebLoginHelperView(accountIDBase64: $coord.videoMgr.psnAccountIDBase64)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct PSNWebLoginHelperView: View {
    @Binding var accountIDBase64: String
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                Text("Đăng nhập tài khoản PSN phụ để lấy thông tin liên kết chính thức từ Sony")
                    .font(.caption)
                    .foregroundColor(.cyan)
                    .padding(.top, 6)
                
                SonyWebView(url: URL(string: "https://my.account.sony.com/")!)
            }
            .navigationTitle("Sony PlayStation Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

struct SonyWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct DatabaseAndTVSettingsView: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var showFileImporter = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("1. Hồ sơ Game & Nạp Database Việt hoá (.sqlite)")) {
                    HStack {
                        Text("Đang kích hoạt:")
                        Spacer()
                        Text(coord.activeGameProfile)
                            .bold()
                            .foregroundColor(.cyan)
                    }
                    
                    Button(action: { showFileImporter = true }) {
                        Label("Nhập file .sqlite từ ứng dụng Tệp (iPhone)", systemImage: "folder.badge.plus")
                            .font(.body.bold())
                            .foregroundColor(.blue)
                    }
                    
                    if !coord.savedProfiles.isEmpty {
                        ForEach(coord.savedProfiles, id: \.self) { name in
                            Button(action: {
                                coord.selectSavedProfile(name)
                            }) {
                                HStack {
                                    Text(name)
                                        .foregroundColor(.white)
                                    Spacer()
                                    if coord.activeGameProfile == name {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Section(header: Text("2. Kết nối WebSocket sang TV Samsung")) {
                    HStack {
                        Text("Địa chỉ IP của iPhone:")
                        Spacer()
                        Text("\(coord.server.ipAddress):\(AppConfig.webSocketPort)")
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundColor(.green)
                    }
                    HStack {
                        Text("Số TV Samsung đang nhận phụ đề:")
                        Spacer()
                        Text("\(coord.server.connectedCount) TV")
                            .bold()
                    }
                }
                
                Section(header: Text("3. Hiển thị vùng quét OCR")) {
                    Toggle("Hiện khung viền nét đứt vùng quét (ROI)", isOn: $coord.showROIGuideBox)
                }
            }
            .navigationTitle("Database & TV Samsung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let selectedURL = urls.first {
                    coord.importSQLiteFromFilesApp(url: selectedURL)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

@main
struct PS5TranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            MainTranslatorView()
        }
    }
}
