// ============================================================================
// FILE 7: 7_SmartSubtitleEngine.swift
// PHIÊN BẢN: PS5Translator 1.12 (QUÉT CHỮ THÔNG MINH + YOUTUBE + APPLE INTELLIGENCE)
//
// Luồng xử lý mỗi lần quét:
//  1. OCR Apple Vision (.accurate) -> lấy từng DÒNG + toạ độ TỪNG TỪ.
//  2. GameTextFilter: bỏ chữ "rác" (vệt tối bị đọc nhầm, ký tự lạ, số HUD, chữ đơn lẻ
//     vô nghĩa, từ tiếng Anh cơ bản mà game thủ đã hiểu như OK/BACK/HP...).
//  3. Tách nút bấm tay cầm (L1, R2, ✕, ○, △, □...) và khoảng trống chứa icon nút
//     -> chia câu thành nhiều đoạn, khung dịch KHÔNG đè lên nút.
//  4. Gom dòng thành khối (phụ đề 2 dòng), nhận diện tên người nói [Ashley].
//  5. Dịch: Data Việt hoá (khớp chính xác -> khớp gần đúng) -> từ điển menu game
//     -> dịch AI online (giữ nguyên tên riêng) -> lưu bộ nhớ đệm.
//  6. StableSubtitleTracker: giữ ID + vị trí khung ổn định (không nhảy), chỉ hiện chữ
//     khi đã chắc chắn, ẩn ngay khi chữ gốc biến mất.
//  7. Lấy màu chữ / màu nền thật từ khung hình, thoại nhân vật = màu vàng.
//  8. SubtitleLayoutEngine: khung dịch neo đúng góc trái-trên chữ gốc, kéo dài sang
//     phải, tự xuống dòng, thu nhỏ chữ để không đè khung khác / nút bấm.
// ============================================================================

import Foundation
import Vision
import CoreGraphics
import UIKit
import SQLite3

// MARK: - Mô hình dữ liệu nội bộ

struct SSWord {
    var text: String
    var rect: CGRect          // toạ độ chuẩn hoá trên TOÀN khung hình, gốc trái-trên
}

struct SSLine {
    var text: String
    var confidence: Float
    var rect: CGRect
    var words: [SSWord]
}

struct SSStyle: Equatable {
    var textRGB: (Double, Double, Double)
    var backgroundRGB: (Double, Double, Double)
    var isBold: Bool

    static let fallback = SSStyle(textRGB: (1, 1, 1), backgroundRGB: (0.05, 0.05, 0.07), isBold: true)

    static func == (a: SSStyle, b: SSStyle) -> Bool {
        a.textRGB == b.textRGB && a.backgroundRGB == b.backgroundRGB && a.isBold == b.isBold
    }
}

/// 1 đơn vị chữ cần dịch + vẽ khung (1 khối thoại, 1 dòng menu hoặc 1 đoạn giữa 2 nút bấm)
struct SSPiece {
    var sourceText: String
    var speaker: String?
    var rect: CGRect
    var lineCount: Int
    var category: TextRegionCategory
    var confidence: Float
    var validRatio: Double
    var wordCount: Int
    /// Giới hạn mép phải (không được vẽ qua): mép trái của nút bấm kế tiếp
    var rightLimit: CGFloat?
}

// MARK: - Từ vựng game

enum GameVocabulary {
    /// Nút bấm tay cầm PS5 (so sánh chữ thường). Không dịch, không che.
    static let controllerTokens: Set<String> = [
        "l1", "l2", "l3", "r1", "r2", "r3", "x", "o", "✕", "✖", "×", "○", "◯", "△", "□", "▢", "⨯",
        "[x]", "[o]", "(x)", "(o)", "[l1]", "[r1]", "[l2]", "[r2]", "[l3]", "[r3]",
        "options", "touchpad", "create", "share", "ps", "d-pad", "dpad", "©", "®", "@"
    ]

    /// Từ tiếng Anh cơ bản game thủ đều hiểu -> đứng một mình thì KHÔNG cần dịch (giảm rối mắt)
    static let basicGamerWords: Set<String> = [
        "ok", "back", "start", "select", "menu", "pause", "hp", "mp", "sp", "xp", "exp", "lv", "lvl",
        "level", "yes", "no", "play", "next", "enter", "exit", "fps", "hud", "boss", "combo", "game",
        "new", "loading", "auto", "on", "off", "max", "min", "ps5", "ps4", "playstation", "online",
        "offline", "home", "ready", "go", "win", "lose", "victory", "game over", "the end"
    ]

    /// Hiệu ứng / thông số HUD không bao giờ dịch
    static let screenEffects: Set<String> = [
        "critical", "miss", "dodge", "parry", "slash", "boom", "bam", "hit", "hits", "fps", "hp", "mp"
    ]

