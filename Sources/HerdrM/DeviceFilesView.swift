import AppKit
import HerdrKit
import SwiftUI

@MainActor
private final class DeviceFileBrowserModel: ObservableObject {
    @Published private(set) var device: Device = .local
    @Published private(set) var currentPath = "~"
    @Published var pathText = "~"
    @Published private(set) var entries: [DeviceFileEntry] = []
    @Published var selectedPath: String?
    @Published var includesHidden = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var service = DeviceFileService(device: .local)
    private var generation = 0

    var selectedEntry: DeviceFileEntry? {
        selectedPath.flatMap { path in entries.first { $0.path == path } }
    }

    func configure(for device: Device, tailscale: TSNetManager? = nil) async {
        guard self.device.id != device.id || entries.isEmpty else { return }
        generation += 1
        self.device = device
        service = DeviceFileService(device: device, tailscale: tailscale)
        currentPath = "~"
        pathText = "~"
        entries = []
        selectedPath = nil
        error = nil
        await refresh()
    }

    func refresh() async {
        await load(pathText)
    }

    func navigate(to path: String) async {
        await load(path)
    }

    func open(_ entry: DeviceFileEntry) async {
        if entry.kind == .directory {
            await load(entry.path)
        } else {
            selectedPath = entry.path
        }
    }

    func goUp() async {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/" : parent)
    }

    func goHome() async {
        await load("~")
    }

    func toggleHidden() async {
        includesHidden.toggle()
        await load(currentPath)
    }

