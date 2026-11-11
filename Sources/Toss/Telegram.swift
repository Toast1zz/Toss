import AppKit
import Foundation

struct ChatInfo: Identifiable, Equatable {
    enum Kind: Equatable { case user, group, channel, savedMessages }

    let id: Int64
    var title: String
    var kind: Kind
    var photoFileID: Int?
    /// The 640px version; used when TDLib already has it but not the small one.
    var bigPhotoFileID: Int?
    var photoPath: String?
    /// Tiny blurred JPEG that ships with the chat; shown until the photo is on disk.
    var miniThumbnail: Data?
    /// For private chats: the other user, used to find a profile photo
    /// when the chat itself has none.
    var userID: Int64?
}

/// Owns the TDLib client: login flow, chat list, avatar downloads and sending.
@MainActor
final class Telegram: ObservableObject {
    static let shared = Telegram()

    enum Step: Equatable {
        case credentials
        case starting
        case phone
        case code(hint: String)
        case password(hint: String)
        case email
        case emailCode(pattern: String)
        case blocked(String)
        case ready
        case loggingOut
    }

    @Published private(set) var step: Step = .starting
    @Published private(set) var busy = false
    @Published var errorMessage: String?
    @Published private(set) var chats: [Int64: ChatInfo] = [:]
    /// Order of chats in the main chat list (higher is newer).
    @Published private(set) var mainListOrder: [Int64: Int64] = [:]
    @Published private(set) var savedMessagesID: Int64?
    @Published private(set) var isConnected = true
    @Published private(set) var accountName: String?

    private var client: TDClient?
    private var credentials: APICredentials?
    private var afterClose: AfterClose = .restart
    private var isShuttingDown = false
    private var photoFileOwners: [Int: Set<Int64>] = [:]
    private var downloads: [Int: DownloadState] = [:]
    private var profilePhotoLookups: Set<Int64> = []
    /// Upload progress listeners per file; parallel sends of the same file each get one.
    private var uploadWatchers: [Int: [UUID: (JSON) -> Void]] = [:]
    private var sendWaiters: [Int64: CheckedContinuation<Void, Error>] = [:]
    private var sendOutcomes: [Int64: Result<Void, TDError>] = [:]

    private enum AfterClose { case restart, forgetCredentials }

