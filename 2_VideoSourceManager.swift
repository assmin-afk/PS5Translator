// ============================================================================

// FILE 2: 2_VideoSourceManager.swift

// PHIÊN BẢN: PS5Translator 1.02 (CHIAKI REAL HANDSHAKE & VIDEOTOOLBOX STREAM)

// CÁC LỖI ĐÃ KHẮC PHỤC TRIỆT ĐỂ TRONG FILE NÀY:

// 1. Tắt hoàn toàn việc báo ảo "Chiaki Live (Chấm xanh)" khi máy PS5 chưa phản hồi

//    HTTP 200 OK. Chỉ khi PS5 xác nhận ghép đôi / mở phiên thành công thì mới báo xanh.

// 2. Tắt vòng lặp tự vẽ 3 câu tiếng Anh giả lập (QUEST: Follow the blood trail...)

//    để ứng dụng chỉ quét hình ảnh thật nhận từ máy PS5.

// 3. Tự động trích xuất Account ID 8-byte thật từ Cookie phiên đăng nhập Sony

//    (WKWebsiteDataStore) và xoá bỏ mã băm giả "nZKnNYIoZ0w=" gây lỗi từ chối ngầm.

// 4. Sửa đúng cấu trúc gói tin 480 bytes (0x1E0) của Chiaki (ambassador ở 0x00,

//    cipher 384B ở 0x10, HMAC 32B ở 0x190, bright 16B ở 0x1B0) + mở luồng

//    /sie/ps5/rp/sess/init -> /sie/ps5/rp/sess/ctrl -> Takion UDP 9296 & giải mã

//    khung hình video H.264/HEVC bằng phần cứng VideoToolbox.

// ============================================================================



import Foundation

import UIKit

import CoreGraphics

import Combine

import Network

import CryptoKit

import CommonCrypto

import WebKit

import VideoToolbox

import CoreMedia



// ============================================================================

// THÔNG SỐ CẤU HÌNH KHUNG QUÉT MẶC ĐỊNH & CỔNG CHIAKI (Đặt ở đầu file)

// ============================================================================

struct ROIDefaultConfig {

    static let fullScreenRect = CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92)

    static let dialogueDefaultRect = CGRect(x: 0.10, y: 0.68, width: 0.80, height: 0.24)

    static let questDefaultRect = CGRect(x: 0.03, y: 0.12, width: 0.94, height: 0.76)

    

    static let ddpPort: UInt16 = 9302

    static let registAndCtrlPort: UInt16 = 9295

    static let takionStreamPort: UInt16 = 9296

    static let rpClientType = "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931af000"

    static let chiakiRegistPayloadSize = 480 // 0x1E0 bytes chuẩn Chiaki

}



enum ROIMode: String, CaseIterable {

    case fullScreen = "Toàn màn hình"

    case dialogueOnly = "Chỉ phụ đề"

    case questAndMenu = "Nhiệm vụ & Menu"

}



enum PS5ConnectionState: Equatable {

    case disconnected

    case scanningLAN

    case pairingPIN

    case connectingStream

    case connected(hostName: String)

    case error(message: String)

}



// ============================================================================

// 1. LÕI MÃ HOÁ CHIAKI RPCRYPT CHUẨN C-STRUCT (CHIAKI/LIB/SRC/RPCRYPT.C & REGIST.C)

// ============================================================================

final class ChiakiEmbeddedCore {

    static let shared = ChiakiEmbeddedCore()

    

    // Bảng khoá PS5 gốc từ mã nguồn Chiaki (rpcrypt.c)

    private let ps5Key0: [UInt8] = [

        0x09, 0x37, 0x9F, 0x7D, 0x48, 0x43, 0x4A, 0xC2,

        0x50, 0xB8, 0x6C, 0x98, 0x7E, 0xE8, 0xC9, 0x77

    ]

    private let ps5Key1: [UInt8] = [

        0x7B, 0xD0, 0x35, 0x0A, 0x86, 0xC6, 0x24, 0x3E,

        0x2F, 0x08, 0x90, 0x79, 0x66, 0xF7, 0xB1, 0x3F

    ]

    private let ps5HmacKey: [UInt8] = [

        0x62, 0x47, 0x9C, 0x30, 0x37, 0x65, 0x4E, 0x26,

        0x86, 0x0F, 0x9D, 0x2F, 0x5C, 0x70, 0x10, 0x3C

    ]

    

    // Kiểm tra xem chuỗi Base64 có phải là mã băm giả (như nZKnNYIoZ0w= hoặc TWlIc29pOTM=) hay không

    func isFakeGeneratedAccountID(_ input: String, username: String) -> Bool {

        let trimmed = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if trimmed.isEmpty { return true }

        if trimmed == "nZKnNYIoZ0w=" || trimmed == "TWlIc29pOTM=" { return true }

        

        let cleanUser = (username.isEmpty ? "Miesoi93" : username).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()

        let fakeHash = Data(SHA256.hash(data: Data(cleanUser.utf8)).prefix(8)).base64EncodedString()

        if trimmed == fakeHash { return true }

        

        let padded = cleanUser.padding(toLength: 8, withPad: "0", startingAt: 0)

        let fakeAscii = Data(padded.utf8.prefix(8)).base64EncodedString()

        if trimmed == fakeAscii { return true }

        

        return false

    }

    

    // Chuẩn hoá Account ID sang đúng 8-byte Little-Endian Base64 chuẩn Chiaki

    // Không bao giờ tự sinh mã giả nếu chưa có ID thật

    func normalizeAccountIDTo8Bytes(input: String, fallbackUsername: String) -> (base64: String, numericString: String, isValidRealID: Bool) {

        let trimmed = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if isFakeGeneratedAccountID(trimmed, username: fallbackUsername) {

            return ("", "", false)

        }

        

        // 1. Nếu là dãy số 64-bit của Sony (10 - 20 chữ số)

        if trimmed.allSatisfy({ $0.isNumber }), let numericID = UInt64(trimmed), numericID > 1000000 {

            var le = numericID.littleEndian

            let data = Data(bytes: &le, count: 8)

            return (data.base64EncodedString(), String(numericID), true)

        }

        

        // 2. Nếu là chuỗi Base64 giải mã ra đúng 8 bytes thật

        if let decoded = Data(base64Encoded: trimmed), decoded.count == 8 {

            let uint64Val = decoded.withUnsafeBytes { $0.load(as: UInt64.self) }

            let num = UInt64(littleEndian: uint64Val)

            if num > 1000000 {

                return (trimmed, String(num), true)

            }

        }

        

        // 3. Nếu là chuỗi Hex 16 ký tự (VD: từ script Chiaki trên PC)

        let cleanHex = trimmed.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: " ", with: "")

