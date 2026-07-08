import SwiftUI

/// Modal used both for "Add backend" and "Edit backend". The caller decides
/// which by passing an initial `BackendEntry` (fresh for add, existing for
/// edit) + an `onDelete` closure (nil for add or for the last backend in
/// the list).
///
/// The Pair-via-code section only renders in edit mode — i.e. when `settings`
/// is non-nil **and** the entry is already in `settings.backends`. Add mode
/// (no `settings`) hides it entirely; the operator adds a backend first, then
/// reopens the sheet to pair.
struct BackendEditSheet: View {
    let title: String
    let initialEntry: BackendEntry
    let onSave: (BackendEntry) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void
    var settings: SettingsStore?

    @State private var label: String
    @State private var urlDraft: String
    @State private var certFingerprintDraft: String
    /// Selected harness id; empty string = the backend's default harness.
    @State private var harnessDraft: String
    @State private var harnessLoad: HarnessLoadState = .idle
    @State private var pairCodeDraft: String = ""
    @State private var pairState: PairState = .idle
    @State private var pairOutcome: PairOutcome? = nil
    @State private var isUnpairing: Bool = false
    #if os(iOS)
    @State private var presentingScanner: Bool = false
    #endif

    private enum PairState: Equatable {
        case idle
        case pairing
        case failed(String)
    }

    private enum HarnessLoadState: Equatable {
        case idle
        case loading
        case loaded([HarnessDescriptor])
        case failed(String)
    }

    /// Transient result banner shown after a pairing attempt: green tick on
    /// success, red cross on failure. Auto-dismisses.
    private enum PairOutcome: Equatable {
        case success
        case failure(String)
    }

    init(
        title: String,
        initialEntry: BackendEntry,
        onSave: @escaping (BackendEntry) -> Void,
        onDelete: (() -> Void)?,
        onCancel: @escaping () -> Void,
        settings: SettingsStore? = nil
    ) {
        self.title = title
        self.initialEntry = initialEntry
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        self.settings = settings
        self._label = State(initialValue: initialEntry.label)
        self._urlDraft = State(initialValue: initialEntry.url.absoluteString)
        self._certFingerprintDraft = State(initialValue: initialEntry.certFingerprint ?? "")
        self._harnessDraft = State(initialValue: initialEntry.harnessID ?? "")
    }

