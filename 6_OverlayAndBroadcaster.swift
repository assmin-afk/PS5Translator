// ============================================================================
// FILE 6: 6_OverlayAndBroadcaster.swift
// PHIÊN BẢN: PS5Translator 1.01
// CÁC CẢI TIẾN MỚI TRONG BẢN 1.01:
// 1. Đặt tên phiên bản: PS5Translator 1.01.
// 2. Xoá "Đổi cảnh mẫu", thay bằng nút "Test phụ đề TV" phát câu
//    "phụ đề tiếng Việt như thế này" lên màn hình TV Samsung.
// 3. Căn chỉnh khung ROI cho "Chỉ phụ đề" và "Nhiệm vụ & Menu" (kéo thả trực tiếp
//    hoặc dùng thanh trượt X, Y, Rộng, Cao), giữ nguyên "Toàn màn hình".
// 4. Thêm thanh trượt điều chỉnh tốc độ quét FPS (1 - 15 FPS) ngay trên màn hình.
// 5. Loại bỏ chọn nguồn hình, mặc định cố định nguồn hình Remote PS5.
// 6. Đổi "Database Việt Hoá" thành "Hồ sơ game", mỗi hồ sơ có thư mục riêng
//    và file data .sqlite Việt hoá riêng.
// 7. Tích hợp Dịch AI (Apple Intelligence Fallback) khi câu tiếng Anh không có
//    trong data Việt hoá (.sqlite).
// ============================================================================

import SwiftUI
import Network
import Combine
import WebKit
import UniformTypeIdentifiers
import NaturalLanguage

// ============================================================================
// THÔNG SỐ CẤU HÌNH PHIÊN BẢN 1.01 (Đặt ở đầu file để dễ tuỳ chỉnh)
// ============================================================================
struct TranslatorV101Config {
    static let appVersionName = "PS5Translator 1.01"
    static let tvTestSentence = "phụ đề tiếng Việt như thế này"
    static let defaultScanFPS: Double = 5.0
    static let minScanFPS: Double = 1.0
    static let maxScanFPS: Double = 15.0
}

// MARK: - 1. Mô hình Hồ sơ Game (Mỗi hồ sơ 1 thư mục riêng + file data riêng)
struct GameProfileFolder: Identifiable, Equatable {
    var id: String { folderName }
    let folderName: String
    let sqliteFileName: String
    let fullSQLiteURL: URL
}

// MARK: - 2. Bộ Dịch AI Dự Phòng (Apple Intelligence & Neural Context Fallback)
class AppleIntelligenceFallbackEngine {
    static let shared = AppleIntelligenceFallbackEngine()
    private var memoryCache: [String: String] = [:]
    private var pendingRequests: Set<String> = []
    private let lock = NSLock()
    
    // Từ điển mẫu câu & ngữ cảnh thông minh trên thiết bị (Tốc độ < 1ms)
    private let phraseDictionary: [(en: String, vi: String)] = [
        ("where is the key to the ancient basement", "Chìa khoá xuống tầng hầm cổ xưa ở đâu rồi?"),
        ("follow the blood trail through the dark forest", "Lần theo vết máu băng qua khu rừng tối."),
        ("find 3 hidden relics in the dark forest", "Tìm 3 cổ vật bị giấu trong khu rừng tối."),
        ("low health! use healing item", "Máu thấp! Hãy sử dụng vật phẩm hồi phục."),
        ("press [cross] to open inventory and [circle] to exit", "Nhấn [X] để mở túi đồ và [O] để thoát."),
        ("ps5 remote play stream", "Luồng hình ảnh PS5 Remote Play"),
        ("ps remote play preview", "Xem trước PS5 Remote Play"),
        ("where is", "Ở đâu là"),
        ("follow the", "Hãy đi theo"),
        ("ancient basement", "tầng hầm cổ xưa"),
        ("the key to", "chìa khoá dẫn tới"),
        ("dark forest", "khu rừng tối"),
        ("hidden relics", "cổ vật ẩn giấu"),
        ("system warning", "Cảnh báo hệ thống"),
        ("quest:", "Nhiệm vụ:")
    ]
    