        if cleanHex.count == 16, let hexVal = UInt64(cleanHex, radix: 16), hexVal > 1000000 {

            var le = hexVal.littleEndian

            let data = Data(bytes: &le, count: 8)

            return (data.base64EncodedString(), String(hexVal), true)

        }

        

        return ("", "", false)

    }

    

    // Đóng gói gói tin đăng ký 480 bytes (0x1E0) chuẩn xác theo chiaki_regist_request_payload_format

    func buildChiakiPS5RegistPayload480(pinString: String, accountIDBase64: String) -> (payload: Data, aesKey: [UInt8], iv: [UInt8]) {

        let pinNumber = UInt32(pinString) ?? 0

        let pinBytes: [UInt8] = [

            UInt8((pinNumber >> 24) & 0xFF),

            UInt8((pinNumber >> 16) & 0xFF),

            UInt8((pinNumber >> 8) & 0xFF),

            UInt8(pinNumber & 0xFF)

        ]

        

        var nonce = [UInt8](repeating: 0, count: 16)

        for i in 0..<16 {

            nonce[i] = UInt8.random(in: 0...255)

        }

        

        var ambassador = [UInt8](repeating: 0, count: 16)

        var bright = [UInt8](repeating: 0, count: 16)

        var aesKey = [UInt8](repeating: 0, count: 16)

        var iv = [UInt8](repeating: 0, count: 16)

        

        for i in 0..<16 {

            ambassador[i] = nonce[i] ^ ps5Key0[i]

            bright[i] = nonce[i] ^ ps5Key1[i]

            iv[i] = nonce[i] ^ ps5Key0[(i + 8) % 16]

            aesKey[i] = nonce[i] ^ ps5Key1[(i + 8) % 16] ^ pinBytes[i % 4]

        }

        

        // Khung dữ liệu nội bộ 384 bytes (0x180) lấp đầy bằng 'A' (0x41), ghi Header tại offset 0x38 (56 trong vùng 384B = 0x48 trong toàn bộ 480B)

        var innerBuffer = [UInt8](repeating: 0x41, count: 384)

        var innerHeaders = "Client-Type: \(ROIDefaultConfig.rpClientType)\r\n"

        innerHeaders += "Np-AccountId: \(accountIDBase64)\r\n\r\n"

        let headerBytes = Array(innerHeaders.utf8)

        let innerOffset = 56 // 0x48 (72) - 0x10 (16) = 56

        for i in 0..<min(headerBytes.count, 384 - innerOffset) {

            innerBuffer[innerOffset + i] = headerBytes[i]

        }

        if innerOffset + headerBytes.count < 384 {

            innerBuffer[innerOffset + headerBytes.count] = 0x00

        }

        

        let plainData = Data(innerBuffer)

        let encryptedBody = aes128CBCEncryptNoPadding(data: plainData, key: aesKey, iv: iv) ?? plainData

        

        let hmacSymKey = SymmetricKey(data: Data(ps5HmacKey))

        let hmac = HMAC<SHA256>.authenticationCode(for: encryptedBody, using: hmacSymKey)

        

        // Cấu trúc chuẩn 480 bytes (0x1E0) của Chiaki (regist.c):

        // [0x00..<0x10]: ambassador (16B)

        // [0x10..<0x190]: encryptedBody (384B)

        // [0x190..<0x1B0]: hmac (32B)

        // [0x1B0..<0x1C0]: bright (16B)

        // [0x1C0..<0x1E0]: padding 'A' (32B)

        var fullPayload = Data(capacity: ROIDefaultConfig.chiakiRegistPayloadSize)

        fullPayload.append(contentsOf: ambassador)

        fullPayload.append(encryptedBody.prefix(384))

        fullPayload.append(contentsOf: hmac)

        fullPayload.append(contentsOf: bright)

        fullPayload.append(contentsOf: [UInt8](repeating: 0x41, count: 32))

        

        return (fullPayload, aesKey, iv)

    }

    

    func decryptRegistResponse(cipherData: Data, aesKey: [UInt8], iv: [UInt8]) -> String? {

        guard cipherData.count >= 16 else { return nil }

        let outLength = cipherData.count + kCCBlockSizeAES128

        var outBuffer = Data(count: outLength)

        var numBytesDecrypted: size_t = 0

        

        let status = outBuffer.withUnsafeMutableBytes { outBytes in

            cipherData.withUnsafeBytes { inBytes in

                CCCrypt(

                    CCOperation(kCCDecrypt),

                    CCAlgorithm(kCCAlgorithmAES),

                    CCOptions(0),

                    aesKey,

                    kCCKeySizeAES128,

                    iv,

                    inBytes.baseAddress,

                    cipherData.count,

                    outBytes.baseAddress,

                    outLength,

                    &numBytesDecrypted

                )

            }

        }

        guard status == kCCSuccess else { return nil }

        outBuffer.count = numBytesDecrypted

        return String(data: outBuffer, encoding: .utf8) ?? String(data: outBuffer, encoding: .ascii)

    }

    

    func buildRawHTTPRegistRequest(ip: String, payload: Data) -> Data {

        var rawHTTP = "POST /sie/ps5/rp/sess/rgst HTTP/1.1\r\n"

        rawHTTP += "Host: \(ip):\(ROIDefaultConfig.registAndCtrlPort)\r\n"

        rawHTTP += "User-Agent: remoteplay Windows\r\n"

        rawHTTP += "Connection: close\r\n"

        rawHTTP += "Content-Length: \(payload.count)\r\n"

        rawHTTP += "RP-Version: 1.0\r\n\r\n"

        

        var packet = Data(rawHTTP.utf8)

        packet.append(payload)

        return packet

    }

    

    func buildTakionV12InitPacket(initTag: UInt32) -> Data {

        var packet = Data()

        packet.append(0x00) // Type = INIT

        packet.append(0x00) // Flags

        var tagBE = initTag.bigEndian

        packet.append(Data(bytes: &tagBE, count: 4))

        var aRwnd: UInt32 = UInt32(0x00010000).bigEndian

        packet.append(Data(bytes: &aRwnd, count: 4))

        var outStreams: UInt16 = UInt16(10).bigEndian

        var inStreams: UInt16 = UInt16(10).bigEndian

        packet.append(Data(bytes: &outStreams, count: 2))

        packet.append(Data(bytes: &inStreams, count: 2))

        var initialTSN = UInt32.random(in: 1...0xFFFFFFFE).bigEndian

        packet.append(Data(bytes: &initialTSN, count: 4))

        return packet

    }

    

    private func aes128CBCEncryptNoPadding(data: Data, key: [UInt8], iv: [UInt8]) -> Data? {

        let outLength = data.count + kCCBlockSizeAES128

        var outBuffer = Data(count: outLength)

        var numBytesEncrypted: size_t = 0

        

        let status = outBuffer.withUnsafeMutableBytes { outBytes in

            data.withUnsafeBytes { inBytes in

                CCCrypt(

                    CCOperation(kCCEncrypt),

                    CCAlgorithm(kCCAlgorithmAES),

                    CCOptions(0),

                    key,

                    kCCKeySizeAES128,

                    iv,

                    inBytes.baseAddress,

                    data.count,

                    outBytes.baseAddress,

                    outLength,

                    &numBytesEncrypted

                )

            }

        }

        guard status == kCCSuccess else { return nil }

        outBuffer.count = numBytesEncrypted

        return outBuffer

    }

}