    /// Từ điển menu / thao tác game hay gặp (khớp nguyên cụm đã chuẩn hoá)
    static let uiDictionary: [String: String] = [
        "press": "Nhấn", "hold": "Giữ", "tap": "Chạm", "release": "Thả",
        "to": "để", "or": "hoặc", "and": "và",
        "continue": "Tiếp tục", "resume": "Tiếp tục", "options": "Tuỳ chọn", "settings": "Cài đặt",
        "quit": "Thoát", "quit game": "Thoát trò chơi", "save": "Lưu", "load": "Tải", "load game": "Tải trò chơi",
        "new game": "Trò chơi mới", "chapter select": "Chọn chương", "chapters": "Các chương", "chapter": "Chương",
        "inventory": "Túi đồ", "map": "Bản đồ", "objective": "Mục tiêu", "objectives": "Mục tiêu",
        "examine": "Xem xét", "inspect": "Kiểm tra", "pick up": "Nhặt", "interact": "Tương tác",
        "open": "Mở", "close": "Đóng", "use": "Dùng", "equip": "Trang bị", "drop": "Bỏ",
        "confirm": "Xác nhận", "cancel": "Huỷ", "skip": "Bỏ qua", "retry": "Thử lại",
        "difficulty": "Độ khó", "easy": "Dễ", "normal": "Thường", "hard": "Khó",
        "subtitles": "Phụ đề", "audio": "Âm thanh", "controls": "Điều khiển", "display": "Hiển thị",
        "brightness": "Độ sáng", "language": "Ngôn ngữ", "credits": "Danh đề", "extras": "Bổ sung",
        "collectibles": "Vật phẩm sưu tầm", "clues": "Manh mối", "totems": "Vật tổ", "characters": "Nhân vật",
        "relationships": "Mối quan hệ", "traits": "Tính cách", "don't move": "Đừng cử động",
        "hide": "Trốn", "run": "Chạy", "aim": "Ngắm", "shoot": "Bắn", "reload": "Nạp đạn",
        "throw": "Ném", "climb": "Leo", "jump": "Nhảy", "crouch": "Ngồi xuống", "sprint": "Chạy nhanh",
        "attack": "Tấn công", "heavy attack": "Đòn mạnh", "light attack": "Đòn nhẹ", "block": "Đỡ đòn",
        "parry": "Đỡ phản", "dodge": "Né", "heal": "Hồi máu", "look": "Nhìn", "move": "Di chuyển",
        "zoom": "Phóng to", "rotate": "Xoay", "flip": "Lật", "read": "Đọc", "talk": "Nói chuyện",
        "follow": "Đi theo", "search": "Tìm kiếm", "previously": "Trước đó", "saving": "Đang lưu",
        "autosave": "Tự động lưu", "loading complete": "Tải xong", "press any button": "Nhấn nút bất kỳ"
    ]

    /// Tên riêng có sẵn (Until Dawn) - không dịch. Data Việt hoá có thể bổ sung qua bảng glossary.
    static let builtInNames: Set<String> = [
        "sam", "samantha", "mike", "michael", "jessica", "jess", "josh", "joshua", "chris", "christopher",
        "ashley", "emily", "em", "matt", "matthew", "hannah", "beth", "bethany", "hill", "alan",
        "washington", "blackwood", "jefferson", "billy", "bates", "stranger", "wendigo", "alberta",
        "ranger", "sanatorium", "mia", "lindsay"
    ]
}

// MARK: - Bộ lọc chữ "rác"

final class GameTextFilter {
    private var checker: UITextChecker?
    private var wordCache: [String: Bool] = [:]
    var extraNames: Set<String> = []

    struct Analysis {
        var isMeaningful: Bool
        var validRatio: Double
        var alphaWords: Int
        var dictionaryWords: Int
    }

    func isEnglishWord(_ raw: String) -> Bool {
        let w = raw.lowercased()
        if w.count <= 1 { return w == "a" || w == "i" }
        if let cached = wordCache[w] { return cached }
        if checker == nil { checker = UITextChecker() }
        let ns = w as NSString
        let range = checker!.rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: ns.length),
                                                   startingAt: 0, wrap: false, language: "en_US")
        let ok = range.location == NSNotFound
        if wordCache.count > 20000 { wordCache.removeAll() }
        wordCache[w] = ok
        return ok
    }

    func isName(_ raw: String) -> Bool {
        let w = raw.lowercased()
        return GameVocabulary.builtInNames.contains(w) || extraNames.contains(w)
    }

    /// Phân tích 1 dòng / 1 đoạn chữ xem có phải chữ thật cần dịch không
    func analyze(_ text: String) -> Analysis {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ký tự lạ đặc trưng của OCR đọc nhầm hoa văn / vệt sáng
        let junkChars = trimmed.filter { "{}<>\\~^_=`¦§¤".contains($0) }.count
        if junkChars > 0 { return Analysis(isMeaningful: false, validRatio: 0, alphaWords: 0, dictionaryWords: 0) }

        let nonSpace = trimmed.filter { !$0.isWhitespace }
        let letters = nonSpace.filter { $0.isLetter }
        if letters.count < 2 || Double(letters.count) / Double(max(1, nonSpace.count)) < 0.6 {
            return Analysis(isMeaningful: false, validRatio: 0, alphaWords: 0, dictionaryWords: 0)
        }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var alpha = 0, valid = 0, dict = 0
        for tok in tokens {
            let core = tok.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            guard core.contains(where: { $0.isLetter }) else { continue }
            if GameVocabulary.controllerTokens.contains(core.lowercased()) { continue }
            alpha += 1
            if Self.looksLikeGarbageToken(core) { continue }
            let plain = core.replacingOccurrences(of: "’", with: "'")
            if isEnglishWord(plain) || isEnglishWord(plain.replacingOccurrences(of: "'", with: "")) {
                valid += 1; dict += 1
            } else if isName(core) || Self.isProperNounCandidate(core) {
                valid += 1
            } else if core.count <= 3 && core.uppercased() == core {
                valid += 1 // từ viết tắt ngắn: HP, NPC, OK...
            }
        }
        guard alpha > 0 else { return Analysis(isMeaningful: false, validRatio: 0, alphaWords: 0, dictionaryWords: 0) }
        let ratio = Double(valid) / Double(alpha)
        let meaningful: Bool
        if alpha == 1 {
            meaningful = dict == 1 && letters.count >= 3
        } else {
            meaningful = ratio >= 0.65 && dict >= max(1, alpha / 3)
        }
        return Analysis(isMeaningful: meaningful, validRatio: ratio, alphaWords: alpha, dictionaryWords: dict)
    }

    /// "uKCTrTr4C", "li'i{'", "b3ng": trộn chữ-số, hoa-thường lộn xộn
    static func looksLikeGarbageToken(_ t: String) -> Bool {
        let chars = Array(t)
        let digits = chars.filter { $0.isNumber }.count
        let lettersCount = chars.filter { $0.isLetter }.count
        if digits > 0 && lettersCount > 0 {
            // cho phép 2nd, 10th, 3D, L1...
            let lower = t.lowercased()
            let okPatterns = ["st", "nd", "rd", "th", "d", "s", "x", "k", "m"]
            let letterPart = String(lower.filter { $0.isLetter })
            if !(okPatterns.contains(letterPart) || GameVocabulary.controllerTokens.contains(lower)) { return true }
        }
        // số lần đổi thường -> hoa bên trong từ
        var switches = 0
        for i in 1..<max(1, chars.count) where i < chars.count {
            if chars[i - 1].isLowercase && chars[i].isUppercase { switches += 1 }
        }
        if switches >= 2 { return true }
        if chars.count >= 2 && chars[0].isLowercase && chars.dropFirst().allSatisfy({ $0.isUppercase }) { return true }
        // 4 phụ âm/nguyên âm lặp kỳ lạ
        if t.count >= 4 && Set(t.lowercased()).count == 1 { return true }
        return false
    }

    static func isProperNounCandidate(_ t: String) -> Bool {
        guard let first = t.first, first.isUppercase, t.count >= 3 else { return false }
        let rest = t.dropFirst()
        return rest.allSatisfy { $0.isLowercase || $0 == "'" || $0 == "-" }
    }
}

