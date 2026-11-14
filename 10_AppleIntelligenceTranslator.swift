// ============================================================================
// FILE 10: 10_AppleIntelligenceTranslator.swift
// PHIÊN BẢN: PS5Translator 1.12
//
// Dịch bằng Apple Intelligence CHẠY TRÊN IPHONE (Foundation Models, iOS 26+).
// - Không cần Internet, hiểu ngữ cảnh: tên game, thoại / menu / nhiệm vụ, người nói,
//   các câu thoại trước đó, danh sách tên riêng phải giữ nguyên.
// - Máy không hỗ trợ (chưa iOS 26, chưa bật Apple Intelligence, máy đời cũ, model chưa
//   tải xong, hoặc model từ chối câu) -> tự chuyển sang Google Dịch (nếu được chọn).
// ============================================================================

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum TranslationEngineMode: String, CaseIterable, Identifiable {
    case appleThenGoogle
    case appleOnly
    case googleOnly
    case offline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleThenGoogle: return "Dùng chung tất cả (khuyên dùng)"
        case .appleOnly: return "Data + Apple Intelligence"
        case .googleOnly: return "Data + Google Dịch"
        case .offline: return "Chỉ data Việt hoá"
        }
    }

    var detail: String {
        switch self {
        case .appleThenGoogle: return "Thứ tự: Data Việt hoá → Apple Intelligence → Google Dịch. Câu có trong data lấy data; câu không có (lựa chọn, câu thiếu tiếng Anh) dịch bằng AI trên iPhone; AI không dịch được hoặc quá chậm thì dùng Google."
        case .appleOnly: return "Data Việt hoá → Apple Intelligence. Không gửi chữ lên Internet."
        case .googleOnly: return "Data Việt hoá → Google Dịch (qua Internet, kém hiểu ngữ cảnh game hơn)."
        case .offline: return "Chỉ hiện câu có trong data Việt hoá và từ điển menu. Lựa chọn / câu thiếu trong data sẽ KHÔNG được dịch."
        }
    }
}

struct AITranslationContext {
    var gameTitle: String
    var category: TextRegionCategory
    var speaker: String?
    var protectedWords: [String]
    var previousLines: [String]
}

final class OnDeviceAITranslator {
    static let shared = OnDeviceAITranslator()

    private let lock = NSLock()
    private var pending: Set<String> = []
    private var inFlight = 0
    private var waiting: [(text: String, key: String, context: AITranslationContext, completion: (String?) -> Void)] = []
    private let maxConcurrent = 2
    private let maxWaiting = 6