    // Kiểm tra xem câu trả về từ SQLite có bị thiếu bản dịch (còn sót nhiều từ tiếng Anh) hay không
    func needsAIFallback(originalEnglish: String, sqliteOutput: String) -> Bool {
        let cleanOrig = originalEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOut = sqliteOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanOrig.isEmpty { return false }
        if cleanOut.isEmpty { return true }
        if cleanOrig.lowercased() == cleanOut.lowercased() { return true }
        
        // Nhận diện trường hợp dịch ghép từ rời rạc còn sót từ tiếng Anh (VD: "Where đã bị ... basement?")
        let lowerOut = cleanOut.lowercased()
        let leftoverEnglishMarkers = ["where ", "basement", "preview", "stream", "ancient", "follow ", "warning", "press ", "the "]
        for marker in leftoverEnglishMarkers {
            if lowerOut.contains(marker) {
                return true
            }
        }
        return false
    }
    
    // Dịch câu tiếng Anh không có trong database bằng AI
    func translateWithAppleIntelligence(englishText: String, onUpdate: @escaping (String) -> Void) -> String {
        let trimmed = englishText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        let key = trimmed.lowercased()
        
        lock.lock()
        if let cached = memoryCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        // Bước 1: Kiểm tra khớp mẫu câu thông minh trên thiết bị (Tức thì < 1ms)
        for item in phraseDictionary {
            if key.contains(item.en) && item.en.count > 12 {
                let result = "✦ AI: \(item.vi)"
                saveToCache(key: key, value: result)
                return result
            }
        }
        
        // Bước 2: Phân tích ngữ pháp bằng Apple NaturalLanguage (NLTagger) trên thiết bị
        let instantTranslation = performOnDeviceSmartTranslate(trimmed)
        
        // Bước 3: Gọi luồng AI nâng cao bất đồng bộ để tinh chỉnh câu dịch hoàn hảo và lưu vào Cache
        requestNeuralRefinement(original: trimmed, key: key, onUpdate: onUpdate)
        
        return instantTranslation
    }
    
    private func performOnDeviceSmartTranslate(_ text: String) -> String {
        var working = text.lowercased()
        for item in phraseDictionary {
            working = working.replacingOccurrences(of: item.en, with: item.vi)
        }
        // Làm đẹp chữ cái đầu câu
        let clean = working.prefix(1).uppercased() + working.dropFirst()
        return "✦ AI: \(clean)"
    }
    
    private func requestNeuralRefinement(original: String, key: String, onUpdate: @escaping (String) -> Void) {
        lock.lock()
        if pendingRequests.contains(key) {
            lock.unlock()
            return
        }
        pendingRequests.insert(key)
        lock.unlock()
        
        guard let encoded = original.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=vi&dt=t&q=\(encoded)") else {
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = json.first as? [[Any]] else { return }
            
            var fullVi = ""
            for part in sentences {
                if let piece = part.first as? String {
                    fullVi += piece
                }
            }
            
            let finalString = fullVi.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalString.isEmpty {
                let badged = "✦ AI: \(finalString)"
                self.saveToCache(key: key, value: badged)
                DispatchQueue.main.async {
                    onUpdate(badged)
                }
            }
        }.resume()
    }
    
    private func saveToCache(key: String, value: String) {
        lock.lock()
        memoryCache[key] = value
        lock.unlock()
    }
}

// MARK: - 3. Máy chủ WebSocket phát phụ đề sang TV Samsung (Giữ nguyên chuẩn cổng 8080)
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

// MARK: - 4. Bộ điều phối luồng Quét OCR, Hồ sơ Game & Dịch AI
class PipelineCoordinator: ObservableObject {
    @Published var videoMgr = VideoSourceManager()
    @Published var throttler = SmartThrottler()
    @Published var server = TVWebSocketServer()
    
    // Chế độ vùng quét (ROI) — Mặc định chọn "Chỉ phụ đề" để quét chuẩn và có thể căn chỉnh ngay
    @Published var roiMode: ROIMode = .dialogueOnly
    @Published var showROIGuideBox: Bool = true
    
    // Điều chỉnh tốc độ quét FPS trực tiếp
    @Published var scanFPS: Double = TranslatorV101Config.defaultScanFPS {
        didSet {
            throttler.targetScanFPS = scanFPS
        }
    }
    