// MARK: - OCR (Apple Vision) lấy toạ độ từng từ

final class SmartOCREngine {
    func recognize(cropped: CGImage, roi: CGRect, customWords: [String]) -> [SSLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Nhận cả tiếng Việt: chữ đã là tiếng Việt (giao diện PS5, game đã Việt hoá) sẽ được bỏ qua
        var langs = ["en-US"]
        if let supported = try? request.supportedRecognitionLanguages(), supported.contains("vi-VT") {
            langs.append("vi-VT")
        }
        request.recognitionLanguages = langs
        request.minimumTextHeight = 0.018
        if !customWords.isEmpty { request.customWords = Array(customWords.prefix(200)) }

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let observations = request.results else { return [] }

        func toFrame(_ b: CGRect) -> CGRect {
            let topY = 1.0 - b.origin.y - b.size.height
            return CGRect(x: roi.origin.x + b.origin.x * roi.size.width,
                          y: roi.origin.y + topY * roi.size.height,
                          width: b.size.width * roi.size.width,
                          height: b.size.height * roi.size.height)
        }

        var lines: [SSLine] = []
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let str = cand.string
            let lineRect = toFrame(obs.boundingBox)
            var words: [SSWord] = []
            var idx = str.startIndex
            while idx < str.endIndex {
                while idx < str.endIndex && str[idx].isWhitespace { idx = str.index(after: idx) }
                guard idx < str.endIndex else { break }
                var end = idx
                while end < str.endIndex && !str[end].isWhitespace { end = str.index(after: end) }
                let range = idx..<end
                if let box = try? cand.boundingBox(for: range) {
                    words.append(SSWord(text: String(str[range]), rect: toFrame(box.boundingBox)))
                }
                idx = end
            }
            if words.isEmpty {
                words = [SSWord(text: str, rect: lineRect)]
            }
            lines.append(SSLine(text: str, confidence: cand.confidence, rect: lineRect, words: words))
        }
        return lines
    }
}

// MARK: - Tách đoạn quanh nút bấm, gom dòng, nhận diện người nói

enum PieceBuilder {
    static let refW: CGFloat = 1280
    static let refH: CGFloat = 720

    static func isControllerToken(_ t: String) -> Bool {
        let core = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
        return GameVocabulary.controllerTokens.contains(core)
    }

    /// Chia 1 dòng thành các đoạn chữ nằm giữa các nút bấm / khoảng trống chứa icon
    static func segments(of line: SSLine, refW: CGFloat = 1280) -> [(words: [SSWord], rightLimit: CGFloat?)] {
        let words = line.words.sorted { $0.rect.minX < $1.rect.minX }
        let lineHpx = line.rect.height * refH
        var result: [(words: [SSWord], rightLimit: CGFloat?)] = []
        var current: [SSWord] = []

        for (i, w) in words.enumerated() {
            if isControllerToken(w.text) {
                if !current.isEmpty {
                    result.append((current, w.rect.minX - 0.004))
                    current = []
                }
                continue
            }
            if let prev = current.last ?? (i > 0 ? words[i - 1] : nil), !current.isEmpty {
                let gapPx = (w.rect.minX - prev.rect.maxX) * refW
                if gapPx > max(18, lineHpx * 1.5) {
                    // Khoảng trống lớn = icon nút bấm Vision không đọc được -> ngắt khung
                    result.append((current, prev.rect.maxX + (w.rect.minX - prev.rect.maxX) * 0.2))
                    current = []
                }
            }
            current.append(w)
        }
        if !current.isEmpty { result.append((current, nil)) }
        return result
    }

