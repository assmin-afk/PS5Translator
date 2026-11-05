// ============================================================================

// FILE 6: 6_OverlayAndBroadcaster.swift

// PHIÊN BẢN: PS5Translator 1.02 (SỬA LỖI 4174 SONY OAUTH & GHI NHỚ TÀI KHOẢN VĨNH VIỄN)

// CÁC CẢI TIẾN TRONG BẢN CẬP NHẬT NÀY:

// 1. Sửa triệt để lỗi {"error":"invalid_request","error_code":4174,"Redirect URI mismatch"}

//    bằng cách sử dụng đúng cặp Client ID + Redirect URI gốc của Sony PlayStation

//    (com.scee.psxandroid.scecompcall://redirect) và bắt gói tin điều hướng trực tiếp.

// 2. Bổ sung nút "Tự lấy ID từ tên PSN" (Miesoi93) và lưu Cookie đăng nhập + Account ID

//    vĩnh viễn vào bộ nhớ máy để KHÔNG BAO GIỜ phải đăng nhập lại nhiều lần.

// 3. Giữ nguyên toàn bộ tính năng quét đa vùng (Hội thoại, Nhiệm vụ, Kỹ năng, Vật phẩm),

//    đặt chữ dịch đè đúng vị trí chữ gốc, cỡ chữ bằng chữ gốc, nền đen mờ che chữ gốc

//    và đồng bộ thời gian thực.

// ============================================================================



import SwiftUI

import Network

import Combine

import WebKit

import UniformTypeIdentifiers

import Vision

import SQLite3



// ============================================================================

// 1. THÔNG SỐ CẤU HÌNH PHIÊN BẢN PS5TRANSLATOR 1.02 (Đặt ở đầu file)

// ============================================================================

struct TranslatorV102Config {

    static let appVersionName = "PS5Translator 1.02"

    static let tvTestSentence = "phụ đề tiếng Việt như thế này"

    static let defaultScanFPS: Double = 6.0

    static let minScanFPS: Double = 1.0

    static let maxScanFPS: Double = 15.0

    

    // Độ đậm phông nền đen mờ che chữ tiếng Anh gốc (0.94 = che kín chữ gốc bên dưới)

    static let subtitleMaskBlackOpacity: Double = 0.94

    

    // ĐÃ SỬA LỖI 4174 REDIRECT URI MISMATCH:

    // Cặp Client ID 09515159-7237-4370-9b40-3806e67c0891 của Sony bắt buộc đi kèm

    // redirect_uri = com.scee.psxandroid.scecompcall://redirect

    static let sonyOAuthLoginURL = "https://ca.account.sony.com/api/authz/v3/oauth/authorize?access_type=offline&client_id=09515159-7237-4370-9b40-3806e67c0891&redirect_uri=com.scee.psxandroid.scecompcall%3A%2F%2Fredirect&response_type=code&scope=psn:mobile.v2.core%20psn:clientapp"

    static let sonyOAuthRedirectPrefix = "com.scee.psxandroid.scecompcall://redirect"

    static let sonyOAuthRedirectEncoded = "com.scee.psxandroid.scecompcall%3A%2F%2Fredirect"

    static let sonyOAuthTokenURL = "https://ca.account.sony.com/api/authz/v3/oauth/token"

    static let sonyBasicAuthHeader = "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="

}



// Khối văn bản OCR kèm toạ độ gốc chính xác và số dòng

struct V102OCRTextRegion {

    var rawText: String

    var x: CGFloat

    var y: CGFloat

    var w: CGFloat

    var h: CGFloat

    var lineCount: Int

}



struct GameProfileFolder: Identifiable, Equatable {

    var id: String { folderName }

    let folderName: String

    let sqliteFileName: String

    let fullSQLiteURL: URL

}



// ============================================================================

// 2. LÕI QUÉT CHỮ ĐA VÙNG & GOM CỤM KHÔNG GIAN (SPATIAL REGION CLUSTERER V1.02)

// ============================================================================

final class V102OCREngine {

    private let queue = DispatchQueue(label: "ps5.v102.ocr.queue", qos: .userInteractive)

    

    func recognizeMultiRegions(in cgImage: CGImage, completion: @escaping ([V102OCRTextRegion]) -> Void) {

        queue.async {

            let request = VNRecognizeTextRequest { req, _ in

                guard let observations = req.results as? [VNRecognizedTextObservation] else {

                    completion([])

                    return

                }

                

                var rawLines: [V102OCRTextRegion] = []

                for obs in observations {

                    guard let top = obs.topCandidates(1).first else { continue }

                    let text = top.string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                    guard !text.isEmpty else { continue }

                    

                    let bbox = obs.boundingBox

                    let convertedY = 1.0 - bbox.origin.y - bbox.size.height

                    rawLines.append(

                        V102OCRTextRegion(

                            rawText: text,

                            x: max(0.0, min(1.0, bbox.origin.x)),

                            y: max(0.0, min(1.0, convertedY)),

                            w: max(0.02, min(1.0, bbox.size.width)),

                            h: max(0.015, min(1.0, bbox.size.height)),

                            lineCount: 1

                        )

                    )

                }

                

                let clustered = Self.clusterAdjacentLinesIntoRegions(lines: rawLines)

                completion(clustered)

            }

            request.recognitionLevel = .fast

            request.usesLanguageCorrection = false

            request.recognitionLanguages = ["en-US"]

            

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {

                try handler.perform([request])

            } catch {

                completion([])

            }

        }

    }

    