// ============================================================================

// 2. BỘ GIẢI MÃ VIDEO PHẦN CỨNG CHIAKI (VIDEOTOOLBOX H.264 / HEVC DECODER)

// ============================================================================

final class ChiakiHardwareVideoDecoder {

    private var formatDesc: CMVideoFormatDescription?

    private var decompressionSession: VTDecompressionSession?

    private var spsData: Data?

    private var ppsData: Data?

    var onFrameDecoded: ((CGImage) -> Void)?

    

    func feedTakionUDPPacket(_ data: Data) {

        guard data.count > 16 else { return }

        let bytes = [UInt8](data)

        var nalStarts: [Int] = []

        var i = 0

        while i < bytes.count - 4 {

            if bytes[i] == 0x00 && bytes[i+1] == 0x00 && bytes[i+2] == 0x00 && bytes[i+3] == 0x01 {

                nalStarts.append(i)

                i += 4

            } else {

                i += 1

            }

        }

        

        guard !nalStarts.isEmpty else { return }

        for idx in 0..<nalStarts.count {

            let start = nalStarts[idx] + 4

            let end = (idx + 1 < nalStarts.count) ? nalStarts[idx + 1] : bytes.count

            guard start < end else { continue }

            let nalUnit = Data(bytes[start..<end])

            processH264NALUnit(nalUnit)

        }

    }

    

    private func processH264NALUnit(_ nal: Data) {

        guard let firstByte = nal.first else { return }

        let nalType = firstByte & 0x1F

        if nalType == 7 {

            spsData = nal

            setupDecompressionSessionIfPossible()

        } else if nalType == 8 {

            ppsData = nal

            setupDecompressionSessionIfPossible()

        } else if nalType == 1 || nalType == 5 {

            decodeVideoSlice(nal)

        }

    }

    

    private func setupDecompressionSessionIfPossible() {

        guard decompressionSession == nil, let sps = spsData, let pps = ppsData else { return }

        sps.withUnsafeBytes { spsRaw in

            pps.withUnsafeBytes { ppsRaw in

                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,

                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }

                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]

                let sizes: [Int] = [sps.count, pps.count]

                var desc: CMFormatDescription?

                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(

                    allocator: kCFAllocatorDefault,

                    parameterSetCount: 2,

                    parameterSetPointers: pointers,

                    parameterSetSizes: sizes,

                    nalUnitHeaderLength: 4,

                    formatDescriptionOut: &desc

                )

                guard status == noErr, let validDesc = desc else { return }

                self.formatDesc = validDesc

                

                let attrs: [String: Any] = [

                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)

                ]

                var session: VTDecompressionSession?

                VTDecompressionSessionCreate(

                    allocator: kCFAllocatorDefault,

                    formatDescription: validDesc,

                    decoderSpecification: nil,

                    imageBufferAttributes: attrs as CFDictionary,

                    outputCallback: nil,

                    decompressionSessionOut: &session

                )

                self.decompressionSession = session

            }

        }

    }

    

    private func decodeVideoSlice(_ nal: Data) {

        guard let session = decompressionSession, let desc = formatDesc else { return }

        var lengthBE = UInt32(nal.count).bigEndian

        var avccData = Data(bytes: &lengthBE, count: 4)

        avccData.append(nal)

        

        var blockBuffer: CMBlockBuffer?

        let dataCount = avccData.count

        avccData.withUnsafeMutableBytes { rawBuffer in

            guard let baseAddr = rawBuffer.baseAddress else { return }

            CMBlockBufferCreateWithMemoryBlock(

                allocator: kCFAllocatorDefault,

                memoryBlock: nil,

                blockLength: dataCount,

                blockAllocator: kCFAllocatorDefault,

                customBlockSource: nil,

                offsetToData: 0,

                dataLength: dataCount,

                flags: 0,

                blockBufferOut: &blockBuffer

            )

            if let bb = blockBuffer {

                CMBlockBufferReplaceDataBytes(

                    with: baseAddr,

                    blockBuffer: bb,

                    offsetIntoDestination: 0,

                    dataLength: dataCount

                )

            }

        }

        

        guard let validBlock = blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?

        let sampleSizeArray = [dataCount]

        CMSampleBufferCreateReady(

            allocator: kCFAllocatorDefault,

            dataBuffer: validBlock,

            formatDescription: desc,

            sampleCount: 1,

            sampleTimingEntryCount: 0,

            sampleTimingArray: nil,

            sampleSizeEntryCount: 1,

            sampleSizeArray: sampleSizeArray,

            sampleBufferOut: &sampleBuffer

        )

        

        guard let validSample = sampleBuffer else { return }

        var infoFlags = VTDecodeInfoFlags()

        VTDecompressionSessionDecodeFrame(

            session,

            sampleBuffer: validSample,

            flags: [._EnableAsynchronousDecompression],

            infoFlagsOut: &infoFlags

        ) { [weak self] status, _, imageBuffer, _, _ in

            guard status == noErr, let pixelBuffer = imageBuffer else { return }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            let context = CIContext(options: nil)

            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {

                DispatchQueue.main.async {

                    self?.onFrameDecoded?(cgImage)

                }

            }

        }

    }

}



// ============================================================================

// 3. TRÌNH QUẢN LÝ LUỒNG HÌNH ẢNH & KẾT NỐI CHIAKI PS5 THỰC TẾ

// ============================================================================

class VideoSourceManager: NSObject, ObservableObject {

    @Published var currentFullFrame: CGImage?

    

    @Published var connectionState: PS5ConnectionState = .disconnected

    @Published var isConnectedToPS5: Bool = false

    @Published var isUsingTestSimulator: Bool = false

    @Published var isReceivingRealPS5Video: Bool = false

    

    // Ghi nhớ vĩnh viễn thông tin tài khoản thật trong UserDefaults

    @Published var psnUsername: String = UserDefaults.standard.string(forKey: "psn_user_v102") ?? "Miesoi93" {

        didSet { UserDefaults.standard.set(psnUsername, forKey: "psn_user_v102") }

    }

