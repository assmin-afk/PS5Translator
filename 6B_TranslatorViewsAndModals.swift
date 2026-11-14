// ============================================================================
// FILE 6B: 6B_TranslatorViewsAndModals.swift (TÁCH TỪ FILE 6 - PHẦN 2/2)
// PHIÊN BẢN: PS5Translator 1.12 (TAB YOUTUBE, XOAY NGANG, THƯ VIỆN GAME)
// ============================================================================

import SwiftUI
import WebKit
import UniformTypeIdentifiers

// ============================================================================
// 7. GIAO DIỆN CHÍNH PS5TRANSLATOR
// ============================================================================
struct MainTranslatorView: View {
    @StateObject private var coord = PipelineCoordinator()
    @StateObject private var youtube = YouTubeTranslatorModel()
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

            // 1.12: 2 tab (Remote PS5 / Dịch YouTube) + chế độ xoay ngang toàn màn hình
            VStack(spacing: 0) {
                if !coord.isLandscapeFullscreen {
                    appTabPicker
                }
                if coord.activeTab == .youtube {
                    YouTubeTranslatorTab(model: youtube, coord: coord)
                        .ignoresSafeArea(edges: coord.isLandscapeFullscreen ? .all : [])
                } else if coord.isLandscapeFullscreen {
                    PS5FullscreenView(coord: coord, videoMgr: coord.videoMgr)
                } else {
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
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(coord.isLandscapeFullscreen)
        .sheet(isPresented: $showPS5ConnectSheet) {
            PS5ConnectionWizardView(coord: coord)
        }
        .sheet(isPresented: $showGameProfilesSheet) {
            GameLibraryView(coord: coord)
        }
    }

    private var appTabPicker: some View {
        HStack(spacing: 6) {
            ForEach(AppTab.allCases) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) { coord.activeTab = tab }
                }) {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(coord.activeTab == tab ? psNeonAccent : Color.white.opacity(0.06))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            Button(action: { showGameProfilesSheet = true }) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 14, weight: .bold))
                    .padding(9)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(.cyan)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

                                // 1.11: Khung dịch neo đúng vị trí chữ gốc, cùng cỡ chữ / màu chữ / màu nền
                                ForEach(coord.translatedBoxes) { box in
                                    TranslatedSubtitleBoxView(box: box, frameSize: geo.size)
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

            Button(action: { coord.isLandscapeFullscreen = true }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .padding(6)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .cornerRadius(7)
            }

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
                    Text("Dịch AI: \(coord.translationEngineMode.title)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text("Dịch câu chưa có trong data Việt hoá. Đổi bộ dịch trong Thư viện game.")
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
                            Text("Thư viện game")
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
                    // 1.11: kết quả kiểm tra data Việt hoá
                    Text(coord.databaseReport)
                        .font(.caption)
                        .foregroundColor(coord.loadedLineCount == 0 ? .orange : .green)

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
                    Toggle("Dịch AI online cho câu chưa có trong data", isOn: $coord.enableAppleIntelligenceFallback)
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
                            Text("Lõi C Chiaki-NG PS5 Remote Play")
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

                    // BƯỚC 2: TÀI KHOẢN PSN (CƠ CHẾ CONSOLE TRANSLATOR: KHUYÊN DÙNG TÀI KHOẢN PHỤ)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("BƯỚC 2: Tài khoản PSN", systemImage: "2.circle.fill")
                                .font(.subheadline.bold())
                                .foregroundColor(.cyan)
                            Spacer()
                            if coord.videoMgr.isAccountRemembered {
                                Label("Đã ghi nhớ", systemImage: "checkmark.shield.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                            }
                        }

                        Text("Lưu ý: Màn hình lấy mã PIN 8 số trên PS5 đang mở ở User nào thì bạn nhập đúng tài khoản PSN của User đó ở đây:")
                            .font(.caption)
                            .foregroundColor(.gray)

                        HStack {
                            TextField("Online ID tài khoản PSN (VD: Maivy1125)", text: $coord.videoMgr.psnUsername)
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
                            TextField("Mã Account ID 8-byte Base64 (Hoặc dán số ID 19 chữ số)", text: $coord.videoMgr.psnAccountIDBase64)
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
                                Text("Online ID: \(coord.videoMgr.psnUsername) • Số ID: \(coord.videoMgr.psnNumericAccountID) • Base64: \(coord.videoMgr.psnAccountIDBase64)")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Spacer()
                                Button("Xoá & Đổi TK") {
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

                    // 1.10: TÀI KHOẢN ĐÃ LIÊN KẾT (GHI NHỚ) + TỰ KẾT NỐI LẠI + GIỮ KẾT NỐI KHI RA NGOÀI
                    LinkedPS5ProfilesSection(videoMgr: coord.videoMgr)

                    // BƯỚC 3: MÃ PIN 8 CHỮ SỐ TRÊN MÀN HÌNH PS5
                    VStack(alignment: .leading, spacing: 10) {
                        Label("BƯỚC 3: Mã PIN 8 số liên kết thiết bị (Chỉ cần nhập lần đầu)", systemImage: "3.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)

                        Text("Trên PS5 (ở đúng tài khoản PSN vừa chọn): Cài đặt -> Hệ thống -> Chơi từ xa -> Liên kết thiết bị:")
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
// 10. TRÌNH ĐĂNG NHẬP SONY OAUTH & BỘ QUÉT ĐỆ QUY ĐA TẦNG (ĐỒNG BỘ COOKIE DEFAULT)
// ============================================================================
struct PSNWebLoginHelperView: View {
    @ObservedObject var coord: PipelineCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var extractionStatus: String = "Đăng nhập đúng tài khoản PSN đang mở trên máy PS5. App sẽ tự lấy Account ID 8-byte và ghi nhớ vĩnh viễn."
    @State private var manualCheckTrigger: Int = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(extractionStatus)
                        .font(.caption.bold())
                        .foregroundColor(.cyan)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    Button(action: {
                        extractionStatus = "Đang quét Cookie npsso & lấy Account ID 8-byte..."
                        manualCheckTrigger += 1
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.shield.fill")
                            Text("Lấy ID ngay")
                                .font(.caption2.bold())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.25))
                        .foregroundColor(.green)
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)

                SonyOAuthWebView(
                    url: URL(string: TranslatorV102Config.sonyOAuthLoginURL)!,
                    manualCheckTrigger: manualCheckTrigger,
                    onExtractedAccount: { onlineID, base64ID, numericID in
                        let finalUser = onlineID.isEmpty ? coord.videoMgr.psnUsername : onlineID
                        coord.videoMgr.saveRememberedAccount(
                            username: finalUser,
                            accountIDBase64: base64ID,
                            numericID: numericID
                        )
                        self.extractionStatus = "✅ Đã lấy thành công Account ID 8-byte (\(base64ID)) • Số ID: \(numericID)!"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            presentationMode.wrappedValue.dismiss()
                        }
                    },
                    onStatusUpdate: { msg in
                        self.extractionStatus = msg
                    }
                )
            }
            .navigationTitle("Đăng nhập Sony (Tự lấy 8-byte)")
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
    let manualCheckTrigger: Int
    let onExtractedAccount: (String, String, String) -> Void
    let onStatusUpdate: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExtractedAccount: onExtractedAccount, onStatusUpdate: onStatusUpdate)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attachedWebView = webView
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastManualTrigger != manualCheckTrigger {
            context.coordinator.lastManualTrigger = manualCheckTrigger
            context.coordinator.inspectCookiesAndDOMForAccountID(in: uiView, forceSilentAuth: true)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onExtractedAccount: (String, String, String) -> Void
        let onStatusUpdate: (String) -> Void
        weak var attachedWebView: WKWebView?
        var lastManualTrigger: Int = 0
        private var didExtractSuccess = false
        private var didExchangeCode = false
        private var isTryingSilentCookieAuth = false

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

            if handlePotentialRedirectURL(currentURL) {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if let failingURL = nsErr.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                _ = handlePotentialRedirectURL(failingURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didExtractSuccess else { return }
            inspectCookiesAndDOMForAccountID(in: webView, forceSilentAuth: false)
        }

        private func handlePotentialRedirectURL(_ urlString: String) -> Bool {
            guard urlString.hasPrefix(TranslatorV102Config.sonyOAuthRedirectPrefix) ||
                  urlString.contains("scecompcall://redirect") ||
                  urlString.contains("remoteplay/redirect") ||
                  urlString.contains("code=v3.") else {
                return false
            }

            if let components = URLComponents(string: urlString),
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
               !code.isEmpty,
               !didExchangeCode {
                didExchangeCode = true
                DispatchQueue.main.async {
                    self.onStatusUpdate("Đã nhận mã OAuth từ Sony! Đang giải mã JWT & lấy Account ID 8-byte...")
                }
                exchangeOAuthCodeForAccountID(code: code)
            }
            return true
        }

        func inspectCookiesAndDOMForAccountID(in webView: WKWebView, forceSilentAuth: Bool) {
            guard !didExtractSuccess else { return }

            let jsFetchProfile = """
            (async function() {
                try {
                    const r1 = await fetch('https://web.np.playstation.com/api/basicProfile/v1/profile/users/me', { credentials: 'include' });
                    if (r1.ok) {
                        const j1 = await r1.json();
                        return JSON.stringify(j1);
                    }
                } catch (e) {}
                return "";
            })();
            """

            webView.evaluateJavaScript(jsFetchProfile) { [weak self] result, _ in
                guard let self = self, !self.didExtractSuccess else { return }
                if let jsonStr = result as? String,
                   !jsonStr.isEmpty,
                   let data = jsonStr.data(using: .utf8),
                   let found = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    self.completeExtraction(onlineID: found.onlineID, base64ID: found.base64ID, numericID: found.numericID)
                }
            }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.didExtractSuccess else { return }
                let sonyCookies = cookies.filter {
                    $0.domain.contains("sony.com") || $0.domain.contains("playstation.net") || $0.domain.contains("playstation.com")
                }
                guard !sonyCookies.isEmpty else { return }

                for cookie in sonyCookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }

                let hasNpsso = sonyCookies.contains { $0.name.lowercased() == "npsso" && $0.value.count >= 24 }
                let currentHost = webView.url?.host?.lowercased() ?? ""
                let isPostLoginPage = currentHost.contains("my.account.sony.com") ||
                                      currentHost.contains("playstation.com") ||
                                      forceSilentAuth

                if (hasNpsso || isPostLoginPage) && !self.didExchangeCode && !self.isTryingSilentCookieAuth {
                    self.isTryingSilentCookieAuth = true
                    DispatchQueue.main.async {
                        self.onStatusUpdate("Đã phát hiện phiên đăng nhập Sony! Đang trích xuất mã Account ID 8-byte...")
                    }
                    self.performSilentAuthorizeWithCookies(sonyCookies)
                }
            }
        }

        private func performSilentAuthorizeWithCookies(_ cookies: [HTTPCookie]) {
            let silentURLStr = TranslatorV102Config.sonyOAuthLoginURL + "&prompt=none"
            guard let silentURL = URL(string: silentURLStr) else {
                isTryingSilentCookieAuth = false
                return
            }

            let config = URLSessionConfiguration.default
            config.httpShouldSetCookies = true
            config.httpCookieAcceptPolicy = .always

            let catcher = SilentOAuthRedirectCatcher { [weak self] code in
                guard let self = self else { return }
                self.isTryingSilentCookieAuth = false
                if let code = code, !code.isEmpty, !self.didExchangeCode {
                    self.didExchangeCode = true
                    DispatchQueue.main.async {
                        self.onStatusUpdate("Đã lấy mã uỷ quyền từ Cookie Sony! Đang giải mã Account ID 8-byte...")
                    }
                    self.exchangeOAuthCodeForAccountID(code: code)
                }
            }

            let session = URLSession(configuration: config, delegate: catcher, delegateQueue: nil)
            var req = URLRequest(url: silentURL)
            let headers = HTTPCookie.requestHeaderFields(with: cookies)
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
            session.dataTask(with: req).resume()
        }

        private func exchangeOAuthCodeForAccountID(code: String) {
            guard let tokenURL = URL(string: TranslatorV102Config.sonyOAuthTokenURL) else { return }
            var req = URLRequest(url: tokenURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(TranslatorV102Config.sonyBasicAuthHeader, forHTTPHeaderField: "Authorization")

            let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
            let bodyStr = "grant_type=authorization_code&code=\(encodedCode)&redirect_uri=\(TranslatorV102Config.sonyOAuthRedirectEncoded)&token_format=jwt"
            req.httpBody = bodyStr.data(using: .utf8)

            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self else { return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.didExchangeCode = false
                    DispatchQueue.main.async {
                        self.onStatusUpdate("Không đổi được token từ Sony. Hãy bấm 'Lấy ID ngay' hoặc đăng nhập lại.")
                    }
                    return
                }

                if let directFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    self.completeExtraction(
                        onlineID: directFound.onlineID,
                        base64ID: directFound.base64ID,
                        numericID: directFound.numericID
                    )
                    return
                }

                guard let accessToken = json["access_token"] as? String else {
                    self.didExchangeCode = false
                    return
                }

                if let jwtFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJWT(accessToken) {
                    self.completeExtraction(
                        onlineID: jwtFound.onlineID,
                        base64ID: jwtFound.base64ID,
                        numericID: jwtFound.numericID
                    )
                    return
                }

                if let idToken = json["id_token"] as? String,
                   let idJwtFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJWT(idToken) {
                    self.completeExtraction(
                        onlineID: idJwtFound.onlineID,
                        base64ID: idJwtFound.base64ID,
                        numericID: idJwtFound.numericID
                    )
                    return
                }

                self.fetchPSNAccountID(accessToken: accessToken)
            }.resume()
        }

        private func fetchPSNAccountID(accessToken: String) {
            let endpoints: [(url: String, useBasicAuth: Bool)] = [
                ("https://dms.api.playstation.com/api/v1/devices/accounts/me", false),
                ("https://ca.account.sony.com/api/v1/oauth/token/\(accessToken)", true),
                ("https://us-prof.np.community.playstation.net/userProfile/v1/users/me/profile2?fields=npId,onlineId,accountId,avatarUrls,plus", false),
                ("https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles", false),
                ("https://web.np.playstation.com/api/basicProfile/v1/profile/users/me", false)
            ]

            tryEndpoint(at: 0, endpoints: endpoints, accessToken: accessToken)
        }

        private func tryEndpoint(at index: Int, endpoints: [(url: String, useBasicAuth: Bool)], accessToken: String) {
            guard !didExtractSuccess else { return }
            guard index < endpoints.count else {
                self.didExchangeCode = false
                DispatchQueue.main.async {
                    self.onStatusUpdate("⚠️ Chưa trích xuất được Account ID tự động. Hãy bấm nút 'Lấy ID ngay' ở góc phải.")
                }
                return
            }

            let item = endpoints[index]
            guard let url = URL(string: item.url) else {
                tryEndpoint(at: index + 1, endpoints: endpoints, accessToken: accessToken)
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 6.0
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if item.useBasicAuth {
                req.setValue(TranslatorV102Config.sonyBasicAuthHeader, forHTTPHeaderField: "Authorization")
            } else {
                req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }

            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self, !self.didExtractSuccess else { return }
                if let data = data,
                   let found = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    self.completeExtraction(
                        onlineID: found.onlineID,
                        base64ID: found.base64ID,
                        numericID: found.numericID
                    )
                    return
                }
                self.tryEndpoint(at: index + 1, endpoints: endpoints, accessToken: accessToken)
            }.resume()
        }

        private func completeExtraction(onlineID: String, base64ID: String, numericID: String) {
            guard !didExtractSuccess else { return }
            didExtractSuccess = true
            DispatchQueue.main.async {
                self.onExtractedAccount(onlineID, base64ID, numericID)
            }
        }
    }
}

