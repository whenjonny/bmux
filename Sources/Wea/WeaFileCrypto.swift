// Sources/Wea/WeaFileCrypto.swift
import CommonCrypto
import CryptoKit
import Foundation

/// Client-side encryption for WEA Difft file uploads.
/// Matches the `@wea/wea-sdk-js` `getFileHash` + `getCipherHash` implementation exactly.
enum WeaFileCrypto {

    struct EncryptedPayload {
        let data: Data          // iv(16) + ciphertext + mac(32)
        let key: String         // base64(SHA512(plaintext))
        let fileHash: String    // base64(SHA256(key_bytes))
        let cipherHash: String  // hex(MD5(data))
    }

    /// Encrypt plaintext data for Difft file upload.
    ///
    /// Steps (matching wea-sdk-js):
    /// 1. `key = SHA512(plaintext)` → 64 bytes, base64-encoded
    /// 2. `fileHash = base64(SHA256(key_raw_bytes))`
    /// 3. `iv = random 16 bytes`
    /// 4. `partKey = key[0..<32]`, `part2Key = key[32..<64]`
    /// 5. `ciphertext = AES-256-CBC-PKCS7(plaintext, partKey, iv)`
    /// 6. `mac = HMAC-SHA256(iv + ciphertext, part2Key)`
    /// 7. `payload = iv + ciphertext + mac`
    /// 8. `cipherHash = hex(MD5(payload))`
    static func encrypt(_ plaintext: Data) -> EncryptedPayload? {
        // 1. key = SHA512(plaintext) → 64 bytes
        let keyDigest = SHA512.hash(data: plaintext)
        let keyBytes = Data(keyDigest)  // 64 bytes
        let base64Key = keyBytes.base64EncodedString()

        // 2. fileHash = base64(SHA256(key_bytes))
        let fileHashDigest = SHA256.hash(data: keyBytes)
        let fileHash = Data(fileHashDigest).base64EncodedString()

        // 3. iv = random 16 bytes
        var iv = Data(count: 16)
        let status = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { return nil }

        // 4. Split key
        let partKey = keyBytes[0..<32]   // AES-256 key
        let part2Key = keyBytes[32..<64] // HMAC key

        // 5. AES-256-CBC with PKCS7 padding
        guard let ciphertext = aesCBCEncrypt(data: plaintext, key: partKey, iv: iv) else { return nil }

        // 6. mac = HMAC-SHA256(iv + ciphertext, part2Key)
        var hmacInput = Data()
        hmacInput.append(iv)
        hmacInput.append(ciphertext)
        let hmacKey = SymmetricKey(data: part2Key)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: hmacInput, using: hmacKey))

        // 7. payload = iv + ciphertext + mac
        var payload = Data()
        payload.append(iv)
        payload.append(ciphertext)
        payload.append(mac)

        // 8. cipherHash = hex(MD5(payload))
        let md5 = Insecure.MD5.hash(data: payload)
        let cipherHash = md5.map { String(format: "%02x", $0) }.joined()

        return EncryptedPayload(
            data: payload,
            key: base64Key,
            fileHash: fileHash,
            cipherHash: cipherHash
        )
    }

    // MARK: - Private

    private static func aesCBCEncrypt(data: Data, key: Data, iv: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesEncrypted = 0

        let cryptStatus = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            bufferPtr.baseAddress, bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }

        guard cryptStatus == kCCSuccess else { return nil }
        return buffer.prefix(numBytesEncrypted)
    }
}