    static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    /// Nhận diện tên người nói ở đầu phụ đề: "[Ashley] ...", "IAshleyl ..." (OCR đọc [ ] thành I l), "Ashley: ..."
    static func extractSpeaker(_ text: String, filter: GameTextFilter) -> (speaker: String?, rest: String) {
        let pattern = "^\\s*([\\[\\(\\{|Il1])\\s?([A-Z][A-Za-z\\.\\-']{1,20}(?: [A-Z][A-Za-z\\.\\-']{1,20})?)\\s?([\\]\\)\\}|Il1:])\\s+(.+)$"
        if let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
           let r4 = Range(m.range(at: 4), in: text) {
            let open = String(text[r1])
            let name = String(text[r2])
            let realBracket = open == "[" || open == "(" || open == "{"
            let known = name.split(separator: " ").allSatisfy { filter.isName(String($0)) }
            if realBracket || known {
                return (name, String(text[r4]))
            }
        }
        // "Ashley: Hello"
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 22 {
            let name = text[..<colon].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.split(separator: " ").allSatisfy({ filter.isName(String($0)) }) {
                return (name, String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (nil, text)
    }

    static func classify(rect: CGRect, wordCount: Int, hasSpeaker: Bool) -> TextRegionCategory {
        if hasSpeaker { return .dialogue }
        if rect.midY >= 0.62 && abs(rect.midX - 0.5) < 0.25 && wordCount >= 3 { return .dialogue }
        if rect.midY <= 0.30 && (rect.midX <= 0.35 || rect.midX >= 0.65) { return .quest }
        return .menu
    }

    /// Dòng -> các khối cần dịch
    static func buildPieces(lines rawLines: [SSLine], filter: GameTextFilter, refW: CGFloat = 1280) -> [SSPiece] {
        var plainLines: [SSLine] = []
        var pieces: [SSPiece] = []

        for line in rawLines {
            guard line.confidence >= 0.45 else { continue }
            if TranslationMemory.hasVietnameseMarks(line.text) { continue }   // đã là tiếng Việt
            let hPx = line.rect.height * refH
            guard hPx >= 9, hPx <= 90 else { continue }   // quá nhỏ (số HUD) hoặc quá to (vệt sáng)

            let segs = segments(of: line, refW: refW)
            if segs.count == 1 && segs[0].rightLimit == nil && segs[0].words.count == line.words.count {
                plainLines.append(line)
                continue
            }
            // Dòng có nút bấm: mỗi đoạn là 1 khung riêng, không gom với dòng khác
            for seg in segs {
                let text = seg.words.map { $0.text }.joined(separator: " ")
                let a = filter.analyze(text)
                let norm = TranslationMemory.normalize(text)
                let isUI = GameVocabulary.uiDictionary[norm] != nil
                guard a.isMeaningful || isUI else { continue }
                let rect = union(seg.words.map { $0.rect })
                pieces.append(SSPiece(sourceText: text, speaker: nil, rect: rect, lineCount: 1,
                                      category: classify(rect: rect, wordCount: a.alphaWords, hasSpeaker: false),
                                      confidence: line.confidence, validRatio: a.validRatio,
                                      wordCount: a.alphaWords, rightLimit: seg.rightLimit))
            }
        }

        // Gom các dòng thường thành khối (phụ đề 2 dòng, đoạn mô tả...)
        let sorted = plainLines.sorted { $0.rect.minY < $1.rect.minY }
        var blocks: [[SSLine]] = []
        for line in sorted {
            let lineWords = line.words.count
            var merged = false
            for i in (0..<blocks.count).reversed() {
                guard let last = blocks[i].last else { continue }
                let lastWords = last.words.count
                let hA = last.rect.height, hB = line.rect.height
                let similarH = abs(hA - hB) < max(hA, hB) * 0.35
                let gap = line.rect.minY - last.rect.maxY
                let closeV = gap >= -hA * 0.3 && gap <= hA * 0.9
                let centerAligned = abs(line.rect.midX - last.rect.midX) < 0.06
                let leftAligned = abs(line.rect.minX - last.rect.minX) < 0.025
                let overlapX = min(line.rect.maxX, last.rect.maxX) - max(line.rect.minX, last.rect.minX) > 0
                let endsItem = last.text.hasSuffix(":")
                if lastWords >= 2 && lineWords >= 2 && similarH && closeV && (centerAligned || leftAligned) && overlapX && !endsItem {
                    blocks[i].append(line)
                    merged = true
                    break
                }
            }
            if !merged { blocks.append([line]) }
        }

        for block in blocks {
            let joined = block.map { $0.text }.joined(separator: " ")
            let (speaker, rest) = extractSpeaker(joined, filter: filter)
            let a = filter.analyze(rest)
            let norm = TranslationMemory.normalize(rest)
            if GameVocabulary.basicGamerWords.contains(norm) { continue }
            if GameVocabulary.screenEffects.contains(norm) { continue }
            let isUI = GameVocabulary.uiDictionary[norm] != nil
            guard a.isMeaningful || isUI else { continue }
            let rect = union(block.map { $0.rect })
            let conf = block.map { $0.confidence }.min() ?? 0
            pieces.append(SSPiece(sourceText: rest, speaker: speaker, rect: rect, lineCount: block.count,
                                  category: classify(rect: rect, wordCount: a.alphaWords, hasSpeaker: speaker != nil),
                                  confidence: conf, validRatio: a.validRatio, wordCount: a.alphaWords, rightLimit: nil))
        }
        return pieces
    }
}

// MARK: - Bộ nhớ dịch (Data Việt hoá .sqlite)

struct TranslationDBReport {
    var schema: String = "Chưa nạp"
    var totalRows: Int = 0
    var validPairs: Int = 0
    var identicalRows: Int = 0
    var emptyRows: Int = 0
    var namesLoaded: Int = 0

    var summary: String {
        if totalRows == 0 { return "Chưa có data Việt hoá" }
        if validPairs == 0 {
            return "⚠️ Data lỗi: \(totalRows) dòng nhưng 0 cặp Anh→Việt (\(identicalRows) dòng có bản dịch giống hệt câu gốc). App sẽ dùng dịch AI."
        }
        var s = "Data: \(validPairs) cặp Anh→Việt hợp lệ / \(totalRows) dòng"
        if identicalRows > 0 { s += " (\(identicalRows) dòng chưa dịch bị bỏ qua)" }
        return s
    }
}

final class TranslationMemory {
    private let lock = NSLock()
    private var entries: [(norm: String, tokens: [String], vi: String)] = []
    private var exact: [String: Int] = [:]
    private var inverted: [String: [Int]] = [:]
    private(set) var names: Set<String> = []
    private(set) var report = TranslationDBReport()

    // ---- Chuẩn hoá (PHẢI GIỐNG tools/vietsub_db_tool.py) ----
    private static let reSpeaker = try! NSRegularExpression(pattern: "^\\s*\\[[^\\]]{1,24}\\]\\s*")
    private static let reBreak = try! NSRegularExpression(pattern: "<\\s*(cr|br)\\s*/?>", options: [.caseInsensitive])
    private static let reTag = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let rePlaceholder = try! NSRegularExpression(pattern: "\\{\\d+\\}")

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    static func normalize(_ input: String) -> String {
        var s = input.precomposedStringWithCanonicalMapping
        s = replace(reSpeaker, in: s, with: "")
        s = replace(reBreak, in: s, with: " ")
        s = replace(reTag, in: s, with: "")
        s = replace(rePlaceholder, in: s, with: " ")
        s = s.lowercased()
        s = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
             .replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: "´", with: "'")
        s = s.replacingOccurrences(of: "'", with: "")
        let mapped = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// Làm sạch câu tiếng Việt để hiển thị (bỏ <Italic>, đổi <cr> thành xuống dòng)
    static func cleanDisplay(_ vi: String) -> String {
        var s = replace(reBreak, in: vi, with: "\n")
        s = replace(reTag, in: s, with: "")
        s = s.replacingOccurrences(of: "\n\n", with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasVietnameseMarks(_ s: String) -> Bool {
        s.range(of: "[àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ]",
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    // ---- Nạp data ----
    @discardableResult
    func load(url: URL) -> TranslationDBReport {
        var newEntries: [(norm: String, tokens: [String], vi: String)] = []
        var newNames: Set<String> = []
        var rep = TranslationDBReport()

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let conn = db else {
            if let d = db { sqlite3_close(d) }
            install(entries: [], names: [], report: rep)
            return rep
        }
        defer { sqlite3_close(conn) }

        func query(_ sql: String, _ row: ([String?]) -> Void) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
            defer { sqlite3_finalize(s) }
            let n = sqlite3_column_count(s)
            while sqlite3_step(s) == SQLITE_ROW {
                var cols: [String?] = []
                for i in 0..<n {
                    cols.append(sqlite3_column_text(s, i).map { String(cString: $0) })
                }
                row(cols)
            }
        }
        func columns(of table: String) -> [String] {
            var names: [String] = []
            query("PRAGMA table_info(\"\(table)\")") { cols in
                if cols.count > 1, let n = cols[1] { names.append(n) }
            }
            return names
        }

        var tables: [String] = []
        query("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'") { c in
            if let n = c.first ?? nil { tables.append(n) }
        }

        // Chọn bảng + cột Anh/Việt
        let enAliases = ["en", "english", "en_raw", "original_text", "original", "source", "source_text", "text_raw", "text_en"]
        let viAliases = ["vi", "vietnamese", "vi_text", "translated_text", "translation", "target", "target_text", "text_vi"]
        var chosen: (table: String, en: String, vi: String)?
        let preferred = ["translations_v2", "translations", "subtitles", "subtitles_fts"]
        let ordered = preferred.filter { tables.contains($0) } + tables.filter { !preferred.contains($0) }
        for t in ordered where !t.hasSuffix("_data") && !t.hasSuffix("_idx") && !t.hasSuffix("_content")
            && !t.hasSuffix("_docsize") && !t.hasSuffix("_config") && t != "glossary" && t != "meta" {
            let cols = columns(of: t).map { $0.lowercased() }
            if let e = enAliases.first(where: { cols.contains($0) }), let v = viAliases.first(where: { cols.contains($0) }) {
                chosen = (t, e, v)
                break
            }
        }

        if let c = chosen {
            rep.schema = "\(c.table)(\(c.en) → \(c.vi))"
            query("SELECT \"\(c.en)\", \"\(c.vi)\" FROM \"\(c.table)\"") { cols in
                rep.totalRows += 1
                guard let en = cols[0] ?? nil, let vi = cols.count > 1 ? cols[1] : nil, !en.isEmpty, !vi.isEmpty else {
                    rep.emptyRows += 1
                    return
                }
                let n = Self.normalize(en)
                let nv = Self.normalize(vi)
                guard !n.isEmpty else { rep.emptyRows += 1; return }
                if n == nv || (Self.hasVietnameseMarks(en) && !Self.hasVietnameseMarks(vi)) {
                    rep.identicalRows += 1
                    return
                }
                let toks = n.split(separator: " ").map(String.init)
                newEntries.append((n, toks, Self.cleanDisplay(vi)))
            }
        }
        rep.validPairs = newEntries.count

        if tables.contains("glossary") {
            let cols = columns(of: "glossary").map { $0.lowercased() }
            if cols.contains("term") {
                query("SELECT term FROM glossary") { c in
                    if let t = c.first ?? nil {
                        for w in t.lowercased().split(separator: " ") { newNames.insert(String(w)) }
                    }
                }
            }
        }
        rep.namesLoaded = newNames.count
        install(entries: newEntries, names: newNames, report: rep)
        return rep
    }

    private func install(entries newEntries: [(norm: String, tokens: [String], vi: String)], names: Set<String>, report rep: TranslationDBReport) {
        var ex: [String: Int] = [:]
        var inv: [String: [Int]] = [:]
        for (i, e) in newEntries.enumerated() {
            if ex[e.norm] == nil { ex[e.norm] = i }
            for t in Set(e.tokens) where t.count >= 3 {
                inv[t, default: []].append(i)
            }
        }
        lock.lock()
        entries = newEntries
        exact = ex
        inverted = inv
        self.names = names
        report = rep
        lock.unlock()
    }

    // ---- Tra cứu ----
    func lookup(_ english: String) -> String? {
        let n = Self.normalize(english)
        guard !n.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let i = exact[n] { return entries[i].vi }

        let qTokens = n.split(separator: " ").map(String.init)
        guard qTokens.count >= 2 else { return nil }
        var counts: [Int: Int] = [:]
        for t in Set(qTokens) where t.count >= 3 {
            if let list = inverted[t], list.count < 4000 {
                for i in list { counts[i, default: 0] += 1 }
            }
        }
        let candidates = counts.sorted { $0.value > $1.value }.prefix(40)
        var best: (score: Double, idx: Int) = (0, -1)
        for (idx, _) in candidates {
            let s = Self.similarity(qTokens, entries[idx].tokens)
            if s > best.score { best = (s, idx) }
        }
        // Khớp gần đúng (OCR sai vài ký tự) hoặc phụ đề mới hiện một phần của câu dài
        if best.idx >= 0 && best.score >= 0.80 { return entries[best.idx].vi }
        if best.idx >= 0 && qTokens.count >= 4 {
            let cand = entries[best.idx].tokens
            let covered = Double(qTokens.filter { q in cand.contains(where: { Self.tokenEqual(q, $0) }) }.count) / Double(qTokens.count)
            if covered >= 0.92 && Double(cand.count) <= Double(qTokens.count) * 2.2 { return entries[best.idx].vi }
        }
        return nil
    }

    static func tokenEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 5 && b.count >= 5 && abs(a.count - b.count) <= 1 { return levenshtein(a, b) <= 1 }
        return false
    }

    static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var used = [Bool](repeating: false, count: b.count)
        var common = 0
        for x in a {
            if let j = b.indices.first(where: { !used[$0] && tokenEqual(x, b[$0]) }) {
                used[j] = true
                common += 1
            }
        }
        return 2.0 * Double(common) / Double(a.count + b.count)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...max(1, x.count) where i <= x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...max(1, y.count) where j <= y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}

// MARK: - Dịch AI online (dự phòng) - GIỮ NGUYÊN TÊN RIÊNG

final class OnlineFallbackTranslator {
    static let shared = OnlineFallbackTranslator()
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var pending: Set<String> = []
    private let cacheURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ai_translation_cache_v111.json")
    }()
    private var dirty = false

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = dict
        }
    }

    func cached(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// Gửi dịch; protectedWords = tên riêng giữ nguyên. completion chạy ở luồng nền.
    func request(text: String, key: String, protectedWords: [String], completion: @escaping (String) -> Void) {
        lock.lock()
        if pending.contains(key) || cache[key] != nil { lock.unlock(); return }
        pending.insert(key)
        lock.unlock()

        // Thay tên riêng bằng mã giữ chỗ để máy dịch không dịch tên
        var working = text
        var slots: [(String, String)] = []
        for (i, word) in protectedWords.enumerated() {
            let token = "ZQX\(i)Q"
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
            if working.range(of: pattern, options: .regularExpression) != nil {
                working = working.replacingOccurrences(of: pattern, with: token, options: .regularExpression)
                slots.append((token, word))
            }
        }

        guard let encoded = working.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=vi&dt=t&q=\(encoded)") else {
            finish(key: key, value: nil)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let parts = json.first as? [[Any]] else {
                self.finish(key: key, value: nil)
                return
            }
            var vi = parts.compactMap { $0.first as? String }.joined()
            for (token, word) in slots {
                vi = vi.replacingOccurrences(of: token, with: word, options: .caseInsensitive)
            }
            vi = vi.trimmingCharacters(in: .whitespacesAndNewlines)
            self.finish(key: key, value: vi.isEmpty ? nil : vi)
            if !vi.isEmpty { completion(vi) }
        }.resume()
    }

    private func finish(key: String, value: String?) {
        lock.lock()
        pending.remove(key)
        if let v = value {
            cache[key] = v
            dirty = true
        }
        let shouldSave = dirty && cache.count % 10 == 0
        let snapshot = shouldSave ? cache : [:]
        if shouldSave { dirty = false }
        lock.unlock()
        if shouldSave, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    func store(key: String, value: String) {
        lock.lock()
        cache[key] = value
        dirty = true
        lock.unlock()
    }

    func persist() {
        lock.lock()
        let snapshot = cache
        dirty = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

// MARK: - Lấy màu chữ / màu nền thật từ khung hình

enum StyleSampler {
    static func sample(frame: CGImage, rect: CGRect) -> SSStyle {
        let W = CGFloat(frame.width), H = CGFloat(frame.height)
        let px = CGRect(x: rect.minX * W, y: rect.minY * H, width: rect.width * W, height: rect.height * H).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard px.width >= 4, px.height >= 4, let crop = frame.cropping(to: px) else { return .fallback }

        let sw = max(8, min(120, Int(px.width / 2)))
        let sh = max(4, min(40, Int(px.height / 2)))
        var buf = [UInt8](repeating: 0, count: sw * sh * 4)
        let drawn: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            return true
        }
        guard drawn else { return .fallback }

        let n = sw * sh
        var lum = [Double](repeating: 0, count: n)
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<n {
            let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            lum[i] = l
            hist[min(255, Int(l))] += 1
        }
        // Ngưỡng Otsu tách 2 lớp: chữ / nền
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 128
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = n - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        var hi = (0.0, 0.0, 0.0, 0), lo = (0.0, 0.0, 0.0, 0)
        for i in 0..<n {
            let r = Double(buf[i * 4]) / 255, g = Double(buf[i * 4 + 1]) / 255, b = Double(buf[i * 4 + 2]) / 255
            if lum[i] > Double(threshold) { hi = (hi.0 + r, hi.1 + g, hi.2 + b, hi.3 + 1) }
            else { lo = (lo.0 + r, lo.1 + g, lo.2 + b, lo.3 + 1) }
        }
        guard hi.3 > 0, lo.3 > 0 else { return .fallback }
        let hiC = (hi.0 / Double(hi.3), hi.1 / Double(hi.3), hi.2 / Double(hi.3))
        let loC = (lo.0 / Double(lo.3), lo.1 / Double(lo.3), lo.2 / Double(lo.3))
        // Chữ thường chiếm ít điểm ảnh hơn nền
        let textIsBright = hi.3 <= lo.3
        let textFrac = Double(textIsBright ? hi.3 : lo.3) / Double(n)
        return SSStyle(textRGB: textIsBright ? hiC : loC,
                       backgroundRGB: textIsBright ? loC : hiC,
                       isBold: textFrac > 0.22)
    }

    /// Ảnh xám rất nhỏ của vùng chữ để phát hiện chữ gốc đã biến mất
    static func thumbnail(frame: CGImage, rect: CGRect) -> [UInt8] {
        let W = CGFloat(frame.width), H = CGFloat(frame.height)
        let px = CGRect(x: rect.minX * W, y: rect.minY * H, width: rect.width * W, height: rect.height * H).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard px.width >= 4, px.height >= 4, let crop = frame.cropping(to: px) else { return [] }
        let tw = 24, th = 6
        var buf = [UInt8](repeating: 0, count: tw * th)
        let drawn: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: tw, height: th))
            return true
        }
        return drawn ? buf : []
    }

    static func thumbDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 999 }
        var s = 0
        for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }

    static func hex(_ c: (Double, Double, Double)) -> String {
        String(format: "#%02X%02X%02X", Int(max(0, min(1, c.0)) * 255), Int(max(0, min(1, c.1)) * 255), Int(max(0, min(1, c.2)) * 255))
    }
}