// 1.13: Vẽ 1 khung dịch đè khít lên chữ gốc: chữ ĐẬM, nền ĐEN cố định, thoại căn giữa
struct TranslatedSubtitleBoxView: View {
    let box: TranslatedBox
    let frameSize: CGSize

    var body: some View {
        let W = frameSize.width, H = frameSize.height
        let fontSize: CGFloat = box.fontSizeNorm > 0
            ? CGFloat(box.fontSizeNorm) * H
            : max(9.5, min(18.0, CGFloat(box.h) * H * 0.78))
        let center = box.textAlignCenter
        let padX = fontSize * (center ? 0.35 : 0.32)
        let padY = fontSize * (center ? 0.18 : 0.14)
        let textColor = Color(hexString: box.textColorHex) ?? .white

        Text(box.text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(textColor)
            .multilineTextAlignment(center ? .center : .leading)
            .lineLimit(nil)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, padX)
            .padding(.vertical, padY)
            .frame(width: CGFloat(box.w) * W, height: CGFloat(box.h) * H, alignment: center ? .center : .topLeading)
            .background(
                RoundedRectangle(cornerRadius: max(3, fontSize * 0.22))
                    .fill(Color.black.opacity(0.86))
            )
            .position(x: CGFloat(box.x + box.w / 2) * W, y: CGFloat(box.y + box.h / 2) * H)
            .animation(nil, value: box)
            .allowsHitTesting(false)
    }
}