    private var parsedURL: URL? {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    private var canSave: Bool { parsedURL != nil }

    /// True when this sheet is editing an entry that already exists in the
    /// store (the Pair section needs a persisted entry to operate on).
    private var isEditMode: Bool {
        guard let settings else { return false }
        return settings.backends.contains { $0.id == initialEntry.id }
    }

    private var currentlyPaired: Bool {
        guard let settings else { return false }
        return settings.isPaired(initialEntry.id) && initialEntry.deviceID != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection

                harnessSection

                if isEditMode {
                    pairSection
                }

                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Delete backend", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                if let pairOutcome {
                    pairOutcomeBanner(pairOutcome)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let url = parsedURL else { return }
                        let fp = certFingerprintDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        let entry = BackendEntry(
                            id: initialEntry.id,
                            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                            url: url,
                            deviceID: settings?.backends.first(where: { $0.id == initialEntry.id })?.deviceID ?? initialEntry.deviceID,
                            certFingerprint: fp.isEmpty ? nil : fp,
                            harnessID: harnessDraft.isEmpty ? nil : harnessDraft
                        )
                        onSave(entry)
                    }
                    .disabled(!canSave)
                }
            }
            #if os(macOS)
            // Match SettingsSheet: iOS-like grouped style (macOS defaults to the
            // tight `.columns` style) so fields keep sensible side margins.
            .formStyle(.grouped)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 560)
            #endif
            #if os(iOS)
            .sheet(isPresented: $presentingScanner) {
                QRScannerView { scanned in
                    presentingScanner = false
                    guard let result = QRScannerView.extractPairingResult(from: scanned) else {
                        pairState = .failed("Scanned content doesn't look like a pairing code.")
                        return
                    }
                    // Pre-fill URL from QR when present (HTTPS self-hosted backend).
                    if let backendURL = result.backendURL {
                        urlDraft = backendURL.absoluteString
                    }
                    // Store cert fingerprint so future requests can pin the cert;
                    // also sync the draft field so manual edits stay coherent.
                    if let fp = result.certFingerprint {
                        settings?.updateBackend(initialEntry.id, certFingerprint: fp)
                        certFingerprintDraft = fp
                    }
                    pairCodeDraft = result.code
                    Task { await triggerPair() }
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func pairOutcomeBanner(_ outcome: PairOutcome) -> some View {
        let isSuccess = outcome == .success
        HStack(spacing: 10) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isSuccess ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(isSuccess ? "Paired" : "Pairing failed")
                    .font(.subheadline.weight(.semibold))
                if case .failure(let reason) = outcome {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder((isSuccess ? Color.green : Color.red).opacity(0.4), lineWidth: 1)
        )
        .shadow(radius: 8, y: 4)
        .padding(.horizontal, 16)
    }

    // MARK: - Sections

    private var isHTTPS: Bool {
        urlDraft.lowercased().hasPrefix("https://")
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            TextField("Label", text: $label, prompt: Text("Local backend"))
            TextField("URL", text: $urlDraft, prompt: Text("http://localhost:8004/"))
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif
            if isHTTPS {
                TextField("Cert fingerprint", text: $certFingerprintDraft, prompt: Text("SHA-256 hex — shown by `pupa-backend pair`"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    #endif
                    .font(.caption.monospaced())
            }
        } footer: {
            Text("Label is a free-form display name. URL must include a scheme (http:// or https://). For self-signed HTTPS backends, paste the SHA-256 cert fingerprint printed by `pupa-backend pair`. Authentication is per-device — complete the pairing below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var harnessSection: some View {
        Section {
            switch harnessLoad {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading harnesses…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                // Keep whatever harness the entry already had; let the user retry.
                Label("Couldn't reach backend", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await loadHarnesses() } }
            case .loaded(let harnesses):
                Picker("Harness", selection: $harnessDraft) {
                    Text("Backend default").tag("")
                    ForEach(harnesses) { h in
                        Text(h.isDefault ? "\(h.label) (default)" : h.label).tag(h.id)
                    }
                }
                #if os(iOS)
                .pickerStyle(.menu)
                #endif
            }
        } header: {
            Text("Agent harness")
        } footer: {
            Text("Which agent loop this backend talks to. The model list and permission controls follow the selected harness. \"Backend default\" uses whatever the server mounts at its root.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: parsedURL) { await loadHarnesses() }
    }

    @MainActor
    private func loadHarnesses() async {
        guard let url = parsedURL else {
            harnessLoad = .failed("Enter a valid backend URL first.")
            return
        }
        harnessLoad = .loading
        let headers: [String: String]
        if let settings, let token = settings.credentials.token(for: initialEntry.id) {
            headers = ["Authorization": "Bearer \(token)"]
        } else {
            headers = [:]
        }
        let session = settings?.session(for: initialEntry) ?? .shared
        let client = BackendHarnessesClient(backendURL: url, extraHeaders: headers, session: session)
        do {
            let harnesses = try await client.list()
            // Drop a stale selection that the backend no longer advertises.
            if !harnessDraft.isEmpty, !harnesses.contains(where: { $0.id == harnessDraft }) {
                harnessDraft = ""
            }
            harnessLoad = .loaded(harnesses)
        } catch {
            harnessLoad = .failed(String(describing: error))
        }
    }

    @ViewBuilder
    private var pairSection: some View {
        Section {
            if currentlyPaired {
                pairedStateRow
            } else {
                pairForm
            }
        } header: {
            Text("Pair this device")
        } footer: {
            pairFooter
        }
    }

    @ViewBuilder
    private var pairedStateRow: some View {
        if let deviceID = settings?.backends.first(where: { $0.id == initialEntry.id })?.deviceID {
            HStack(spacing: 10) {
                Image(systemName: "link.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paired").font(.headline)
                    Text("device id: \(deviceID.uuidString.prefix(8))…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await triggerUnpair() }
                } label: {
                    if isUnpairing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Unpair")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isUnpairing)
            }
        }
    }

    @ViewBuilder
    private var pairForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Pairing code", text: $pairCodeDraft, prompt: Text("8 characters"))
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .keyboardType(.asciiCapable)
                #endif
                .font(.body.monospaced())
            HStack(spacing: 8) {
                Button {
                    Task { await triggerPair() }
                } label: {
                    if case .pairing = pairState {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Pair", systemImage: "link")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pairCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || pairState == .pairing
                          || parsedURL == nil)

                #if os(iOS)
                Button {
                    presentingScanner = true
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
                .disabled(pairState == .pairing)
                #endif
            }
            if case .failed(let reason) = pairState {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var pairFooter: some View {
        if currentlyPaired {
            Text("This device is paired — requests carry a device-scoped token from the Keychain. Tap Unpair to revoke this device from both the backend and the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Run `make pair` on the laptop running this backend to mint an 8-character code, then enter or scan it here. Pairs once; no need to enter the API key after.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    @MainActor
    private func triggerUnpair() async {
        guard let deviceID = initialEntry.deviceID else { return }
        isUnpairing = true
        defer { isUnpairing = false }
        // Best-effort backend revocation — don't block the local clear on failure.
        if let client = makeDevicesClient() {
            try? await client.revokeDevice(id: deviceID.uuidString)
        }
        do {
            try settings?.clearPairing(backendID: initialEntry.id)
            pairState = .idle
        } catch {
            pairState = .failed("Couldn't clear local credential: \(error)")
        }
    }

    private func makeDevicesClient() -> BackendDevicesClient? {
        guard let url = parsedURL,
              let token = settings?.credentials.token(for: initialEntry.id)
        else { return nil }
        let session = settings?.session(for: initialEntry) ?? .shared
        return BackendDevicesClient(
            backendURL: url,
            authHeaders: ["Authorization": "Bearer \(token)"],
            session: session
        )
    }

    @MainActor
    private func triggerPair() async {
        guard let settings, let url = parsedURL else { return }
        let trimmed = pairCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return }

        // Commit the in-flight URL and cert fingerprint edits BEFORE pairing so
        // the session is built with the current fingerprint (needed for self-signed
        // HTTPS backends where the fingerprint was entered manually).
        settings.updateBackend(initialEntry.id, url: url)
        let fp = certFingerprintDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.updateBackend(initialEntry.id, certFingerprint: fp.isEmpty ? .some(nil) : .some(fp))

        pairState = .pairing
        // Use the now-updated entry so URLSession has the current fingerprint.
        let currentEntry = settings.backends.first(where: { $0.id == initialEntry.id }) ?? initialEntry
        let session = settings.session(for: currentEntry)
        let client = BackendPairingClient(backendURL: url, session: session)
        do {
            let result = try await client.pair(code: trimmed, label: DeviceInfo.localName)
            try settings.markPaired(backendID: initialEntry.id, deviceID: result.deviceID, token: result.token)
            // Never force a name: if the user paired without one, mint a random
            // label so the row isn't blank.
            if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let generated = SettingsStore.randomBackendLabel()
                settings.updateBackend(initialEntry.id, label: generated)
                label = generated
            }
            pairCodeDraft = ""
            pairState = .idle
            showOutcome(.success)
        } catch let pairingError as PairingError {
            pairState = .failed(pairingError.description)
            showOutcome(.failure(pairingError.description))
        } catch {
            let reason = "Keychain refused to store the token: \(error.localizedDescription)"
            pairState = .failed(reason)
            showOutcome(.failure(reason))
        }
    }

    /// Show the result banner, then auto-dismiss after a short delay.
    @MainActor
    private func showOutcome(_ outcome: PairOutcome) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pairOutcome = outcome
        }
        Task {
            try? await Task.sleep(for: .seconds(outcome == .success ? 2 : 3))
            withAnimation(.easeOut(duration: 0.25)) { pairOutcome = nil }
        }
    }

}

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