// MARK: - Theo dõi khung chữ ổn định (không nhảy, không nhấp nháy)

final class TrackedPiece {
    let id: String
    var key: String
    var piece: SSPiece
    var translation: String?
    var fromDatabase = false
    var hits = 1
    var misses = 0
    var thumb: [UInt8] = []
    var style: SSStyle = .fallback

    init(id: String, key: String, piece: SSPiece) {
        self.id = id
        self.key = key
        self.piece = piece
    }

    var requiredHits: Int {
        if fromDatabase { return 1 }
        if piece.wordCount <= 1 { return 3 }
        if piece.confidence >= 0.8 && piece.validRatio >= 0.85 && piece.wordCount >= 3 { return 1 }
        return 2
    }

    var isVisible: Bool { translation != nil && hits >= requiredHits }
}

// MARK: - Bố cục khung dịch (neo vị trí gốc, kéo sang phải, xuống dòng, không đè)

enum SubtitleLayoutEngine {
    static let refW: CGFloat = 1280
    static let refH: CGFloat = 720
    static let dialogueYellow = (1.0, 0.86, 0.10)

    static func layout(_ items: [TrackedPiece], refW: CGFloat = 1280) -> [TranslatedBox] {
        var out: [TranslatedBox] = []
        for item in items {
            guard let vi = item.translation else { continue }
            let p = item.piece
            let display = p.speaker.map { "[\($0)] \(vi)" } ?? vi
            let lineHpx = p.rect.height * refH / CGFloat(max(1, p.lineCount))
            let baseFont = max(9, min(64, lineHpx * 0.80))
            let isBold = item.style.isBold || p.category == .dialogue

            let padX = baseFont * 0.30, padY = baseFont * 0.10
            let originX = p.rect.minX * refW - padX
            let originY = p.rect.minY * refH - padY
            let minW = p.rect.width * refW + padX * 2
            let minH = p.rect.height * refH + padY * 2

            // Giới hạn phải: nút bấm kế tiếp, khung khác cùng hàng, mép màn hình
            var rightLimit = refW - 4
            if let r = p.rightLimit { rightLimit = min(rightLimit, r * refW) }
            var bottomLimit = refH - 2
            for other in items where other !== item {
                let o = other.piece.rect
                let vOverlap = min(o.maxY, p.rect.maxY) - max(o.minY, p.rect.minY) > 0
                if vOverlap && o.minX >= p.rect.maxX - 0.002 { rightLimit = min(rightLimit, o.minX * refW - 3) }
                let hOverlap = min(o.maxX, p.rect.maxX) - max(o.minX, p.rect.minX) > 0
                if hOverlap && o.minY >= p.rect.maxY - 0.002 { bottomLimit = min(bottomLimit, o.minY * refH - 2) }
            }
            let maxW = max(minW, rightLimit - originX)
            let maxH = max(minH, bottomLimit - originY)

            var scale: CGFloat = 1.0
            var boxW = minW, boxH = minH
            while true {
                let font = UIFont.systemFont(ofSize: baseFont * scale, weight: isBold ? .semibold : .medium)
                let bounds = (display as NSString).boundingRect(
                    with: CGSize(width: maxW - padX * 2, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font], context: nil)
                boxW = max(minW, ceil(bounds.width) + padX * 2 + 2)
                boxH = max(minH, ceil(bounds.height) + padY * 2)
                if boxH <= maxH + 1 || scale <= 0.62 { break }
                scale -= 0.06
            }
            boxW = min(boxW, maxW)

            let textRGB = p.category == .dialogue ? dialogueYellow : item.style.textRGB
            var box = TranslatedBox(
                text: display,
                x: Double(originX / refW), y: Double(originY / refH),
                w: Double(boxW / refW), h: Double(boxH / refH),
                category: p.category.rawValue,
                isAITranslated: !item.fromDatabase
            )
            box.stableID = item.id
            box.fontSizeNorm = Double(baseFont * scale / refH)
            box.textColorHex = StyleSampler.hex(textRGB)
            box.backgroundColorHex = StyleSampler.hex(item.style.backgroundRGB)
            box.isBold = isBold
            out.append(box)
        }
        return out
    }
}