    /// Trạng thái hiển thị trong app
    var statusText: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return supportsVietnamese
                    ? "✅ Apple Intelligence sẵn sàng (dịch trên máy)"
                    : "⚠️ Apple Intelligence trên máy này chưa hỗ trợ tiếng Việt → dùng Google"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "❌ iPhone này không hỗ trợ Apple Intelligence → dùng Google"
                case .appleIntelligenceNotEnabled: return "⚠️ Chưa bật Apple Intelligence (Cài đặt > Apple Intelligence & Siri)"
                case .modelNotReady: return "⏳ Apple Intelligence đang tải model, thử lại sau ít phút"
                @unknown default: return "⚠️ Apple Intelligence chưa sẵn sàng"
                }
            @unknown default:
                return "⚠️ Apple Intelligence chưa sẵn sàng"
            }
        }
        return "❌ Cần iOS 26 trở lên để dùng Apple Intelligence → dùng Google"
        #else
        return "❌ Bản build chưa có Foundation Models (cần Xcode 26) → dùng Google"
        #endif
    }

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return supportsVietnamese }
        }
        #endif
        return false
    }

    private var supportsVietnamese: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let langs = SystemLanguageModel.default.supportedLanguages
            return langs.contains { $0.languageCode?.identifier == "vi" }
        }
        #endif
        return false
    }

    /// completion: bản dịch, hoặc nil nếu không dịch được (để chuyển sang Google)
    func translate(_ text: String, key: String, context: AITranslationContext, completion: @escaping (String?) -> Void) {
        lock.lock()
        if pending.contains(key) { lock.unlock(); return }
        pending.insert(key)
        if inFlight >= maxConcurrent {
            waiting.append((text, key, context, completion))
            // Ưu tiên câu mới nhất trên màn hình: bỏ câu cũ đang chờ quá lâu
            if waiting.count > maxWaiting {
                let dropped = waiting.removeFirst()
                pending.remove(dropped.key)
                lock.unlock()
                dropped.completion(nil)
                return
            }
            lock.unlock()
            return
        }
        inFlight += 1
        lock.unlock()
        run(text, key: key, context: context, completion: completion)
    }

    private func run(_ text: String, key: String, context: AITranslationContext, completion: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let prompt = Self.buildPrompt(text, context: context)
            Task.detached(priority: .userInitiated) { [weak self] in
                var result: String?
                do {
                    let session = LanguageModelSession(instructions: """
                    Bạn là dịch giả Việt hoá game chuyên nghiệp. Nhiệm vụ: dịch chữ tiếng Anh xuất hiện trong game sang tiếng Việt.
                    Quy tắc:
                    - Dịch tự nhiên, đúng ngữ cảnh game. Lời thoại dùng văn nói, xưng hô hợp với nhân vật trẻ (tớ/cậu, tao/mày khi cãi nhau, anh/em khi thân mật).
                    - Menu, nút, nhiệm vụ: dịch ngắn gọn như trong game Việt hoá.
                    - GIỮ NGUYÊN tên riêng (tên người, địa danh, tên vật phẩm riêng), tên nút tay cầm (L1, R2, X, O...), con số.
                    - KHÔNG được bỏ bớt tên người có trong câu gốc: câu gốc có "Sam" thì câu dịch cũng phải có "Sam".
                    - Chỉ trả về đúng câu tiếng Việt, không giải thích, không thêm dấu ngoặc kép.
                    """)
                    let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
                    result = Self.clean(response.content, original: text)
                } catch {
                    result = nil   // từ chối / lỗi -> để Google dịch
                }
                self?.finish(key: key)
                completion(result)
            }
            return
        }
        #endif
        finish(key: key)
        completion(nil)
    }

    private func finish(key: String) {
        lock.lock()
        pending.remove(key)
        inFlight = max(0, inFlight - 1)
        var next: (text: String, key: String, context: AITranslationContext, completion: (String?) -> Void)?
        if !waiting.isEmpty {
            next = waiting.removeLast()   // câu mới nhất trước
            inFlight += 1
        }
        lock.unlock()
        if let n = next {
            run(n.text, key: n.key, context: n.context, completion: n.completion)
        }
    }

    static func buildPrompt(_ text: String, context: AITranslationContext) -> String {
        var lines: [String] = []
        if !context.gameTitle.isEmpty { lines.append("Game: \(context.gameTitle)") }
        switch context.category {
        case .dialogue:
            lines.append("Loại chữ: lời thoại nhân vật" + (context.speaker.map { " (người nói: \($0))" } ?? ""))
        case .quest:
            lines.append("Loại chữ: nhiệm vụ / thông báo trên màn hình")
        case .menu:
            lines.append("Loại chữ: menu / hướng dẫn thao tác / vật phẩm")
        }
        if !context.previousLines.isEmpty {
            lines.append("Các câu thoại ngay trước đó (chỉ để hiểu ngữ cảnh, KHÔNG dịch):")
            for l in context.previousLines.suffix(3) { lines.append("- \(l)") }
        }
        let names = Array(Set(context.protectedWords)).prefix(30)
        if !names.isEmpty { lines.append("Tên riêng giữ nguyên: \(names.joined(separator: ", "))") }
        lines.append("Câu cần dịch: \(text)")
        lines.append("Bản dịch tiếng Việt:")
        return lines.joined(separator: "\n")
    }

    static func clean(_ raw: String, original: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Bản dịch tiếng Việt:", "Bản dịch:", "Dịch:", "Tiếng Việt:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        // Chỉ lấy dòng đầu nếu model giải thích thêm
        if let firstLine = s.split(separator: "\n").first, original.split(separator: "\n").count <= 1 {
            s = String(firstLine)
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'` "))
        guard !s.isEmpty, s.lowercased() != original.lowercased() else { return nil }
        return s
    }
}
