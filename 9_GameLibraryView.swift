// ============================================================================
// FILE 9: 9_GameLibraryView.swift
// PHIÊN BẢN: PS5Translator 1.12
//
// THƯ VIỆN GAME (thay màn hình "Quản lý Hồ sơ Game" cũ):
// - Thẻ game đang dùng: tên, số câu Việt hoá dùng được, tình trạng data, bộ dịch AI.
// - Lưới danh sách game: chạm để chọn game, menu "..." để nạp data / xoá.
// - "Thêm game mới": nhập tên + chọn file data Việt hoá trong 1 màn hình.
// - Nhập data từ .sqlite / .db, hoặc .csv / .tsv (cột en, vi), hoặc .txt (Anh ||| Việt)
//   -> tự chuyển sang cấu trúc chuẩn translations_v2.
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import SQLite3

// MARK: - Chuyển CSV / TXT thành SQLite chuẩn

enum DataImporter {
    enum ImportError: LocalizedError {
        case unreadable, noPairs, columnsNotFound([String]), sqlite(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Không đọc được file (cần mã hoá UTF-8)."
            case .noPairs: return "Không tìm thấy cặp câu Anh → Việt nào trong file."
            case .columnsNotFound(let cols): return "Không thấy cột tiếng Anh / tiếng Việt. Cột hiện có: \(cols.joined(separator: ", "))"
            case .sqlite(let m): return "Lỗi tạo SQLite: \(m)"
            }
        }
    }

    static let enAliases = ["en", "english", "en_raw", "original_text", "original", "source", "source_text", "text_raw", "text_en"]
    static let viAliases = ["vi", "vietnamese", "vi_text", "translated_text", "translation", "target", "target_text", "text_vi"]

    /// Đọc file văn bản thành danh sách cặp (en, vi, speaker)
    static func readPairs(from url: URL) throws -> [(en: String, vi: String, speaker: String?)] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { throw ImportError.unreadable }
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
        let ext = url.pathExtension.lowercased()

        if ext == "txt" {
            var pairs: [(en: String, vi: String, speaker: String?)] = []
            for line in text.components(separatedBy: .newlines) where line.contains("|||") {
                let parts = line.components(separatedBy: "|||")
                guard parts.count >= 2 else { continue }
                pairs.append((en: parts[0].trimmingCharacters(in: .whitespaces), vi: parts[1].trimmingCharacters(in: .whitespaces), speaker: nil))
            }
            if pairs.isEmpty { throw ImportError.noPairs }
            return pairs
        }

        let delimiter: Character = (ext == "tsv" || ext == "tab") ? "\t" : ","
        let rows = parseCSV(text, delimiter: delimiter)
        guard let header = rows.first else { throw ImportError.noPairs }
        let lower = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        guard let enIdx = enAliases.compactMap({ lower.firstIndex(of: $0) }).first,
              let viIdx = viAliases.compactMap({ lower.firstIndex(of: $0) }).first else {
            throw ImportError.columnsNotFound(header)
        }
        let spkIdx = lower.firstIndex(of: "speaker")
        var pairs: [(en: String, vi: String, speaker: String?)] = []
        for row in rows.dropFirst() where row.count > max(enIdx, viIdx) {
            let spk = spkIdx.flatMap { $0 < row.count ? row[$0] : nil }
            pairs.append((en: row[enIdx], vi: row[viIdx], speaker: (spk?.isEmpty ?? true) ? nil : spk))
        }
        if pairs.isEmpty { throw ImportError.noPairs }
        return pairs
    }

    /// Bộ đọc CSV chuẩn RFC 4180 (ô có dấu ngoặc kép, xuống dòng trong ô)
    static func parseCSV(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    /// Ghi các cặp câu ra SQLite chuẩn translations_v2. Trả về số cặp đã ghi.
    @discardableResult
    static func writeSQLite(pairs: [(en: String, vi: String, speaker: String?)], to dest: URL) throws -> Int {
        try? FileManager.default.removeItem(at: dest)
        var db: OpaquePointer?
        guard sqlite3_open(dest.path, &db) == SQLITE_OK, let conn = db else {
            throw ImportError.sqlite("không mở được file")
        }
        defer { sqlite3_close(conn) }
        let schema = """
        CREATE TABLE translations_v2(id INTEGER PRIMARY KEY, en TEXT NOT NULL, vi TEXT NOT NULL, en_norm TEXT NOT NULL,
                                     speaker TEXT, category TEXT, string_key TEXT);
        CREATE INDEX idx_translations_v2_norm ON translations_v2(en_norm);
        CREATE TABLE glossary(term TEXT PRIMARY KEY, vi TEXT, keep_original INTEGER DEFAULT 1, kind TEXT);
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO meta VALUES ('format','ps5translator-v2');
        BEGIN TRANSACTION;
        """
        guard sqlite3_exec(conn, schema, nil, nil, nil) == SQLITE_OK else {
            throw ImportError.sqlite(String(cString: sqlite3_errmsg(conn)))
        }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO translations_v2(en, vi, en_norm, speaker) VALUES (?,?,?,?)"
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw ImportError.sqlite(String(cString: sqlite3_errmsg(conn)))
        }
        defer { sqlite3_finalize(s) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var count = 0
        var seen = Set<String>()
        for p in pairs {
            let en = p.en.trimmingCharacters(in: .whitespacesAndNewlines)
            let vi = p.vi.trimmingCharacters(in: .whitespacesAndNewlines)
            let norm = TranslationMemory.normalize(en)
            guard !norm.isEmpty, !vi.isEmpty, norm != TranslationMemory.normalize(vi) else { continue }
            guard seen.insert(norm + "\u{1}" + vi).inserted else { continue }
            sqlite3_reset(s)
            sqlite3_bind_text(s, 1, en, -1, transient)
            sqlite3_bind_text(s, 2, vi, -1, transient)
            sqlite3_bind_text(s, 3, norm, -1, transient)
            if let spk = p.speaker { sqlite3_bind_text(s, 4, spk, -1, transient) } else { sqlite3_bind_null(s, 4) }
            if sqlite3_step(s) == SQLITE_DONE { count += 1 }
        }
        sqlite3_exec(conn, "COMMIT;", nil, nil, nil)
        if count == 0 { throw ImportError.noPairs }
        return count
    }
}