    /// One avatar file's download bookkeeping, so failures are retried.
    private struct DownloadState {
        var attempts = 0
        var lastRequest: Date?
    }


    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard client == nil else { return }
        guard let credentials = APICredentials.load() else {
            step = .credentials
            return
        }
        self.credentials = credentials
        startClient()
    }

    private func startClient() {
        step = .starting
        let client = TDClient { [weak self] update in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(update) }
            }
        }
        self.client = client
        // Any request wakes the client up; it then reports its authorization state.
        client.post(["@type": "getOption", "name": "version"])
    }

    /// Saves new API credentials and starts logging in.
    func saveCredentials(apiID: Int32, apiHash: String) {
        let credentials = APICredentials(apiID: apiID, apiHash: apiHash)
        guard credentials.save() else {
            errorMessage = L("Couldn't save to Keychain.")
            return
        }
        errorMessage = nil
        self.credentials = credentials
        if client == nil { startClient() }
    }

    /// Goes back to the API credentials step. Only offered before login, so the
    /// TDLib folder holds no session yet and is safe to discard.
    func changeCredentials() {
        errorMessage = nil
        guard let client else {
            forgetCredentials()
            return
        }
        afterClose = .forgetCredentials
        client.post(["@type": "close"])
    }

    func logOut() {
        guard let client else { return }
        afterClose = .restart
        step = .loggingOut
        client.post(["@type": "logOut"])
    }

    /// Closes TDLib cleanly so its database is flushed before the app quits.
    func shutdown() {
        guard let client else { return }
        isShuttingDown = true
        client.post(["@type": "close"])
        let deadline = Date().addingTimeInterval(2)
        while self.client != nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func forgetCredentials() {
        APICredentials.remove()
        DatabaseKey.remove()
        try? FileManager.default.removeItem(at: AppPaths.tdlib)
        credentials = nil
        step = .credentials
    }

    // MARK: - Login steps

    func submitPhone(_ phone: String) {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        run(["@type": "setAuthenticationPhoneNumber", "phone_number": digits])
    }

    func submitCode(_ code: String) {
        run(["@type": "checkAuthenticationCode", "code": code.filter(\.isNumber)])
    }

    func resendCode() {
        run(["@type": "resendAuthenticationCode", "reason": ["@type": "resendCodeReasonUserRequest"]])
    }

    func submitPassword(_ password: String) {
        run(["@type": "checkAuthenticationPassword", "password": password])
    }

    func submitEmail(_ email: String) {
        run(["@type": "setAuthenticationEmailAddress", "email_address": email.trimmingCharacters(in: .whitespaces)])
    }

    func submitEmailCode(_ code: String) {
        run([
            "@type": "checkAuthenticationEmailCode",
            "code": ["@type": "emailAddressAuthenticationCode", "code": code.trimmingCharacters(in: .whitespaces)],
        ])
    }

    private func run(_ request: JSON) {
        guard let client else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                try await client.send(request)
            } catch let error as TDError {
                errorMessage = Self.describeAuthError(error)
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    static func describeAuthError(_ error: TDError) -> String {
        let message = error.message
        if message.contains("API_ID") || message.contains("API_KEY") { return L("API ID or hash is invalid.") }
        if message.contains("PHONE_NUMBER_INVALID") { return L("Invalid phone number.") }
        if message.contains("PHONE_NUMBER_BANNED") { return L("This phone number is banned.") }
        if message.contains("PHONE_CODE_INVALID") { return L("Wrong code.") }
        if message.contains("PHONE_CODE_EXPIRED") { return L("Code expired. Request a new one.") }
        if message.contains("PASSWORD_HASH_INVALID") { return L("Wrong password.") }
        if message.contains("EMAIL") && message.contains("INVALID") { return L("Invalid email or code.") }
        if message.contains("FLOOD") || error.code == 429 { return L("Too many attempts. Try again later.") }
        return message
    }

    // MARK: - Updates

    private func handle(_ update: JSON) {
        switch update.type {
        case "updateAuthorizationState":
            if let state = update.object("authorization_state") { handleAuthorization(state) }
        case "updateNewChat":
            if let chat = update.object("chat") { store(chat: chat) }
        case "updateChatTitle":
            if let id = update.int64("chat_id"), let title = update.string("title") {
                chats[id]?.title = title
            }
        case "updateChatPhoto":
            if let id = update.int64("chat_id") { setPhoto(update.object("photo"), for: id) }
        case "updateChatPosition":
            if let id = update.int64("chat_id"), let position = update.object("position") {
                apply(position: position, to: id)
            }
        case "updateChatLastMessage":
            if let id = update.int64("chat_id") {
                for position in update.objects("positions") { apply(position: position, to: id) }
            }
        case "updateFile":
            if let file = update.object("file") { handle(file: file) }
        case "updateMessageSendSucceeded":
            if let old = update.int64("old_message_id") { finishSend(old, .success(())) }
        case "updateMessageSendFailed":
            if let old = update.int64("old_message_id") {
                let error = update.object("error")
                let failure = TDError(code: error?.int("code") ?? 0, message: error?.string("message") ?? "")
                finishSend(old, .failure(failure))
            }
        case "updateConnectionState":
            let wasConnected = isConnected
            isConnected = update.object("state")?.type == "connectionStateReady"
                || update.object("state")?.type == "connectionStateUpdating"
            if isConnected, !wasConnected { retryStalledDownloads() }
        default:
            break
        }
    }

    private func handleAuthorization(_ state: JSON) {
        switch state.type {
        case "authorizationStateWaitTdlibParameters":
            sendParameters()
        case "authorizationStateWaitPhoneNumber":
            step = .phone
        case "authorizationStateWaitCode":
            step = .code(hint: Self.codeHint(state.object("code_info")))
        case "authorizationStateWaitPassword":
            step = .password(hint: state.string("password_hint") ?? "")
        case "authorizationStateWaitEmailAddress":
            step = .email
        case "authorizationStateWaitEmailCode":
            step = .emailCode(pattern: state.object("code_info")?.string("email_address_pattern") ?? "")
        case "authorizationStateWaitRegistration":
            step = .blocked(L("This number has no Telegram account."))
        case "authorizationStateWaitPremiumPurchase", "authorizationStateWaitOtherDeviceConfirmation":
            step = .blocked(L("Sign in with the official Telegram app first, then try again."))
        case "authorizationStateReady":
            errorMessage = nil
            step = .ready
            didBecomeReady()
        case "authorizationStateLoggingOut":
            step = .loggingOut
        case "authorizationStateClosed":
            client?.close()
            client = nil
            resetSessionState()
            let next = afterClose
            afterClose = .restart
            switch next {
            case .forgetCredentials:
                forgetCredentials()
            case .restart:
                if credentials != nil, !isShuttingDown { startClient() } else { step = .credentials }
            }
        default:
            break
        }
    }

    private func sendParameters() {
        guard let client, let credentials else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let params: JSON = [
            "@type": "setTdlibParameters",
            "use_test_dc": false,
            "database_directory": AppPaths.tdlibDatabase.path,
            "files_directory": AppPaths.tdlibFiles.path,
            "database_encryption_key": DatabaseKey.loadOrCreate().base64EncodedString(),
            "use_file_database": true,
            "use_chat_info_database": true,
            "use_message_database": false,
            "use_secret_chats": false,
            "api_id": Int(credentials.apiID),
            "api_hash": credentials.apiHash,
            "system_language_code": Locale.preferredLanguages.first ?? "en",
            "device_model": Self.deviceModel,
            "system_version": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "application_version": "Toss \(version)",
        ]
        Task {
            do {
                try await client.send(params)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func codeHint(_ info: JSON?) -> String {
        switch info?.object("type")?.type {
        case "authenticationCodeTypeTelegramMessage": return L("Check Telegram on your other device.")
        case "authenticationCodeTypeSms", "authenticationCodeTypeSmsWord", "authenticationCodeTypeSmsPhrase":
            return L("Check your SMS.")
        case "authenticationCodeTypeCall", "authenticationCodeTypeFlashCall", "authenticationCodeTypeMissedCall":
            return L("You'll get a call.")
        default: return ""
        }
    }

    private func resetSessionState() {
        chats = [:]
        mainListOrder = [:]
        savedMessagesID = nil
        accountName = nil
        photoFileOwners = [:]
        downloads = [:]
        profilePhotoLookups = []
        uploadWatchers = [:]
        for waiter in sendWaiters.values {
            waiter.resume(throwing: TDError(code: 500, message: L("Logged out")))
        }
        sendWaiters = [:]
        sendOutcomes = [:]
    }

    private func didBecomeReady() {
        guard let client else { return }
        Task {
            if let me = try? await client.send(["@type": "getMe"]), let userID = me.int64("id") {
                let first = me.string("first_name") ?? ""
                let last = me.string("last_name") ?? ""
                accountName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                if let chat = try? await client.send(["@type": "createPrivateChat", "user_id": userID, "force": true]) {
                    savedMessagesID = chat.int64("id")
                    store(chat: chat)
                }
            }
            let preferences = Preferences.shared
            if !preferences.didSeedTargets, let saved = savedMessagesID {
                preferences.targetChatIDs = [saved]
                preferences.didSeedTargets = true
                NotificationCenter.default.post(name: .tossOpenSettings, object: nil)
            }
            for id in preferences.targetChatIDs where chats[id] == nil {
                if let chat = try? await client.send(["@type": "getChat", "chat_id": id]) { store(chat: chat) }
            }
            // Fills the main list through updateNewChat/updateChatPosition. TDLib
            // answers 404 once everything is loaded, which is fine to ignore.
            _ = try? await client.send([
                "@type": "loadChats", "chat_list": ["@type": "chatListMain"], "limit": 200,
            ])
        }
    }

    // MARK: - Chats

    private func store(chat: JSON) {
        guard let id = chat.int64("id") else { return }
        let type = chat.object("type")
        let kind: ChatInfo.Kind
        switch type?.type {
        case "chatTypeBasicGroup": kind = .group
        case "chatTypeSupergroup": kind = type?.bool("is_channel") == true ? .channel : .group
        default: kind = .user
        }
        var info = chats[id] ?? ChatInfo(id: id, title: "", kind: kind)
        info.title = chat.string("title") ?? info.title
        info.kind = id == savedMessagesID ? .savedMessages : kind
        if type?.type == "chatTypePrivate" || type?.type == "chatTypeSecret" {
            info.userID = type?.int64("user_id")
        }
        chats[id] = info
        setPhoto(chat.object("photo"), for: id)
        for position in chat.objects("positions") { apply(position: position, to: id) }
    }

    private func apply(position: JSON, to chatID: Int64) {
        guard position.object("list")?.type == "chatListMain" else { return }
        let order = position.int64("order") ?? 0
        mainListOrder[chatID] = order == 0 ? nil : order
    }

    /// `photo` is a chatPhotoInfo (small/big files plus a minithumbnail).
    private func setPhoto(_ photo: JSON?, for chatID: Int64) {
        guard let small = photo?.object("small"), small.int("id") != nil else {
            chats[chatID]?.photoFileID = nil
            chats[chatID]?.bigPhotoFileID = nil
            chats[chatID]?.photoPath = nil
            chats[chatID]?.miniThumbnail = nil
            return
        }
        setPhotoFile(small, big: photo?.object("big"), miniThumbnail: photo?.object("minithumbnail"), for: chatID)
    }

    private func setPhotoFile(_ file: JSON, big: JSON?, miniThumbnail: JSON?, for chatID: Int64) {
        guard let fileID = file.int("id") else { return }
        let bigID = big?.int("id")
        if chats[chatID]?.photoFileID != fileID { chats[chatID]?.photoPath = nil }
        chats[chatID]?.photoFileID = fileID
        chats[chatID]?.bigPhotoFileID = bigID
        if let data = miniThumbnail?.string("data").flatMap({ Data(base64Encoded: $0) }) {
            chats[chatID]?.miniThumbnail = data
        }
        photoFileOwners[fileID, default: []].insert(chatID)
        if let bigID { photoFileOwners[bigID, default: []].insert(chatID) }
        if let path = Self.completedPath(file) ?? big.flatMap(Self.completedPath) {
            chats[chatID]?.photoPath = path
        }
    }

    /// Whether `fileID` is one of the photo files of a chat that still shows no photo.
    private func isWanted(_ fileID: Int) -> Bool {
        photoFileOwners[fileID]?.contains { owner in
            guard let chat = chats[owner], chat.photoPath == nil else { return false }
            return chat.photoFileID == fileID || chat.bigPhotoFileID == fileID
        } == true
    }

    private static func completedPath(_ file: JSON) -> String? {
        let local = file.object("local")
        guard local?.bool("is_downloading_completed") == true,
              let path = local?.string("path"), !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Shows a chat's avatar: downloads its small photo, or for a private chat
    /// without one, looks up the user's profile photos.
    func loadPhoto(for chatID: Int64) {
        guard client != nil, let info = chats[chatID], info.photoPath == nil else { return }
        if let fileID = info.photoFileID {
            download(fileID)
        } else if let userID = info.userID, info.kind != .savedMessages {
            lookUpProfilePhoto(userID: userID, chatID: chatID)
        }
    }

    /// Asks TDLib for a photo file and keeps asking until it arrives.
    ///
    /// TDLib keeps a pending download alive on its own and reports progress in
    /// `updateFile`, so a request is never cancelled; it is only repeated now and
    /// then, because a file DC that refuses the connection (seen with Telegram
    /// filtering) can leave it waiting a long time.
    private func download(_ fileID: Int) {
        guard let client, isWanted(fileID) else { return }
        var state = downloads[fileID] ?? DownloadState()
        if let last = state.lastRequest, Date().timeIntervalSince(last) < 20 { return }
        state.attempts += 1
        state.lastRequest = Date()
        downloads[fileID] = state
        Task {
            do {
                let file = try await client.send([
                    "@type": "downloadFile", "file_id": fileID, "priority": 32,
                    "offset": 0, "limit": 0, "synchronous": false,
                ])
                handle(file: file)
            } catch {
            }
            scheduleRecheck(fileID)
        }
    }

    private func scheduleRecheck(_ fileID: Int) {
        guard isWanted(fileID), let attempts = downloads[fileID]?.attempts else { return }
        // 30 s, 60 s, then every 2 minutes for as long as the photo is missing.
        let delay = min(120, 15 * pow(2, Double(attempts)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isWanted(fileID) else { return }
            if let owner = self.photoFileOwners[fileID]?.first(where: { self.chats[$0]?.photoFileID == fileID }) {
                self.loadPhoto(for: owner)
            } else {
                self.download(fileID)
            }
        }
    }

    /// After reconnecting, give every avatar that never arrived a fresh set of attempts.
    private func retryStalledDownloads() {
        for fileID in downloads.keys where isWanted(fileID) {
            downloads[fileID]?.lastRequest = nil
            download(fileID)
        }
    }

    private func lookUpProfilePhoto(userID: Int64, chatID: Int64) {
        guard let client, !profilePhotoLookups.contains(userID) else { return }
        profilePhotoLookups.insert(userID)
        Task {
            guard let full = try? await client.send(["@type": "getUserFullInfo", "user_id": userID]) else {
                profilePhotoLookups.remove(userID)
                return
            }
            // What this account sees first: a photo set for us, then the real one, then the public one.
            guard let photo = full.object("personal_photo") ?? full.object("photo") ?? full.object("public_photo") else {
                return
            }
            let sizes = photo.objects("sizes").sorted { ($0.int("width") ?? 0) < ($1.int("width") ?? 0) }
            guard let size = sizes.first(where: { ($0.int("width") ?? 0) >= 160 }) ?? sizes.last,
                  let file = size.object("photo"), chats[chatID]?.photoFileID == nil else { return }
            let big = sizes.last.flatMap { $0.object("photo") }
            setPhotoFile(file, big: big?.int("id") == file.int("id") ? nil : big,
                         miniThumbnail: photo.object("minithumbnail"), for: chatID)
            loadPhoto(for: chatID)
        }
    }

    private func handle(file: JSON) {
        guard let id = file.int("id") else { return }
        if let owners = photoFileOwners[id] {
            if let path = Self.completedPath(file) {
                for chatID in owners where chats[chatID]?.photoPath == nil
                    && (chats[chatID]?.photoFileID == id || chats[chatID]?.bigPhotoFileID == id) {
                    chats[chatID]?.photoPath = path
                }
                downloads[id] = nil
            }
        }
        uploadWatchers[id]?.values.forEach { $0(file) }
    }

    /// Main-list chats, newest first, with Saved Messages on top.
    var recentChats: [ChatInfo] {
        let ordered = mainListOrder.sorted { $0.value > $1.value }.compactMap { chats[$0.key] }
        var list = ordered.filter { $0.id != savedMessagesID }
        if let saved = savedMessagesID, let info = chats[saved] { list.insert(info, at: 0) }
        return list
    }

    /// Display model for a chat; also starts fetching its avatar if needed.
    func target(for chat: ChatInfo) -> Target {
        loadPhoto(for: chat.id)
        return Target(id: chat.id, name: displayName(chat), photoPath: chat.photoPath,
                      isSavedMessages: chat.kind == .savedMessages, thumbnail: chat.miniThumbnail)
    }

    func displayName(_ chat: ChatInfo) -> String {
        chat.kind == .savedMessages ? L("Me") : chat.title
    }

    /// Server-side search for chats not yet in the loaded list.
    func search(_ query: String) async -> [ChatInfo] {
        guard let client, !query.isEmpty else { return [] }
        guard let result = try? await client.send(["@type": "searchChats", "query": query, "limit": 30]) else {
            return []
        }
        let ids = (result["chat_ids"] as? [NSNumber])?.map(\.int64Value) ?? []
        var found: [ChatInfo] = []
        for id in ids {
            if chats[id] == nil, let chat = try? await client.send(["@type": "getChat", "chat_id": id]) {
                store(chat: chat)
            }
            if let info = chats[id] { found.append(info) }
        }
        return found
    }

    // MARK: - Sending

    /// Sends prepared items to a chat and returns once Telegram has accepted
    /// every message. `progress` gets the upload fraction (0...1).
    func send(_ items: [OutgoingItem], to chatID: Int64, progress: @escaping (Double) -> Void) async throws {
        guard let client, step == .ready else { throw TDError(code: 401, message: L("Not signed in")) }
        var messageIDs: [Int64] = []
        var fileSizes: [Int: Int64] = [:]
        var uploaded: [Int: Int64] = [:]
        let watcher = UUID()

        func report() {
            let total = fileSizes.values.reduce(0, +)
            guard total > 0 else { return }
            let done = fileSizes.keys.reduce(Int64(0)) { $0 + min(uploaded[$1] ?? 0, fileSizes[$1] ?? 0) }
            progress(Double(done) / Double(total))
        }

        func track(_ message: JSON) {
            guard let id = message.int64("id") else { return }
            if message.object("sending_state") != nil { messageIDs.append(id) }
            for file in collectFiles(in: message["content"] as Any) {
                guard let fileID = file.int("id") else { continue }
                // A photo carries several sizes; only files we are uploading count.
                guard file.object("remote")?.bool("is_uploading_active") == true
                    || file.object("remote")?.bool("is_uploading_completed") == false else { continue }
                let size = file.int64("size").flatMap { $0 > 0 ? $0 : nil } ?? file.int64("expected_size") ?? 0
                fileSizes[fileID] = size
                uploadWatchers[fileID, default: [:]][watcher] = { update in
                    let remote = update.object("remote")
                    if let newSize = update.int64("size"), newSize > 0 { fileSizes[fileID] = newSize }
                    uploaded[fileID] = remote?.bool("is_uploading_completed") == true
                        ? (fileSizes[fileID] ?? 0) : (remote?.int64("uploaded_size") ?? 0)
                    report()
                }
            }
        }

        defer { for fileID in fileSizes.keys { uploadWatchers[fileID]?[watcher] = nil } }

        for batch in OutgoingItem.batches(items) {
            if batch.count == 1 {
                let message = try await client.send([
                    "@type": "sendMessage", "chat_id": chatID,
                    "input_message_content": batch[0].content,
                ])
                track(message)
            } else {
                let result = try await client.send([
                    "@type": "sendMessageAlbum", "chat_id": chatID,
                    "input_message_contents": batch.map(\.content),
                ])
                for message in result.objects("messages") { track(message) }
            }
        }
        report()

        for id in messageIDs {
            try await waitForSend(id)
        }
        progress(1)
    }

    private func waitForSend(_ messageID: Int64) async throws {
        if let outcome = sendOutcomes.removeValue(forKey: messageID) {
            try outcome.get()
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendWaiters[messageID] = continuation
        }
    }

    private func finishSend(_ messageID: Int64, _ outcome: Result<Void, TDError>) {
        if let waiter = sendWaiters.removeValue(forKey: messageID) {
            switch outcome {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        } else {
            sendOutcomes[messageID] = outcome
        }
    }

    static func describeSendError(_ error: Error) -> String {
        guard let error = error as? TDError else { return error.localizedDescription }
        let message = error.message
        if error.code == 429 || message.contains("FLOOD") { return L("Too many requests") }
        if error.code == 403 || message.contains("WRITE_FORBIDDEN") || message.contains("write access") {
            return L("Not allowed in this chat")
        }
        if message.contains("too big") || message.contains("FILE_PARTS") || message.contains("TOO_BIG") {
            return L("File too large")
        }
        if message.contains("Chat not found") { return L("Chat not found") }
        return message.isEmpty ? L("Unknown error") : message
    }
}

extension Notification.Name {
    static let tossOpenSettings = Notification.Name("TossOpenSettings")
    /// object: Bool, true while the shortcut recorder is listening.
    static let tossRecordingShortcut = Notification.Name("TossRecordingShortcut")
}