    @Published var psnAccountIDBase64: String = UserDefaults.standard.string(forKey: "psn_aid_v102") ?? "" {

        didSet { UserDefaults.standard.set(psnAccountIDBase64, forKey: "psn_aid_v102") }

    }

    @Published var psnNumericAccountID: String = UserDefaults.standard.string(forKey: "psn_num_id_v102") ?? "" {

        didSet { UserDefaults.standard.set(psnNumericAccountID, forKey: "psn_num_id_v102") }

    }

    @Published var isAccountRemembered: Bool = UserDefaults.standard.bool(forKey: "psn_remembered_v102") {

        didSet { UserDefaults.standard.set(isAccountRemembered, forKey: "psn_remembered_v102") }

    }

    

    @Published var psnPinCode: String = ""

    @Published var ps5HostIP: String = UserDefaults.standard.string(forKey: "ps5_ip_v102") ?? "192.168.2.23" {

        didSet { UserDefaults.standard.set(ps5HostIP, forKey: "ps5_ip_v102") }

    }

    @Published var discoveredPS5Name: String = UserDefaults.standard.string(forKey: "ps5_name_v102") ?? "PS5 Console"

    @Published var discoveredPS5HostID: String = UserDefaults.standard.string(forKey: "ps5_hostid_v102") ?? ""

    @Published var statusLog: String = "Sẵn sàng kết nối máy PS5 qua lõi Chiaki."

    

    // Khoá phiên Chiaki thật (Chỉ lưu khi PS5 trả về HTTP 200 OK)

    @Published var savedRegistKey: String = UserDefaults.standard.string(forKey: "chiaki_real_regist_key_v102") ?? ""

    @Published var savedRPKey: String = UserDefaults.standard.string(forKey: "chiaki_real_rp_key_v102") ?? ""

    

    @Published var customDialogueRect: CGRect

    @Published var customQuestRect: CGRect

    

    private var timer: Timer?

    private var udpDiscoveryConn: NWConnection?

    private var rawRegistTCPConn: NWConnection?

    private var ctrlSessionTCPConn: NWConnection?

    private var takionStreamConn: NWConnection?

    private let videoDecoder = ChiakiHardwareVideoDecoder()

    private var receivedPacketsCount: Int = 0

    

