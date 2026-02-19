import AppKit
import AVFoundation
import Domain
import Export
import Foundation
import Pipeline
import SecurityKit
import Storage
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    enum Screen: Equatable {
        case loading
        case setup
        case upload
        case processing
        case result
    }

    enum SavedTranscriptTitleValidationError: LocalizedError, Equatable {
        case empty
        case invalidCharacters
        case reservedName

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Titel kan ikke være tom."
            case .invalidCharacters:
                return "Titel indeholder ugyldige tegn. Brug ikke / \\ : * ? \" < > |"
            case .reservedName:
                return "Titel er ikke gyldig som filnavn."
            }
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let text: String
    }

    struct SavedTranscriptEntry: Identifiable, Hashable {
        let id: String
        let sourceName: String
        let updatedAt: Date
        let durationMinutes: Int
    }

    @Published var screen: Screen = .loading
    @Published var apiKeyInput = ""
    @Published var selectedFileURL: URL?
    @Published var jobId: String?
    @Published var progress: ProgressEvent?
    @Published var result: JobResult?
    @Published var editableTranscript = ""
    @Published var savedTranscript = ""
    @Published var isSavingTranscript = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var logs: [LogEntry] = []
    @Published var startedAt: Date?
    @Published var interviewerCount = 1 {
        didSet {
            let clamped = Self.clampRoleCount(interviewerCount)
            if interviewerCount != clamped {
                interviewerCount = clamped
            }
        }
    }
    @Published var participantCount = 1 {
        didSet {
            let clamped = Self.clampRoleCount(participantCount)
            if participantCount != clamped {
                participantCount = clamped
            }
        }
    }
    @Published var savedTranscripts: [SavedTranscriptEntry] = []
    @Published var selectedSavedTranscriptID: String?
    @Published var isDeletingSavedTranscripts = false
    @Published var isClearingCache = false
    @Published var isApplyingAITranscriptAction = false
    @Published var hasOpenAIKeyForAIActions = false
    @Published var useOpenAITranscription = false
    @Published var showOpenAIKeyPrompt = false
    @Published var canPlaySourceAudio = false
    @Published var isPlayingSourceAudio = false
    @Published var sourceAudioCurrentTimeSec: Double = 0
    @Published var sourceAudioDurationSec: Double = 0
    @Published var aiTranscriptProcessedChunks = 0
    @Published var aiTranscriptTotalChunks = 0
    @Published private(set) var originalTranscript = ""

    private let keychain = KeychainService()
    private let store: JobStore
    private let coordinator: TranscriptionCoordinator
    private let txtExporter = TxtExporter()
    private let docxExporter = DocxExporter()
    private let openAIFileTitleGenerator = OpenAIFileTitleGenerator()
    private let aiTranscriptProcessor = AITranscriptProcessor()
    private var cachedApiKey: String?
    private var suggestedExportFileNames: [String: String] = [:]
    private var sourceAudioPlayer: AVPlayer?
    private var sourceAudioTimeObserver: Any?
    private var sourceAudioEndObserver: NSObjectProtocol?

    private var progressTask: Task<Void, Never>?
    private static let useOpenAIPreferenceKey = "transkriptor.useOpenAI.enabled"

    init() {
        do {
            store = try JobStore()
            coordinator = TranscriptionCoordinator(store: store)
        } catch {
            fatalError("Kunne ikke initialisere storage: \(error.localizedDescription)")
        }

        subscribeProgress()

        Task {
            await bootstrap()
        }
    }

    deinit {
        progressTask?.cancel()
    }

    var hasUnsavedChanges: Bool {
        editableTranscript != savedTranscript
    }

    var canRestoreOriginalTranscript: Bool {
        !originalTranscript.isEmpty &&
        editableTranscript != originalTranscript &&
        !isApplyingAITranscriptAction &&
        !isSavingTranscript
    }

    var extendedProgressVisible: Bool {
        guard let startedAt else { return false }
        return Date().timeIntervalSince(startedAt) > 30
    }

    var roleConfig: SpeakerRoleConfig {
        SpeakerRoleConfig(interviewerCount: interviewerCount, participantCount: participantCount)
    }

    static func defaultLandingScreen(hasAPIKey: Bool) -> Screen {
        hasAPIKey ? .upload : .setup
    }

    static func displayDurationMinutes(from seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        return max(1, Int(ceil(seconds / 60)))
    }

    static func validatedSavedTranscriptTitle(_ raw: String) throws -> String {
        let normalized = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SavedTranscriptTitleValidationError.empty
        }

        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        guard normalized.rangeOfCharacter(from: invalidCharacters) == nil else {
            throw SavedTranscriptTitleValidationError.invalidCharacters
        }

        let reserved = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !reserved.isEmpty, reserved != ".", reserved != ".." else {
            throw SavedTranscriptTitleValidationError.reservedName
        }

        return String(normalized.prefix(120))
    }

    func bootstrap() async {
        await refreshSavedTranscriptions()

        let key = (try? await keychain.read())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cachedApiKey = key.isEmpty ? nil : key
        hasOpenAIKeyForAIActions = !key.isEmpty
        useOpenAITranscription = UserDefaults.standard.bool(forKey: Self.useOpenAIPreferenceKey)
        if useOpenAITranscription && key.isEmpty {
            useOpenAITranscription = false
            UserDefaults.standard.set(false, forKey: Self.useOpenAIPreferenceKey)
            addLog("OpenAI blev slået fra, fordi API-nøgle mangler.")
        }
        screen = .upload

        if let incomplete = try? await store.latestIncompleteJob() {
            switch incomplete.status {
            case .pausedRetryOpenAI:
                addLog("Sidste job er pauset. Vælg fil og start igen for at køre OpenAI-retry.")
            case .queued, .preprocessing, .transcribingOpenAI, .transcribingFallback, .merging:
                addLog("Tidligere job kan fortsættes manuelt fra forsiden ved at vælge fil og starte igen.")
            case .ready, .failed:
                break
            }
        }
    }

    func saveAPIKey() {
        Task {
            do {
                try await keychain.save(apiKey: apiKeyInput)
                let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                cachedApiKey = trimmed
                hasOpenAIKeyForAIActions = !trimmed.isEmpty
                useOpenAITranscription = !trimmed.isEmpty
                persistOpenAIPreference(useOpenAITranscription)
                apiKeyInput = ""
                errorMessage = nil
                screen = .upload
                await refreshSavedTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setOpenAIEnabled(_ enabled: Bool) {
        if !enabled {
            useOpenAITranscription = false
            showOpenAIKeyPrompt = false
            persistOpenAIPreference(false)
            errorMessage = nil
            return
        }

        Task {
            let key = await resolveAPIKeyForExport()
            if key.isEmpty {
                await MainActor.run {
                    useOpenAITranscription = false
                    showOpenAIKeyPrompt = true
                    apiKeyInput = ""
                    persistOpenAIPreference(false)
                }
            } else {
                await MainActor.run {
                    useOpenAITranscription = true
                    persistOpenAIPreference(true)
                    errorMessage = nil
                }
            }
        }
    }

    func confirmEnableOpenAIFromPrompt() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Indsæt en gyldig OpenAI API-nøgle eller tryk Annuller."
            return
        }

        Task {
            do {
                try await keychain.save(apiKey: trimmed)
                cachedApiKey = trimmed
                hasOpenAIKeyForAIActions = true
                useOpenAITranscription = true
                persistOpenAIPreference(true)
                showOpenAIKeyPrompt = false
                apiKeyInput = ""
                errorMessage = nil
                addLog("OpenAI aktiveret.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelEnableOpenAIPrompt() {
        showOpenAIKeyPrompt = false
        apiKeyInput = ""
        useOpenAITranscription = false
        persistOpenAIPreference(false)
    }

    func startTranscription() {
        guard let selectedFileURL else {
            errorMessage = "Vælg en fil først."
            return
        }

        Task {
            do {
                let shouldUseOpenAI = useOpenAITranscription
                var key = ""
                if shouldUseOpenAI {
                    if let cachedApiKey, !cachedApiKey.isEmpty {
                        key = cachedApiKey
                    } else {
                        key = try await keychain.read() ?? ""
                        cachedApiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errorMessage = "OpenAI er slået til, men API-nøgle mangler."
                        showOpenAIKeyPrompt = true
                        useOpenAITranscription = false
                        persistOpenAIPreference(false)
                        return
                    }
                }

                errorMessage = nil
                isBusy = true
                result = nil
                cleanupAudioPlayer()
                logs = []
                startedAt = Date()
                let id = try await coordinator.startJob(
                    sourceURL: selectedFileURL,
                    apiKey: shouldUseOpenAI ? key : nil,
                    useOpenAI: shouldUseOpenAI,
                    roleConfig: roleConfig
                )
                jobId = id
                screen = .processing
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    func swapRoles() {
        guard let jobId else { return }
        Task {
            do {
                if hasUnsavedChanges {
                    let saved = try await saveEditedTranscript(silent: true)
                    if !saved { return }
                }

                if let swapped = try await coordinator.swapRoles(jobId: jobId) {
                    result = swapped
                    selectedSavedTranscriptID = swapped.jobId
                    loadEditorText(from: swapped)
                    await refreshSavedTranscriptions()
                    addLog("Roller byttet.")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func saveEditedTranscriptButton() {
        Task {
            _ = try? await saveEditedTranscript(silent: false)
        }
    }

    @discardableResult
    func saveEditedTranscript(silent: Bool) async throws -> Bool {
        guard let jobId else { return false }
        if !hasUnsavedChanges { return true }

        let trimmed = editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Transcript kan ikke være tomt."
            return false
        }

        isSavingTranscript = true
        defer { isSavingTranscript = false }

        do {
            if let updated = try await coordinator.updateTranscript(jobId: jobId, transcriptText: editableTranscript) {
                result = updated
                savedTranscript = editableTranscript
            } else {
                savedTranscript = editableTranscript
            }
            if !silent {
                addLog("Redigeringer gemt.")
            }
            await refreshSavedTranscriptions()
            return true
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func aiFormatTranscript() {
        runAITranscriptAction(.format)
    }

    func aiAnonymizeTranscript() {
        runAITranscriptAction(.anonymize)
    }

    func aiFormatAndAnonymizeTranscript() {
        runAITranscriptAction(.formatAndAnonymize)
    }

    func restoreOriginalTranscript() {
        guard !originalTranscript.isEmpty else {
            errorMessage = "Der er ingen original transskription at gendanne."
            return
        }
        guard !isApplyingAITranscriptAction else {
            return
        }

        editableTranscript = originalTranscript
        errorMessage = nil
        addLog("Editor nulstillet til original transskription.")
    }

    func toggleSourceAudioPlayback() {
        guard let sourceAudioPlayer, canPlaySourceAudio else { return }

        if isPlayingSourceAudio {
            sourceAudioPlayer.pause()
            isPlayingSourceAudio = false
        } else {
            sourceAudioPlayer.play()
            isPlayingSourceAudio = true
        }
    }

    func seekSourceAudio(to seconds: Double) {
        guard let sourceAudioPlayer, canPlaySourceAudio else { return }

        let clamped = max(0, min(seconds, sourceAudioDurationSec))
        sourceAudioCurrentTimeSec = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        sourceAudioPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func exportTXT() {
        Task {
            do {
                guard result != nil else { return }
                if hasUnsavedChanges {
                    let saved = try await saveEditedTranscript(silent: true)
                    if !saved { return }
                }
                guard let current = result else { return }

                let fileStem = await suggestedExportFileName(for: current)
                guard let saveURL = savePanel(defaultName: "\(fileStem).txt", allowed: ["txt"]) else {
                    return
                }

                let sourceNameOverride = await sourceNameOverride(forJobID: current.jobId)
                let exported = try txtExporter.export(
                    result: current,
                    outputURL: saveURL,
                    sourceNameOverride: sourceNameOverride
                )
                addLog("TXT gemt: \(exported.path)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportDOCX() {
        Task {
            do {
                guard result != nil else { return }
                if hasUnsavedChanges {
                    let saved = try await saveEditedTranscript(silent: true)
                    if !saved { return }
                }
                guard let current = result else { return }

                let fileStem = await suggestedExportFileName(for: current)
                guard let saveURL = savePanel(defaultName: "\(fileStem).docx", allowed: ["docx"]) else {
                    return
                }

                let sourceNameOverride = await sourceNameOverride(forJobID: current.jobId)
                let exported = try docxExporter.export(
                    result: current,
                    outputURL: saveURL,
                    sourceNameOverride: sourceNameOverride
                )
                addLog("DOCX gemt: \(exported.path)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func handleDroppedFile(url: URL) {
        selectedFileURL = url
    }

    func chooseFile() {
        guard let url = openPanel() else { return }
        selectedFileURL = url
    }

    func startNewJobFlow() {
        cleanupAudioPlayer()
        result = nil
        jobId = nil
        progress = nil
        editableTranscript = ""
        savedTranscript = ""
        selectedSavedTranscriptID = nil
        suggestedExportFileNames.removeAll()
        errorMessage = nil
        screen = .upload
        Task {
            await refreshSavedTranscriptions()
        }
    }

    func refreshSavedTranscriptions() async {
        do {
            let jobs = try await store.listReadyJobs(limit: 200)
            let entries = jobs.map { job in
                SavedTranscriptEntry(
                    id: job.id,
                    sourceName: job.sourceName,
                    updatedAt: job.updatedAt,
                    durationMinutes: Self.displayDurationMinutes(from: job.durationSec)
                )
            }
            savedTranscripts = entries
            if let selectedSavedTranscriptID,
               !entries.contains(where: { $0.id == selectedSavedTranscriptID }) {
                self.selectedSavedTranscriptID = nil
            }
            if selectedSavedTranscriptID == nil {
                selectedSavedTranscriptID = entries.first?.id
            }
        } catch {
            addLog("Kunne ikke indlæse tidligere transskriptioner: \(error.localizedDescription)")
        }
    }

    func deleteSavedTranscript(jobId: String) {
        guard !isDeletingSavedTranscripts, !isClearingCache else { return }

        Task {
            isDeletingSavedTranscripts = true
            defer { isDeletingSavedTranscripts = false }

            do {
                let deleted = try await store.deleteReadyJob(id: jobId)
                if !deleted {
                    addLog("Interviewet var allerede slettet.")
                    await refreshSavedTranscriptions()
                    return
                }

                suggestedExportFileNames[jobId] = nil
                if self.jobId == jobId {
                    clearCurrentResultFromUI()
                    screen = .upload
                }

                await refreshSavedTranscriptions()
                addLog("Slettede interview: \(jobId)")
            } catch {
                errorMessage = "Kunne ikke slette interview: \(error.localizedDescription)"
            }
        }
    }

    func renameSavedTranscript(jobId: String, newTitle: String) {
        guard !isDeletingSavedTranscripts, !isClearingCache else { return }

        Task {
            do {
                let validated = try Self.validatedSavedTranscriptTitle(newTitle)
                let renamed = try await store.updateReadyJobSourceName(id: jobId, sourceName: validated)
                guard renamed else {
                    errorMessage = "Kunne ikke omdøbe interviewet."
                    await refreshSavedTranscriptions()
                    return
                }

                suggestedExportFileNames[jobId] = validated
                await refreshSavedTranscriptions()
                errorMessage = nil
                addLog("Omdøbte interview: \(validated)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteAllSavedTranscriptions() {
        guard !isDeletingSavedTranscripts, !isClearingCache else { return }
        if screen == .processing {
            errorMessage = "Vent til transskription er færdig, før du sletter interviews."
            return
        }

        Task {
            isDeletingSavedTranscripts = true
            defer { isDeletingSavedTranscripts = false }

            do {
                let deletedCount = try await store.deleteAllReadyJobs()
                if deletedCount == 0 {
                    addLog("Ingen gemte transskriptioner at slette.")
                    await refreshSavedTranscriptions()
                    return
                }

                clearCurrentResultFromUI()
                errorMessage = nil
                screen = .upload

                await refreshSavedTranscriptions()
                addLog("Slettede \(deletedCount) gemte transskriptioner.")
            } catch {
                errorMessage = "Kunne ikke slette gemte transskriptioner: \(error.localizedDescription)"
            }
        }
    }

    func clearCacheAndAllData() {
        guard !isClearingCache, !isDeletingSavedTranscripts else { return }
        if screen == .processing {
            errorMessage = "Vent til transskription er færdig, før cache ryddes."
            return
        }

        Task {
            isClearingCache = true
            defer { isClearingCache = false }

            do {
                let deletedJobs = try await store.clearAllData()
                try await keychain.delete()

                clearCurrentResultFromUI()
                selectedFileURL = nil
                cachedApiKey = nil
                hasOpenAIKeyForAIActions = false
                useOpenAITranscription = false
                showOpenAIKeyPrompt = false
                persistOpenAIPreference(false)
                apiKeyInput = ""
                logs.removeAll()
                errorMessage = nil
                screen = .upload

                await refreshSavedTranscriptions()
                addLog("Cache ryddet. Slettede \(deletedJobs) job og nulstillede API-nøgle.")
            } catch {
                errorMessage = "Kunne ikke rydde cache: \(error.localizedDescription)"
            }
        }
    }

    func openSavedTranscript(jobId: String) {
        Task {
            do {
                guard let loaded = try await coordinator.jobResult(jobId: jobId) else {
                    errorMessage = "Kunne ikke åbne den valgte transskription."
                    return
                }
                if loaded.transcript.isEmpty {
                    errorMessage = "Den valgte transskription er tom."
                    return
                }
                result = loaded
                self.jobId = loaded.jobId
                selectedSavedTranscriptID = loaded.jobId
                await loadRoleConfig(for: loaded.jobId)
                loadEditorText(from: loaded)
                screen = .result
                errorMessage = nil
                addLog("Åbnede gemt transskription: \(loaded.jobId)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func subscribeProgress() {
        progressTask = Task { [weak self] in
            guard let self else { return }
            let stream = await coordinator.progressStream()
            for await event in stream {
                await MainActor.run {
                    self.progress = event
                    self.jobId = event.jobId
                    switch event.status {
                    case .ready:
                        self.screen = .result
                    case .pausedRetryOpenAI, .failed:
                        self.screen = .upload
                    default:
                        self.screen = .processing
                    }
                    self.addLog(event.message)
                    self.startedAt = self.startedAt ?? Date()

                    if event.status == .failed || event.status == .pausedRetryOpenAI {
                        self.errorMessage = event.message
                    }

                    if event.status == .ready {
                        Task {
                            if let result = try? await self.coordinator.jobResult(jobId: event.jobId) {
                                await MainActor.run {
                                    if result.transcript.isEmpty {
                                        self.result = nil
                                        self.editableTranscript = ""
                                        self.savedTranscript = ""
                                        self.screen = .upload
                                        self.errorMessage = "Transskriptionen blev tom efter behandling. Prøv igen."
                                        self.addLog("Resultatet var tomt efter merge. Kør transskriptionen igen.")
                                        return
                                    }
                                    self.result = result
                                    self.selectedSavedTranscriptID = result.jobId
                                    Task {
                                        await self.loadRoleConfig(for: result.jobId)
                                        await self.refreshSavedTranscriptions()
                                    }
                                    self.loadEditorText(from: result)
                                    self.errorMessage = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadEditorText(from result: JobResult) {
        let text = TranscriptEditorParser.buildEditorText(from: result.transcript)
        originalTranscript = text
        editableTranscript = text
        savedTranscript = text
        prepareAudioPlayer(sourcePath: result.sourcePath)
        Task {
            _ = await suggestedExportFileName(for: result)
        }
    }

    private func runAITranscriptAction(_ action: AITranscriptProcessor.Action) {
        guard !isApplyingAITranscriptAction else { return }
        guard useOpenAITranscription else {
            errorMessage = "Slå \"Brug OpenAI\" til for at bruge AI-værktøjer."
            return
        }

        let sourceText = editableTranscript
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Der er ingen tekst at behandle."
            return
        }

        Task {
            do {
                let key = await resolveAPIKeyForExport()
                guard !key.isEmpty else {
                    hasOpenAIKeyForAIActions = false
                    errorMessage = "Aktivér OpenAI API-nøgle for at bruge AI-funktionerne."
                    return
                }
                hasOpenAIKeyForAIActions = true

                isApplyingAITranscriptAction = true
                aiTranscriptProcessedChunks = 0
                aiTranscriptTotalChunks = 0
                defer {
                    isApplyingAITranscriptAction = false
                    aiTranscriptProcessedChunks = 0
                    aiTranscriptTotalChunks = 0
                }

                addLog("\(action.logLabel) startet...")
                let transformed = try await aiTranscriptProcessor.processStreaming(
                    text: sourceText,
                    action: action,
                    apiKey: key
                ) { [weak self] partialText, processedChunks, totalChunks in
                    await MainActor.run {
                        guard let self else { return }
                        self.aiTranscriptProcessedChunks = processedChunks
                        self.aiTranscriptTotalChunks = totalChunks
                        self.editableTranscript = partialText
                    }
                }

                guard !transformed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "AI returnerede tom tekst. Ingen ændringer blev anvendt."
                    addLog("\(action.logLabel) returnerede tom tekst.")
                    editableTranscript = sourceText
                    return
                }

                editableTranscript = transformed
                errorMessage = nil
                addLog("\(action.logLabel) færdig.")
            } catch {
                editableTranscript = sourceText
                errorMessage = error.localizedDescription
                addLog("\(action.logLabel) fejlede: \(error.localizedDescription)")
            }
        }
    }

    private func prepareAudioPlayer(sourcePath: String) {
        cleanupAudioPlayer()

        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            canPlaySourceAudio = false
            return
        }

        let item = AVPlayerItem(url: sourceURL)
        let player = AVPlayer(playerItem: item)
        sourceAudioPlayer = player
        canPlaySourceAudio = true
        isPlayingSourceAudio = false
        sourceAudioCurrentTimeSec = 0
        sourceAudioDurationSec = 0

        sourceAudioTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let current = CMTimeGetSeconds(time)
                if current.isFinite {
                    self.sourceAudioCurrentTimeSec = max(0, current)
                }

                if let duration = player.currentItem?.duration {
                    let seconds = CMTimeGetSeconds(duration)
                    if seconds.isFinite, seconds > 0 {
                        self.sourceAudioDurationSec = seconds
                    }
                }
            }
        }

        sourceAudioEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlayingSourceAudio = false
                self.sourceAudioCurrentTimeSec = self.sourceAudioDurationSec
            }
        }

        Task {
            let asset = AVURLAsset(url: sourceURL)
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite, seconds > 0 {
                    self.sourceAudioDurationSec = seconds
                }
            }
        }
    }

    private func cleanupAudioPlayer() {
        if let sourceAudioPlayer {
            sourceAudioPlayer.pause()
        }
        if let sourceAudioTimeObserver, let sourceAudioPlayer {
            sourceAudioPlayer.removeTimeObserver(sourceAudioTimeObserver)
        }
        if let sourceAudioEndObserver {
            NotificationCenter.default.removeObserver(sourceAudioEndObserver)
        }

        sourceAudioTimeObserver = nil
        sourceAudioEndObserver = nil
        sourceAudioPlayer = nil
        canPlaySourceAudio = false
        isPlayingSourceAudio = false
        sourceAudioCurrentTimeSec = 0
        sourceAudioDurationSec = 0
    }

    private func addLog(_ text: String) {
        logs.append(LogEntry(timestamp: Date(), text: text))
        if logs.count > 120 {
            logs.removeFirst(logs.count - 120)
        }
    }

    private func clearCurrentResultFromUI() {
        cleanupAudioPlayer()
        suggestedExportFileNames.removeAll()
        result = nil
        jobId = nil
        progress = nil
        originalTranscript = ""
        editableTranscript = ""
        savedTranscript = ""
        selectedSavedTranscriptID = nil
    }

    private func loadRoleConfig(for jobId: String) async {
        guard let job = try? await store.getJob(id: jobId) else {
            return
        }
        interviewerCount = Self.clampRoleCount(job.interviewerCount)
        participantCount = Self.clampRoleCount(job.participantCount)
    }

    private func suggestedExportFileName(for result: JobResult) async -> String {
        if let cached = suggestedExportFileNames[result.jobId] {
            return cached
        }

        let sourceName = URL(fileURLWithPath: result.sourcePath).deletingPathExtension().lastPathComponent
        let currentSourceName = await sourceNameOverride(forJobID: result.jobId) ?? sourceName
        if currentSourceName != sourceName {
            suggestedExportFileNames[result.jobId] = currentSourceName
            return currentSourceName
        }

        let fallback = OpenAIFileTitleGenerator.sanitizeBaseName(
            "",
            fallback: ExportFileNameSuggester.suggestedBaseName(for: result),
            sourceName: sourceName
        )
        guard useOpenAITranscription else {
            suggestedExportFileNames[result.jobId] = fallback
            return fallback
        }

        let key = await resolveAPIKeyForExport()
        guard !key.isEmpty else {
            suggestedExportFileNames[result.jobId] = fallback
            return fallback
        }

        do {
            let generated = try await openAIFileTitleGenerator.suggestBaseName(result: result, apiKey: key, fallback: fallback)
            suggestedExportFileNames[result.jobId] = generated
            return generated
        } catch {
            suggestedExportFileNames[result.jobId] = fallback
            addLog("AI-filnavn kunne ikke genereres hurtigt nok. Bruger standardnavn.")
            return fallback
        }
    }

    private func sourceNameOverride(forJobID jobId: String) async -> String? {
        if let saved = savedTranscripts.first(where: { $0.id == jobId })?.sourceName {
            let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        guard let job = try? await store.getJob(id: jobId) else {
            return nil
        }
        let trimmed = job.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistOpenAIPreference(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.useOpenAIPreferenceKey)
    }

    private func resolveAPIKeyForExport() async -> String {
        if let cachedApiKey, !cachedApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasOpenAIKeyForAIActions = true
            return cachedApiKey
        }

        let key = (try? await keychain.read())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            cachedApiKey = key
            hasOpenAIKeyForAIActions = true
        } else {
            hasOpenAIKeyForAIActions = false
        }
        return key
    }

    static func clampRoleCount(_ value: Int) -> Int {
        max(1, min(8, value))
    }

    private func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.prompt = "Vælg"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func savePanel(defaultName: String, allowed: [String]) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = allowed.compactMap { UTType(filenameExtension: $0) }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloads
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