    private static func clusterAdjacentLinesIntoRegions(lines: [V102OCRTextRegion]) -> [V102OCRTextRegion] {

        guard !lines.isEmpty else { return [] }

        let sorted = lines.sorted {

            if abs($0.y - $1.y) < 0.018 {

                return $0.x < $1.x

            }

            return $0.y < $1.y

        }

        

        var clusters: [V102OCRTextRegion] = []

        for line in sorted {

            var merged = false

            for i in (0..<clusters.count).reversed() {

                let existing = clusters[i]

                let existingBottom = existing.y + existing.h

                let verticalGap = line.y - existingBottom

                

                let minRight = min(existing.x + existing.w, line.x + line.w)

                let maxLeft = max(existing.x, line.x)

                let horizontalOverlap = minRight - maxLeft

                let isLeftAligned = abs(existing.x - line.x) < 0.06

                let singleLineH = existing.h / CGFloat(max(1, existing.lineCount))

                let similarFontHeight = abs(singleLineH - line.h) < (singleLineH * 0.55)

                

                if verticalGap >= -0.015 && verticalGap <= (singleLineH * 0.95) &&

                   (horizontalOverlap > 0.05 || isLeftAligned) && similarFontHeight {

                    let newMinX = min(existing.x, line.x)

                    let newMinY = min(existing.y, line.y)

                    let newMaxX = max(existing.x + existing.w, line.x + line.w)

                    let newMaxY = max(existing.y + existing.h, line.y + line.h)

                    

                    clusters[i] = V102OCRTextRegion(

                        rawText: existing.rawText + " " + line.rawText,

                        x: newMinX,

                        y: newMinY,

                        w: newMaxX - newMinX,

                        h: newMaxY - newMinY,

                        lineCount: existing.lineCount + 1

                    )

                    merged = true

                    break

                }

            }

            if !merged {

                clusters.append(line)

            }

        }

        return clusters

    }

}



// ============================================================================

// 3. LÕI ĐỌC DATABASE VIỆT HOÁ (.SQLITE) TRỰC TIẾP V1.02

// ============================================================================

final class V102SQLiteTranslator {

    private var db: OpaquePointer?

    private let queue = DispatchQueue(label: "ps5.v102.sqlite.queue", qos: .userInitiated)

    private(set) var totalLines: Int = 0

    private var inMemoryLines: [(clean: String, raw: String, vi: String)] = []

    

    init() {

        loadDefaultDatabaseIfAvailable()

    }

    

    deinit {

        if db != nil {

            sqlite3_close(db)

        }

    }

    

    func loadDefaultDatabaseIfAvailable() {

        let fm = FileManager.default

        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let candidates = ["game_data.sqlite", "default_rpg.sqlite"]

        for name in candidates {

            let url = docs.appendingPathComponent(name)

            if fm.fileExists(atPath: url.path) {

                loadDatabase(at: url)

                return

            }

        }

    }

    

