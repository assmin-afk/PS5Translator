// ============================================================================
// FILE 5: 5_PredictiveTranslator.swift
// NHIỆM VỤ: Bộ não "Đoán câu Việt hoá".
// Nhận các từ khoá bị thiếu hoặc hơi sai chính tả từ OCR (File 4), đối chiếu với
// cơ sở dữ liệu SQLite FTS5 và thứ tự câu thoại liền kề để lấy ra câu dịch
// tiếng Việt chuẩn xác và giàu cảm xúc nhất.
// ============================================================================

import Foundation
import SQLite3

class PredictiveTranslator {
    private var db: OpaquePointer?
    
    // Lưu lại ID của câu thoại vừa dịch trước đó để ưu tiên đoán các câu kế tiếp theo kịch bản
    private var lastMatchedLineID: Int = -1
    
    init() {
        setupDatabase()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    // MARK: - 1. Khởi tạo SQLite FTS5 (Ưu tiên đọc file game_data.sqlite, nếu chưa có thì tự tạo DB mẫu)
    private func setupDatabase() {
        // Kiểm tra xem người dùng đã chép file game_data.sqlite vào App chưa
        if let bundleDBPath = Bundle.main.path(forResource: "game_data", ofType: "sqlite") {
            if sqlite3_open(bundleDBPath, &db) == SQLITE_OK {
                print("Đã nạp thành công file game_data.sqlite của bạn!")
                return
            }
        }
        
        // Nếu chưa có file ngoài, tự tạo Database FTS5 ngay trong RAM chứa sẵn dữ liệu Việt hoá mẫu để Test
        if sqlite3_open(":memory:", &db) == SQLITE_OK {
            let createTableSQL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS translations USING fts5(
                line_id UNINDEXED,
                text_raw,
                text_clean,
                text_vi
            );
            """
            sqlite3_exec(db, createTableSQL, nil, nil, nil)
            seedSampleVietnameseData()
        }
    }
    
    /// Nạp sẵn các câu Việt hoá chuẩn tương ứng với bộ giả lập PS5 ở File 2
    private func seedSampleVietnameseData() {
        let samples: [(Int, String, String)] = [
            (101, "Where is the key to the ancient basement?", "Chìa khoá dẫn xuống tầng hầm cổ xưa nằm ở đâu?"),
            (102, "Follow the blood trail through the dark forest.", "Hãy lần theo vết máu xuyên qua khu rừng tối."),
            (103, "Wait! Someone is watching us from the shadows.", "Khoan đã! Có kẻ nào đó đang rình rập chúng ta từ trong bóng tối."),
            (104, "Take this healing potion before the boss fight begins.", "Hãy uống bình thuốc hồi máu này trước khi trận quyết chiến bắt đầu.")
        ]
        
        for item in samples {
            let clean = cleanString(item.1)
            let insertSQL = "INSERT INTO translations (line_id, text_raw, text_clean, text_vi) VALUES ('\(item.0)', '\(item.1)', '\(clean)', '\(item.2)');"
            sqlite3_exec(db, insertSQL, nil, nil, nil)
        }
    }
    
    // MARK: - 2. Thuật toán Đoán câu từ kết quả OCR thô
    func translateAndPredict(ocrResults: [RawOCRResult]) -> [TranslatedBox] {
        guard !ocrResults.isEmpty else { return [] }
        
        // Gộp các dòng nằm sát nhau trong vùng phụ đề thành 1 câu thoại hoàn chỉnh
        let combinedRawText = ocrResults.map { $0.rawText }.joined(separator: " ")
        let unionRect = ocrResults.reduce(ocrResults[0].normalizedRect) { $0.union($1.normalizedRect) }
        
        let translatedText = findBestVietnameseMatch(for: combinedRawText)
        
        let box = TranslatedBox(
            text: translatedText,
            x: Double(unionRect.origin.x),
            y: Double(unionRect.origin.y),
            w: Double(unionRect.size.width),
            h: Double(unionRect.size.height)
        )
        return [box]
    }
    
    /// Tìm câu dịch trong SQLite FTS5 bằng từ khoá OCR + Điểm thưởng ngữ cảnh liền kề
    private func findBestVietnameseMatch(for ocrRaw: String) -> String {
        let cleanedOCR = cleanString(ocrRaw)
        let tokens = cleanedOCR.split(separator: " ").map { String($0) }.filter { $0.count >= 3 }
        
        guard !tokens.isEmpty, let db = db else {
            return "[Dịch nhanh]: \(ocrRaw)"
        }
        
        // Tạo câu truy vấn FTS5 tìm bất kỳ câu nào chứa ít nhất 1 từ khoá (OR) kèm đoán chữ đầu (*)
        let ftsQuery = tokens.map { "\($0)*" }.joined(separator: " OR ")
        let querySQL = "SELECT line_id, text_clean, text_vi FROM translations WHERE text_clean MATCH '\(ftsQuery)' LIMIT 20;"
        
        var statement: OpaquePointer?
        var bestTranslation: String?
        var highestScore: Double = 0.0
        var bestLineID: Int = -1
        
        if sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let lineIDStr = String(cString: sqlite3_column_text(statement, 0))
                let dbCleanText = String(cString: sqlite3_column_text(statement, 1))
                let dbViText = String(cString: sqlite3_column_text(statement, 2))
                let lineID = Int(lineIDStr) ?? 0
                
                // Tính điểm khớp từ khoá
                var score = calculateTokenOverlapScore(ocrTokens: tokens, candidateCleanText: dbCleanText)
                
                // Cộng điểm thưởng nếu câu này nằm ngay sau câu vừa xuất hiện trước đó trong kịch bản game
                if lastMatchedLineID > 0 && lineID > lastMatchedLineID && (lineID - lastMatchedLineID) <= AppConfig.sequentialLookaheadWindow {
                    score += 0.20
                }
                
                if score > highestScore {
                    highestScore = score
                    bestTranslation = dbViText
                    bestLineID = lineID
                }
            }
        }
        sqlite3_finalize(statement)
        
        // Nếu độ tự tin vượt ngưỡng -> Trả về bản dịch Việt hoá chuẩn
        if highestScore >= AppConfig.minimumMatchScore, let matchedVi = bestTranslation {
            lastMatchedLineID = bestLineID
            return matchedVi
        }
        
        // Dự phòng nếu câu thoại không nằm trong file Việt hoá
        return "[Ngoài DB]: \(ocrRaw)"
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