extension Color {
    /// "#RRGGBB" -> Color
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// 1.10: Danh sách tài khoản PS5 đã liên kết + tuỳ chọn tự kết nối lại / chạy nền
struct LinkedPS5ProfilesSection: View {
    @ObservedObject var videoMgr: VideoSourceManager
    private let psBlue = Color(red: 0.0, green: 0.44, blue: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tài khoản đã liên kết (chạm để kết nối, không cần PIN)", systemImage: "person.2.fill")
                .font(.subheadline.bold())
                .foregroundColor(.cyan)

            if videoMgr.linkedProfiles.isEmpty {
                Text("Chưa có tài khoản nào. Ghép đôi bằng mã PIN 8 số ở BƯỚC 3 (mỗi tài khoản PSN ghép đôi 1 lần).")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                ForEach(videoMgr.linkedProfiles) { profile in
                    HStack(spacing: 10) {
                        Button(action: {
                            videoMgr.connectWithProfile(profile)
                        }) {
                            HStack {
                                Image(systemName: profile.accountBase64 == videoMgr.psnAccountIDBase64 ? "checkmark.circle.fill" : "person.circle")
                                    .foregroundColor(profile.accountBase64 == videoMgr.psnAccountIDBase64 ? .green : .white)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.username.isEmpty ? profile.accountBase64 : profile.username)
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                    Text("PS5: \(profile.host)")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Text("Kết nối")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(psBlue)
                                    .cornerRadius(8)
                            }
                        }
                        Button(action: {
                            videoMgr.removeProfile(profile)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.35))
                    .cornerRadius(10)
                }
            }

            Toggle(isOn: $videoMgr.autoReconnectEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tự kết nối lại").font(.subheadline.bold()).foregroundColor(.white)
                    Text("Khi mở app, khi quay lại app, hoặc khi PS5 ngắt phiên (đổi tài khoản bằng nút PS)")
                        .font(.caption2).foregroundColor(.gray)
                }
            }
            Toggle(isOn: $videoMgr.keepAliveInBackground) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Giữ kết nối khi thoát app ra ngoài").font(.subheadline.bold()).foregroundColor(.white)
                    Text("App tiếp tục chạy nền để không mất Remote Play (tốn pin hơn)")
                        .font(.caption2).foregroundColor(.gray)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

@main
struct PS5TranslatorApp: App {
    // 1.12: điều khiển xoay ngang toàn màn hình
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) var orientationDelegate

    var body: some Scene {
        WindowGroup {
            MainTranslatorView()
        }
    }
}