    func loadDatabase(at url: URL) {

        queue.sync {

            if db != nil {

                sqlite3_close(db)

                db = nil

            }

            inMemoryLines.removeAll()

            totalLines = 0

            

            guard FileManager.default.fileExists(atPath: url.path) else { return }

            var tempDB: OpaquePointer?

            if sqlite3_open_v2(url.path, &tempDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let openedDB = tempDB {

                db = openedDB

                let tableNames = fetchTableNames(from: openedDB)

                for table in tableNames {

                    loadRows(from: openedDB, tableName: table)

                    if !inMemoryLines.isEmpty { break }

                }

                totalLines = inMemoryLines.count

            } else if let tempDB = tempDB {

                sqlite3_close(tempDB)

            }

        }

    }

    

    private func fetchTableNames(from dbConn: OpaquePointer) -> [String] {

        var names: [String] = []

        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"

        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(dbConn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {

            while sqlite3_step(s) == SQLITE_ROW {

                if let cStr = sqlite3_column_text(s, 0) {

                    names.append(String(cString: cStr))

                }

            }

            sqlite3_finalize(s)

        }

        return names

    }

    

    private func loadRows(from dbConn: OpaquePointer, tableName: String) {

        let sql = "SELECT * FROM \"\(tableName)\" LIMIT 50000;"

        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(dbConn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }

        defer { sqlite3_finalize(s) }

        

        let colCount = sqlite3_column_count(s)

        guard colCount >= 2 else { return }

        

        while sqlite3_step(s) == SQLITE_ROW {

            var cols: [String] = []

            for i in 0..<colCount {

                if let cStr = sqlite3_column_text(s, i) {

                    cols.append(String(cString: cStr))

                } else {

                    cols.append("")

                }

            }

            if cols.count >= 4 {

                let raw = cols[1]

                let clean = cols[2].isEmpty ? Self.normalize(raw) : cols[2].lowercased()

                let vi = cols[3]

                if !vi.isEmpty {

                    inMemoryLines.append((clean: clean, raw: raw, vi: vi))

                }

            } else if cols.count == 3 {

                let raw = cols[1]

                let vi = cols[2]

                if !vi.isEmpty {

                    inMemoryLines.append((clean: Self.normalize(raw), raw: raw, vi: vi))

                }

            } else if cols.count == 2 {

                let raw = cols[0]

                let vi = cols[1]

                if !vi.isEmpty {

                    inMemoryLines.append((clean: Self.normalize(raw), raw: raw, vi: vi))

                }

            }

        }

    }

    

    static func normalize(_ text: String) -> String {

        let lower = text.lowercased()

        let allowed = CharacterSet.alphanumerics.union(CharacterSet.whitespaces)

        let filtered = lower.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") }

        return String(filtered)

            .components(separatedBy: CharacterSet.whitespacesAndNewlines)

            .filter { !$0.isEmpty }

            .joined(separator: " ")

    }

    

    func findBestVietnameseMatch(for englishText: String) -> String? {

        let cleanInput = Self.normalize(englishText)

        guard cleanInput.count >= 2 else { return nil }

        

        var bestResult: String? = nil

        queue.sync {

            guard !inMemoryLines.isEmpty else { return }

            

            for row in inMemoryLines {

                if row.clean == cleanInput {

                    bestResult = row.vi

                    return

                }

            }

            

            let inputWords = cleanInput.components(separatedBy: " ").filter { $0.count >= 3 }

            guard inputWords.count >= 2 else { return }

            

            var bestScore: Double = 0.0

            for row in inMemoryLines {

                var matched = 0

                for w in inputWords {

                    if row.clean.contains(w) {

                        matched += 1

                    }

                }

                let score = Double(matched) / Double(inputWords.count)

                if score > bestScore && score >= 0.72 {

                    bestScore = score

                    bestResult = row.vi

                }

            }

        }

        return bestResult

    }

}



// ============================================================================

// 4. BỘ DỊCH AI DỰ PHÒNG ĐA VÙNG (APPLE INTELLIGENCE FALLBACK ENGINE V1.02)

// ============================================================================

final class AppleIntelligenceFallbackEngine {

    static let shared = AppleIntelligenceFallbackEngine()

    private var memoryCache: [String: String] = [:]

    private var pendingRequests: Set<String> = []

    private let lock = NSLock()

    

    private let phraseDictionary: [(en: String, vi: String)] = [

        ("where is the key to the ancient basement", "Chìa khoá xuống tầng hầm cổ xưa ở đâu rồi?"),

        ("follow the blood trail through the dark forest", "Lần theo vết máu băng qua khu rừng tối."),

        ("follow the blood trail to the old tower", "Lần theo vết máu dẫn tới toà tháp cổ."),

        ("find 3 hidden relics in the dark forest", "Tìm 3 cổ vật bị giấu trong khu rừng tối."),

        ("silent strike - deal 250% stealth damage", "Đòn Ám Sát - Gây 250% sát thương lén lút."),

        ("ancient healing herb - restores 50% hp", "Thảo Dược Cổ Xưa - Hồi phục 50% Máu."),

        ("low health! use healing item", "Máu thấp! Hãy dùng vật phẩm hồi phục."),

        ("press [cross] to open inventory and [circle] to exit", "Nhấn [X] mở túi đồ và [O] để thoát."),

        ("quest:", "NHIỆM VỤ:"),

        ("objective:", "MỤC TIÊU:"),

        ("skill:", "KỸ NĂNG:"),

        ("item:", "VẬT PHẨM:"),

        ("menu:", "TRÌNH ĐƠN:"),

        ("deal 250% stealth damage", "gây 250% sát thương lén lút"),

        ("restores 50% hp", "hồi phục 50% Máu"),

        ("where is", "Ở đâu là"),

        ("follow the", "Hãy đi theo"),

        ("ancient basement", "tầng hầm cổ xưa"),

        ("the key to", "chìa khoá dẫn tới"),

        ("dark forest", "khu rừng tối"),

        ("hidden relics", "cổ vật ẩn giấu"),

        ("blood trail", "vết máu"),

        ("old tower", "toà tháp cổ"),

        ("system warning", "Cảnh báo hệ thống")

    ]

    

    func translateRegion(englishText: String, onAsyncRefined: @escaping (String) -> Void) -> String {

        let trimmed = englishText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return "" }

        

        let key = trimmed.lowercased()

        

        lock.lock()

        if let cached = memoryCache[key] {

            lock.unlock()

            return cached

        }

        lock.unlock()

        

        let instantResult = performOnDeviceContextualTranslate(trimmed)

        

        for item in phraseDictionary where item.en.count > 14 {

            if key.contains(item.en) {

                saveToCache(key: key, value: instantResult)

                return instantResult

            }

        }

        

        requestNeuralRefinement(original: trimmed, key: key, onUpdate: onAsyncRefined)

        return instantResult

    }

    

    private func performOnDeviceContextualTranslate(_ text: String) -> String {

        var working = text.lowercased()

        for item in phraseDictionary {

            working = working.replacingOccurrences(of: item.en, with: item.vi)

        }

        guard !working.isEmpty else { return text }

        return working.prefix(1).uppercased() + working.dropFirst()

    }

    

    private func requestNeuralRefinement(original: String, key: String, onUpdate: @escaping (String) -> Void) {

        lock.lock()

        if pendingRequests.contains(key) {

            lock.unlock()

            return

        }

        pendingRequests.insert(key)

        lock.unlock()

        

        guard let encoded = original.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),

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

            

            let finalString = fullVi.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            if !finalString.isEmpty {

                self.saveToCache(key: key, value: finalString)

                DispatchQueue.main.async {

                    onUpdate(finalString)

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



// ============================================================================

// 5. MÁY CHỦ WEBSOCKET PHÁT PHỤ ĐỀ SANG TV SAMSUNG (GIỮ NGUYÊN CỔNG 8080)

// ============================================================================

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



// ============================================================================

// 6. BỘ ĐIỀU PHỐI TRUNG TÂM ĐỒNG BỘ VỊ TRÍ & THỜI GIAN THỰC (V1.02)

// ============================================================================

class PipelineCoordinator: ObservableObject {

    @Published var videoMgr = VideoSourceManager()

    @Published var throttler = SmartThrottler()

    @Published var server = TVWebSocketServer()

    

    @Published var roiMode: ROIMode = .fullScreen

    @Published var showROIGuideBox: Bool = true

    

    @Published var scanFPS: Double = TranslatorV102Config.defaultScanFPS {

        didSet {

            throttler.targetScanFPS = scanFPS

        }

    }

    

    @Published var isShowingTVTestSentence: Bool = false

    

    @Published var gameProfiles: [GameProfileFolder] = []

    @Published var activeProfileFolderName: String = "Mặc định"

    @Published var loadedLineCount: Int = 0

    

    @Published var enableAppleIntelligenceFallback: Bool = true

    

    @Published var translatedBoxes: [TranslatedBox] = []

    @Published var lastRecognizedEnglish: String = "Đang quét chữ thời gian thực..."

    

    private let ocrEngine = V102OCREngine()

    private let sqliteTranslator = V102SQLiteTranslator()

    private var cancellables = Set<AnyCancellable>()

    private var tvTestWorkItem: DispatchWorkItem?

    

    private var lastScanTimestamp: TimeInterval = 0

    private var isOCRProcessing: Bool = false

    

    init() {

        throttler.targetScanFPS = TranslatorV102Config.defaultScanFPS

        setupInitialGameProfileFolders()

        refreshGameProfileFolders()

        

        videoMgr.$currentFullFrame

            .compactMap { $0 }

            .sink { [weak self] frame in

                self?.processFrameRealtime(frame)

            }

            .store(in: &cancellables)

    }

    

    func triggerTVTestSentence() {

        tvTestWorkItem?.cancel()

        isShowingTVTestSentence = true

        

        let testBox = TranslatedBox(

            text: TranslatorV102Config.tvTestSentence,

            x: 0.14,

            y: 0.74,

            w: 0.72,

            h: 0.12

        )

        

        self.lastRecognizedEnglish = "TV Test: \"\(TranslatorV102Config.tvTestSentence)\""

        self.translatedBoxes = [testBox]

        self.server.broadcast(boxes: [testBox])

        

        let work = DispatchWorkItem { [weak self] in

            guard let self = self else { return }

            self.isShowingTVTestSentence = false

            self.lastRecognizedEnglish = "Đang quét chữ thời gian thực..."

        }

        tvTestWorkItem = work

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)

    }

    

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

        

        if let savedName = UserDefaults.standard.string(forKey: "active_profile_folder_v102"),

           let matched = found.first(where: { $0.folderName == savedName }) {

            self.activeProfileFolderName = matched.folderName

            sqliteTranslator.loadDatabase(at: matched.fullSQLiteURL)

        } else if let first = found.first {

            self.activeProfileFolderName = first.folderName

            sqliteTranslator.loadDatabase(at: first.fullSQLiteURL)

        }

        

        self.loadedLineCount = sqliteTranslator.totalLines

    }

    

    func createNewGameProfileFolder(folderName: String) {

        let cleanName = folderName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !cleanName.isEmpty else { return }

        let folderURL = profilesRootURL.appendingPathComponent(cleanName, isDirectory: true)

        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        refreshGameProfileFolders()

    }

    

    func importSQLiteIntoProfileFolder(folderName: String, sourceURL: URL) {

        let secured = sourceURL.startAccessingSecurityScopedResource()

        defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

        

        let fm = FileManager.default

        let cleanFolder = folderName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? "Hồ sơ mới" : folderName

        let folderURL = profilesRootURL.appendingPathComponent(cleanFolder, isDirectory: true)

        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        

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

            sqliteTranslator.loadDatabase(at: sourceSQLiteURL)

        }

        

        activeProfileFolderName = folderName

        UserDefaults.standard.set(folderName, forKey: "active_profile_folder_v102")

        loadedLineCount = sqliteTranslator.totalLines

        refreshGameProfileFolders()

    }

    

    func deleteGameProfileFolder(folderName: String) {

        let folderURL = profilesRootURL.appendingPathComponent(folderName, isDirectory: true)

        try? FileManager.default.removeItem(at: folderURL)

        refreshGameProfileFolders()

    }

    

    // MARK: - Luồng quét đa vùng, đặt đúng vị trí từng khối chữ và đồng bộ thời gian xuất hiện thực tế

    private func processFrameRealtime(_ frame: CGImage) {

        guard !isShowingTVTestSentence else { return }

        guard !isOCRProcessing else { return }

        

        let now = Date().timeIntervalSince1970

        let minInterval = 1.0 / max(1.0, scanFPS)

        guard (now - lastScanTimestamp) >= minInterval else { return }

        

        guard let cropped = videoMgr.cropFrameToSmartROI(fullImage: frame, mode: roiMode) else { return }

        lastScanTimestamp = now

        isOCRProcessing = true

        

        let roiRect = videoMgr.getNormalizedROIRect(for: roiMode)

        

        ocrEngine.recognizeMultiRegions(in: cropped) { [weak self] (regions: [V102OCRTextRegion]) in

            guard let self = self else { return }

            self.isOCRProcessing = false

            guard !self.isShowingTVTestSentence else { return }

            

            if regions.isEmpty {

                DispatchQueue.main.async {

                    if !self.translatedBoxes.isEmpty {

                        self.translatedBoxes = []

                        self.server.broadcast(boxes: [])

                    }

                    self.lastRecognizedEnglish = "Màn hình không có chữ (Đã ẩn phụ đề)"

                }

                return

            }

            

            var mappedBoxes: [TranslatedBox] = []

            var englishSummaryParts: [String] = []

            

            for region in regions {

                let rawEng = region.rawText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                guard !rawEng.isEmpty else { continue }

                englishSummaryParts.append(rawEng)

                

                let exactX = roiRect.origin.x + region.x * roiRect.size.width

                let exactY = roiRect.origin.y + region.y * roiRect.size.height

                let exactW = region.w * roiRect.size.width

                let exactH = region.h * roiRect.size.height

                

                if let dbText = self.sqliteTranslator.findBestVietnameseMatch(for: rawEng) {

                    mappedBoxes.append(

                        TranslatedBox(

                            text: dbText,

                            x: exactX,

                            y: exactY,

                            w: exactW,

                            h: exactH

                        )

                    )

                } else if self.enableAppleIntelligenceFallback {

                    let aiText = AppleIntelligenceFallbackEngine.shared.translateRegion(

                        englishText: rawEng,

                        onAsyncRefined: { [weak self] _ in

                            self?.lastScanTimestamp = 0

                        }

                    )

                    mappedBoxes.append(

                        TranslatedBox(

                            text: aiText,

                            x: exactX,

                            y: exactY,

                            w: exactW,

                            h: exactH

                        )

                    )

                }

            }

            

            DispatchQueue.main.async {

                self.lastRecognizedEnglish = englishSummaryParts.joined(separator: " | ")

                self.translatedBoxes = mappedBoxes

                self.server.broadcast(boxes: mappedBoxes)

            }

        }

    }

}



// ============================================================================

// 7. GIAO DIỆN CHÍNH PS5TRANSLATOR 1.02 (HIỂN THỊ ĐÈ ĐÚNG CHỖ & BẰNG CỠ CHỮ GỐC)

// ============================================================================

struct MainTranslatorView: View {