// MARK: - Thư viện game

struct GameLibraryView: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode

    @State private var showAddGame = false
    @State private var importTargetFolder: String = ""
    @State private var showImporter = false
    @State private var confirmDelete: GameProfileFolder?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let accent = Color(red: 0.0, green: 0.44, blue: 0.82)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    activeGameCard
                    if let msg = coord.importMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(msg.hasPrefix("✅") ? .green : .orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(10)
                    }

                    HStack {
                        Text("Danh sách game")
                            .font(.title3.bold())
                        Spacer()
                        Text("\(coord.gameProfiles.count) game")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        addGameTile
                        ForEach(coord.gameProfiles) { profile in
                            gameTile(profile)
                        }
                    }

                    aiEngineSection
                    tvSection
                    dataHelpSection
                }
                .padding(16)
            }
            .background(Color(red: 0.02, green: 0.04, blue: 0.09).ignoresSafeArea())
            .navigationTitle("Thư viện game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $showAddGame) {
                AddGameSheet(coord: coord)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: DataTypes.allowed, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    coord.importDataIntoProfileFolder(folderName: importTargetFolder, sourceURL: url)
                }
            }
            .alert(item: $confirmDelete) { profile in
                Alert(
                    title: Text("Xoá game \"\(profile.folderName)\"?"),
                    message: Text("Data Việt hoá của game này cũng bị xoá khỏi app."),
                    primaryButton: .destructive(Text("Xoá")) { coord.deleteGameProfileFolder(folderName: profile.folderName) },
                    secondaryButton: .cancel(Text("Huỷ"))
                )
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    // Thẻ game đang chơi
    private var activeGameCard: some View {
        HStack(spacing: 14) {
            GameMonogram(name: coord.activeProfileFolderName, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text("ĐANG CHƠI")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.green)
                Text(coord.activeProfileFolderName)
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)
                Label(coord.loadedLineCount > 0 ? "\(coord.loadedLineCount.formatted()) câu Việt hoá" : "Chưa có câu Việt hoá dùng được",
                      systemImage: coord.loadedLineCount > 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundColor(coord.loadedLineCount > 0 ? .green : .orange)
                Text(coord.databaseReport)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            LinearGradient(colors: [accent.opacity(0.55), Color(red: 0.05, green: 0.10, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12)))
    }

    private var addGameTile: some View {
        Button(action: { showAddGame = true }) {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(accent)
                Text("Thêm game mới")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Text("Tên game + data Việt hoá")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundColor(accent.opacity(0.8))
            )
        }
        .buttonStyle(.plain)
    }

    private func gameTile(_ profile: GameProfileFolder) -> some View {
        let isActive = coord.activeProfileFolderName == profile.folderName
        let stat = coord.profileStats[profile.folderName]
        let hasFile = profile.sqliteFileName.hasSuffix(".sqlite") || profile.sqliteFileName.hasSuffix(".db")
        return Button(action: { coord.activateGameProfileFolder(folderName: profile.folderName) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    GameMonogram(name: profile.folderName, size: 44)
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)
                    }
                    Menu {
                        Button(action: {
                            importTargetFolder = profile.folderName
                            showImporter = true
                        }) {
                            Label(hasFile ? "Thay data Việt hoá" : "Nạp data Việt hoá", systemImage: "square.and.arrow.down")
                        }
                        Button(action: { coord.activateGameProfileFolder(folderName: profile.folderName) }) {
                            Label("Chọn game này", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive, action: { confirmDelete = profile }) {
                            Label("Xoá game", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.leading, 4)
                    }
                }
                Text(profile.folderName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if !hasFile {
                    Label("Chưa có data", systemImage: "doc.badge.plus")
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                } else if let n = stat {
                    Label(n > 0 ? "\(n.formatted()) câu" : "Data lỗi (0 câu)", systemImage: n > 0 ? "text.book.closed.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundColor(n > 0 ? .cyan : .orange)
                } else {
                    Label("Có data · chạm để kiểm tra", systemImage: "doc.text")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(isActive ? Color.green.opacity(0.12) : Color.white.opacity(0.07))
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isActive ? Color.green.opacity(0.7) : Color.white.opacity(0.1), lineWidth: isActive ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private var aiEngineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bộ dịch AI")
                .font(.title3.bold())
            Text(OnDeviceAITranslator.shared.statusText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.75))
            ForEach(TranslationEngineMode.allCases) { mode in
                Button(action: { coord.translationEngineMode = mode }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: coord.translationEngineMode == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(coord.translationEngineMode == mode ? accent : .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).font(.subheadline.bold()).foregroundColor(.white)
                            Text(mode.detail).font(.caption2).foregroundColor(.gray)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.white.opacity(coord.translationEngineMode == mode ? 0.1 : 0.04))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tvSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TV Samsung")
                .font(.title3.bold())
            HStack {
                Label("IP nhập vào TV", systemImage: "tv")
                Spacer()
                Text("\(coord.server.ipAddress):\(String(AppConfig.webSocketPort))")
                    .font(.system(.subheadline, design: .monospaced).bold())
                    .foregroundColor(.green)
            }
            HStack {
                Label("TV đang kết nối", systemImage: "wifi")
                Spacer()
                Text("\(coord.server.connectedCount)")
                    .bold()
            }
            Button(action: {
                coord.triggerTVTestSentence()
                presentationMode.wrappedValue.dismiss()
            }) {
                Label("Gửi câu test lên TV", systemImage: "tv.badge.wifi")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(10)
            }
        }
        .font(.subheadline)
        .padding(14)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
    }

    private var dataHelpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Data Việt hoá nhận được")
                .font(.subheadline.bold())
            Text("• .sqlite / .db có cột tiếng Anh + cột tiếng Việt (vd: en, vi)\n• .csv / .tsv có dòng tiêu đề en,vi (tuỳ chọn: speaker)\n• .txt mỗi dòng: Câu tiếng Anh ||| Câu tiếng Việt\nTạo data từ file game: dùng tools/vietsub_db_tool.py trên máy tính.")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(16)
    }
}

enum DataTypes {
    static var allowed: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .data, .item]
        if let sqlite = UTType(filenameExtension: "sqlite") { types.insert(sqlite, at: 0) }
        if let db = UTType(filenameExtension: "db") { types.insert(db, at: 0) }
        return types
    }
}

