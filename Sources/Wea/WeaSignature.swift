import CryptoKit
import Foundation

/// HMAC-SHA256 signing for the WEA (Difft) OpenAPI.
///
/// Matches the `@wea/wea-sdk-js` `RequestApi` signing exactly:
///
///   POST: calcStr = `${appid};${timestamp};${nonce};POST;${path};content-length=${utf8ByteLen},content-type=${contentType};${jsonBody}`
///   GET:  calcStr = `${appid};${timestamp};${nonce};GET;${path};${sortedQueryParams}`
///   WS:   calcStr = `${appid};${timestamp};${nonce};GET;/v1/websocket;`
///
///   signature = HmacSHA256(calcStr, secret).toString()  // hex output
///   nonce = uuid without dashes
enum WeaSignature {

    // MARK: - Signed headers

    /// The set of HTTP headers required to authenticate a WEA API request.
    struct SignedHeaders {
        let appId: String
        let timestamp: String
        let nonce: String
        let algorithm: String
        let signature: String
        let signedHeaders: String

        /// Returns the X-Signature-* headers for a `URLRequest`.
        /// Note: Content-Type is NOT included here — callers (e.g. WeaHttpClient)
        /// set it separately for POST requests. WebSocket upgrade must NOT have it.
        var httpHeaders: [String: String] {
            [
                "X-Signature-appid": appId,
                "X-Signature-timestamp": timestamp,
                "X-Signature-nonce": nonce,
                "X-Signature-algorithm": algorithm,
                "X-Signature-signedHeaders": signedHeaders,
                "X-Signature-signature": signature,
            ]
        }
    }

    // MARK: - Public API

    /// Sign a WebSocket connection request.
    ///
    /// SDK format:
    /// ```
    /// calcStr = "${appid};${ts};${nonce};GET;/v1/websocket;"
    /// ```
    static func signWebSocket(appId: String, appSecret: String) -> SignedHeaders {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let calcStr = "\(appId);\(timestamp);\(nonce);GET;/v1/websocket;"
        let signature = hmacSHA256(message: calcStr, secret: appSecret)

        return SignedHeaders(
            appId: appId,
            timestamp: timestamp,
            nonce: nonce,
            algorithm: "HmacSHA256",
            signature: signature,
            signedHeaders: ""
        )
    }

    /// Sign a POST request to the WEA API.
    ///
    /// SDK format:
    /// ```
    /// calcStr = "${appid};${ts};${nonce};POST;${path};content-length=${byteLen},content-type=application/json;charset=utf-8;${jsonBody}"
    /// ```
    static func signPost(
        appId: String,
        appSecret: String,
        path: String,
        jsonBody: String
    ) -> SignedHeaders {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let contentType = "application/json;charset=utf-8"

        let byteLen = jsonBody.utf8.count
        let signatureData = "content-length=\(byteLen),content-type=\(contentType);\(jsonBody)"
        let calcStr = "\(appId);\(timestamp);\(nonce);POST;\(path);\(signatureData)"
        let signature = hmacSHA256(message: calcStr, secret: appSecret)

        return SignedHeaders(
            appId: appId,
            timestamp: timestamp,
            nonce: nonce,
            algorithm: "HmacSHA256",
            signature: signature,
            signedHeaders: "Content-Length,Content-Type"
        )
    }

    /// Sign a GET request to the WEA API.
    ///
    /// SDK format:
    /// ```
    /// calcStr = "${appid};${ts};${nonce};GET;${path};${sortedQueryParams}"
    /// ```
    /// - Parameter sortedQuery: Canonical query string sorted by key (e.g. `a=1&b=2`), or empty string.
    static func signGet(
        appId: String,
        appSecret: String,
        path: String,
        sortedQuery: String = ""
    ) -> SignedHeaders {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let calcStr = "\(appId);\(timestamp);\(nonce);GET;\(path);\(sortedQuery)"
        let signature = hmacSHA256(message: calcStr, secret: appSecret)

        return SignedHeaders(
            appId: appId,
            timestamp: timestamp,
            nonce: nonce,
            algorithm: "HmacSHA256",
            signature: signature,
            signedHeaders: ""
        )
    }

    // MARK: - Private

    /// Compute HMAC-SHA256 and return the result as a lowercase hex string.
    private static func hmacSHA256(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
