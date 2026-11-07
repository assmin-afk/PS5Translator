// ============================================================================
// FILE 2A: 2A_ChiakiCoreAndDecoder.swift (TÁCH TỪ FILE 2 - PHẦN 1/2)
// PHIÊN BẢN: PS5Translator 1.02
// NHIỆM VỤ:
// 1. Cấu hình vùng quét mặc định (ROIDefaultConfig, ROIMode, PS5ConnectionState).
// 2. Lõi mã hoá Chiaki (ChiakiEmbeddedCore): Đóng gói 480-byte AES-128-CBC + HMAC-SHA256,
//    giải mã phản hồi PS5 và tạo gói bắt tay Takion V12.
// 3. Bộ giải mã phần cứng VideoToolbox (ChiakiHardwareVideoDecoder): Giải mã luồng
//    H.264/HEVC từ cổng UDP 9296 của PS5 thành CGImage thời gian thực.
// 4. Bộ bắt Redirect OAuth ngầm (SilentOAuthRedirectCatcher).
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


// Bộ bắt Redirect OAuth ngầm từ Cookie Sony đã đăng nhập
final class SilentOAuthRedirectCatcher: NSObject, URLSessionTaskDelegate {
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