// MARK: - Bộ máy tổng

final class SmartSubtitleEngine {
    let memory = TranslationMemory()
    let online = OnlineFallbackTranslator.shared
    private let filter = GameTextFilter()
    private let ocr = SmartOCREngine()
    private let queue = DispatchQueue(label: "ps5translator.smartsubtitle", qos: .userInitiated)
    private var tracked: [TrackedPiece] = []
    private var nextID = 1
    private var lastFrame: CGImage?
    private var busy = false

    var useOnlineAI = true
    /// 1.12: chọn bộ dịch AI (Apple Intelligence trên máy / Google online)
    var engineMode: TranslationEngineMode = .appleThenGoogle
    /// Tên game đang chơi (ngữ cảnh cho AI)
    var gameTitle: String = ""
    private var frameRefW: CGFloat = 1280
    private var recentDialogue: [String] = []
    /// Gọi khi bản dịch AI về muộn -> cập nhật khung ngay không đợi lần quét sau
    var onAsyncUpdate: (([TranslatedBox]) -> Void)?

    func loadDatabase(url: URL) -> TranslationDBReport {
        let rep = memory.load(url: url)
        queue.async {
            self.filter.extraNames = self.memory.names
            self.tracked.removeAll()
        }
        return rep
    }

    var isBusy: Bool { busy }

