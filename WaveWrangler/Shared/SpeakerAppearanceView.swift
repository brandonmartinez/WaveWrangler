import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WWCore

extension SpeakerColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .purple: .purple
        case .pink: .pink
        case .indigo: .indigo
        case .brown: .brown
        case .orange: .orange
        }
    }
}

struct SpeakerAvatarView: View {
    let name: String
    let appearance: SpeakerAppearance
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(appearance.color.swiftUIColor.opacity(0.18))
            if let data = appearance.avatarPNG, let image = SpeakerAvatarImages.image(for: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                    .font(.system(size: size * 0.35, weight: .semibold))
                    .foregroundStyle(appearance.color.swiftUIColor)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay {
            if let data = appearance.avatarPNG, SpeakerAvatarImages.image(for: data) == nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    .accessibilityLabel("Saved avatar unavailable. Replace the image.")
            }
        }
        .accessibilityLabel(name)
    }
}

@MainActor
private enum SpeakerAvatarImages {
    private static let cache: NSCache<NSData, NSImage> = {
        let value = NSCache<NSData, NSImage>()
        value.countLimit = 64
        value.totalCostLimit = 16 * 1024 * 1024
        return value
    }()

    static func image(for data: Data) -> NSImage? {
        if let image = cache.object(forKey: data as NSData) { return image }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: data as NSData, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

enum SpeakerAvatarImport {
    private static let maximumInputBytes = 20 * 1024 * 1024

    @concurrent static func png(from url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data()
        while bytes.count <= maximumInputBytes {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: min(1_048_576, maximumInputBytes + 1 - bytes.count)),
                  !chunk.isEmpty else { break }
            bytes.append(chunk)
        }
        return try await png(from: bytes)
    }

    @concurrent static func png(from bytes: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= maximumInputBytes else { throw Failure.inputSize }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw Failure.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
                UTType.png.identifier as CFString, 1, nil) else { throw Failure.encoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        let png = output as Data
        guard SpeakerAppearance(color: .blue, avatarPNG: png).isValid else { throw Failure.encoding }
        try Task.checkCancellation()
        return png
    }

    enum Failure: LocalizedError {
        case inputSize, unreadable, encoding
        var errorDescription: String? {
            switch self {
            case .inputSize: "Choose an image smaller than 20 MB."
            case .unreadable: "This image could not be read. Choose a PNG, JPEG, TIFF, or another supported image."
            case .encoding: "The image could not be stored as a portable avatar. Choose a different image."
            }
        }
    }
}

struct SpeakerAppearanceEditor: View {
    let store: ShowDocumentStore
    let episodeID: EpisodeID
    let speakerID: SpeakerID
    @State private var choosingImage = false
    @State private var dropTargeted = false
    @State private var importing = false
    @State private var error: String?

    private var episodeOverride: Bool {
        store.model.episode(episodeID)?.speakerAppearanceOverrides?.contains { $0.speaker == speakerID } == true
    }
    private var appearance: SpeakerAppearance? {
        store.model.speakerAppearance(speakerID, in: episodeOverride ? episodeID : nil)
    }

    var body: some View {
        if let appearance {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show host · default in new episodes", isOn: Binding(
                    get: { store.model.show.profile?.hosts.contains(speakerID) == true },
                    set: { value in apply("Change Show Hosts") { model throws(DomainError) in
                        try model.settingHost(speakerID, isHost: value)
                    } }
                ))
                .help("Only future new episodes inherit host membership. Existing episode assignments are never rewritten.")
                .accessibilityIdentifier("workspace.speaker.host")
                Toggle("Override appearance in this episode", isOn: Binding(
                    get: { episodeOverride },
                    set: { value in
                        apply("Change Speaker Appearance Override") { model throws(DomainError) in
                            try model.settingSpeakerAppearance(value ? appearance : nil, for: speakerID, in: episodeID)
                        }
                    }
                ))
                .accessibilityIdentifier("workspace.speaker.override")
                HStack(alignment: .center, spacing: 10) {
                    SpeakerAvatarView(name: store.model.speaker(speakerID)?.name ?? "", appearance: appearance, size: 56)
                        .overlay(Circle().stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 3))
                        .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: acceptDrop)
                        .accessibilityLabel("Speaker avatar. Drop an image here, or use Choose image or Paste.")
                        .accessibilityIdentifier("workspace.speaker.avatar")
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Choose image…") { choosingImage = true }
                            .accessibilityIdentifier("workspace.speaker.chooseAvatar")
                        Button("Paste image", action: paste)
                            .accessibilityIdentifier("workspace.speaker.pasteAvatar")
                        if appearance.avatarPNG != nil {
                            Button("Remove image") { change { $0.avatarPNG = nil } }
                        }
                    }
                    .disabled(importing)
                }
                Picker("Speaker color", selection: Binding(
                    get: { appearance.color },
                    set: { color in change { $0.color = color } }
                )) {
                    ForEach(SpeakerColor.allCases, id: \.self) { color in
                        Label { Text(color.rawValue.capitalized) } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(color.swiftUIColor)
                        }.tag(color)
                    }
                }
                .accessibilityIdentifier("workspace.speaker.color")
                Text(episodeOverride ? "This episode only. Reset the override to inherit the show appearance."
                    : "Show appearance, reused in episodes without an override. Images are copied into the show.")
                    .font(.caption).foregroundStyle(.secondary)
                if importing { ProgressView("Preparing portable avatar").controlSize(.small) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workspace.speaker.appearanceError")
                }
            }
            .controlSize(.small)
            .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
                switch result {
                case let .success(url): importImage(url: url)
                case let .failure(failure): error = failure.localizedDescription
                }
            }
        }
    }

    private func change(_ update: (inout SpeakerAppearance) -> Void) {
        guard var next = appearance else { error = "This speaker is no longer in the show."; return }
        update(&next)
        let targetEpisode = episodeOverride ? episodeID : nil
        apply("Change Speaker Appearance") { model throws(DomainError) in
            try model.settingSpeakerAppearance(next, for: speakerID, in: targetEpisode)
        }
    }

    private func apply(_ name: String, _ operation: (ShowDocumentModel) throws(DomainError) -> ShowDocumentModel) {
        error = store.apply(name, operation) ? nil : store.lastError.map(EpisodeSetupModel.describe) ?? "The document is read-only."
    }

    private func importImage(url: URL? = nil, bytes: Data? = nil) {
        guard !importing else { error = "Wait for the current image import to finish."; return }
        importing = true
        error = nil
        Task {
            defer { importing = false }
            do {
                let png: Data
                if let url { png = try await SpeakerAvatarImport.png(from: url) }
                else if let bytes { png = try await SpeakerAvatarImport.png(from: bytes) }
                else { error = "No image was supplied."; return }
                change { $0.avatarPNG = png }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func paste() {
        let pasteboard = NSPasteboard.general
        if let bytes = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            importImage(bytes: bytes)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  let url = urls.first {
            importImage(url: url)
        } else {
            error = "The clipboard does not contain an image or image file."
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            ?? (provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : nil)
        guard let type else { error = "Drop an image or an image file."; return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, failure in
            let reason = failure?.localizedDescription
            Task { @MainActor in
                guard let data else { error = reason ?? "The dropped image could not be loaded."; return }
                if type == UTType.fileURL.identifier {
                    guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        error = "The dropped file location could not be read."; return
                    }
                    importImage(url: url)
                } else {
                    importImage(bytes: data)
                }
            }
        }
        return true
    }
}
