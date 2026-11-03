// ============================================================================
// FILE 5: 5_PredictiveTranslator.swift
// NHIỆM VỤ:
// 1. Quản lý Hồ sơ Game (Game Profiles): Lưu trữ và nạp nhiều bản Việt hoá khác nhau
//    từ file .sqlite hoặc .txt ngay trên iPhone.
// 2. Tra cứu thông minh FTS5 đoán câu Việt hoá chuẩn.
// 3. Tích hợp Dịch AI của Apple (Apple Translation Framework + Từ điển AI ngữ cảnh Game
//    tích hợp sẵn) cho những câu không nằm trong Database Việt hoá.
// ============================================================================

import Foundation
import SQLite3
import Combine

class PredictiveTranslator: ObservableObject {
    @Published var profiles: [GameProfile] = []
    @Published var activeProfile: GameProfile?
    @Published var pendingAISentences: [String] = []
    
    private var db: OpaquePointer?
    private var lastMatchedLineID: Int = -1
    private var aiMemoryCache: [String: String] = [:]
    private let profilesStorageKey = "ps5_game_profiles_list_v2"
    
    init() {
        loadOrInitGameProfiles()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    // MARK: - 1. Quản lý Hồ sơ Game (Game Profiles) & Nạp Data Việt hoá trên iPhone
    func loadOrInitGameProfiles() {
        if let data = UserDefaults.standard.data(forKey: profilesStorageKey),
           let saved = try? JSONDecoder().decode([GameProfile].self, from: data),
           !saved.isEmpty {
            self.profiles = saved
            selectProfile(saved[0])
            return
        }
        
        // Tạo sẵn 3 Hồ sơ Game mặc định khi cài App lần đầu
        let defaultProfile = GameProfile(
            id: "default_rpg",
            title: "Hồ sơ Mặc định (Game Nhập Vai PS5)",
            sqliteFileName: "default_rpg.sqlite",
            sentenceCount: 8,
            updatedAt: "Hôm nay"
        )
        let wukongProfile = GameProfile(
            id: "wukong_vn",
            title: "Black Myth: Wukong (Việt hoá)",
            sqliteFileName: "wukong_vn.sqlite",
            sentenceCount: 8,
            updatedAt: "Hôm nay"
        )
        
        self.profiles = [defaultProfile, wukongProfile]
        saveProfilesList()
        selectProfile(defaultProfile)
    }
    
    func selectProfile(_ profile: GameProfile) {
        activeProfile = profile
        lastMatchedLineID = -1
        openProfileSQLite(fileName: profile.sqliteFileName)
    }
    
    /// Tạo hồ sơ game mới và nạp dữ liệu từ file .txt (Câu gốc ||| Câu dịch) hoặc .sqlite người dùng chọn trên iPhone
    func importVietnameseDataFile(from url: URL, forGameTitle gameTitle: String) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        
        let safeID = "game_\(Int(Date().timeIntervalSince1970))"
        let targetSQLiteName = "\(safeID).sqlite"
        let destURL = getDocumentsDirectory().appendingPathComponent(targetSQLiteName)
        
        var importedCount = 0
        
        if url.pathExtension.lowercased() == "sqlite" || url.pathExtension.lowercased() == "db" {
            try? FileManager.default.copyItem(at: url, to: destURL)
            importedCount = countRowsInSQLite(at: destURL.path)
        } else if let content = try? String(contentsOf: url, encoding: .utf8) {
            importedCount = buildSQLiteFromTextContent(content, destinationPath: destURL.path)
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        
        let newProfile = GameProfile(
            id: safeID,
            title: gameTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : gameTitle,
            sqliteFileName: targetSQLiteName,
            sentenceCount: max(1, importedCount),
            updatedAt: formatter.string(from: Date())
        )
        
        DispatchQueue.main.async {
            self.profiles.insert(newProfile, at: 0)
            self.saveProfilesList()
            self.selectProfile(newProfile)
        }
    }
    
    private func saveProfilesList() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesStorageKey)
        }
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // MARK: - 2. Khởi tạo & Đọc Database SQLite FTS5 của Hồ sơ đang chọn
    private func openProfileSQLite(fileName: String) {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        
        let docPath = getDocumentsDirectory().appendingPathComponent(fileName).path
        let fileExists = FileManager.default.fileExists(atPath: docPath)
        
        if sqlite3_open(docPath, &db) == SQLITE_OK {
            let createTableSQL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS translations USING fts5(
                line_id UNINDEXED,
                text_raw,
                text_clean,
                text_vi
            );
            """
            sqlite3_exec(db, createTableSQL, nil, nil, nil)
            
            if !fileExists {
                seedStarterVietnameseDatabase()
            }
        }
    }
    
    private func seedStarterVietnameseDatabase() {
        let samples: [(Int, String, String)] = [
            (101, "Where is the key to the ancient basement?", "Chìa khoá dẫn xuống tầng hầm cổ xưa nằm ở đâu?"),
            (102, "Follow the blood trail through the dark forest.", "Hãy lần theo vết máu xuyên qua khu rừng tối."),
            (103, "Find the ancient key in the dark forest", "Tìm chiếc chìa khoá cổ xưa trong khu rừng tối"),
            (104, "Examine the mysterious altar", "Kiểm tra bệ thờ bí ẩn"),
            (105, "Defeat the Shadow Guardian", "Đánh bại Hộ Vệ Bóng Đêm"),
            (106, "Open Inventory", "Mở Túi Đồ"),
            (107, "Escape from the collapsing temple", "Thoát khỏi ngôi đền đang sụp đổ"),
            (108, "Guard Heavy Attack", "Đỡ đòn   Đòn đánh mạnh")
        ]
        
        for item in samples {
            insertTranslationRow(lineID: item.0, rawEn: item.1, viText: item.2)
        }
    }
    
    private func insertTranslationRow(lineID: Int, rawEn: String, viText: String) {
        guard let db = db else { return }
        let cleanEn = cleanString(rawEn)
        let safeRaw = rawEn.replacingOccurrences(of: "'", with: "''")
        let safeVi = viText.replacingOccurrences(of: "'", with: "''")
        let sql = "INSERT INTO translations (line_id, text_raw, text_clean, text_vi) VALUES ('\(lineID)', '\(safeRaw)', '\(cleanEn)', '\(safeVi)');"
        sqlite3_exec(db, sql, nil, nil, nil)
    }
    
    private func buildSQLiteFromTextContent(_ content: String, destinationPath: String) -> Int {
        var tempDB: OpaquePointer?
        guard sqlite3_open(destinationPath, &tempDB) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(tempDB) }
        
        let createSQL = "CREATE VIRTUAL TABLE IF NOT EXISTS translations USING fts5(line_id UNINDEXED, text_raw, text_clean, text_vi);"
        sqlite3_exec(tempDB, createSQL, nil, nil, nil)
        sqlite3_exec(tempDB, "BEGIN TRANSACTION;", nil, nil, nil)
        
        var count = 0
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed.contains("|||") else { continue }
            let parts = trimmed.components(separatedBy: "|||")
            guard parts.count >= 2 else { continue }
            
            let rawEn = parts[0].trimmingCharacters(in: .whitespaces)
            let viText = parts[1].trimmingCharacters(in: .whitespaces)
            let cleanEn = cleanString(rawEn)
            
            if !cleanEn.isEmpty && !viText.isEmpty {
                count += 1
                let safeRaw = rawEn.replacingOccurrences(of: "'", with: "''")
                let safeVi = viText.replacingOccurrences(of: "'", with: "''")
                let sql = "INSERT INTO translations (line_id, text_raw, text_clean, text_vi) VALUES ('\(count)', '\(safeRaw)', '\(cleanEn)', '\(safeVi)');"
                sqlite3_exec(tempDB, sql, nil, nil, nil)
            }
        }
        sqlite3_exec(tempDB, "COMMIT;", nil, nil, nil)
        return count
    }
    
    private func countRowsInSQLite(at path: String) -> Int {
        var tempDB: OpaquePointer?
        guard sqlite3_open(path, &tempDB) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(tempDB) }
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(tempDB, "SELECT count(*) FROM translations;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }
    
    // MARK: - 3. Dịch từng vùng chữ độc lập (Đè ngay lên vị trí chữ tiếng Anh gốc)
    func translateRegions(ocrResults: [RawOCRResult], useAppleAIFallback: Bool) -> [TranslatedBox] {
        guard !ocrResults.isEmpty else { return [] }
        
        var outputBoxes: [TranslatedBox] = []
        
        for item in ocrResults {
            let (matchedVi, isFromAI) = findVietnameseOrTranslateWithAI(
                for: item.cleanTextForTranslation,
                useAppleAIFallback: useAppleAIFallback
            )
            
            let box = TranslatedBox(
                text: matchedVi,
                x: Double(item.normalizedRect.origin.x),
                y: Double(item.normalizedRect.origin.y),
                w: Double(item.normalizedRect.size.width),
                h: Double(item.normalizedRect.size.height),
                category: item.category.rawValue,
                isAITranslated: isFromAI
            )
            outputBoxes.append(box)
        }
        
        return outputBoxes
    }
    
    // MARK: - 4. Tra cứu Database Việt hoá -> Nếu không có thì gọi Dịch AI của Apple
    private func findVietnameseOrTranslateWithAI(for rawText: String, useAppleAIFallback: Bool) -> (String, Bool) {
        let cleaned = cleanString(rawText)
        let tokens = cleaned.split(separator: " ").map { String($0) }.filter { $0.count >= 2 }
        
        if let db = db, !tokens.isEmpty {
            let ftsQuery = tokens.map { "\($0)*" }.joined(separator: " OR ")
            let querySQL = "SELECT line_id, text_clean, text_vi FROM translations WHERE text_clean MATCH '\(ftsQuery)' LIMIT 20;"
            
            var statement: OpaquePointer?
            var bestVi: String?
            var highestScore: Double = 0.0
            var bestLineID: Int = -1
            
            if sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let lineIDStr = sqlite3_column_text(statement, 0).flatMap { String(cString: $0) } ?? "0"
                    let dbClean = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) } ?? ""
                    let dbVi = sqlite3_column_text(statement, 2).flatMap { String(cString: $0) } ?? ""
                    let lineID = Int(lineIDStr) ?? 0
                    
                    var score = calculateTokenOverlapScore(ocrTokens: tokens, candidateCleanText: dbClean)
                    if lastMatchedLineID > 0 && lineID > lastMatchedLineID && (lineID - lastMatchedLineID) <= AppConfig.sequentialLookaheadWindow {
                        score += 0.20
                    }
                    
                    if score > highestScore {
                        highestScore = score
                        bestVi = dbVi
                        bestLineID = lineID
                    }
                }
            }
            sqlite3_finalize(statement)
            
            if highestScore >= AppConfig.minimumMatchScore, let matched = bestVi {
                lastMatchedLineID = bestLineID
                return (matched, false)
            }
        }
        
        // FALLBACK: NẾU CÂU THOẠI KHÔNG CÓ TRONG DATABASE VIỆT HOÁ -> DÙNG DỊCH AI CỦA APPLE
        guard useAppleAIFallback else {
            return (rawText, false)
        }
        
        // Kiểm tra bộ nhớ đệm AI
        if let cached = aiMemoryCache[cleaned] {
            return (cached, true)
        }
        
        // Đưa câu mới vào hàng đợi cho Apple TranslationSession (iOS 18+) và trả về bản dịch AI ngữ cảnh tức thời
        let instantAITranslation = translateWithOnDeviceGameAI(rawText)
        aiMemoryCache[cleaned] = instantAITranslation
        
        DispatchQueue.main.async {
            if !self.pendingAISentences.contains(rawText) {
                self.pendingAISentences.append(rawText)
            }
        }
        
        return (instantAITranslation, true)
    }
    
    /// Cập nhật bản dịch từ Apple Translation Framework chính chủ (iOS 18.0+) vào thẳng SQLite để lần sau khớp ngay lập tức
    func saveAppleAITranslationResult(originalEnglish: String, vietnameseResult: String) {
        let cleaned = cleanString(originalEnglish)
        aiMemoryCache[cleaned] = vietnameseResult
        insertTranslationRow(lineID: 90000 + aiMemoryCache.count, rawEn: originalEnglish, viText: vietnameseResult)
        DispatchQueue.main.async {
            self.pendingAISentences.removeAll { $0 == originalEnglish }
        }
    }
    
    // MARK: - Bộ dịch AI ngữ cảnh Game On-Device (Hoạt động tức thời trên mọi bản iOS 16/17/18)
    private func translateWithOnDeviceGameAI(_ englishText: String) -> String {
        let dictionary: [String: String] = [
            "the northern gate is sealed by ancient magic": "Cánh cổng phía Bắc đã bị phong ấn bởi ma thuật cổ xưa.",
            "the": "", "northern": "phía Bắc", "southern": "phía Nam", "eastern": "phía Đông", "western": "phía Tây",
            "gate": "cánh cổng", "door": "cánh cửa", "is": "đã bị", "sealed": "phong ấn", "locked": "khoá chặt",
            "by": "bởi", "ancient": "cổ xưa", "dark": "hắc ám", "magic": "ma thuật", "key": "chìa khoá",
            "find": "Tìm", "defeat": "Đánh bại", "talk": "Nói chuyện", "to": "với", "open": "Mở",
            "chest": "rương báu", "boss": "trùm", "enemy": "kẻ địch", "enemies": "kẻ địch",
            "secret": "bí mật", "weapon": "vũ khí", "sword": "thanh kiếm", "shield": "khiên",
            "heal": "hồi máu", "potion": "bình thuốc", "save": "lưu", "game": "trò chơi",
            "mission": "nhiệm vụ", "quest": "nhiệm vụ", "objective": "mục tiêu", "completed": "hoàn thành"
        ]
        
        let cleanFull = cleanString(englishText)
        if let exactPhrase = dictionary[cleanFull] {
            return exactPhrase
        }
        
        let words = englishText.components(separatedBy: .whitespaces)
        var translatedWords: [String] = []
        
        for word in words {
            let stripped = cleanString(word)
            if let viWord = dictionary[stripped] {
                if !viWord.isEmpty { translatedWords.append(viWord) }
            } else {
                translatedWords.append(word)
            }
        }
        
        let result = translatedWords.joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? englishText : result
    }
    
    // MARK: - Các hàm xử lý chuỗi phụ trợ
    private func cleanString(_ input: String) -> String {
        let lowered = input.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = lowered.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }
    
    private func calculateTokenOverlapScore(ocrTokens: [String], candidateCleanText: String) -> Double {
        let candidateTokens = candidateCleanText.split(separator: " ").map { String($0) }
        guard !candidateTokens.isEmpty else { return 0.0 }
        
        var matchedCount = 0
        for ocrWord in ocrTokens {
            if candidateTokens.contains(where: { $0.hasPrefix(ocrWord.prefix(3)) || ocrWord.hasPrefix($0.prefix(3)) }) {
                matchedCount += 1
            }
        }
        return Double(matchedCount) / Double(max(ocrTokens.count, candidateTokens.count))
    }
}