    private func load(_ requestedPath: String) async {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        error = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        do {
            let listing = try await service.listDirectory(
                at: requestedPath,
                includingHidden: includesHidden
            )
            guard requestGeneration == generation, !Task.isCancelled else { return }
            currentPath = listing.path
            pathText = (listing.path as NSString).abbreviatingWithTildeInPath
            entries = listing.entries
            if let selectedPath, !entries.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private final class DeviceFileTransferModel: ObservableObject {
    enum Direction {
        case upload
        case download
    }

    @Published private(set) var isTransferring = false
    @Published private(set) var progress: FileTransferProgress?
    @Published private(set) var label = ""
    @Published var error: String?

    private var task: Task<Void, Never>?

    func start(
        direction: Direction,
        entry: DeviceFileEntry,
        targetDevice: Device,
        localDirectory: String,
        targetDirectory: String,
        conflictPolicy: FileConflictPolicy,
        tailscale: TSNetManager? = nil,
        onFinished: @escaping @MainActor () async -> Void
    ) {
        guard !isTransferring else { return }
        isTransferring = true
        progress = nil
        error = nil
        label = direction == .upload
            ? String(localized: "Uploading \(entry.name)")
            : String(localized: "Downloading \(entry.name)")

        let progressHandler: DeviceFileService.ProgressHandler = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        task = Task { [weak self] in
            do {
                let service = DeviceFileService(
                    device: targetDevice,
                    tailscale: targetDevice.isTailscale ? tailscale : nil
                )
                switch direction {
                case .upload:
                    _ = try await service.uploadFile(
                        from: URL(fileURLWithPath: entry.path),
                        toDirectory: targetDirectory,
                        conflictPolicy: conflictPolicy,
                        progress: progressHandler
                    )
                case .download:
                    _ = try await service.downloadFile(
                        at: entry.path,
                        toLocalDirectory: URL(
                            fileURLWithPath: localDirectory,
                            isDirectory: true
                        ),
                        conflictPolicy: conflictPolicy,
                        progress: progressHandler
                    )
                }
                await onFinished()
            } catch is CancellationError {
                // Explicit cancellation should not produce a failure alert.
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isTransferring = false
            self?.progress = nil
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    deinit {
        task?.cancel()
    }
}

struct DeviceFilesView: View {
    @ObservedObject var model: AppModel
    @StateObject private var local = DeviceFileBrowserModel()
    @StateObject private var target = DeviceFileBrowserModel()
    @StateObject private var transfer = DeviceFileTransferModel()
    @State private var targetDeviceID = Device.local.id
    @State private var pendingConflict: PendingFileTransfer?

    private var targetDevice: Device {
        model.device(targetDeviceID) ?? .local
    }

    var body: some View {
        VStack(spacing: 0) {
            deviceBar
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                DeviceFilePane(
                    title: String(localized: "Local"),
                    device: .local,
                    tailscale: nil,
                    browser: local
                )
                transferButtons
                DeviceFilePane(
                    title: targetDevice.name,
                    device: targetDevice,
                    tailscale: targetDevice.isTailscale ? model.tailscaleManager : nil,
                    browser: target
                )
            }
            if transfer.isTransferring {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                transferBar
            }
        }
        .background(Theme.contentBackground)
        .task {
            targetDeviceID = preferredTargetDeviceID()
        }
        .onChange(of: model.deviceFilter) { _, deviceID in
            if let deviceID { targetDeviceID = deviceID }
        }
        .onChange(of: model.devices.map(\.id)) { _, ids in
            if !ids.contains(targetDeviceID) {
                targetDeviceID = preferredTargetDeviceID()
            }
        }
        .confirmationDialog(
            "File Already Exists",
            isPresented: Binding(
                get: { pendingConflict != nil },
                set: { if !$0 { pendingConflict = nil } }
            ),
            presenting: pendingConflict
        ) { pending in
            Button("Replace", role: .destructive) {
                begin(pending, policy: .replace)
                pendingConflict = nil
            }
            Button("Keep Both") {
                begin(pending, policy: .keepBoth)
                pendingConflict = nil
            }
            Button("Cancel", role: .cancel) {
                pendingConflict = nil
            }
        } message: { pending in
            Text("“\(pending.entry.name)” already exists in the destination.")
        }
        .alert(
            "Transfer Failed",
            isPresented: Binding(
                get: { transfer.error != nil },
                set: { if !$0 { transfer.error = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transfer.error ?? "")
        }
    }

    private var deviceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(Theme.textTertiary)
            Text("Local")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("Transfer with")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Picker("", selection: $targetDeviceID) {
                ForEach(model.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(transfer.isTransferring)
            Spacer()
            Image(systemName: targetDevice.isLocal ? "laptopcomputer" : "network")
                .foregroundStyle(Theme.deviceTint(targetDevice))
            Text(targetDevice.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private var transferButtons: some View {
        VStack(spacing: 10) {
            Spacer()
            Button {
                prepare(.upload)
            } label: {
                Image(systemName: "arrow.right")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Copy the selected local file to \(targetDevice.name)")
            .disabled(!canUpload)

            Button {
                prepare(.download)
            } label: {
                Image(systemName: "arrow.left")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Copy the selected file from \(targetDevice.name) to Local")
            .disabled(!canDownload)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 58)
        .background(Theme.statusBarBackground.opacity(0.55))
        .overlay(
            HStack {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                Spacer()
                Rectangle().fill(Theme.hairline).frame(width: 1)
            }
        )
    }

    private var transferBar: some View {
        HStack(spacing: 10) {
            ProgressView(value: transfer.progress?.fractionCompleted ?? 0)
                .frame(maxWidth: 180)
            Text(transfer.label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            if let progress = transfer.progress {
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: progress.completedBytes,
                        countStyle: .file
                    )
                )
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            }
            Button("Cancel") { transfer.cancel() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.statusBarBackground)
    }

    private var canUpload: Bool {
        !transfer.isTransferring && local.selectedEntry?.kind == .regularFile
    }

    private var canDownload: Bool {
        !transfer.isTransferring && target.selectedEntry?.kind == .regularFile
    }

    private func preferredTargetDeviceID() -> UUID {
        if let filtered = model.deviceFilter, model.device(filtered) != nil { return filtered }
        return model.devices.first(where: { !$0.isLocal })?.id
            ?? model.devices.first?.id
            ?? Device.local.id
    }

    private func prepare(_ direction: DeviceFileTransferModel.Direction) {
        let entry = direction == .upload ? local.selectedEntry : target.selectedEntry
        guard let entry else { return }
        let destinationEntries = direction == .upload ? target.entries : local.entries
        let pending = PendingFileTransfer(direction: direction, entry: entry)
        if destinationEntries.contains(where: { $0.name == entry.name }) {
            pendingConflict = pending
        } else {
            begin(pending, policy: .fail)
        }
    }

    private func begin(_ pending: PendingFileTransfer, policy: FileConflictPolicy) {
        transfer.start(
            direction: pending.direction,
            entry: pending.entry,
            targetDevice: targetDevice,
            localDirectory: local.currentPath,
            targetDirectory: target.currentPath,
            conflictPolicy: policy,
            tailscale: targetDevice.isTailscale ? model.tailscaleManager : nil
        ) {
            switch pending.direction {
            case .upload:
                await target.refresh()
            case .download:
                await local.refresh()
            }
        }
    }
}

private struct PendingFileTransfer: Identifiable {
    let id = UUID()
    let direction: DeviceFileTransferModel.Direction
    let entry: DeviceFileEntry
}

private struct DeviceFilePane: View {
    let title: String
    let device: Device
    let tailscale: TSNetManager?
    @ObservedObject var browser: DeviceFileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Rectangle().fill(Theme.hairline).frame(height: 1)
            pathBar
            columnHeader
            Rectangle().fill(Theme.hairline).frame(height: 1)
            listing
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
        .task(id: device.id) {
            await browser.configure(for: device, tailscale: tailscale)
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: device.isLocal ? "laptopcomputer" : "network")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.deviceTint(device))
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            if browser.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await browser.toggleHidden() }
            } label: {
                Image(systemName: browser.includesHidden ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help(browser.includesHidden ? "Hide hidden files" : "Show hidden files")
            Button {
                Task { await browser.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await browser.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(browser.currentPath == "/")
            .help("Parent folder")

            Button {
                Task { await browser.goHome() }
            } label: {
                Image(systemName: "house")
            }
            .buttonStyle(.plain)
            .help("Home folder")

            TextField("Path", text: $browser.pathText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .onSubmit {
                    Task { await browser.navigate(to: browser.pathText) }
                }

            if device.isLocal {
                Button {
                    chooseLocalFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Choose folder")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(width: 72, alignment: .trailing)
            Text("Modified")
                .frame(width: 126, alignment: .leading)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 12)
        .frame(height: 25)
        .background(Theme.statusBarBackground.opacity(0.7))
    }

    private var listing: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(browser.entries) { entry in
                    Button {
                        Task { await browser.open(entry) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: entry))
                                .font(.system(size: 11.5))
                                .foregroundStyle(
                                    entry.kind == .directory ? Theme.accent : Theme.textTertiary
                                )
                                .frame(width: 16)
                            Text(entry.name)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(size(for: entry))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 72, alignment: .trailing)
                            Text(modified(for: entry))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 126, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    browser.selectedPath == entry.path
                                        ? Theme.accentWash
                                        : Color.clear
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .overlay {
            if browser.entries.isEmpty, !browser.isLoading, browser.error == nil {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("This folder contains no visible items.")
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = browser.error {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                Text(error)
                    .lineLimit(1)
                    .help(error)
            } else {
                Text("\(browser.entries.count) items")
            }
            Spacer()
            if let selected = browser.selectedEntry {
                Text(selected.name)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.statusBarBackground.opacity(0.7))
    }

    private func icon(for entry: DeviceFileEntry) -> String {
        switch entry.kind {
        case .directory: return entry.isPackage ? "shippingbox" : "folder"
        case .regularFile: return "doc"
        case .symbolicLink: return "link"
        case .other: return "questionmark.square"
        }
    }

    private func size(for entry: DeviceFileEntry) -> String {
        guard let size = entry.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func modified(for entry: DeviceFileEntry) -> String {
        guard let date = entry.modificationDate else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: browser.currentPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await browser.navigate(to: url.path) }
        }
    }
}
