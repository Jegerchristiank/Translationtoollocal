import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TranskriptorApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandMenu("Transkriptor") {
                Button("Gem ændringer") {
                    viewModel.saveEditedTranscriptButton()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(viewModel.screen != .result)

                Button("Gem som TXT") {
                    viewModel.exportTXT()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(viewModel.screen != .result)

                Button("Gem som DOCX") {
                    viewModel.exportDOCX()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(viewModel.screen != .result)
            }
        }
    }
}

private struct RootView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showingDeleteAllSavedTranscriptsConfirmation = false
    @State private var showingClearCacheConfirmation = false
    @State private var pendingSingleDeleteEntry: AppViewModel.SavedTranscriptEntry?
    @State private var pendingRenameEntry: AppViewModel.SavedTranscriptEntry?
    @State private var renameTitleInput = ""

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                header
                content
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .alert("Slet alle gemte interviews?", isPresented: $showingDeleteAllSavedTranscriptsConfirmation) {
            Button("Slet alle", role: .destructive) {
                viewModel.deleteAllSavedTranscriptions()
            }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Alle tidligere gemte transskriptioner slettes permanent fra appen.")
        }
        .alert("Ryd cache og nulstil app?", isPresented: $showingClearCacheConfirmation) {
            Button("Ryd cache", role: .destructive) {
                viewModel.clearCacheAndAllData()
            }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Dette sletter alle interviews, jobhistorik og gemt API-nøgle.")
        }
        .alert(
            "Slet dette interview?",
            isPresented: Binding(
                get: { pendingSingleDeleteEntry != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingSingleDeleteEntry = nil
                    }
                }
            ),
            presenting: pendingSingleDeleteEntry
        ) { entry in
            Button("Slet", role: .destructive) {
                viewModel.deleteSavedTranscript(jobId: entry.id)
                pendingSingleDeleteEntry = nil
            }
            Button("Annuller", role: .cancel) {
                pendingSingleDeleteEntry = nil
            }
        } message: { entry in
            Text("\"\(entry.sourceName)\" slettes permanent.")
        }
        .sheet(item: $pendingRenameEntry, onDismiss: {
            renameTitleInput = ""
        }) { entry in
            VStack(alignment: .leading, spacing: 12) {
                Text("Redigér titel")
                    .font(.headline)

                TextField("Ny titel", text: $renameTitleInput)
                    .textFieldStyle(.roundedBorder)

                Text("Titlen bruges også som standard ved eksport til TXT og DOCX.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Spacer()

                    Button("Annuller") {
                        pendingRenameEntry = nil
                    }
                    .buttonStyle(.bordered)

                    Button("Gem") {
                        do {
                            _ = try AppViewModel.validatedSavedTranscriptTitle(renameTitleInput)
                            viewModel.renameSavedTranscript(jobId: entry.id, newTitle: renameTitleInput)
                            pendingRenameEntry = nil
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 460)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.showOpenAIKeyPrompt },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelEnableOpenAIPrompt()
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Aktivér OpenAI")
                    .font(.headline)

                SecureField("sk-...", text: $viewModel.apiKeyInput)
                    .textFieldStyle(.roundedBorder)

                Text("Når OpenAI er slået til, bruges API-kald til transskription og AI-værktøjer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Spacer()
                    Button("Annuller") {
                        viewModel.cancelEnableOpenAIPrompt()
                    }
                    .buttonStyle(.bordered)

                    Button("Gem") {
                        viewModel.confirmEnableOpenAIFromPrompt()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 460)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text("Transkriptor")
                    .font(.title2.weight(.semibold))
                Text("macOS 14+ • Native SwiftUI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.screen == .result {
                Button("Nyt job") {
                    viewModel.startNewJobFlow()
                }
                .buttonStyle(.bordered)
                .help("Start et nyt interview-job og gå tilbage til forsiden.")
            }

            Text(statusText)
                .font(.caption.weight(.medium))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.screen {
        case .loading:
            loadingView
        case .setup:
            setupView
        case .upload:
            uploadView
        case .processing:
            processingView
        case .result:
            resultView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Indlæser...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tilføj OpenAI API-nøgle")
                .font(.headline)

            SecureField("sk-...", text: $viewModel.apiKeyInput)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Gem nøgle") {
                    viewModel.saveAPIKey()
                }
                .buttonStyle(.borderedProminent)
                .help("Gem OpenAI API-nøglen sikkert i macOS Keychain.")
            }

            Text("Nøglen gemmes lokalt i macOS Keychain og aldrig i repo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var uploadView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vælg interviewfil")
                    .font(.headline)

                RoundedRectangle(cornerRadius: 6)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [8, 4]))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Træk en fil herind eller vælg manuelt")
                                .font(.body)

                            if let file = viewModel.selectedFileURL {
                                Text(file.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            HStack(spacing: 8) {
                                Button("Vælg fil") { viewModel.chooseFile() }
                                    .buttonStyle(.bordered)
                                    .help("Vælg en lyd- eller videofil til transskription.")

                                Button("Start transskription") { viewModel.startTranscription() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(viewModel.selectedFileURL == nil || viewModel.isBusy)
                                    .help("Start transskription af den valgte fil.")
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Taler-forhold (ratio)")
                                    .font(.subheadline.weight(.semibold))
                                Text("Angiv antal interviewere og deltagere. AI bruger dette forhold ved rollefordeling.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 16) {
                                    ratioInput(
                                        label: "Interviewere",
                                        value: $viewModel.interviewerCount
                                    )
                                    ratioInput(
                                        label: "Deltagere",
                                        value: $viewModel.participantCount
                                    )
                                }
                            }
                        }
                        .padding(14)
                    }
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                        handleDrop(providers: providers)
                    }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            sidePanel
                .frame(width: 340)
        }
    }

    private var processingView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Behandler")
                    .font(.headline)

                HStack(spacing: 10) {
                    ProgressView()
                    Text(viewModel.progress?.message ?? "Klargør job...")
                        .font(.subheadline)
                }

                ProgressView(value: viewModel.progress?.percent ?? 0, total: 100)
                    .progressViewStyle(.linear)

                if viewModel.extendedProgressVisible {
                    HStack(spacing: 14) {
                        Text("Stage: \(stageText)")
                        Text("Chunks: \(viewModel.progress?.chunksDone ?? 0)/\(viewModel.progress?.chunksTotal ?? 0)")
                        Text("ETA: \(etaText)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            logPanel
                .frame(width: 340)
        }
    }

    private var resultView: some View {
        VStack(spacing: 10) {
            if viewModel.result == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ingen transskription at vise")
                        .font(.headline)
                    Text("Appen fandt et tomt eller ugyldigt resultat. Start en ny transskription.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Vælg fil") {
                            viewModel.startNewJobFlow()
                            viewModel.chooseFile()
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Gå til forsiden og vælg en ny fil.")
                        Spacer()
                    }
                }
                Spacer()
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Resultat")
                            .font(.headline)
                        if let result = viewModel.result {
                            Text("Varighed: \(AppViewModel.displayDurationMinutes(from: result.durationSec)) minutter")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()

                    Text(viewModel.hasUnsavedChanges ? "Ikke gemte ændringer" : "Alt gemt")
                        .font(.caption)
                        .foregroundStyle(viewModel.hasUnsavedChanges ? .orange : .secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Gem ændringer") { viewModel.saveEditedTranscriptButton() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.hasUnsavedChanges || viewModel.isSavingTranscript)
                        .help("Gem redigeringer i den valgte transskription.")

                    Button("Gå tilbage til original") { viewModel.restoreOriginalTranscript() }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.canRestoreOriginalTranscript)
                        .help("Gendan den originale transskriptionstekst og fjern alle ikke-gemte ændringer.")

                    Button("Byt roller (I/D)") { viewModel.swapRoles() }
                        .buttonStyle(.bordered)
                        .help("Byt roller mellem interviewer (I) og deltager (D).")

                    Spacer()

                    Button("Gem som TXT") { viewModel.exportTXT() }
                        .buttonStyle(.bordered)
                        .help("Eksportér transskriptionen som TXT.")

                    Button("Gem som DOCX") { viewModel.exportDOCX() }
                        .buttonStyle(.borderedProminent)
                        .help("Eksportér transskriptionen som DOCX.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Formater med AI") {
                        viewModel.aiFormatTranscript()
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !viewModel.useOpenAITranscription ||
                        !viewModel.hasOpenAIKeyForAIActions ||
                        viewModel.isApplyingAITranscriptAction ||
                        viewModel.editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .help("Retter kun grammatik, tegnsætning, I:/D:-format og mellemrum. Tekstens indhold/ord bevares.")

                    Button("Fortroliggør med AI") {
                        viewModel.aiAnonymizeTranscript()
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !viewModel.useOpenAITranscription ||
                        !viewModel.hasOpenAIKeyForAIActions ||
                        viewModel.isApplyingAITranscriptAction ||
                        viewModel.editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .help("Anonymiserer personhenførbare oplysninger og erstatter dem med [CENSURERET].")

                    Button("Formater + fortroliggør") {
                        viewModel.aiFormatAndAnonymizeTranscript()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !viewModel.useOpenAITranscription ||
                        !viewModel.hasOpenAIKeyForAIActions ||
                        viewModel.isApplyingAITranscriptAction ||
                        viewModel.editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .help("Kører både formatering og anonymisering i én omgang.")

                    Spacer()

                    if viewModel.isApplyingAITranscriptAction {
                        ProgressView()
                            .controlSize(.small)
                        if viewModel.aiTranscriptTotalChunks > 0 {
                            Text("AI behandler: \(viewModel.aiTranscriptProcessedChunks)/\(viewModel.aiTranscriptTotalChunks) chunks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("AI behandler tekst...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !viewModel.useOpenAITranscription {
                        Text("AI-værktøjer er slået fra i Indstillinger.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !viewModel.hasOpenAIKeyForAIActions {
                        Text("AI-værktøjer kræver aktiv OpenAI API-nøgle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(viewModel.isPlayingSourceAudio ? "Pause lyd" : "Afspil lyd") {
                        viewModel.toggleSourceAudioPlayback()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canPlaySourceAudio)
                    .help("Afspil eller paus den oprindelige lydfil.")

                    Slider(
                        value: Binding(
                            get: {
                                viewModel.sourceAudioCurrentTimeSec
                            },
                            set: { newValue in
                                viewModel.seekSourceAudio(to: newValue)
                            }
                        ),
                        in: 0...max(1, viewModel.sourceAudioDurationSec)
                    )
                    .disabled(!viewModel.canPlaySourceAudio)
                    .help("Spol i lydfilen.")

                    Text("\(formatPlaybackTime(viewModel.sourceAudioCurrentTimeSec)) / \(formatPlaybackTime(viewModel.sourceAudioDurationSec))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Linjer: \(max(1, viewModel.editableTranscript.components(separatedBy: .newlines).count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Hver linje eksporteres 1:1 med samme linjenummer i TXT og DOCX.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Start en ny talerblok med I: eller D:. Fortsættelseslinjer kan skrives uden prefix.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topLeading) {
                        LineNumberTextEditor(text: $viewModel.editableTranscript, isEditable: !viewModel.isApplyingAITranscriptAction)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        if viewModel.editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Ingen tekst at redigere.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(minHeight: 260, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Robusthedslog")
                .font(.headline)

            List(viewModel.logs.reversed()) { log in
                VStack(alignment: .leading, spacing: 2) {
                    Text(log.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(log.text)
                        .font(.caption)
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var sidePanel: some View {
        VStack(spacing: 12) {
            settingsPanel
            savedTranscriptsPanel
                .frame(maxHeight: .infinity)

            logPanel
                .frame(maxHeight: .infinity)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Indstillinger")
                .font(.headline)

            Toggle(
                "Brug OpenAI",
                isOn: Binding(
                    get: { viewModel.useOpenAITranscription },
                    set: { viewModel.setOpenAIEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .help("Slå OpenAI til/fra for transskription og AI-værktøjer.")

            if viewModel.useOpenAITranscription {
                Text("OpenAI er aktiv. API bruges til transskription og AI-værktøjer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Lokal mode er aktiv. Ingen OpenAI-kald.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var savedTranscriptsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gemte transskriptioner")
                    .font(.headline)
                Spacer()

                Button(viewModel.isDeletingSavedTranscripts ? "Sletter..." : "Slet alle") {
                    showingDeleteAllSavedTranscriptsConfirmation = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(
                    viewModel.savedTranscripts.isEmpty ||
                    viewModel.isDeletingSavedTranscripts ||
                    viewModel.isClearingCache
                )
                .help("Slet alle gemte transskriptioner.")

                Button(viewModel.isClearingCache ? "Rydder..." : "Ryd cache") {
                    showingClearCacheConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isDeletingSavedTranscripts || viewModel.isClearingCache)
                .help("Slet alle interviews, jobhistorik og gemt API-nøgle.")

                Button("Opdatér") {
                    Task { await viewModel.refreshSavedTranscriptions() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isDeletingSavedTranscripts || viewModel.isClearingCache)
                .help("Genindlæs listen over gemte transskriptioner.")
            }

            List(selection: $viewModel.selectedSavedTranscriptID) {
                ForEach(viewModel.savedTranscripts) { entry in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.sourceName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text("Opdateret: \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.durationMinutes) min")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Button {
                            renameTitleInput = entry.sourceName
                            pendingRenameEntry = entry
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Redigér titel")
                        .disabled(viewModel.isDeletingSavedTranscripts || viewModel.isClearingCache)

                        Button(role: .destructive) {
                            pendingSingleDeleteEntry = entry
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Slet interview")
                        .disabled(viewModel.isDeletingSavedTranscripts || viewModel.isClearingCache)
                    }
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.openSavedTranscript(jobId: entry.id)
                    }
                }
            }
            .listStyle(.plain)

            HStack {
                Spacer()
                Button("Åbn valgt") {
                    if let selected = viewModel.selectedSavedTranscriptID {
                        viewModel.openSavedTranscript(jobId: selected)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.selectedSavedTranscriptID == nil ||
                    viewModel.isDeletingSavedTranscripts ||
                    viewModel.isClearingCache
                )
                .help("Åbn den valgte transskription i editoren.")
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func ratioInput(label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("1", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                Stepper("", value: value, in: 1...8)
                    .labelsHidden()
            }
        }
    }

    private var statusText: String {
        switch viewModel.screen {
        case .loading: return "Indlæser"
        case .setup: return "Opsætning"
        case .upload: return "Klar"
        case .processing: return "Behandler"
        case .result: return "Færdig"
        }
    }

    private var stageText: String {
        switch viewModel.progress?.stage {
        case .upload: return "Upload"
        case .preprocess: return "Forbehandler"
        case .transcribe: return "Transskriberer"
        case .merge: return "Sammenfletter"
        case .export: return "Eksporterer"
        case .none: return "-"
        }
    }

    private var etaText: String {
        guard let eta = viewModel.progress?.etaSeconds else { return "Beregner..." }
        let min = eta / 60
        let sec = eta % 60
        return "\(min):\(String(format: "%02d", sec))"
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let item = providers.first else { return false }

        item.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else {
                return
            }

            Task { @MainActor in
                viewModel.handleDroppedFile(url: url)
            }
        }

        return true
    }

    private func formatPlaybackTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