/// Biểu tượng chữ cái đầu tên game (màu theo tên)
struct GameMonogram: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360.0
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(hue: hue, saturation: 0.7, brightness: 0.85), Color(hue: hue, saturation: 0.8, brightness: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .cornerRadius(size * 0.24)
    }
}

// MARK: - Thêm game mới

struct AddGameSheet: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var name = ""
    @State private var pickedFile: URL?
    @State private var showImporter = false

    private let accent = Color(red: 0.0, green: 0.44, blue: 0.82)

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tên game").font(.subheadline.bold())
                    TextField("VD: Until Dawn, God of War Ragnarök", text: $name)
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Data Việt hoá (không bắt buộc)").font(.subheadline.bold())
                    Button(action: { showImporter = true }) {
                        HStack {
                            Image(systemName: pickedFile == nil ? "doc.badge.plus" : "doc.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pickedFile?.lastPathComponent ?? "Chọn file data")
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text(".sqlite, .db, .csv, .tsv hoặc .txt (Anh ||| Việt)")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundColor(accent))
                    }
                    .buttonStyle(.plain)
                    Text("Chưa có data? Vẫn tạo được game: app sẽ dịch bằng AI và bạn nạp data sau.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button(action: create) {
                    Text(pickedFile == nil ? "Tạo game" : "Tạo game & nạp data")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : accent)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(18)
            .navigationTitle("Thêm game mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Huỷ") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: DataTypes.allowed, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result { pickedFile = urls.first }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func create() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        coord.createNewGameProfileFolder(folderName: clean)
        if let file = pickedFile {
            coord.importDataIntoProfileFolder(folderName: clean, sourceURL: file)
        } else {
            coord.activateGameProfileFolder(folderName: clean)
        }
        presentationMode.wrappedValue.dismiss()
    }
}