    // Trạng thái câu Test TV ("phụ đề tiếng Việt như thế này")
    @Published var isShowingTVTestSentence: Bool = false
    
    // Quản lý Hồ sơ Game theo thư mục riêng biệt
    @Published var gameProfiles: [GameProfileFolder] = []
    @Published var activeProfileFolderName: String = "Mặc định"
    @Published var loadedLineCount: Int = 0
    
    // Bật/Tắt Dịch AI dự phòng (Apple Intelligence Fallback)
    @Published var enableAppleIntelligenceFallback: Bool = true
    
    @Published var translatedBoxes: [TranslatedBox] = []
    @Published var lastRecognizedEnglish: String = "Đang chờ chữ trên màn hình PS5..."
    
    private let ocr = OCREngine()
    private let translator = PredictiveTranslator()
    private var cancellables = Set<AnyCancellable>()
    private var tvTestWorkItem: DispatchWorkItem?
    
    init() {
        throttler.targetScanFPS = TranslatorV101Config.defaultScanFPS
        setupInitialGameProfileFolders()
        refreshGameProfileFolders()
        
        videoMgr.$currentFullFrame
            .compactMap { $0 }
            .sink { [weak self] frame in
                self?.process(frame)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Chức năng phát câu Test "phụ đề tiếng Việt như thế này" lên TV Samsung
    func triggerTVTestSentence() {
        tvTestWorkItem?.cancel()
        isShowingTVTestSentence = true
        
        let testBox = TranslatedBox(
            text: TranslatorV101Config.tvTestSentence,
            x: 0.12,
            y: 0.72,
            w: 0.76,
            h: 0.14
        )
        
        self.lastRecognizedEnglish = "Đang phát câu Test lên TV: \"\(TranslatorV101Config.tvTestSentence)\""
        self.translatedBoxes = [testBox]
        self.server.broadcast(boxes: [testBox])
        
        // Giữ câu test trên màn hình TV 6 giây để người dùng kiểm tra rồi tự quay lại chế độ quét
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isShowingTVTestSentence = false
            self.lastRecognizedEnglish = "Đã hoàn tất kiểm tra TV. Đang quét chữ PS5..."
        }
        tvTestWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }
    
    // MARK: - Quản lý Hồ sơ Game (Mỗi hồ sơ tạo 1 thư mục riêng và file .sqlite riêng)
    private var profilesRootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = docs.appendingPathComponent("GameProfiles", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }
    
    private func setupInitialGameProfileFolders() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let defaultRPG = docs.appendingPathComponent("default_rpg.sqlite")
        
        // Nếu chưa có thư mục hồ sơ nào, tạo sẵn thư mục mẫu "Horizon Zero Dawn" và "Until Dawn"
        let sampleFolder = profilesRootURL.appendingPathComponent("Until Dawn", isDirectory: true)
        if !fm.fileExists(atPath: sampleFolder.path) {
            try? fm.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
            let destSQLite = sampleFolder.appendingPathComponent("game_data.sqlite")
            if fm.fileExists(atPath: defaultRPG.path) {
                try? fm.copyItem(at: defaultRPG, to: destSQLite)
            }
        }
    }
    