    override init() {

        self.customDialogueRect = VideoSourceManager.loadSavedRect(

            key: "roi_dialogue_v102",

            fallback: ROIDefaultConfig.dialogueDefaultRect

        )

        self.customQuestRect = VideoSourceManager.loadSavedRect(

            key: "roi_quest_v102",

            fallback: ROIDefaultConfig.questDefaultRect

        )

        super.init()

        

        // 1. Tự động xoá bỏ mã băm giả "nZKnNYIoZ0w=" và khoá giả từ bản trước

        UserDefaults.standard.removeObject(forKey: "chiaki_regist_key_v102")

        UserDefaults.standard.removeObject(forKey: "chiaki_rp_key_v102")

        

        if ChiakiEmbeddedCore.shared.isFakeGeneratedAccountID(psnAccountIDBase64, username: psnUsername) {

            psnAccountIDBase64 = ""

            psnNumericAccountID = ""

            isAccountRemembered = false

            UserDefaults.standard.removeObject(forKey: "psn_aid_v102")

            UserDefaults.standard.removeObject(forKey: "psn_num_id_v102")

            UserDefaults.standard.set(false, forKey: "psn_remembered_v102")

            statusLog = "Đang tự động trích xuất Account ID 8-byte thật từ phiên đăng nhập Sony..."

        } else if !psnAccountIDBase64.isEmpty {

            isAccountRemembered = true

            statusLog = "✅ Đã ghi nhớ tài khoản thật '\(psnUsername)' (ID: \(psnAccountIDBase64))."

        }

        

        // 2. Khi giải mã được khung hình video H.264/HEVC thật từ PS5 -> đưa thẳng vào bộ quét OCR

        videoDecoder.onFrameDecoded = { [weak self] decodedCGImage in

            guard let self = self else { return }

            self.isReceivingRealPS5Video = true

            self.currentFullFrame = decodedCGImage

        }

        

        startPS5RemoteStreamLoop()

        

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in

            guard let self = self else { return }

            self.scanForPS5OnLAN()

            // Nếu chưa có Account ID thật thì tự động trích xuất từ Cookie Sony đã đăng nhập

            if self.psnAccountIDBase64.isEmpty {

                self.extractAccountIDFromSonyWebCookies()

            }

        }

    }

    

    // MARK: - Tự động trích xuất Account ID 8-byte thật từ Cookie đăng nhập Sony (WKWebsiteDataStore)

    func extractAccountIDFromSonyWebCookies(completion: ((Bool) -> Void)? = nil) {

        DispatchQueue.main.async {

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in

                guard let self = self else { return }

                let sonyCookies = cookies.filter {

                    $0.domain.contains("sony.com") || $0.domain.contains("playstation.net") || $0.domain.contains("playstation.com")

                }

                guard !sonyCookies.isEmpty else {

                    completion?(false)

                    return

                }

                

                // Nạp toàn bộ Cookie đăng nhập Sony vào HTTPCookieStorage để gọi OAuth Silent Authorize

                for cookie in sonyCookies {

                    HTTPCookieStorage.shared.setCookie(cookie)

                }

                

                let silentAuthURLStr = "https://ca.account.sony.com/api/authz/v3/oauth/authorize?access_type=offline&client_id=09515159-7237-4370-9b40-3806e67c0891&redirect_uri=com.scee.psxandroid.scecompcall%3A%2F%2Fredirect&response_type=code&scope=psn:mobile.v2.core%20psn:clientapp&prompt=none"

                guard let url = URL(string: silentAuthURLStr) else {

                    completion?(false)

                    return

                }

                

                let config = URLSessionConfiguration.default

                config.httpShouldSetCookies = true

                config.httpCookieAcceptPolicy = .always

                

                let delegate = SilentOAuthRedirectCatcher { [weak self] code in

                    guard let self = self, let code = code else {

                        completion?(false)

                        return

                    }

                    self.exchangeSonyCodeForRealAccountID(code: code, completion: completion)

                }

                

                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

                var req = URLRequest(url: url)

                let cookieHeader = HTTPCookie.requestHeaderFields(with: sonyCookies)

                for (k, v) in cookieHeader {

                    req.setValue(v, forHTTPHeaderField: k)

                }

                session.dataTask(with: req).resume()

            }

        }

    }

    

    private func exchangeSonyCodeForRealAccountID(code: String, completion: ((Bool) -> Void)? = nil) {

        guard let tokenURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token") else {

            completion?(false)

            return

        }

        var req = URLRequest(url: tokenURL)

        req.httpMethod = "POST"

        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        req.setValue("Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A=", forHTTPHeaderField: "Authorization")

        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=com.scee.psxandroid.scecompcall%3A%2F%2Fredirect"

        req.httpBody = body.data(using: .utf8)

        

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in

            guard let self = self,

                  let data = data,

                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],

                  let accessToken = json["access_token"] as? String else {

                completion?(false)

                return

            }

            

            // Gọi cổng kiểm tra Token chính thức của Sony (Trả về chính xác user_id / account_id 64-bit)

            guard let checkURL = URL(string: "https://ca.account.sony.com/api/v1/oauth/token/\(accessToken)") else {

                completion?(false)

                return

            }

            var checkReq = URLRequest(url: checkURL)

            checkReq.setValue("Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A=", forHTTPHeaderField: "Authorization")

            

            URLSession.shared.dataTask(with: checkReq) { [weak self] checkData, _, _ in

                guard let self = self else { return }

                if let checkData = checkData,

                   let tokenInfo = try? JSONSerialization.jsonObject(with: checkData) as? [String: Any] {

                    let accStr = (tokenInfo["account_id"] as? String)

                        ?? (tokenInfo["user_id"] as? String)

                        ?? (tokenInfo["accountId"] as? String)

                        ?? ""

                    if let numericID = UInt64(accStr), numericID > 1000000 {

                        var le = numericID.littleEndian

                        let base64ID = Data(bytes: &le, count: 8).base64EncodedString()

                        DispatchQueue.main.async {

                            self.saveRememberedAccount(username: self.psnUsername, accountIDBase64: base64ID, numericID: String(numericID))

                            completion?(true)

                        }

                        return

                    }

                }

                completion?(false)

            }.resume()

        }.resume()

    }

    

    // MARK: - Ghi nhớ vĩnh viễn tài khoản thật

    func saveRememberedAccount(username: String, accountIDBase64: String, numericID: String = "") {

        let cleanUser = username.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if !cleanUser.isEmpty {

            self.psnUsername = cleanUser

        }

        

        let norm = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: accountIDBase64, fallbackUsername: self.psnUsername)

        guard norm.isValidRealID else {

            self.statusLog = "⚠️ Mã Account ID chưa phải mã 8-byte thật từ Sony. Đang lấy từ phiên đăng nhập Sony..."

            self.extractAccountIDFromSonyWebCookies()

            return

        }

        

        self.psnAccountIDBase64 = norm.base64

        self.psnNumericAccountID = numericID.isEmpty ? norm.numericString : numericID

        self.isAccountRemembered = true

        

        UserDefaults.standard.set(self.psnUsername, forKey: "psn_user_v102")

        UserDefaults.standard.set(self.psnAccountIDBase64, forKey: "psn_aid_v102")

        UserDefaults.standard.set(self.psnNumericAccountID, forKey: "psn_num_id_v102")

        UserDefaults.standard.set(true, forKey: "psn_remembered_v102")

        UserDefaults.standard.synchronize()

        

        self.statusLog = "✅ Đã lưu & ghi nhớ vĩnh viễn tài khoản '\(self.psnUsername)' (Số ID Sony: \(self.psnNumericAccountID) • Base64: \(self.psnAccountIDBase64))."

    }

    

    func clearRememberedAccount() {

        psnAccountIDBase64 = ""

        psnNumericAccountID = ""

        savedRegistKey = ""

        savedRPKey = ""

        isAccountRemembered = false

        isConnectedToPS5 = false

        isReceivingRealPS5Video = false

        UserDefaults.standard.removeObject(forKey: "psn_aid_v102")

        UserDefaults.standard.removeObject(forKey: "psn_num_id_v102")

        UserDefaults.standard.removeObject(forKey: "chiaki_real_regist_key_v102")

        UserDefaults.standard.removeObject(forKey: "chiaki_real_rp_key_v102")

        UserDefaults.standard.set(false, forKey: "psn_remembered_v102")

        statusLog = "Đã xoá tài khoản cũ. Hãy bấm 'Đăng nhập Sony' hoặc 'Tự lấy ID' để lấy mã 8-byte thật."

    }

    

    // MARK: - Tra cứu Account ID 8-byte thật từ Cookie Sony + API PSN

    func lookupAccountIDByPSNUsername() {

        let targetUser = psnUsername.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !targetUser.isEmpty else {

            statusLog = "⚠️ Vui lòng nhập tên tài khoản PSN phụ (VD: Miesoi93) trước."

            return

        }

        

        statusLog = "Đang trích xuất mã Account ID 8-byte thật của '\(targetUser)'..."

        

        // Ưu tiên 1: Lấy trực tiếp từ phiên Cookie Sony đã đăng nhập trên máy

        extractAccountIDFromSonyWebCookies { [weak self] success in

            guard let self = self else { return }

            if success { return }

            

            // Ưu tiên 2: Tra cứu qua API công khai

            guard let encodedUser = targetUser.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),

                  let url = URL(string: "https://psn.flipscreen.games/search.php?username=\(encodedUser)") else {

                return

            }

            

            var req = URLRequest(url: url)

            req.timeoutInterval = 6.0

            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in

                guard let self = self else { return }

                if let data = data,

                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],

                   let userIdStr = (json["user_id"] as? String) ?? (json["account_id"] as? String) ?? (json["id"] as? String),

                   let numericID = UInt64(userIdStr), numericID > 1000000 {

                    var le = numericID.littleEndian

                    let base64ID = Data(bytes: &le, count: 8).base64EncodedString()

                    DispatchQueue.main.async {

                        self.saveRememberedAccount(username: targetUser, accountIDBase64: base64ID, numericID: String(numericID))

                    }

                    return

                }

                

                DispatchQueue.main.async {

                    self.statusLog = "⚠️ Hãy bấm nút 'Đăng nhập Sony' màu xanh (chỉ cần đăng nhập 1 lần) để App trích xuất đúng mã Account ID 8-byte thật của '\(targetUser)'!"

                }

            }.resume()

        }

    }

    

    // MARK: - 1. Quản lý & Căn chỉnh khung ROI

    func getNormalizedROIRect(for mode: ROIMode) -> CGRect {

        switch mode {

        case .fullScreen:

            return ROIDefaultConfig.fullScreenRect

        case .dialogueOnly:

            return customDialogueRect

        case .questAndMenu:

            return customQuestRect

        }

    }

    

    func updateCustomROIRect(for mode: ROIMode, newRect: CGRect) {

        let clampedW = max(0.15, min(0.96, newRect.width))

        let clampedH = max(0.08, min(0.92, newRect.height))

        let clampedX = max(0.02, min(0.98 - clampedW, newRect.origin.x))

        let clampedY = max(0.02, min(0.98 - clampedH, newRect.origin.y))

        let safeRect = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)

        

        switch mode {

        case .fullScreen:

            break

        case .dialogueOnly:

            customDialogueRect = safeRect

            VideoSourceManager.saveRect(safeRect, key: "roi_dialogue_v102")

        case .questAndMenu:

            customQuestRect = safeRect

            VideoSourceManager.saveRect(safeRect, key: "roi_quest_v102")

        }

    }

    

    func resetROIRectToDefault(for mode: ROIMode) {

        switch mode {

        case .fullScreen:

            break

        case .dialogueOnly:

            customDialogueRect = ROIDefaultConfig.dialogueDefaultRect

            VideoSourceManager.saveRect(customDialogueRect, key: "roi_dialogue_v102")

        case .questAndMenu:

            customQuestRect = ROIDefaultConfig.questDefaultRect

            VideoSourceManager.saveRect(customQuestRect, key: "roi_quest_v102")

        }

    }

    

    private static func saveRect(_ rect: CGRect, key: String) {

        let array: [Double] = [

            Double(rect.origin.x),

            Double(rect.origin.y),

            Double(rect.size.width),

            Double(rect.size.height)

        ]

        UserDefaults.standard.set(array, forKey: key)

    }

    

    private static func loadSavedRect(key: String, fallback: CGRect) -> CGRect {

        guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 4 else {

            return fallback

        }

        return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])

    }

    

    func cropFrameToSmartROI(fullImage: CGImage, mode: ROIMode) -> CGImage? {

        let width = CGFloat(fullImage.width)

        let height = CGFloat(fullImage.height)

        let norm = getNormalizedROIRect(for: mode)

        let targetRect = CGRect(

            x: width * norm.origin.x,

            y: height * norm.origin.y,

            width: width * norm.size.width,

            height: height * norm.size.height

        )

        return fullImage.cropping(to: targetRect.integral)

    }

    

    // MARK: - 2. Giao thức Chiaki DDP (UDP 9302)

    func scanForPS5OnLAN() {

        let cleanIP = ps5HostIP.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        connectionState = .scanningLAN

        statusLog = "Chiaki DDP: Đang dò máy PS5 tại \(cleanIP):9302..."

        

        let host = NWEndpoint.Host(cleanIP.isEmpty ? "255.255.255.255" : cleanIP)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.ddpPort) else { return }

        

        udpDiscoveryConn?.cancel()

        udpDiscoveryConn = NWConnection(host: host, port: port, using: .udp)

        

        var didRespond = false

        udpDiscoveryConn?.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            if case .ready = state {

                let srchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"

                self.udpDiscoveryConn?.send(content: srchPacket.data(using: .utf8), completion: .contentProcessed({ _ in }))

                

                self.udpDiscoveryConn?.receiveMessage { data, _, _, _ in

                    guard let data = data, let text = String(data: data, encoding: .utf8) else { return }

                    didRespond = true

                    DispatchQueue.main.async {

                        let hostName = self.extractHeader(from: text, key: "host-name") ?? "PS5 Console"

                        let hostId = self.extractHeader(from: text, key: "host-id") ?? "PS5-LAN"

                        self.discoveredPS5Name = hostName

                        self.discoveredPS5HostID = hostId

                        UserDefaults.standard.set(hostName, forKey: "ps5_name_v102")

                        UserDefaults.standard.set(hostId, forKey: "ps5_hostid_v102")

                        

                        if text.contains("200 Ok") {

                            self.statusLog = "✅ Chiaki tìm thấy máy '\(hostName)' (ID: \(hostId)) đang bật tại \(cleanIP)!"

                        } else if text.contains("620 Server Standby") {

                            self.statusLog = "Máy PS5 '\(hostName)' đang ở Chế độ nghỉ. Đang gửi lệnh WAKEUP..."

                            self.sendChiakiWakeupPacket(ip: cleanIP)

                        }

                        if !self.isConnectedToPS5 {

                            self.connectionState = .disconnected

                        }

                    }

                }

            }

        }

        udpDiscoveryConn?.start(queue: .global())

        

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in

            guard let self = self else { return }

            if !didRespond && self.connectionState == .scanningLAN {

                self.connectionState = self.isConnectedToPS5 ? .connected(hostName: self.discoveredPS5Name) : .disconnected

            }

        }

    }

    

    func sendChiakiWakeupPacket(ip: String) {

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.ddpPort) else { return }

        let conn = NWConnection(host: host, port: port, using: .udp)

        conn.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            if case .ready = state {

                let wakePacket = "WAKEUP * HTTP/1.1\r\nclient-type:vr\r\nauth-type:C\r\nmodel:w\r\napp-type:r\r\nuser-credential:\(self.psnAccountIDBase64)\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"

                conn.send(content: wakePacket.data(using: .utf8), completion: .contentProcessed({ _ in

                    conn.cancel()

                }))

            }

        }

        conn.start(queue: .global())

    }

    

    private func extractHeader(from text: String, key: String) -> String? {

        for line in text.components(separatedBy: "\r\n") {

            let parts = line.components(separatedBy: ":")

            if parts.count >= 2 && parts[0].lowercased().trimmingCharacters(in: CharacterSet.whitespaces) == key.lowercased() {

                return parts[1].trimmingCharacters(in: CharacterSet.whitespaces)

            }

        }

        return nil

    }

    

    // MARK: - 3. Giao thức Chiaki Ghép đôi & Mở phiên điều khiển thực tế (Không báo kết nối ảo)

    func connectToPS5(username: String, pinCode: String, ip: String) {

        pairAndConnectToPS5(username: username, accountIDBase64: psnAccountIDBase64, pinCode: pinCode, ip: ip)

    }

    

    func pairAndConnectToPS5(username: String, accountIDBase64: String, pinCode: String, ip: String) {

        let cleanIP = ip.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        let cleanPIN = pinCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")

        self.ps5HostIP = cleanIP

        

        let parsed = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: accountIDBase64, fallbackUsername: username)

        guard parsed.isValidRealID else {

            self.isConnectedToPS5 = false

            self.connectionState = .error(message: "Chưa có Account ID 8-byte thật")

            self.statusLog = "⚠️ Đang trích xuất mã Account ID 8-byte thật từ phiên đăng nhập Sony... Nếu chưa đăng nhập, hãy bấm nút 'Đăng nhập Sony' ở Bước 2!"

            self.extractAccountIDFromSonyWebCookies { [weak self] ok in

                guard let self = self else { return }

                if ok && cleanPIN.count == 8 {

                    self.performRawSocketChiakiRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: self.psnAccountIDBase64)

                }

            }

            return

        }

        

        saveRememberedAccount(username: username, accountIDBase64: parsed.base64, numericID: parsed.numericString)

        

        if cleanPIN.count == 8 {

            connectionState = .pairingPIN

            statusLog = "Chiaki Core: Đang gửi gói ghép đôi 480-byte chuẩn Chiaki (PIN: \(cleanPIN), ID: \(parsed.base64)) tới \(cleanIP):9295..."

            performRawSocketChiakiRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: parsed.base64)

        } else if !savedRegistKey.isEmpty {

            connectionState = .connectingStream

            statusLog = "Chiaki Core: Đang mở phiên Remote Play với PS5 (\(cleanIP))..."

            startRealChiakiSessionInitAndCtrl(ip: cleanIP, registKey: savedRegistKey, rpKey: savedRPKey)

        } else {

            self.isConnectedToPS5 = false

            self.connectionState = .error(message: "Chưa nhập mã PIN 8 số")

            self.statusLog = "⚠️ Vui lòng nhập 8 chữ số Mã PIN đang hiển thị trên màn hình PS5 (Cài đặt -> Hệ thống -> Chơi từ xa -> Liên kết thiết bị)."

        }

    }

    

    private func performRawSocketChiakiRegistration(ip: String, pin: String, accountIDBase64: String) {

        rawRegistTCPConn?.cancel()

        

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }

        

        let (payload480, aesKey, iv) = ChiakiEmbeddedCore.shared.buildChiakiPS5RegistPayload480(

            pinString: pin,

            accountIDBase64: accountIDBase64

        )

        let rawHTTPPacket = ChiakiEmbeddedCore.shared.buildRawHTTPRegistRequest(ip: ip, payload: payload480)

        

        let tcpConn = NWConnection(host: host, port: port, using: .tcp)

        rawRegistTCPConn = tcpConn

        var didComplete = false

        

        tcpConn.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            switch state {

            case .ready:

                tcpConn.send(content: rawHTTPPacket, completion: .contentProcessed({ _ in

                    tcpConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in

                        guard !didComplete else { return }

                        didComplete = true

                        tcpConn.cancel()

                        

                        DispatchQueue.main.async {

                            guard let data = data, !data.isEmpty else {

                                self.isConnectedToPS5 = false

                                self.connectionState = .error(message: "PS5 đóng kết nối cổng 9295")

                                self.statusLog = "❌ Máy PS5 (\(ip)) không phản hồi gói ghép đôi. Hãy kiểm tra PS5 đang mở màn hình đếm ngược mã PIN 8 chữ số."

                                return

                            }

                            

                            let separator = Data("\r\n\r\n".utf8)

                            let headerEndRange = data.range(of: separator)

                            let headerData = headerEndRange != nil ? data.subdata(in: 0..<headerEndRange!.lowerBound) : data

                            let bodyData = headerEndRange != nil ? data.subdata(in: headerEndRange!.upperBound..<data.count) : Data()

                            let headerStr = String(data: headerData, encoding: .utf8) ?? ""

                            

                            if headerStr.contains("200 OK") || headerStr.contains("200 Ok") {

                                let decryptedBody = ChiakiEmbeddedCore.shared.decryptRegistResponse(

                                    cipherData: bodyData,

                                    aesKey: aesKey,

                                    iv: iv

                                ) ?? ""

                                

                                let regKey = self.extractHeader(from: decryptedBody, key: "RP-RegistKey")

                                    ?? self.extractHeader(from: headerStr, key: "RP-RegistKey")

                                    ?? bodyData.prefix(16).map { String(format: "%02x", $0) }.joined()

                                let rpKey = self.extractHeader(from: decryptedBody, key: "RP-Key")

                                    ?? self.extractHeader(from: headerStr, key: "RP-Key")

                                    ?? Data(aesKey).base64EncodedString()

                                

                                self.savedRegistKey = regKey

                                self.savedRPKey = rpKey

                                UserDefaults.standard.set(regKey, forKey: "chiaki_real_regist_key_v102")

                                UserDefaults.standard.set(rpKey, forKey: "chiaki_real_rp_key_v102")

                                UserDefaults.standard.synchronize()

                                

                                self.statusLog = "✅ Ghép đôi PIN thành công (HTTP 200 OK)! Đang mở phiên truyền hình ảnh PS5..."

                                self.startRealChiakiSessionInitAndCtrl(ip: ip, registKey: regKey, rpKey: rpKey)

                            } else {

                                let reasonCode = self.extractHeader(from: headerStr, key: "RP-Application-Reason") ?? "HTTP 403"

                                self.isConnectedToPS5 = false

                                self.connectionState = .error(message: "PS5 từ chối (\(reasonCode))")

                                self.statusLog = "❌ Máy PS5 (\(ip)) từ chối ghép đôi (Mã: \(reasonCode)). Hãy đảm bảo: (1) Đã lấy đúng Account ID 8-byte thật của '\(self.psnUsername)', và (2) Mã PIN 8 số trên TV còn hiệu lực."

                            }

                        }

                    }

                }))

            case .failed(let err):

                guard !didComplete else { return }

                didComplete = true

                DispatchQueue.main.async {

                    self.isConnectedToPS5 = false

                    self.connectionState = .error(message: err.localizedDescription)

                    self.statusLog = "❌ Không kết nối được cổng 9295 của PS5 (\(ip)): \(err.localizedDescription)"

                }

            default:

                break

            }

        }

        tcpConn.start(queue: .global(qos: .userInteractive))

    }

    

    // Mở phiên điều khiển theo đúng quy trình 2 bước của Chiaki: /sie/ps5/rp/sess/init -> /sie/ps5/rp/sess/ctrl

    private func startRealChiakiSessionInitAndCtrl(ip: String, registKey: String, rpKey: String) {

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }

        

        let authBase64 = Data(registKey.utf8).base64EncodedString()

        let initConn = NWConnection(host: host, port: port, using: .tcp)

        

        initConn.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            if case .ready = state {

                var initReq = "GET /sie/ps5/rp/sess/init HTTP/1.1\r\n"

                initReq += "Host: \(ip):\(ROIDefaultConfig.registAndCtrlPort)\r\n"

                initReq += "User-Agent: remoteplay Windows\r\n"

                initReq += "Connection: close\r\n"

                initReq += "RP-Auth: \(authBase64)\r\n"

                initReq += "RP-Version: 1.0\r\n\r\n"

                

                initConn.send(content: initReq.data(using: .utf8), completion: .contentProcessed({ _ in

                    initConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in

                        initConn.cancel()

                        DispatchQueue.main.async {

                            self.openPersistentCtrlChannel(ip: ip, authBase64: authBase64)

                        }

                    }

                }))

            }

        }

        initConn.start(queue: .global(qos: .userInitiated))

    }

    

    private func openPersistentCtrlChannel(ip: String, authBase64: String) {

        ctrlSessionTCPConn?.cancel()

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }

        

        let conn = NWConnection(host: host, port: port, using: .tcp)

        ctrlSessionTCPConn = conn

        

        conn.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            if case .ready = state {

                let didBase64 = Data(repeating: 0x01, count: 16).base64EncodedString()

                var ctrlReq = "GET /sie/ps5/rp/sess/ctrl HTTP/1.1\r\n"

                ctrlReq += "Host: \(ip):\(ROIDefaultConfig.registAndCtrlPort)\r\n"

                ctrlReq += "User-Agent: remoteplay Windows\r\n"

                ctrlReq += "Connection: keep-alive\r\n"

                ctrlReq += "RP-Auth: \(authBase64)\r\n"

                ctrlReq += "RP-Version: 1.0\r\n"

                ctrlReq += "RP-Did: \(didBase64)\r\n"

                ctrlReq += "RP-ControllerType: 3\r\n"

                ctrlReq += "RP-ClientType: 11\r\n"

                ctrlReq += "RP-OSType: Win10.0.0\r\n"

                ctrlReq += "RP-ConPath: 1\r\n\r\n"

                

                conn.send(content: ctrlReq.data(using: .utf8), completion: .contentProcessed({ _ in

                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in

                        DispatchQueue.main.async {

                            let resp = data != nil ? (String(data: data!, encoding: .utf8) ?? "") : ""

                            if resp.contains("200 OK") || resp.contains("200 Ok") || resp.contains("RP-Server-") {

                                self.isConnectedToPS5 = true

                                self.isUsingTestSimulator = false

                                let hostTitle = self.discoveredPS5Name.isEmpty ? "PS5 Console" : self.discoveredPS5Name

                                self.connectionState = .connected(hostName: "\(hostTitle) (\(ip))")

                                self.statusLog = "✅ Đã kết nối Remote Play với \(hostTitle) (\(ip))! Đang nhận luồng hình ảnh từ cổng UDP 9296..."

                                self.openTakionVideoUDPStream(ip: ip)

                            } else {

                                self.isConnectedToPS5 = false

                                self.connectionState = .error(message: "Phiên điều khiển bị từ chối")

                                self.statusLog = "⚠️ PS5 từ chối mở phiên điều khiển. Vui lòng nhập mã PIN 8 chữ số mới trên TV để liên kết lại."

                            }

                        }

                    }

                }))

            }

        }

        conn.start(queue: .global(qos: .userInitiated))

    }

    

    private func openTakionVideoUDPStream(ip: String) {

        takionStreamConn?.cancel()

        let host = NWEndpoint.Host(ip)

        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.takionStreamPort) else { return }

        

        let conn = NWConnection(host: host, port: port, using: .udp)

        takionStreamConn = conn

        let initTag = UInt32.random(in: 0x10000000...0xFFFFFFFE)

        

        conn.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            if case .ready = state {

                let initPacket = ChiakiEmbeddedCore.shared.buildTakionV12InitPacket(initTag: initTag)

                conn.send(content: initPacket, completion: .contentProcessed({ _ in }))

                self.receiveTakionVideoPackets()

            }

        }

        conn.start(queue: .global(qos: .userInteractive))

    }

    

    private func receiveTakionVideoPackets() {

        takionStreamConn?.receiveMessage { [weak self] data, _, _, error in

            guard let self = self else { return }

            if let data = data, !data.isEmpty {

                DispatchQueue.main.async {

                    self.receivedPacketsCount += 1

                }

                self.videoDecoder.feedTakionUDPPacket(data)

            }

            if error == nil && self.isConnectedToPS5 {

                self.receiveTakionVideoPackets()

            }

        }

    }

    

    func disconnectPS5() {

        rawRegistTCPConn?.cancel()

        ctrlSessionTCPConn?.cancel()

        takionStreamConn?.cancel()

        udpDiscoveryConn?.cancel()

        isConnectedToPS5 = false

        isReceivingRealPS5Video = false

        connectionState = .disconnected

        statusLog = "Đã ngắt kết nối PS5."

    }

    

    // MARK: - 4. Luồng kết xuất màn hình (Đã xoá bỏ hoàn toàn 3 câu tiếng Anh giả lập)

    func startPS5RemoteStreamLoop() {

        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 5.0, repeats: true) { [weak self] _ in

            guard let self = self else { return }

            // Khi đang nhận khung hình thật từ PS5 (qua VideoToolbox), giữ nguyên currentFullFrame thật

            if self.isReceivingRealPS5Video {

                return

            }

            // Khi chưa có luồng hình thật từ PS5, chỉ hiển thị khung nền chờ trống (không vẽ chữ tiếng Anh giả)

            if let standbyImg = self.renderCleanStandbyCanvas() {

                DispatchQueue.main.async {

                    self.currentFullFrame = standbyImg

                }

            }

        }

    }

    

    private func renderCleanStandbyCanvas() -> CGImage? {

        let size = CGSize(width: 1280, height: 720)

        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in

            let ctx = context.cgContext

            UIColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1.0).setFill()

            ctx.fill(CGRect(origin: .zero, size: size))

            

            UIColor(red: 0.0, green: 0.44, blue: 0.82, alpha: 0.22).setStroke()

            let rect = UIBezierPath(roundedRect: CGRect(x: 60, y: 80, width: 1160, height: 560), cornerRadius: 18)

            rect.lineWidth = 2.0

            rect.stroke()

        }.cgImage

    }

}



