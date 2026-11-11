import Foundation
import TDLibFramework

typealias JSON = [String: Any]

/// An error returned by TDLib (`error` object) or produced locally.
struct TDError: LocalizedError {
    let code: Int
    let message: String

    var errorDescription: String? { message }
}

/// The single reader of `td_receive`. TDLib allows only one thread to call it
/// for all clients, so every `TDClient` registers here and gets its own
/// responses and updates routed back by `@client_id`.
final class TDReceiver: @unchecked Sendable {
    static let shared = TDReceiver()

    private let lock = NSLock()
    private var clients: [Int32: TDClient] = [:]
    private var thread: Thread?

    private init() {}

    func register(_ client: TDClient) {
        lock.lock()
        clients[client.id] = client
        let needsThread = thread == nil
        lock.unlock()
        if needsThread { startThread() }
    }

    func unregister(_ client: TDClient) {
        lock.lock()
        clients[client.id] = nil
        lock.unlock()
    }

    private func startThread() {
        let thread = Thread { [weak self] in
            while true {
                guard let self else { return }
                guard let raw = td_receive(1.0) else { continue }
                let data = Data(bytes: raw, count: strlen(raw))
                guard let object = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
                let clientID = (object["@client_id"] as? NSNumber)?.int32Value ?? 0
                self.lock.lock()
                let client = self.clients[clientID]
                self.lock.unlock()
                client?.receive(object)
            }
        }
        thread.name = "TDLib receive"
        thread.qualityOfService = .userInitiated
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()
    }
}

/// A thin async wrapper over TDLib's JSON interface.
final class TDClient: @unchecked Sendable {
    let id: Int32

    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    private var nextExtra: UInt64 = 0
    private let onUpdate: @Sendable (JSON) -> Void

    /// `onUpdate` is called on the receive thread, in TDLib's order.
    init(onUpdate: @escaping @Sendable (JSON) -> Void) {
        TDClient.configureLoggingOnce()
        self.id = td_create_client_id()
        self.onUpdate = onUpdate
        TDReceiver.shared.register(self)
    }

    func close() {
        TDReceiver.shared.unregister(self)
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for continuation in waiting.values {
            continuation.resume(throwing: TDError(code: 500, message: "Client closed"))
        }
    }

    /// Sends a request and returns TDLib's response object.
    /// Throws `TDError` when TDLib answers with an `error`.
    @discardableResult
    func send(_ request: JSON) async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            nextExtra += 1
            let extra = "toss-\(nextExtra)"
            pending[extra] = continuation
            lock.unlock()

            var request = request
            request["@extra"] = extra
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  let string = String(data: data, encoding: .utf8) else {
                lock.lock()
                pending[extra] = nil
                lock.unlock()
                continuation.resume(throwing: TDError(code: 400, message: "Invalid request"))
                return
            }
            td_send(id, string)
        }
    }

    /// Fire-and-forget request.
    func post(_ request: JSON) {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let string = String(data: data, encoding: .utf8) else { return }
        td_send(id, string)
    }

    fileprivate func receive(_ object: JSON) {
        if let extra = object["@extra"] as? String {
            lock.lock()
            let continuation = pending.removeValue(forKey: extra)
            lock.unlock()
            guard let continuation else { return }
            if object["@type"] as? String == "error" {
                let code = (object["code"] as? NSNumber)?.intValue ?? 0
                let message = object["message"] as? String ?? "Unknown error"
                continuation.resume(throwing: TDError(code: code, message: message))
            } else {
                continuation.resume(returning: object)
            }
            return
        }
        onUpdate(object)
    }

    /// Synchronous TDLib call for methods documented as "Can be called synchronously".
    @discardableResult
    static func execute(_ request: JSON) -> JSON? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let string = String(data: data, encoding: .utf8),
              let raw = td_execute(string) else { return nil }
        let result = Data(bytes: raw, count: strlen(raw))
        return try? JSONSerialization.jsonObject(with: result) as? JSON
    }

    /// TDLib version string; also proves the framework is linked and loads.
    static var version: String? {
        let result = execute(["@type": "getOption", "name": "version"])
        return result?["value"] as? String
    }

    private static let loggingConfigured: Void = {
        // Errors only; TDLib's default verbosity floods stderr.
        execute(["@type": "setLogVerbosityLevel", "new_verbosity_level": 1])
    }()

    private static func configureLoggingOnce() { _ = loggingConfigured }
}

// MARK: - JSON helpers

extension Dictionary where Key == String, Value == Any {
    var type: String? { self["@type"] as? String }

    func int64(_ key: String) -> Int64? {
        if let number = self[key] as? NSNumber { return number.int64Value }
        if let string = self[key] as? String { return Int64(string) }
        return nil
    }

    func int(_ key: String) -> Int? { int64(key).map { Int($0) } }

    func string(_ key: String) -> String? { self[key] as? String }

    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }

    func object(_ key: String) -> JSON? { self[key] as? JSON }

    func objects(_ key: String) -> [JSON] { self[key] as? [JSON] ?? [] }
}

/// Collects every `file` object nested anywhere inside a TDLib object.
func collectFiles(in value: Any) -> [JSON] {
    if let object = value as? JSON {
        if object.type == "file" { return [object] }
        return object.values.flatMap { collectFiles(in: $0) }
    }
    if let array = value as? [Any] {
        return array.flatMap { collectFiles(in: $0) }
    }
    return []
}