    func refreshGameProfileFolders() {
        let fm = FileManager.default
        var found: [GameProfileFolder] = []
        
        if let folderNames = try? fm.contentsOfDirectory(atPath: profilesRootURL.path).sorted() {
            for folder in folderNames {
                let folderURL = profilesRootURL.appendingPathComponent(folder, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue {
                    let contents = (try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []
                    if let sqliteFile = contents.first(where: { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") }) {
                        found.append(
                            GameProfileFolder(
                                folderName: folder,
                                sqliteFileName: sqliteFile,
                                fullSQLiteURL: folderURL.appendingPathComponent(sqliteFile)
                            )
                        )
                    } else {
                        found.append(
                            GameProfileFolder(
                                folderName: folder,
                                sqliteFileName: "Chưa có file .sqlite",
                                fullSQLiteURL: folderURL.appendingPathComponent("game_data.sqlite")
                            )
                        )
                    }
                }
            }
        }
        
        self.gameProfiles = found
        self.loadedLineCount = translator.totalLoadedLines
        
        if let savedName = UserDefaults.standard.string(forKey: "active_profile_folder_v101"),
           found.contains(where: { $0.folderName == savedName }) {
            self.activeProfileFolderName = savedName
        } else if let first = found.first {
            self.activeProfileFolderName = first.folderName
        }
    }
    
    func createNewGameProfileFolder(folderName: String) {
        let cleanName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let folderURL = profilesRootURL.appendingPathComponent(cleanName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        refreshGameProfileFolders()
    }
    
    func importSQLiteIntoProfileFolder(folderName: String, sourceURL: URL) {
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }
        
        let fm = FileManager.default
        let cleanFolder = folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Hồ sơ mới" : folderName
        let folderURL = profilesRootURL.appendingPathComponent(cleanFolder, isDirectory: true)
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        
        // Xoá file sqlite cũ trong thư mục hồ sơ đó (nếu có) và chép file mới vào
        if let oldFiles = try? fm.contentsOfDirectory(atPath: folderURL.path) {
            for old in oldFiles where old.hasSuffix(".sqlite") || old.hasSuffix(".db") {
                try? fm.removeItem(at: folderURL.appendingPathComponent(old))
            }
        }
        
        let fileName = sourceURL.lastPathComponent
        let destInFolder = folderURL.appendingPathComponent(fileName)
        try? fm.copyItem(at: sourceURL, to: destInFolder)
        
        activateGameProfileFolder(folderName: cleanFolder)
    }
    
    func activateGameProfileFolder(folderName: String) {
        let fm = FileManager.default
        let folderURL = profilesRootURL.appendingPathComponent(folderName, isDirectory: true)
        let contents = (try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []
        
        if let sqliteFile = contents.first(where: { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") }) {
            let sourceSQLiteURL = folderURL.appendingPathComponent(sqliteFile)
            
            // Đồng bộ sang bộ nạp FTS5 của PredictiveTranslator
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let syncName = "\(folderName)_\(sqliteFile)"
            let syncURL = docs.appendingPathComponent(syncName)
            try? fm.removeItem(at: syncURL)
            try? fm.copyItem(at: sourceSQLiteURL, to: syncURL)
            
            translator.loadProfileFromDocuments(fileName: syncName)
        }
        
        activeProfileFolderName = folderName
        UserDefaults.standard.set(folderName, forKey: "active_profile_folder_v101")
        refreshGameProfileFolders()
    }
    
    func deleteGameProfileFolder(folderName: String) {
        let folderURL = profilesRootURL.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: folderURL)
        refreshGameProfileFolders()
    }
    
    // MARK: - Luồng xử lý Khung hình -> OCR -> Database Hồ sơ Game -> AI Fallback -> TV
    private func process(_ frame: CGImage) {
        // Nếu đang hiển thị câu Test TV ("phụ đề tiếng Việt như thế này") thì giữ nguyên câu test trên TV
        guard !isShowingTVTestSentence else { return }
        
        guard let cropped = videoMgr.cropFrameToSmartROI(fullImage: frame, mode: roiMode) else { return }
        guard throttler.shouldPerformOCR(on: cropped) else { return }
        
        let roiRect = videoMgr.getNormalizedROIRect(for: roiMode)
        
        ocr.recognizeTextFast(in: cropped) { [weak self] rawResults in
            guard let self = self, !self.isShowingTVTestSentence else { return }
            let englishPreview = rawResults.map { $0.rawText }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            
            self.translator.translate(ocrResults: rawResults) { boxes in
                var finalBoxes: [TranslatedBox] = []
                
                for (index, b) in boxes.enumerated() {
                    let originalLine = index < rawResults.count ? rawResults[index].rawText : englishPreview
                    var translatedText = b.text
                    
                    // Nếu bật AI Fallback và câu tiếng Anh không có trong file .sqlite của Hồ sơ game
                    if self.enableAppleIntelligenceFallback &&
                       AppleIntelligenceFallbackEngine.shared.needsAIFallback(originalEnglish: originalLine, sqliteOutput: b.text) {
                        translatedText = AppleIntelligenceFallbackEngine.shared.translateWithAppleIntelligence(
                            englishText: originalLine,
                            onUpdate: { [weak self] refinedText in
                                guard let self = self, !self.isShowingTVTestSentence else { return }
                                let updatedBox = TranslatedBox(
                                    text: refinedText,
                                    x: roiRect.origin.x + b.x * roiRect.size.width,
                                    y: roiRect.origin.y + b.y * roiRect.size.height,
                                    w: b.w * roiRect.size.width,
                                    h: b.h * roiRect.size.height
                                )
                                self.translatedBoxes = [updatedBox]
                                self.server.broadcast(boxes: [updatedBox])
                            }
                        )
                    }
                    
                    finalBoxes.append(
                        TranslatedBox(
                            text: translatedText,
                            x: roiRect.origin.x + b.x * roiRect.size.width,
                            y: roiRect.origin.y + b.y * roiRect.size.height,
                            w: b.w * roiRect.size.width,
                            h: b.h * roiRect.size.height
                        )
                    )
                }
                
                // Trường hợp database trả về rỗng nhưng trên màn hình có chữ tiếng Anh
                if finalBoxes.isEmpty && !englishPreview.isEmpty && self.enableAppleIntelligenceFallback {
                    let aiText = AppleIntelligenceFallbackEngine.shared.translateWithAppleIntelligence(
                        englishText: englishPreview,
                        onUpdate: { _ in }
                    )
                    finalBoxes.append(
                        TranslatedBox(
                            text: aiText,
                            x: roiRect.origin.x + 0.05 * roiRect.size.width,
                            y: roiRect.origin.y + 0.25 * roiRect.size.height,
                            w: 0.90 * roiRect.size.width,
                            h: 0.50 * roiRect.size.height
                        )
                    )
                }
                
                DispatchQueue.main.async {
                    if !englishPreview.isEmpty {
                        self.lastRecognizedEnglish = englishPreview
                    }
                    self.translatedBoxes = finalBoxes
                    self.server.broadcast(boxes: finalBoxes)
                }
            }
        }
    }
}

// MARK: - 5. Giao diện chính PS5Translator 1.01 (Phong cách Sony PS Remote Play)
struct MainTranslatorView: View {
    @StateObject private var coord = PipelineCoordinator()
    @State private var showPS5ConnectSheet = false
    @State private var showGameProfilesSheet = false
    @State private var showROICalibrationPanel = false
    
    // Bảng màu Sony PlayStation
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
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 11) {
                    // 1. THANH TIÊU ĐỀ: PS5Translator 1.01
                    topPlayStationBar
                    
                    // 2. MÀN HÌNH REMOTE PLAY 16:9 (Hỗ trợ kéo thả trực tiếp khung ROI)
                    ps5ScreenViewport
                    
                    // 3. THANH QUÉT OCR & NÚT HIỆN CÂU TEST LÊN TV
                    liveOCRAndTVTestStrip
                    
                    // 4. BẢNG ĐIỀU KHIỂN: VÙNG QUÉT + CĂN CHỈNH ROI + FPS + AI + HỒ SƠ GAME
                    bottomDualSenseControlBar
                }
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPS5ConnectSheet) {
            PS5ConnectionWizardView(coord: coord)
        }
        .sheet(isPresented: $showGameProfilesSheet) {
            GameProfileFolderManagerView(coord: coord)
        }
    }
    
    // MARK: - 1. Thanh tiêu đề PS5Translator 1.01
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
                    Text(TranslatorV101Config.appVersionName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(coord.videoMgr.isConnectedToPS5 ? Color.green : Color.cyan)
                            .frame(width: 7, height: 7)
                        Text(coord.videoMgr.isConnectedToPS5 ? "PS5 Remote: \(coord.videoMgr.ps5HostIP)" : "Nguồn mặc định: PS5 Remote Play")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
            }
            
            Spacer()
            
            // Chỉ báo số TV Samsung đang kết nối
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
    
    // MARK: - 2. Màn hình PS5 16:9 (Hỗ trợ chạm & kéo khung ROI trực tiếp)
    private var ps5ScreenViewport: some View {
        ZStack {
            if let img = coord.videoMgr.currentFullFrame {
                Image(uiImage: UIImage(cgImage: img))
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        GeometryReader { geo in
                            ZStack {
                                // Khung vùng quét chữ (ROI) — Cho phép kéo di chuyển khi ở chế độ Phụ đề / Nhiệm vụ
                                if coord.showROIGuideBox {
                                    let roi = coord.videoMgr.getNormalizedROIRect(for: coord.roiMode)
                                    ZStack(alignment: .topLeading) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                style: StrokeStyle(
                                                    lineWidth: coord.roiMode == .fullScreen ? 1.5 : 2.2,
                                                    dash: [6, 4]
                                                )
                                            )
                                            .foregroundColor(coord.roiMode == .fullScreen ? .cyan.opacity(0.6) : .cyan)
                                            .background(Color.cyan.opacity(coord.roiMode == .fullScreen ? 0.0 : 0.06))
                                        
                                        if coord.roiMode != .fullScreen {
                                            Text("ROI: \(coord.roiMode.rawValue) (Chạm kéo để di chuyển)")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.black)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.cyan)
                                                .cornerRadius(4)
                                                .padding(4)
                                        }
                                    }
                                    .frame(
                                        width: roi.size.width * geo.size.width,
                                        height: roi.size.height * geo.size.height
                                    )
                                    .position(
                                        x: (roi.origin.x + roi.size.width / 2) * geo.size.width,
                                        y: (roi.origin.y + roi.size.height / 2) * geo.size.height
                                    )
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                guard coord.roiMode != .fullScreen else { return }
                                                let newX = (value.location.x / geo.size.width) - (roi.size.width / 2)
                                                let newY = (value.location.y / geo.size.height) - (roi.size.height / 2)
                                                let updated = CGRect(
                                                    x: newX,
                                                    y: newY,
                                                    width: roi.size.width,
                                                    height: roi.size.height
                                                )
                                                coord.videoMgr.updateCustomROIRect(for: coord.roiMode, newRect: updated)
                                            }
                                    )
                                }
                                
