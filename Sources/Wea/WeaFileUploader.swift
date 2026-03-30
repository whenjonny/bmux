// Sources/Wea/WeaFileUploader.swift
import Foundation
import os

/// Orchestrates the 3-step Difft encrypted file upload flow:
/// 1. `POST /v1/file/isExists` — register file, get authorizeId and upload URL
/// 2. `PUT <oss-url>` — upload encrypted payload to Alibaba Cloud OSS (skip if exists)
/// 3. `POST /v1/file/uploadInfo` — confirm upload
final class WeaFileUploader {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaFileUploader")
    private let baseURL = "https://openapi.difft.org"
    private let session = URLSession.shared

    private let appId: String
    private let appSecret: String
    private let botId: String

    struct UploadResult {
        let authorizeId: String
        let key: String           // base64 key for attachment
        let cipherHash: String    // hex MD5 for attachment "digest"
        let encryptedSize: Int    // for attachment "size"
    }

    init(appId: String, appSecret: String, botId: String) {
        self.appId = appId
        self.appSecret = appSecret
        self.botId = botId
    }

    /// Upload file data through the Difft encrypted upload flow.
    func upload(data: Data, dest: WeaMessageDest) async throws -> UploadResult {
        // Encrypt
        guard let encrypted = WeaFileCrypto.encrypt(data) else {
            throw WeaError.apiError(statusCode: 0, body: "File encryption failed")
        }

        weaUploadLog("Encrypted: plaintext=\(data.count)B payload=\(encrypted.data.count)B cipherHash=\(encrypted.cipherHash)")

        // Step 1: Check if file exists / register
        let existsResult = try await checkFileExists(
            fileHash: encrypted.fileHash,
            fileSize: encrypted.data.count,
            dest: dest
        )

        weaUploadLog("isExists: exists=\(existsResult.exists) authorizeId=\(existsResult.authorizeId)")

        // Step 2: Upload to OSS if needed
        if !existsResult.exists, let uploadURL = existsResult.url {
            try await uploadToOSS(url: uploadURL, data: encrypted.data)
            weaUploadLog("OSS upload complete")
        }

        // Step 3: Confirm upload
        let authorizeId = try await confirmUpload(
            authorizeId: existsResult.authorizeId,
            attachmentId: existsResult.attachmentId,
            fileHash: encrypted.fileHash,
            cipherHash: encrypted.cipherHash,
            encryptedSize: encrypted.data.count,
            dest: dest
        )

        weaUploadLog("Upload confirmed: authorizeId=\(authorizeId)")

        return UploadResult(
            authorizeId: authorizeId,
            key: encrypted.key,
            cipherHash: encrypted.cipherHash,
            encryptedSize: encrypted.data.count
        )
    }

    // MARK: - Step 1: isExists

    private struct ExistsResponse {
        let authorizeId: String
        let attachmentId: String
        let url: String?
        let exists: Bool
    }

    private func checkFileExists(
        fileHash: String,
        fileSize: Int,
        dest: WeaMessageDest
    ) async throws -> ExistsResponse {
        var body: [String: Any] = [
            "wuid": botId,
            "fileHash": fileHash,
            "fileSize": fileSize,
        ]
        // Authorize for the destination
        switch dest.type {
        case .group:
            if let groupId = dest.groupId {
                body["gids"] = [groupId]
            }
        case .user:
            if let wuid = dest.wuid {
                body["numbers"] = [wuid]
            }
        }

        let responseData = try await signedPost(path: "/v1/file/isExists", body: body)

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let status = json["status"] as? Int, status == 0,
              let data = json["data"] as? [String: Any] else {
            let respStr = String(data: responseData, encoding: .utf8) ?? ""
            throw WeaError.apiError(statusCode: 0, body: "isExists failed: \(respStr)")
        }

        return ExistsResponse(
            authorizeId: data["authorizeId"] as? String ?? "",
            attachmentId: data["attachmentId"] as? String ?? "",
            url: data["url"] as? String,
            exists: data["exists"] as? Bool ?? false
        )
    }

    // MARK: - Step 2: OSS Upload

    private func uploadToOSS(url: String, data: Data) async throws {
        guard let uploadURL = URL(string: url) else {
            throw WeaError.apiError(statusCode: 0, body: "Invalid OSS URL")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw WeaError.apiError(statusCode: httpResponse.statusCode, body: "OSS upload failed")
        }
    }

    // MARK: - Step 3: Confirm Upload

    private func confirmUpload(
        authorizeId: String,
        attachmentId: String,
        fileHash: String,
        cipherHash: String,
        encryptedSize: Int,
        dest: WeaMessageDest
    ) async throws -> String {
        var body: [String: Any] = [
            "wuid": botId,
            "authorizeId": authorizeId,
            "attachmentId": attachmentId,
            "fileHash": fileHash,
            "cipherHash": cipherHash,
            "fileSize": encryptedSize,
            "hashAlg": "sha256",
            "keyAlg": "sha256",
            "encAlg": "sha256",
            "cipherHashType": "MD5",
        ]
        switch dest.type {
        case .group:
            if let groupId = dest.groupId {
                body["gids"] = [groupId]
            }
        case .user:
            if let wuid = dest.wuid {
                body["numbers"] = [wuid]
            }
        }

        let responseData = try await signedPost(path: "/v1/file/uploadInfo", body: body)

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let status = json["status"] as? Int, status == 0,
              let data = json["data"] as? [String: Any] else {
            let respStr = String(data: responseData, encoding: .utf8) ?? ""
            throw WeaError.apiError(statusCode: 0, body: "uploadInfo failed: \(respStr)")
        }

        return data["authorizeId"] as? String ?? authorizeId
    }

    // MARK: - Signed POST Helper

    private func signedPost(path: String, body: [String: Any]) async throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? ""

        let signed = WeaSignature.signPost(
            appId: appId, appSecret: appSecret,
            path: path, jsonBody: jsonStr
        )

        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in signed.httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let respBody = String(data: data, encoding: .utf8) ?? ""
            throw WeaError.apiError(statusCode: httpResponse.statusCode, body: respBody)
        }
        return data
    }

    // MARK: - Logging

    private func weaUploadLog(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] [Upload] \(message)\n"
        let path = "/tmp/cmux-wea-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
