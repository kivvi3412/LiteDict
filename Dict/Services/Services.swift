import AVFoundation
import Foundation

@MainActor
final class Services {
    static let shared = Services()

    static let youdaoUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)"

    let session: URLSession
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    var audioPlayer: AVAudioPlayer?
    var wordLookupCache: [String: WordLookupResult] = [:]
    var wordLookupCacheOrder: [String] = []
    let wordLookupCacheLimit = 60

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        loadPersistedWordLookupCache()
    }

    func validatedHTTPResponse(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DictError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DictError.httpStatus(httpResponse.statusCode, serverMessage(from: data))
        }
        return httpResponse
    }

    func serverMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String {
                return message
            }
        }

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(raw.prefix(800))
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DictError.decodingFailed(error.localizedDescription)
        }
    }
}