    /// Xử lý 1 khung hình. completion trên luồng nền: (các khung dịch, chữ gốc tóm tắt)
    func process(frame: CGImage, cropped: CGImage, roi: CGRect, completion: @escaping ([TranslatedBox], String) -> Void) {
        busy = true
        queue.async {
            defer { self.busy = false }
            self.lastFrame = frame
            // Hệ toạ độ tham chiếu cao 720, rộng theo tỉ lệ khung hình (YouTube có video dọc / vuông)
            self.frameRefW = 720 * CGFloat(frame.width) / CGFloat(max(1, frame.height))
            let names = Array(GameVocabulary.builtInNames.union(self.memory.names)).map { $0.capitalized }
            let lines = self.ocr.recognize(cropped: cropped, roi: roi, customWords: names)
            let pieces = PieceBuilder.buildPieces(lines: lines, filter: self.filter, refW: self.frameRefW)
            self.updateTracking(with: pieces, frame: frame)
            let visible = self.tracked.filter { $0.isVisible }
            let boxes = SubtitleLayoutEngine.layout(visible, refW: self.frameRefW)
            let summary = visible.isEmpty
                ? (lines.isEmpty ? "Màn hình không có chữ" : "Đã lọc \(lines.count) dòng chữ rác / chưa cần dịch")
                : visible.map { $0.piece.sourceText }.joined(separator: " | ")
            completion(boxes, summary)
        }
    }