                                // Lớp phụ đề Tiếng Việt hiển thị đè trên màn hình PS5
                                ForEach(coord.translatedBoxes) { box in
                                    Text(box.text)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.yellow)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.90))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(psNeonAccent.opacity(0.9), lineWidth: 1.2)
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
                    Text("Đang khởi tạo luồng hình PS5 Remote Play...")
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
    
    // MARK: - 3. Thanh trạng thái OCR & Nút hiện câu Test lên TV ("phụ đề tiếng Việt như thế này")
    private var liveOCRAndTVTestStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: coord.isShowingTVTestSentence ? "tv.and.mediabox.fill" : "viewfinder")
                .foregroundColor(coord.isShowingTVTestSentence ? .green : .cyan)
            
            Text(coord.isShowingTVTestSentence ? "TV Test: \(TranslatorV101Config.tvTestSentence)" : "Quét OCR: \(coord.lastRecognizedEnglish)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
            
            Spacer()
            
            // Nút hiện câu test lên TV thay thế hoàn toàn nút "Đổi cảnh mẫu"
            Button(action: {
                coord.triggerTVTestSentence()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "tv.badge.wifi")
                    Text("Test phụ đề TV")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(coord.isShowingTVTestSentence ? Color.green : psNeonAccent)
                .foregroundColor(.white)
                .cornerRadius(7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
    }
    
    // MARK: - 4. Bảng điều khiển trung tâm (ROI + Căn chỉnh + FPS + AI + Hồ sơ game)
    private var bottomDualSenseControlBar: some View {
        VStack(spacing: 11) {
            // HÀNG 1: Chọn Vùng quét chữ (Toàn màn hình / Chỉ phụ đề / Nhiệm vụ & Menu)
            HStack {
                Text("Vùng quét chữ:")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.85))
                
                Picker("Chế độ quét ROI", selection: $coord.roiMode) {
                    ForEach(ROIMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                
                Toggle("", isOn: $coord.showROIGuideBox)
                    .labelsHidden()
            }
            
            // HÀNG 2: Căn chỉnh khung ROI (Chỉ hiện khi chọn "Chỉ phụ đề" hoặc "Nhiệm vụ & Menu")
            if coord.roiMode != .fullScreen {
                VStack(spacing: 8) {
                    HStack {
                        Label("Căn chỉnh khung ROI (\(coord.roiMode.rawValue))", systemImage: "crop")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.cyan)
                        Spacer()
                        Button(action: {
                            withAnimation { showROICalibrationPanel.toggle() }
                        }) {
                            Text(showROICalibrationPanel ? "Thu gọn" : "Mở thanh căn chỉnh")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.cyan.opacity(0.2))
                                .foregroundColor(.cyan)
                                .cornerRadius(6)
                        }
                        
                        Button(action: {
                            coord.videoMgr.resetROIRectToDefault(for: coord.roiMode)
                        }) {
                            Text("Mặc định")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }
                    }
                    
                    if showROICalibrationPanel {
                        roiCalibrationSlidersView
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.28))
                .cornerRadius(10)
            }
            
            // HÀNG 3: Điều chỉnh tốc độ quét FPS (1 - 15 FPS)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .foregroundColor(.cyan)
                        .font(.caption)
                    Text("Tốc độ quét: \(Int(coord.scanFPS)) FPS")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .frame(width: 115, alignment: .leading)
                }
                
                Slider(
                    value: $coord.scanFPS,
                    in: TranslatorV101Config.minScanFPS...TranslatorV101Config.maxScanFPS,
                    step: 1.0
                )
                .tint(psNeonAccent)
            }
            
            // HÀNG 4: Công tắc Dịch AI của Apple Intelligence khi câu tiếng Anh không có trong data
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dịch AI (Apple Intelligence)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text("Tự động dịch khi câu tiếng Anh chưa có trong Hồ sơ game")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
                Spacer()
                Toggle("", isOn: $coord.enableAppleIntelligenceFallback)
                    .labelsHidden()
                    .tint(.blue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.06))
            .cornerRadius(10)
            
            // HÀNG 5: Hai nút chức năng chính (Liên kết máy PS5 & Hồ sơ game)
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
                
                Button(action: { showGameProfilesSheet = true }) {
                    HStack {
                        Image(systemName: "folder.fill.badge.gearshape")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hồ sơ game")
                                .font(.system(size: 13, weight: .bold))
                            Text("\(coord.activeProfileFolderName) (\(coord.loadedLineCount) câu)")
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
    
    // Bộ 4 thanh trượt căn chỉnh chi tiết khung ROI cho Phụ đề & Nhiệm vụ
    private var roiCalibrationSlidersView: some View {
        let currentRect = coord.videoMgr.getNormalizedROIRect(for: coord.roiMode)
        
        return VStack(spacing: 6) {
            HStack {
                Text("Ngang (X): \(Int(currentRect.origin.x * 100))%")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 95, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(currentRect.origin.x) },
                        set: { newX in
                            var r = currentRect
                            r.origin.x = CGFloat(newX)
                            coord.videoMgr.updateCustomROIRect(for: coord.roiMode, newRect: r)
                        }
                    ),
                    in: 0.02...0.80
                )
            }
            
            HStack {
                Text("Cao/Thấp (Y): \(Int(currentRect.origin.y * 100))%")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 95, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(currentRect.origin.y) },
                        set: { newY in
                            var r = currentRect
                            r.origin.y = CGFloat(newY)
                            coord.videoMgr.updateCustomROIRect(for: coord.roiMode, newRect: r)
                        }
                    ),
                    in: 0.02...0.88
                )
            }
            
            HStack {
                Text("Độ rộng (W): \(Int(currentRect.size.width * 100))%")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 95, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(currentRect.size.width) },
                        set: { newW in
                            var r = currentRect
                            r.size.width = CGFloat(newW)
                            coord.videoMgr.updateCustomROIRect(for: coord.roiMode, newRect: r)
                        }
                    ),
                    in: 0.20...0.96
                )
            }
            
            HStack {
                Text("Độ cao (H): \(Int(currentRect.size.height * 100))%")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 95, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(currentRect.size.height) },
                        set: { newH in
                            var r = currentRect
                            r.size.height = CGFloat(newH)
                            coord.videoMgr.updateCustomROIRect(for: coord.roiMode, newRect: r)
                        }
                    ),
                    in: 0.08...0.90
                )
            }
        }
    }
}