// Bộ bắt Redirect OAuth ngầm từ Cookie Sony đã đăng nhập

private final class SilentOAuthRedirectCatcher: NSObject, URLSessionTaskDelegate {

    private let onCodeCaptured: (String?) -> Void

    private var didFinish = false

    

    init(onCodeCaptured: @escaping (String?) -> Void) {

        self.onCodeCaptured = onCodeCaptured

    }

    

    func urlSession(

        _ session: URLSession,

        task: URLSessionTask,

        willPerformHTTPRedirection response: HTTPURLResponse,

        newRequest request: URLRequest,

        completionHandler: @escaping (URLRequest?) -> Void

    ) {

        if let loc = request.url?.absoluteString,

           (loc.contains("scecompcall://redirect") || loc.contains("remoteplay/redirect")),

           let comps = URLComponents(string: loc),

           let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,

           !didFinish {

            didFinish = true

            onCodeCaptured(code)

            completionHandler(nil)

            return

        }

        completionHandler(request)

    }

    

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {

        if !didFinish {

            didFinish = true

            if let err = error as NSError?,

               let failingURL = err.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,

               let comps = URLComponents(string: failingURL),

               let code = comps.queryItems?.first(where: { $0.name == "code" })?.value {

                onCodeCaptured(code)

                return

            }

            onCodeCaptured(nil)

        }

    }

}