    func reset() {
        queue.async { self.tracked.removeAll() }
    }

    private func updateTracking(with pieces: [SSPiece], frame: CGImage) {
        var matchedIDs = Set<String>()
        for piece in pieces {
            let key = TranslationMemory.normalize(piece.sourceText)
            guard !key.isEmpty else { continue }
            let keyTokens = key.split(separator: " ").map(String.init)

            var bestMatch: TrackedPiece?
            var bestScore = 0.0
            for t in tracked where !matchedIDs.contains(t.id) {
                let dist = hypot(t.piece.rect.midX - piece.rect.midX, t.piece.rect.midY - piece.rect.midY)
                guard dist < max(0.06, piece.rect.height * 2.5) else { continue }
                let sim = t.key == key ? 1.0 : TranslationMemory.similarity(keyTokens, t.key.split(separator: " ").map(String.init))
                let score = sim - Double(dist)
                if sim >= 0.6 && score > bestScore { bestScore = score; bestMatch = t }
            }

            if let t = bestMatch {
                matchedIDs.insert(t.id)
                t.hits += 1
                t.misses = 0
                let r = t.piece.rect, n = piece.rect
                let moved = abs(r.minX - n.minX) > 0.012 || abs(r.minY - n.minY) > 0.012
                    || abs(r.width - n.width) > 0.03 || abs(r.height - n.height) > 0.02
                var updated = piece
                if !moved { updated.rect = r }   // giữ nguyên vị trí -> khung không rung
                let textChanged = t.key != key && TranslationMemory.similarity(keyTokens, t.key.split(separator: " ").map(String.init)) < 0.95
                t.piece = updated
                if moved { t.style = StyleSampler.sample(frame: frame, rect: piece.rect) }
                t.thumb = StyleSampler.thumbnail(frame: frame, rect: t.piece.rect)
                if textChanged {
                    t.key = key
                    t.translation = nil
                    translate(t)
                } else if t.translation == nil {
                    translate(t)
                }
            } else {
                let t = TrackedPiece(id: "ss\(nextID)", key: key, piece: piece)
                nextID += 1
                t.style = StyleSampler.sample(frame: frame, rect: piece.rect)
                t.thumb = StyleSampler.thumbnail(frame: frame, rect: piece.rect)
                translate(t)
                tracked.append(t)
                matchedIDs.insert(t.id)
            }
        }

        // Khung không còn thấy trong lần quét này
        tracked.removeAll { t in
            guard !matchedIDs.contains(t.id) else { return false }
            t.misses += 1
            let now = StyleSampler.thumbnail(frame: frame, rect: t.piece.rect)
            let vanished = StyleSampler.thumbDiff(now, t.thumb) > 16
            return vanished || t.misses >= 2 || !t.isVisible
        }
    }

    private func translate(_ t: TrackedPiece) {
        let src = t.piece.sourceText
        if let vi = memory.lookup(src) {
            t.translation = vi
            t.fromDatabase = true
            return
        }
        if let vi = GameVocabulary.uiDictionary[t.key] {
            t.translation = vi
            t.fromDatabase = true
            return
        }
        let aiKey = "ai|" + t.key
        let preferApple = engineMode == .appleThenGoogle || engineMode == .appleOnly
        if preferApple, let vi = online.cached(aiKey) {
            t.translation = vi
            return
        }
        if engineMode != .appleOnly, let vi = online.cached(t.key) {
            t.translation = vi
            return
        }
        guard useOnlineAI, engineMode != .offline else { return }
        // Tên riêng: tên có sẵn + từ viết hoa giữa câu không có trong từ điển tiếng Anh
        var protected: [String] = []
        let words = src.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        for (i, w) in words.enumerated() where !w.isEmpty {
            if filter.isName(w) || (i > 0 && GameTextFilter.isProperNounCandidate(w) && !filter.isEnglishWord(w.lowercased())) {
                if !protected.contains(w) { protected.append(w) }
            }
        }
        let key = t.key
        let deliver: (String) -> Void = { [weak self] vi in
            guard let self = self else { return }
            self.queue.async {
                var changed = false
                for item in self.tracked where item.key == key && item.translation == nil {
                    item.translation = vi
                    changed = true
                }
                if changed {
                    let boxes = SubtitleLayoutEngine.layout(self.tracked.filter { $0.isVisible }, refW: self.frameRefW)
                    self.onAsyncUpdate?(boxes)
                }
            }
        }
        let google: () -> Void = { [weak self] in
            self?.online.request(text: src, key: key, protectedWords: protected, completion: deliver)
        }

        if preferApple && OnDeviceAITranslator.shared.isAvailable {
            let context = AITranslationContext(
                gameTitle: gameTitle,
                category: t.piece.category,
                speaker: t.piece.speaker,
                protectedWords: protected + Array(memory.names.prefix(40)).map { $0.capitalized },
                previousLines: recentDialogue
            )
            if t.piece.category == .dialogue {
                recentDialogue.append(src)
                if recentDialogue.count > 3 { recentDialogue.removeFirst() }
            }
            let mode = engineMode
            OnDeviceAITranslator.shared.translate(src, key: aiKey, context: context) { [weak self] vi in
                if let vi = vi {
                    self?.online.store(key: aiKey, value: vi)
                    deliver(vi)
                } else if mode == .appleThenGoogle {
                    google()
                }
            }
        } else if engineMode != .appleOnly {
            google()
        }
    }
}