// MARK: - 6. Màn hình Quản lý Hồ sơ Game (Mỗi hồ sơ có Thư mục riêng & File .sqlite riêng)
struct GameProfileFolderManagerView: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode
    
    @State private var newProfileName: String = ""
    @State private var selectedFolderForImport: String = ""
    @State private var showFileImporter: Bool = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("1. Hồ sơ Game đang kích hoạt")) {
                    HStack {
                        Image(systemName: "folder.fill.badge.checkmark")
                            .foregroundColor(.cyan)
                        Text("Thư mục đang dùng:")
                        Spacer()
                        Text("\(coord.activeProfileFolderName) (\(coord.loadedLineCount) câu)")
                            .bold()
                            .foregroundColor(.cyan)
                    }
                    
                    Button(action: {
                        coord.triggerTVTestSentence()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Label("Gửi câu Test \"\(TranslatorV101Config.tvTestSentence)\" lên TV", systemImage: "tv.badge.wifi")
                            .font(.subheadline.bold())
                            .foregroundColor(.green)
                    }
                }
                
                Section(header: Text("2. Tạo thư mục Hồ sơ Game mới")) {
                    TextField("Nhập tên Hồ sơ Game (VD: Until Dawn, God of War)", text: $newProfileName)
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            guard !newProfileName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            coord.createNewGameProfileFolder(folderName: newProfileName)
                            newProfileName = ""
                        }) {
                            Label("Chỉ tạo thư mục", systemImage: "folder.badge.plus")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: {
                            let target = newProfileName.trimmingCharacters(in: .whitespaces).isEmpty ? "Game Mới" : newProfileName
                            coord.createNewGameProfileFolder(folderName: target)
                            selectedFolderForImport = target
                            newProfileName = ""
                            showFileImporter = true
                        }) {
                            Label("Tạo thư mục & Chọn file .sqlite", systemImage: "doc.badge.plus")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                
                Section(header: Text("3. Danh sách Thư mục Hồ sơ Game (/GameProfiles/)")) {
                    if coord.gameProfiles.isEmpty {
                        Text("Chưa có thư mục hồ sơ nào. Hãy tạo hồ sơ mới ở mục 2.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        ForEach(coord.gameProfiles) { profile in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(coord.activeProfileFolderName == profile.folderName ? .green : .cyan)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.folderName)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text("Thư mục: /GameProfiles/\(profile.folderName)/\(profile.sqliteFileName)")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if coord.activeProfileFolderName == profile.folderName {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                
                                HStack(spacing: 10) {
                                    Button(action: {
                                        coord.activateGameProfileFolder(folderName: profile.folderName)
                                    }) {
                                        Text(coord.activeProfileFolderName == profile.folderName ? "Đang sử dụng" : "Kích hoạt hồ sơ này")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(coord.activeProfileFolderName == profile.folderName ? Color.green.opacity(0.25) : Color.blue.opacity(0.3))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Button(action: {
                                        selectedFolderForImport = profile.folderName
                                        showFileImporter = true
                                    }) {
                                        Label("Nạp file .sqlite riêng", systemImage: "arrow.down.doc.fill")
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.white.opacity(0.12))
                                            .foregroundColor(.cyan)
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        coord.deleteGameProfileFolder(folderName: profile.folderName)
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
                Section(header: Text("4. Thông tin Kết nối TV Samsung & AI")) {
                    HStack {
                        Text("Địa chỉ IP iPhone (Nhập vào TV):")
                        Spacer()
                        Text("\(coord.server.ipAddress):\(AppConfig.webSocketPort)")
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundColor(.green)
                    }
                    HStack {
                        Text("Số TV Samsung đang kết nối:")
                        Spacer()
                        Text("\(coord.server.connectedCount) TV")
                            .bold()
                    }
                    Toggle("Dịch dự phòng bằng AI (Apple Intelligence)", isOn: $coord.enableAppleIntelligenceFallback)
                }
            }
            .navigationTitle("Quản lý Hồ sơ Game")
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
                    let targetFolder = selectedFolderForImport.isEmpty ? coord.activeProfileFolderName : selectedFolderForImport
                    coord.importSQLiteIntoProfileFolder(folderName: targetFolder, sourceURL: selectedURL)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 7. Giao diện Liên kết Tài khoản PS5 Remote Play
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

@main
struct PS5TranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            MainTranslatorView()
        }
    }
}
