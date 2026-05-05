import Foundation
import CommonCrypto

enum EncryptedHLSDecoder {
    static func ivData(from ivHex: String?, sequence: Int) throws -> Data {
        if let ivHex, !ivHex.isEmpty {
            let stripped = ivHex.hasPrefix("0x") ? String(ivHex.dropFirst(2)) : ivHex
            guard stripped.count <= 32, stripped.count % 2 == 0 else {
                throw DownloadError.downloadFailed("Invalid HLS IV: \(ivHex)")
            }
            var bytes = Data()
            bytes.reserveCapacity(16)
            var index = stripped.startIndex
            while index < stripped.endIndex {
                let next = stripped.index(index, offsetBy: 2)
                guard let byte = UInt8(stripped[index..<next], radix: 16) else {
                    throw DownloadError.downloadFailed("Invalid HLS IV: \(ivHex)")
                }
                bytes.append(byte)
                index = next
            }
            if bytes.count < 16 {
                bytes.insert(contentsOf: Array(repeating: 0, count: 16 - bytes.count), at: 0)
            }
            return bytes
        }

        var seq = UInt64(sequence)
        var iv = Data(count: 16)
        for i in 0..<8 {
            iv[15 - i] = UInt8(seq & 0xff)
            seq >>= 8
        }
        return iv
    }

    static func decryptAES128CBC(data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw DownloadError.downloadFailed("Invalid AES-128 key/IV size")
        }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var outLength: size_t = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw DownloadError.downloadFailed("AES-128 decrypt failed")
        }
        out.removeSubrange(outLength..<out.count)
        return out
    }
}