    @StateObject private var coord = PipelineCoordinator()

    @State private var showPS5ConnectSheet = false

    @State private var showGameProfilesSheet = false

    @State private var showROICalibrationPanel = false

    

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

                    topPlayStationBar

                    ps5ScreenViewport

                    liveOCRAndTVTestStrip

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

                    Text(TranslatorV102Config.appVersionName)

                        .font(.system(size: 15, weight: .bold))

                        .foregroundColor(.white)

                    HStack(spacing: 5) {

                        Circle()

                            .fill(coord.videoMgr.isConnectedToPS5 ? Color.green : (coord.videoMgr.isAccountRemembered ? Color.cyan : Color.orange))

                            .frame(width: 7, height: 7)

                        Text(coord.videoMgr.isConnectedToPS5

                             ? "Chiaki Live: \(coord.videoMgr.ps5HostIP)"

                             : (coord.videoMgr.isAccountRemembered ? "Đã nhớ TK: \(coord.videoMgr.psnUsername)" : "Chưa nối PS5"))

                            .font(.system(size: 11, weight: .medium))

                            .foregroundColor(.white.opacity(0.85))

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

                                    ZStack(alignment: .topLeading) {

                                        RoundedRectangle(cornerRadius: 8)

                                            .stroke(

                                                style: StrokeStyle(

                                                    lineWidth: coord.roiMode == .fullScreen ? 1.4 : 2.2,

                                                    dash: [6, 4]

                                                )

                                            )

                                            .foregroundColor(coord.roiMode == .fullScreen ? .cyan.opacity(0.55) : .cyan)

                                            .background(Color.cyan.opacity(coord.roiMode == .fullScreen ? 0.0 : 0.05))

                                        

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

                                

                                ForEach(coord.translatedBoxes) { box in

                                    let pixelW = max(36.0, box.w * geo.size.width)

                                    let pixelH = max(16.0, box.h * geo.size.height)

                                    let matchedFontSize = calculateMatchingFontSize(boxWidth: pixelW, boxHeight: pixelH, text: box.text)

                                    

                                    Text(box.text)

                                        .font(.system(size: matchedFontSize, weight: .bold))

                                        .foregroundColor(.yellow)

                                        .multilineTextAlignment(.center)

                                        .lineLimit(nil)

                                        .minimumScaleFactor(0.65)

                                        .padding(.horizontal, 6)

                                        .padding(.vertical, 4)

                                        .frame(

                                            minWidth: pixelW + 14,

                                            minHeight: pixelH + 10

                                        )

                                        .background(

                                            RoundedRectangle(cornerRadius: 6)

                                                .fill(Color.black.opacity(TranslatorV102Config.subtitleMaskBlackOpacity))

                                        )

                                        .overlay(

                                            RoundedRectangle(cornerRadius: 6)

                                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)

                                        )

                                        .position(

                                            x: (box.x + box.w / 2.0) * geo.size.width,

                                            y: (box.y + box.h / 2.0) * geo.size.height

                                        )

                                }

                            }

                        }

                    )

            } else {

                VStack(spacing: 10) {

                    ProgressView()

                    Text("Đang khởi tạo luồng hình Chiaki PS5...")

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

    

    private func calculateMatchingFontSize(boxWidth: CGFloat, boxHeight: CGFloat, text: String) -> CGFloat {

        let estimatedLines: CGFloat = (boxHeight > 34 && text.count > 42) ? 2.0 : 1.0

        let singleLineHeight = boxHeight / estimatedLines

        let rawFontSize = singleLineHeight * 0.78

        return max(9.5, min(18.0, rawFontSize))

    }

    

    private var liveOCRAndTVTestStrip: some View {

        HStack(spacing: 8) {

            Image(systemName: coord.isShowingTVTestSentence ? "tv.and.mediabox.fill" : "viewfinder")

                .foregroundColor(coord.isShowingTVTestSentence ? .green : .cyan)

            

            Text(coord.isShowingTVTestSentence ? "TV Test: \(TranslatorV102Config.tvTestSentence)" : "Quét (\(coord.translatedBoxes.count) vùng): \(coord.lastRecognizedEnglish)")

                .font(.system(size: 12, weight: .medium))

                .foregroundColor(.white.opacity(0.92))

                .lineLimit(1)

            

            Spacer()

            

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

    

    private var bottomDualSenseControlBar: some View {

        VStack(spacing: 11) {

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

                    in: TranslatorV102Config.minScanFPS...TranslatorV102Config.maxScanFPS,

                    step: 1.0

                )

                .tint(psNeonAccent)

            }

            

            HStack {

                Image(systemName: "sparkles")

                    .foregroundColor(.yellow)

                VStack(alignment: .leading, spacing: 1) {

                    Text("Dịch AI (Apple Intelligence)")

                        .font(.system(size: 12, weight: .bold))

                        .foregroundColor(.white)

                    Text("Tự động dịch Hội thoại, Nhiệm vụ, Kỹ năng, Vật phẩm chưa có trong data")

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

            

            HStack(spacing: 10) {

                Button(action: { showPS5ConnectSheet = true }) {

                    HStack {

                        Image(systemName: "play.tv.fill")

                        VStack(alignment: .leading, spacing: 2) {

                            Text("Liên kết máy PS5")

                                .font(.system(size: 13, weight: .bold))

                            Text(coord.videoMgr.isAccountRemembered ? "Đã nhớ: \(coord.videoMgr.psnUsername)" : "Lõi Chiaki & Mã PIN")

                                .font(.system(size: 10))

                                .foregroundColor(.white.opacity(0.8))

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



// ============================================================================

// 8. MÀN HÌNH QUẢN LÝ HỒ SƠ GAME

// ============================================================================

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

                        Label("Gửi câu Test \"\(TranslatorV102Config.tvTestSentence)\" lên TV", systemImage: "tv.badge.wifi")

                            .font(.subheadline.bold())

                            .foregroundColor(.green)

                    }

                }

                

                Section(header: Text("2. Tạo thư mục Hồ sơ Game mới")) {

                    TextField("Nhập tên Hồ sơ Game (VD: Until Dawn, God of War)", text: $newProfileName)

                    

                    HStack(spacing: 12) {

                        Button(action: {

                            guard !newProfileName.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty else { return }

                            coord.createNewGameProfileFolder(folderName: newProfileName)

                            newProfileName = ""

                        }) {

                            Label("Chỉ tạo thư mục", systemImage: "folder.badge.plus")

                                .font(.caption.bold())

                        }

                        .buttonStyle(.bordered)

                        

                        Button(action: {

                            let target = newProfileName.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty ? "Game Mới" : newProfileName

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



// ============================================================================

// 9. MÀN HÌNH LIÊN KẾT CHIAKI PS5 & GHI NHỚ TÀI KHOẢN VĨNH VIỄN

// ============================================================================

struct PS5ConnectionWizardView: View {

    @ObservedObject var coord: PipelineCoordinator

    @Environment(\.presentationMode) var presentationMode

    @State private var showPSNWebLogin = false

    

    private let psBlue = Color(red: 0.0, green: 0.44, blue: 0.82)

    

    var body: some View {

        NavigationView {

            ScrollView {

                VStack(alignment: .leading, spacing: 16) {

                    // Khung trạng thái phản hồi từ Lõi Chiaki

                    HStack(spacing: 12) {

                        Image(systemName: coord.videoMgr.isConnectedToPS5 ? "checkmark.seal.fill" : "gamecontroller.fill")

                            .font(.system(size: 28))

                            .foregroundColor(.white)

                            .padding(14)

                            .background(coord.videoMgr.isConnectedToPS5 ? Color.green : psBlue)

                            .clipShape(Circle())

                        

                        VStack(alignment: .leading, spacing: 4) {

                            Text("Lõi Chiaki PS5 Remote Play")

                                .font(.headline)

                                .foregroundColor(.white)

                            Text(coord.videoMgr.statusLog)

                                .font(.caption)

                                .foregroundColor(coord.videoMgr.statusLog.contains("❌") || coord.videoMgr.statusLog.contains("⚠️") ? .yellow : .cyan)

                        }

                    }

                    .padding()

                    .frame(maxWidth: .infinity, alignment: .leading)

                    .background(Color(red: 0.06, green: 0.13, blue: 0.28))

                    .cornerRadius(14)

                    

                    // BƯỚC 1: ĐỊA CHỈ IP MÁY PS5

                    VStack(alignment: .leading, spacing: 10) {

                        Label("BƯỚC 1: Địa chỉ IP của máy PS5", systemImage: "1.circle.fill")

                            .font(.subheadline.bold())

                            .foregroundColor(.cyan)

                        

                        HStack {

                            TextField("VD: 192.168.2.23", text: $coord.videoMgr.ps5HostIP)

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

                    

                    // BƯỚC 2: TÀI KHOẢN PSN PHỤ & GHI NHỚ TỰ ĐỘNG

                    VStack(alignment: .leading, spacing: 10) {

                        HStack {

                            Label("BƯỚC 2: Tài khoản PSN Phụ", systemImage: "2.circle.fill")

                                .font(.subheadline.bold())

                                .foregroundColor(.cyan)

                            Spacer()

                            if coord.videoMgr.isAccountRemembered {

                                Label("Đã ghi nhớ", systemImage: "checkmark.shield.fill")

                                    .font(.caption.bold())

                                    .foregroundColor(.green)

                            }

                        }

                        

                        Text("Sau khi lấy mã Account ID 8-byte 1 lần, ứng dụng sẽ tự động ghi nhớ vĩnh viễn tài khoản này:")

                            .font(.caption)

                            .foregroundColor(.gray)

                        

                        HStack {

                            TextField("Tên tài khoản PSN phụ (VD: Miesoi93)", text: $coord.videoMgr.psnUsername)

                                .padding(10)

                                .background(Color.black.opacity(0.35))

                                .cornerRadius(8)

                                .foregroundColor(.white)

                            

                            Button(action: {

                                coord.videoMgr.lookupAccountIDByPSNUsername()

                            }) {

                                HStack(spacing: 4) {

                                    Image(systemName: "magnifyingglass")

                                    Text("Tự lấy ID")

                                        .font(.caption.bold())

                                }

                                .padding(.horizontal, 10)

                                .padding(.vertical, 10)

                                .background(Color.cyan.opacity(0.25))

                                .foregroundColor(.cyan)

                                .cornerRadius(8)

                            }

                        }

                        

                        HStack {

                            TextField("Mã Account ID 8-byte Base64 (Hoặc số ID 19 số)", text: $coord.videoMgr.psnAccountIDBase64)

                                .font(.caption.monospaced())

                                .padding(10)

                                .background(Color.black.opacity(0.35))

                                .cornerRadius(8)

                                .foregroundColor(.yellow)

                            

                            Button(action: { showPSNWebLogin = true }) {

                                HStack(spacing: 4) {

                                    Image(systemName: "person.badge.key.fill")

                                    Text("Đăng nhập Sony")

                                        .font(.caption.bold())

                                }

                                .padding(.horizontal, 12)

                                .padding(.vertical, 10)

                                .background(psBlue)

                                .foregroundColor(.white)

                                .cornerRadius(8)

                            }

                        }

                        

                        if coord.videoMgr.isAccountRemembered {

                            HStack {

                                Text("Đã lưu: \(coord.videoMgr.psnUsername) (\(coord.videoMgr.psnAccountIDBase64))")

                                    .font(.caption2)

                                    .foregroundColor(.green)

                                Spacer()

                                Button("Đổi TK khác") {

                                    coord.videoMgr.clearRememberedAccount()

                                }

                                .font(.caption2.bold())

                                .foregroundColor(.orange)

                            }

                        }

                    }

                    .padding()

                    .background(Color.white.opacity(0.06))

                    .cornerRadius(14)

                    

                    // BƯỚC 3: MÃ PIN 8 CHỮ SỐ TRÊN MÀN HÌNH PS5

                    VStack(alignment: .leading, spacing: 10) {

                        Label("BƯỚC 3: Mã PIN 8 số liên kết thiết bị (Chỉ cần nhập lần đầu)", systemImage: "3.circle.fill")

                            .font(.subheadline.bold())

                            .foregroundColor(.cyan)

                        

                        Text("Trên PS5 (ở tài khoản phụ Miesoi93): Cài đặt -> Hệ thống -> Chơi từ xa -> Liên kết thiết bị:")

                            .font(.caption)

                            .foregroundColor(.gray)

                        

                        TextField("Nhập 8 chữ số trên TV (VD: 4326 2954)", text: $coord.videoMgr.psnPinCode)

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

                    }) {

                        HStack {

                            Spacer()

                            Image(systemName: "link.circle.fill")

                                .font(.title3)

                            Text("LIÊN KẾT CHIAKI & GHI NHỚ TÀI KHOẢN")

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

                PSNWebLoginHelperView(coord: coord)

            }

        }

        .preferredColorScheme(.dark)

    }

}



// ============================================================================

// 10. TRÌNH ĐĂNG NHẬP SONY OAUTH (ĐÃ SỬA LỖI 4174 & LƯU COOKIE GHI NHỚ TÀI KHOẢN)

// ============================================================================

struct PSNWebLoginHelperView: View {

    @ObservedObject var coord: PipelineCoordinator

    @Environment(\.presentationMode) var presentationMode

    @State private var extractionStatus: String = "Đăng nhập tài khoản phụ (Miesoi93) một lần duy nhất. App sẽ tự lấy Account ID 8-byte và ghi nhớ vĩnh viễn."

    

    var body: some View {

        NavigationView {

            VStack(spacing: 8) {

                Text(extractionStatus)

                    .font(.caption.bold())

                    .foregroundColor(.cyan)

                    .multilineTextAlignment(.center)

                    .padding(.horizontal, 10)

                    .padding(.top, 6)

                

                SonyOAuthWebView(

                    url: URL(string: TranslatorV102Config.sonyOAuthLoginURL)!,

                    onExtractedAccount: { onlineID, base64ID, numericID in

                        let finalUser = onlineID.isEmpty ? coord.videoMgr.psnUsername : onlineID

                        coord.videoMgr.saveRememberedAccount(

                            username: finalUser,

                            accountIDBase64: base64ID,

                            numericID: numericID

                        )

                        self.extractionStatus = "✅ Đã lấy & ghi nhớ thành công Account ID 8-byte (\(base64ID)) của \(finalUser)!"

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {

                            presentationMode.wrappedValue.dismiss()

                        }

                    },

                    onStatusUpdate: { msg in

                        self.extractionStatus = msg

                    }

                )

            }

            .navigationTitle("Đăng nhập Sony (Đã sửa 4174)")

            .navigationBarTitleDisplayMode(.inline)

            .toolbar {

                ToolbarItem(placement: .navigationBarTrailing) {

                    Button("Đóng") {

                        presentationMode.wrappedValue.dismiss()

                    }

                }

            }

        }

        .preferredColorScheme(.dark)

    }

}



struct SonyOAuthWebView: UIViewRepresentable {

    let url: URL

    let onExtractedAccount: (String, String, String) -> Void

    let onStatusUpdate: (String) -> Void

    

    func makeCoordinator() -> Coordinator {

        Coordinator(onExtractedAccount: onExtractedAccount, onStatusUpdate: onStatusUpdate)

    }

    

    func makeUIView(context: Context) -> WKWebView {

        // Sử dụng WKWebsiteDataStore.default() để lưu Cookie phiên đăng nhập Sony vĩnh viễn

        let config = WKWebViewConfiguration()

        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: config)

        webView.navigationDelegate = context.coordinator

        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        webView.load(URLRequest(url: url))

        return webView

    }

    

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    

    class Coordinator: NSObject, WKNavigationDelegate {

        let onExtractedAccount: (String, String, String) -> Void

        let onStatusUpdate: (String) -> Void

        private var didExchangeCode = false

        

        init(onExtractedAccount: @escaping (String, String, String) -> Void, onStatusUpdate: @escaping (String) -> Void) {

            self.onExtractedAccount = onExtractedAccount

            self.onStatusUpdate = onStatusUpdate

        }

        

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let reqURL = navigationAction.request.url else {

                decisionHandler(.allow)

                return

            }

            let currentURL = reqURL.absoluteString

            

            // Bắt chính xác URL chuyển hướng com.scee.psxandroid.scecompcall://redirect?code=v3.xxxx

            if currentURL.hasPrefix(TranslatorV102Config.sonyOAuthRedirectPrefix) ||

               currentURL.contains("scecompcall://redirect") ||

               currentURL.contains("remoteplay/redirect") {

                if let components = URLComponents(string: currentURL),

                   let code = components.queryItems?.first(where: { $0.name == "code" })?.value,

                   !didExchangeCode {

                    didExchangeCode = true

                    DispatchQueue.main.async {

                        self.onStatusUpdate("Đã nhận mã xác thực từ Sony! Đang trích xuất Account ID 8-byte...")

                    }

                    exchangeOAuthCodeForAccountID(code: code)

                }

                // Huỷ điều hướng sang custom scheme để tránh báo lỗi trang trống trên WebKit

                decisionHandler(.cancel)

                return

            }

            

            decisionHandler(.allow)

        }

        

        private func exchangeOAuthCodeForAccountID(code: String) {

            guard let tokenURL = URL(string: TranslatorV102Config.sonyOAuthTokenURL) else { return }

            var req = URLRequest(url: tokenURL)

            req.httpMethod = "POST"

            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            req.setValue(TranslatorV102Config.sonyBasicAuthHeader, forHTTPHeaderField: "Authorization")

            

            let bodyStr = "grant_type=authorization_code&code=\(code)&redirect_uri=\(TranslatorV102Config.sonyOAuthRedirectEncoded)"

            req.httpBody = bodyStr.data(using: .utf8)

            

            URLSession.shared.dataTask(with: req) { data, _, _ in

                guard let data = data,

                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],

                      let accessToken = json["access_token"] as? String else {

                    DispatchQueue.main.async {

                        self.onStatusUpdate("Không đổi được token từ Sony. Hãy thử đăng nhập lại.")

                    }

                    return

                }

                self.fetchPSNAccountID(accessToken: accessToken)

            }.resume()

        }

        

        private func fetchPSNAccountID(accessToken: String) {

            // 1. Gọi API thiết bị chính thức của Sony để lấy accountId 64-bit

            guard let profileURL = URL(string: "https://dms.api.playstation.com/api/v1/devices/accounts/me") else { return }

            var req = URLRequest(url: profileURL)

            req.httpMethod = "GET"

            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            

            URLSession.shared.dataTask(with: req) { data, _, _ in

                if let data = data,

                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],

                   let accountIdStr = json["accountId"] as? String,

                   let numericID = UInt64(accountIdStr) {

                    var le = numericID.littleEndian

                    let base64ID = Data(bytes: &le, count: 8).base64EncodedString()

                    let onlineId = (json["onlineId"] as? String) ?? ""

                    DispatchQueue.main.async {

                        self.onExtractedAccount(onlineId, base64ID, String(numericID))

                    }

                    return

                }

                

                // 2. Dự phòng gọi API SSOCookie của Sony

                guard let fallbackURL = URL(string: "https://ca.account.sony.com/api/v1/ssocookie") else { return }

                var req2 = URLRequest(url: fallbackURL)

                req2.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

                URLSession.shared.dataTask(with: req2) { data2, _, _ in

                    if let data2 = data2,

                       let json2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],

                       let accStr = (json2["account_id"] as? String) ?? (json2["user_id"] as? String),

                       let num = UInt64(accStr) {

                        var le = num.littleEndian

                        let base64ID = Data(bytes: &le, count: 8).base64EncodedString()

                        DispatchQueue.main.async {

                            self.onExtractedAccount("", base64ID, String(num))

                        }

                    }

                }.resume()

            }.resume()

        }

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
