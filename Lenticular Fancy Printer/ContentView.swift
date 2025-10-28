//
//  ContentView.swift
//  Lenticular Fancy Printer
//
//  Created by Mathilda on 10/27/25.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Data Models

/// Lens parameters
struct LensParameters: Codable, Equatable {
    var lpi: Double = 40
    var pitch: Double = 0.635
    var radius: Double = 0.32  // ~pitch/2 for proper scalloping
    var height: Double = 2.0
    var viewingAngle: Double = 40

    // Computed: Calculate pitch from LPI
    mutating func updatePitchFromLPI() {
        pitch = 25.4 / lpi
    }

    // Computed: Calculate LPI from pitch
    mutating func updateLPIFromPitch() {
        lpi = 25.4 / pitch
    }

    // Auto-calculate radius based on pitch (approximately pitch/2)
    mutating func autoCalculateRadius() {
        radius = pitch / 2.0
    }

    // Auto-calculate viewing angle based on geometry
    // Viewing angle ≈ 2 * atan(pitch / (2 * height)) converted to degrees
    mutating func autoCalculateViewingAngle() {
        let angleRadians = 2.0 * atan(pitch / (2.0 * height))
        viewingAngle = angleRadians * 180.0 / .pi
    }

    // Update all dependent values
    mutating func updateDependentValues() {
        autoCalculateRadius()
        autoCalculateViewingAngle()
    }

    // Preset definitions
    // Note: Radius should be approximately pitch/2 for proper scalloped lenticules
    static let presets: [String: LensParameters] = [
        "Standard 40 LPI": LensParameters(lpi: 40, pitch: 0.635, radius: 0.32, height: 2.0, viewingAngle: 40),
        "Fine Detail 60 LPI": LensParameters(lpi: 60, pitch: 0.423, radius: 0.21, height: 1.5, viewingAngle: 35),
        "Wide Angle 20 LPI": LensParameters(lpi: 20, pitch: 1.27, radius: 0.64, height: 3.0, viewingAngle: 50),
        "Custom": LensParameters()
    ]
}

/// Source image
struct SourceImage: Identifiable {
    let id = UUID()
    var url: URL
    var order: Int

    var thumbnail: NSImage? {
        // Start accessing security-scoped resource
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        let maxSize: CGFloat = 150
        let size = image.size
        let ratio = min(maxSize / size.width, maxSize / size.height)
        let thumbSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        let thumbnail = NSImage(size: thumbSize)
        thumbnail.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: thumbSize),
                   from: CGRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        thumbnail.unlockFocus()
        return thumbnail
    }

    var dimensions: CGSize? {
        // Start accessing security-scoped resource
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        // Get actual pixel dimensions from CGImage, not points from NSImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image.size
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}

/// Project model
class Project: ObservableObject {
    @Published var name: String = "Untitled Project"
    @Published var sourceImages: [SourceImage] = []
    @Published var lensParameters = LensParameters()
    @Published var interlacedImage: NSImage?
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double = 0.0
    @Published var outputDPI: Int = 300
    @Published var outputWidth: Int = 0
    @Published var outputHeight: Int = 0
    @Published var aspectRatioLocked: Bool = true

    // Physical dimensions in inches (computed from pixels and DPI)
    var physicalWidth: Double {
        guard outputDPI > 0 else { return 0 }
        return Double(outputWidth) / Double(outputDPI)
    }

    var physicalHeight: Double {
        guard outputDPI > 0 else { return 0 }
        return Double(outputHeight) / Double(outputDPI)
    }

    func setPhysicalWidth(_ inches: Double) {
        let newWidth = Int(inches * Double(outputDPI))
        setOutputWidth(newWidth)
    }

    func setPhysicalHeight(_ inches: Double) {
        let newHeight = Int(inches * Double(outputDPI))
        setOutputHeight(newHeight)
    }

    func setOutputDPI(_ newDPI: Int) {
        guard newDPI > 0 else { return }
        // Keep physical size constant when DPI changes
        let currentPhysicalWidth = physicalWidth
        let currentPhysicalHeight = physicalHeight
        outputDPI = newDPI
        // Recalculate pixel dimensions to maintain physical size
        outputWidth = Int(currentPhysicalWidth * Double(newDPI))
        outputHeight = Int(currentPhysicalHeight * Double(newDPI))
    }

    func addImages(from urls: [URL]) {
        let newImages = urls.enumerated().map { index, url in
            SourceImage(url: url, order: sourceImages.count + index)
        }
        sourceImages.append(contentsOf: newImages)
        updateOutputDimensionsFromSource()
    }

    func updateOutputDimensionsFromSource() {
        guard let firstSize = sourceImages.first?.dimensions else { return }
        outputWidth = Int(firstSize.width)
        outputHeight = Int(firstSize.height)
    }

    func setOutputWidth(_ newWidth: Int) {
        if aspectRatioLocked && outputHeight > 0 {
            let aspectRatio = Double(outputWidth) / Double(outputHeight)
            outputWidth = newWidth
            outputHeight = Int(Double(newWidth) / aspectRatio)
        } else {
            outputWidth = newWidth
        }
    }

    func setOutputHeight(_ newHeight: Int) {
        if aspectRatioLocked && outputWidth > 0 {
            let aspectRatio = Double(outputWidth) / Double(outputHeight)
            outputHeight = newHeight
            outputWidth = Int(Double(newHeight) * aspectRatio)
        } else {
            outputHeight = newHeight
        }
    }

    func removeImage(at index: Int) {
        guard index < sourceImages.count else { return }
        sourceImages.remove(at: index)
        reorderImages()
    }

    private func reorderImages() {
        for (index, _) in sourceImages.enumerated() {
            sourceImages[index].order = index
        }
    }

    func validateImageDimensions() -> (valid: Bool, message: String) {
        guard !sourceImages.isEmpty else {
            return (false, "No images imported")
        }

        guard let firstSize = sourceImages.first?.dimensions else {
            return (false, "Could not read first image dimensions")
        }

        for image in sourceImages.dropFirst() {
            guard let size = image.dimensions else {
                return (false, "Could not read dimensions for \(image.url.lastPathComponent)")
            }

            if size != firstSize {
                return (false, "Image dimensions do not match")
            }
        }

        return (true, "All images have matching dimensions: \(Int(firstSize.width))x\(Int(firstSize.height))")
    }

    var isReadyForInterlace: Bool {
        guard sourceImages.count >= 2 else { return false }
        return validateImageDimensions().valid
    }

    // MARK: - Interlacing

    func generateInterlacedImage() async {
        await MainActor.run {
            isProcessing = true
            processingProgress = 0.0
        }

        let result = await InterlaceEngine.interlace(
            sourceImages: sourceImages,
            lensParameters: lensParameters,
            dpi: outputDPI,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            progressCallback: { progress in
                Task { @MainActor in
                    self.processingProgress = progress
                }
            }
        )

        await MainActor.run {
            interlacedImage = result
            isProcessing = false
            processingProgress = 1.0
        }
    }
}

// MARK: - Interlace Engine

class InterlaceEngine {
    static func interlace(
        sourceImages: [SourceImage],
        lensParameters: LensParameters,
        dpi: Int,
        outputWidth: Int,
        outputHeight: Int,
        progressCallback: @escaping (Double) -> Void
    ) async -> NSImage? {
        guard !sourceImages.isEmpty else { return nil }
        guard outputWidth > 0 && outputHeight > 0 else { return nil }

        // Load all source images
        var loadedImages: [NSImage] = []
        for sourceImage in sourceImages {
            let accessing = sourceImage.url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    sourceImage.url.stopAccessingSecurityScopedResource()
                }
            }

            guard let image = NSImage(contentsOf: sourceImage.url) else {
                return nil
            }
            loadedImages.append(image)
        }

        // Calculate pixels per lenticule based on DPI
        // DPI tells us how many pixels per inch in the output
        // LPI tells us how many lenticules per inch
        // Therefore: pixels per lenticule = DPI / LPI
        let pixelsPerLenticule = Double(dpi) / lensParameters.lpi

        let numImages = Double(loadedImages.count)

        // Create output bitmap context
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Scale and get CGImages from NSImages
        var cgImages: [CGImage] = []
        for nsImage in loadedImages {
            // Get source size
            guard let sourceRep = nsImage.representations.first else { continue }
            let sourceWidth = sourceRep.pixelsWide
            let sourceHeight = sourceRep.pixelsHigh

            // Calculate aspect-fit scaling
            let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
            let targetAspect = Double(outputWidth) / Double(outputHeight)

            var destWidth = outputWidth
            var destHeight = outputHeight
            var destX = 0
            var destY = 0

            if sourceAspect > targetAspect {
                // Source is wider - fit to width
                destHeight = Int(Double(outputWidth) / sourceAspect)
                destY = (outputHeight - destHeight) / 2
            } else {
                // Source is taller - fit to height
                destWidth = Int(Double(outputHeight) * sourceAspect)
                destX = (outputWidth - destWidth) / 2
            }

            // Create a scaled version of the image to match output dimensions
            let scaledImage = NSImage(size: NSSize(width: outputWidth, height: outputHeight))
            scaledImage.lockFocus()

            // Fill background with black
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: outputWidth, height: outputHeight).fill()

            // Draw scaled image centered
            nsImage.draw(in: NSRect(x: destX, y: destY, width: destWidth, height: destHeight),
                        from: NSRect(origin: .zero, size: nsImage.size),
                        operation: .copy,
                        fraction: 1.0)
            scaledImage.unlockFocus()

            guard let cgImage = scaledImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            cgImages.append(cgImage)
        }

        // Interlace column by column
        for x in 0..<outputWidth {
            // Calculate which lenticule and position within lenticule
            let lenticulePosition = Double(x).truncatingRemainder(dividingBy: pixelsPerLenticule)

            // Determine which source image this strip comes from
            let imageIndex = Int((lenticulePosition / pixelsPerLenticule) * numImages)
            let clampedIndex = min(imageIndex, cgImages.count - 1)

            let sourceImage = cgImages[clampedIndex]

            // Copy this column from source to output
            for y in 0..<outputHeight {
                // Sample pixel from source (images are already scaled to output size)
                let pixelData = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
                defer { pixelData.deallocate() }

                let bitmapContext = CGContext(
                    data: pixelData,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )

                bitmapContext?.draw(sourceImage, in: CGRect(x: -x, y: -y, width: outputWidth, height: outputHeight))

                let r = CGFloat(pixelData[0]) / 255.0
                let g = CGFloat(pixelData[1]) / 255.0
                let b = CGFloat(pixelData[2]) / 255.0
                let a = CGFloat(pixelData[3]) / 255.0

                context.setFillColor(red: r, green: g, blue: b, alpha: a)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }

            // Update progress
            if x % 100 == 0 {
                let progress = Double(x) / Double(outputWidth)
                progressCallback(progress)
            }
        }

        progressCallback(1.0)

        // Create NSImage from context
        guard let cgImage = context.makeImage() else { return nil }
        let outputImage = NSImage(cgImage: cgImage, size: CGSize(width: outputWidth, height: outputHeight))

        return outputImage
    }
}

// MARK: - Navigation sections
enum NavigationSection: String, CaseIterable, Identifiable {
    case import_ = "Import"
    case lens = "Lens Config"
    case interlace = "Interlace"
    case tiles = "Tiles"
    case model3D = "3D Model"
    case export = "Export"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .import_: return "photo.on.rectangle.angled"
        case .lens: return "camera.aperture"
        case .interlace: return "square.grid.3x3"
        case .tiles: return "square.split.2x2"
        case .model3D: return "cube.transparent"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct ContentView: View {
    @StateObject private var project = Project()
    @State private var selectedSection: NavigationSection = .import_

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(NavigationSection.allCases, selection: $selectedSection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
            }
            .navigationTitle("Lenticular Fancy Printer")
            .frame(minWidth: 200)
        } detail: {
            // Main content area
            Group {
                switch selectedSection {
                case .import_:
                    ImportView(project: project)
                case .lens:
                    LensConfigView(project: project)
                case .interlace:
                    InterlaceView(project: project)
                case .tiles:
                    PlaceholderView(title: "Tile Configuration", subtitle: "Coming in Phase 5")
                case .model3D:
                    PlaceholderView(title: "3D Model Generation", subtitle: "Coming in Phase 6")
                case .export:
                    PlaceholderView(title: "Export & Print", subtitle: "Coming in Phase 7")
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
    }
}

/// Placeholder view for sections not yet implemented
struct PlaceholderView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}

// MARK: - Import View

struct ImportView: View {
    @ObservedObject var project: Project
    @State private var isTargeted = false
    @State private var showingFilePicker = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Import Images")
                    .font(.title)
                Text("Import 2-20 images for interlacing. All images must have the same dimensions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            // Main content
            ScrollView {
                VStack(spacing: 20) {
                    // Drop zone
                    dropZone
                        .padding()

                    // Imported images grid
                    if !project.sourceImages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("\(project.sourceImages.count) Images Imported")
                                    .font(.headline)
                                Spacer()
                                Button(action: clearAll) {
                                    Label("Clear All", systemImage: "trash")
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(.horizontal)

                            // Validation message
                            if let message = validationMessage {
                                HStack {
                                    Image(systemName: project.validateImageDimensions().valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(project.validateImageDimensions().valid ? .green : .orange)
                                    Text(message)
                                        .font(.caption)
                                }
                                .padding(.horizontal)
                            }

                            imageGrid
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(isTargeted ? .blue : .secondary)

            Text("Drag and drop images here")
                .font(.title3)
                .foregroundStyle(isTargeted ? .blue : .primary)

            Text("or")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: { showingFilePicker = true }) {
                Label("Browse Files", systemImage: "folder")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)

            Text("Supported: PNG, JPEG, TIFF")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.blue : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.png, .jpeg, .tiff],
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result: result)
        }
    }

    private var imageGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
            ForEach(Array(project.sourceImages.enumerated()), id: \.element.id) { index, image in
                ImageThumbnailView(
                    image: image,
                    index: index,
                    onRemove: { removeImage(at: index) }
                )
            }
        }
        .padding(.horizontal)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url = url, isValidImageFile(url) {
                    urls.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                project.addImages(from: urls)
                validateImages()
            }
        }

        return true
    }

    private func handleFileSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let validURLs = urls.filter { isValidImageFile($0) }
            if !validURLs.isEmpty {
                project.addImages(from: validURLs)
                validateImages()
            }
        case .failure(let error):
            print("File selection error: \(error)")
        }
    }

    private func isValidImageFile(_ url: URL) -> Bool {
        let validExtensions = ["png", "jpg", "jpeg", "tiff", "tif"]
        return validExtensions.contains(url.pathExtension.lowercased())
    }

    private func removeImage(at index: Int) {
        project.removeImage(at: index)
        validateImages()
    }

    private func clearAll() {
        project.sourceImages.removeAll()
        validationMessage = nil
    }

    private func validateImages() {
        let validation = project.validateImageDimensions()
        validationMessage = validation.message
    }
}

struct ImageThumbnailView: View {
    let image: SourceImage
    let index: Int
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail
                Group {
                    if let thumbnail = image.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 150)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Remove button
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .padding(8)
            }

            // Image info
            VStack(alignment: .leading, spacing: 2) {
                Text("Frame \(index + 1)")
                    .font(.caption)
                    .fontWeight(.medium)

                Text(image.url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let dimensions = image.dimensions {
                    Text("\(Int(dimensions.width)) × \(Int(dimensions.height))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 150)
    }
}

// MARK: - Custom Preset Storage

class PresetManager: ObservableObject {
    @Published var customPresets: [String: LensParameters] = [:]

    private let presetsKey = "CustomLensPresets"

    init() {
        loadPresets()
    }

    func savePreset(name: String, parameters: LensParameters) {
        customPresets[name] = parameters
        persistPresets()
    }

    func deletePreset(name: String) {
        customPresets.removeValue(forKey: name)
        persistPresets()
    }

    func allPresets() -> [String: LensParameters] {
        var all = LensParameters.presets
        all.merge(customPresets) { _, new in new }
        return all
    }

    private func persistPresets() {
        if let encoded = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(encoded, forKey: presetsKey)
        }
    }

    private func loadPresets() {
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let decoded = try? JSONDecoder().decode([String: LensParameters].self, from: data) {
            customPresets = decoded
        }
    }
}

// MARK: - Lens Configuration View

struct LensConfigView: View {
    @ObservedObject var project: Project
    @StateObject private var presetManager = PresetManager()
    @State private var selectedPreset: String = "Standard 40 LPI"
    @State private var editMode: ParameterEditMode = .lpi
    @State private var showingSaveDialog = false
    @State private var newPresetName = ""
    @State private var showingDeleteConfirm = false
    @State private var presetToDelete: String?

    enum ParameterEditMode {
        case lpi
        case pitch
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lens Configuration")
                        .font(.title)
                    Text("Configure the physical parameters of your custom 3D-printed lenticular lens.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top)

                Divider()

                // Preset Selector
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Preset", systemImage: "bookmark.fill")
                            .font(.headline)
                        Spacer()
                        Button(action: { showingSaveDialog = true }) {
                            Label("Save", systemImage: "plus.circle.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                    }

                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(Array(presetManager.allPresets().keys.sorted()), id: \.self) { key in
                            Text(key).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedPreset) { _, newValue in
                        if let preset = presetManager.allPresets()[newValue] {
                            project.lensParameters = preset
                        }
                    }

                    // Delete button for custom presets
                    if presetManager.customPresets.keys.contains(selectedPreset) {
                        Button(role: .destructive, action: {
                            presetToDelete = selectedPreset
                            showingDeleteConfirm = true
                        }) {
                            Label("Delete '\(selectedPreset)'", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal)
                .alert("Save Preset", isPresented: $showingSaveDialog) {
                    TextField("Preset Name", text: $newPresetName)
                    Button("Cancel", role: .cancel) {
                        newPresetName = ""
                    }
                    Button("Save") {
                        if !newPresetName.isEmpty {
                            presetManager.savePreset(name: newPresetName, parameters: project.lensParameters)
                            selectedPreset = newPresetName
                            newPresetName = ""
                        }
                    }
                } message: {
                    Text("Enter a name for this preset")
                }
                .alert("Delete Preset", isPresented: $showingDeleteConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        if let name = presetToDelete {
                            presetManager.deletePreset(name: name)
                            selectedPreset = "Standard 40 LPI"
                            presetToDelete = nil
                        }
                    }
                } message: {
                    Text("Are you sure you want to delete '\(presetToDelete ?? "")'?")
                }

                Divider()

                // LPI vs Pitch Toggle
                VStack(alignment: .leading, spacing: 12) {
                    Label("Primary Parameter", systemImage: "arrow.left.arrow.right")
                        .font(.headline)

                    Picker("Edit Mode", selection: $editMode) {
                        Text("LPI (Lines Per Inch)").tag(ParameterEditMode.lpi)
                        Text("Pitch (millimeters)").tag(ParameterEditMode.pitch)
                    }
                    .pickerStyle(.segmented)

                    Text("LPI = 25.4 / Pitch (mm)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                .padding(.horizontal)

                Divider()

                // Parameter Controls
                VStack(alignment: .leading, spacing: 20) {
                    Text("Lens Parameters")
                        .font(.headline)
                        .padding(.horizontal)

                    // LPI or Pitch (depending on mode)
                    if editMode == .lpi {
                        ParameterSlider(
                            title: "LPI (Lines Per Inch)",
                            value: Binding(
                                get: { project.lensParameters.lpi },
                                set: { newValue in
                                    project.lensParameters.lpi = newValue
                                    project.lensParameters.updatePitchFromLPI()
                                    project.lensParameters.updateDependentValues()
                                    selectedPreset = "Custom"
                                }
                            ),
                            range: 10...100,
                            step: 1,
                            unit: "lpi",
                            tooltip: "Density of lenticules. Higher LPI = more detail but narrower viewing angle."
                        )
                    } else {
                        ParameterSlider(
                            title: "Pitch (Spacing)",
                            value: Binding(
                                get: { project.lensParameters.pitch },
                                set: { newValue in
                                    project.lensParameters.pitch = newValue
                                    project.lensParameters.updateLPIFromPitch()
                                    project.lensParameters.updateDependentValues()
                                    selectedPreset = "Custom"
                                }
                            ),
                            range: 0.1...5.0,
                            step: 0.01,
                            unit: "mm",
                            tooltip: "Physical spacing between lenticules in millimeters."
                        )
                    }

                    // Height
                    ParameterSlider(
                        title: "Lens Height (Thickness)",
                        value: Binding(
                            get: { project.lensParameters.height },
                            set: { newValue in
                                project.lensParameters.height = newValue
                                project.lensParameters.updateDependentValues()
                                selectedPreset = "Custom"
                            }
                        ),
                        range: 0.5...5.0,
                        step: 0.1,
                        unit: "mm",
                        tooltip: "Thickness of the lens layer to be 3D printed."
                    )
                }

                Divider()

                // Advanced parameters (auto-calculated, but editable)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Advanced Parameters (Auto-Calculated)")
                        .font(.headline)
                        .padding(.horizontal)

                    Text("These values are automatically calculated based on LPI and Height. You can override them if needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    // Radius (editable field)
                    HStack {
                        Text("Lens Radius:")
                            .font(.subheadline)
                        Spacer()
                        TextField("Radius", value: Binding(
                            get: { project.lensParameters.radius },
                            set: { newValue in
                                project.lensParameters.radius = newValue
                                selectedPreset = "Custom"
                            }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        Text("mm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                    }
                    .padding(.horizontal)

                    Text("Auto: ≈ pitch/2 for proper scalloped shape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.leading, 4)

                    // Viewing Angle (editable field)
                    HStack {
                        Text("Viewing Angle:")
                            .font(.subheadline)
                        Spacer()
                        TextField("Angle", value: Binding(
                            get: { project.lensParameters.viewingAngle },
                            set: { newValue in
                                project.lensParameters.viewingAngle = newValue
                                selectedPreset = "Custom"
                            }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        Text("°")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                    }
                    .padding(.horizontal)

                    Text("Auto: calculated from lens geometry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.leading, 4)
                }

                Divider()

                // Cross-section Preview
                VStack(alignment: .leading, spacing: 12) {
                    Label("Lens Cross-Section Preview", systemImage: "eye")
                        .font(.headline)

                    LensCrossSectionView(parameters: project.lensParameters)
                        .frame(height: 200)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Current values summary
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Settings:")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("LPI: \(String(format: "%.1f", project.lensParameters.lpi)) • Pitch: \(String(format: "%.3f", project.lensParameters.pitch)) mm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Radius: \(String(format: "%.1f", project.lensParameters.radius)) mm • Height: \(String(format: "%.1f", project.lensParameters.height)) mm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Parameter Slider Component

struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let tooltip: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                TextField("Value", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)

                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
            }

            Slider(value: $value, in: range, step: step)

            Text(tooltip)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .padding(.horizontal)
    }
}

// MARK: - Lens Cross-Section View

struct LensCrossSectionView: View {
    let parameters: LensParameters

    var body: some View {
        Canvas { context, size in
            // Show exactly 1 inch worth of lenticules
            let lenticuleCount = Int(parameters.lpi.rounded())

            // Scale: fit 1 inch to 80% of canvas width
            let oneInchPixels = size.width * 0.8
            let pixelsPerMM = oneInchPixels / 25.4  // 25.4mm = 1 inch

            // Calculate drawing parameters
            let radiusPixels = CGFloat(parameters.radius) * pixelsPerMM
            let pitchPixels = CGFloat(parameters.pitch) * pixelsPerMM
            let heightPixels = CGFloat(parameters.height) * pixelsPerMM

            // Position: show lens from bottom of canvas
            let substrateY = size.height * 0.85  // substrate baseline

            // Draw all lenticules as one continuous piece
            var lensPath = Path()
            let segments = 40
            let startX = (size.width - CGFloat(lenticuleCount) * pitchPixels) / 2.0
            let endX = startX + CGFloat(lenticuleCount) * pitchPixels

            // Calculate where scallops start (top of flat base portion)
            let scallopsBaseY = substrateY - heightPixels + radiusPixels

            // Start at bottom left of lens (on substrate)
            lensPath.move(to: CGPoint(x: startX, y: substrateY))

            // Go up left side to where scallops begin
            lensPath.addLine(to: CGPoint(x: startX, y: scallopsBaseY))

            // Draw scalloped top edge (all lenticules)
            for i in 0..<lenticuleCount {
                let centerX = startX + CGFloat(i) * pitchPixels + (pitchPixels / 2.0)

                // Draw semi-circular arc for this lenticule (going upward)
                for j in 0...segments {
                    let angle = .pi * Double(j) / Double(segments) - .pi / 2
                    let x = centerX + radiusPixels * CGFloat(sin(angle))
                    let y = scallopsBaseY - radiusPixels * (CGFloat(cos(angle)) + 1)
                    lensPath.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Go down right side back to substrate
            lensPath.addLine(to: CGPoint(x: endX, y: scallopsBaseY))
            lensPath.addLine(to: CGPoint(x: endX, y: substrateY))

            // Close along bottom
            lensPath.addLine(to: CGPoint(x: startX, y: substrateY))
            lensPath.closeSubpath()

            // Fill and stroke the entire lens as one piece
            context.fill(lensPath, with: .color(.blue.opacity(0.4)))
            context.stroke(lensPath, with: .color(.blue), lineWidth: 1.5)

            // Draw a subtle line showing the flat base portion
            if heightPixels > radiusPixels * 1.5 {
                var baseLine = Path()
                baseLine.move(to: CGPoint(x: startX, y: scallopsBaseY))
                baseLine.addLine(to: CGPoint(x: endX, y: scallopsBaseY))
                context.stroke(baseLine, with: .color(.blue.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
            }

            // Draw substrate baseline
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: substrateY))
            baseline.addLine(to: CGPoint(x: size.width, y: substrateY))
            context.stroke(baseline, with: .color(.primary), lineWidth: 3)

            // Draw dimension annotations

            // 1-inch scale bar
            let scaleY = substrateY + 20
            let scaleStartX = startX
            let scaleEndX = startX + oneInchPixels

            var scaleLine = Path()
            scaleLine.move(to: CGPoint(x: scaleStartX, y: scaleY))
            scaleLine.addLine(to: CGPoint(x: scaleEndX, y: scaleY))
            // Add tick marks
            scaleLine.move(to: CGPoint(x: scaleStartX, y: scaleY - 5))
            scaleLine.addLine(to: CGPoint(x: scaleStartX, y: scaleY + 5))
            scaleLine.move(to: CGPoint(x: scaleEndX, y: scaleY - 5))
            scaleLine.addLine(to: CGPoint(x: scaleEndX, y: scaleY + 5))
            context.stroke(scaleLine, with: .color(.primary), lineWidth: 2)

            // 1-inch label
            context.draw(Text("← 1 inch (\(lenticuleCount) lenticules) →")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary),
                         at: CGPoint(x: (scaleStartX + scaleEndX) / 2, y: scaleY + 15))

            // Pitch annotation (show on first lenticule)
            let firstCenterX = startX + (pitchPixels / 2.0)
            let pitchArrowY = scallopsBaseY - radiusPixels - 15
            var pitchArrow = Path()
            pitchArrow.move(to: CGPoint(x: firstCenterX - (pitchPixels/2.0), y: pitchArrowY))
            pitchArrow.addLine(to: CGPoint(x: firstCenterX + (pitchPixels/2.0), y: pitchArrowY))
            context.stroke(pitchArrow, with: .color(.orange), lineWidth: 1)

            // Pitch label
            context.draw(Text("\(String(format: "%.2f", parameters.pitch))mm")
                .font(.caption2)
                .foregroundColor(.orange),
                         at: CGPoint(x: firstCenterX, y: pitchArrowY - 8))

            // Height annotation (show total thickness on left side)
            let heightLineX = startX - 30
            var heightLine = Path()
            heightLine.move(to: CGPoint(x: heightLineX, y: substrateY))
            heightLine.addLine(to: CGPoint(x: heightLineX, y: substrateY - heightPixels))
            // Add arrows
            heightLine.move(to: CGPoint(x: heightLineX - 3, y: substrateY - 5))
            heightLine.addLine(to: CGPoint(x: heightLineX, y: substrateY))
            heightLine.addLine(to: CGPoint(x: heightLineX + 3, y: substrateY - 5))
            heightLine.move(to: CGPoint(x: heightLineX - 3, y: substrateY - heightPixels + 5))
            heightLine.addLine(to: CGPoint(x: heightLineX, y: substrateY - heightPixels))
            heightLine.addLine(to: CGPoint(x: heightLineX + 3, y: substrateY - heightPixels + 5))
            context.stroke(heightLine, with: .color(.purple), lineWidth: 1.5)

            context.draw(Text("\(String(format: "%.1f", parameters.height))mm")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.purple),
                         at: CGPoint(x: heightLineX - 35, y: substrateY - heightPixels/2))

            // Radius annotation (show on first lenticule)
            if lenticuleCount > 0 {
                let radiusCenterX = startX + (pitchPixels / 2.0)
                let peakY = scallopsBaseY - radiusPixels * 2
                var radiusLine = Path()
                radiusLine.move(to: CGPoint(x: radiusCenterX, y: scallopsBaseY))
                radiusLine.addLine(to: CGPoint(x: radiusCenterX, y: peakY))
                context.stroke(radiusLine, with: .color(.green.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3]))

                context.draw(Text("r: \(String(format: "%.2f", parameters.radius))mm")
                    .font(.caption2)
                    .foregroundColor(.green),
                             at: CGPoint(x: radiusCenterX + 25, y: (scallopsBaseY + peakY)/2))
            }
        }
        .padding()
    }
}

// MARK: - Image Document for Export

struct ImageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }

    var image: NSImage

    init(image: NSImage) {
        self.image = image
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let image = NSImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.image = image
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return FileWrapper(regularFileWithContents: pngData)
    }
}

// MARK: - Preview Mode

enum PreviewMode: String, CaseIterable {
    case interlaced = "Interlaced"
    case animated = "Animated"
    case sourceComparison = "Source Images"
}

// MARK: - Interlace View

struct InterlaceView: View {
    @ObservedObject var project: Project
    @State private var zoomScale: CGFloat = 1.0
    @State private var previewMode: PreviewMode = .interlaced
    @State private var showGrid: Bool = false
    @State private var isAnimating: Bool = false
    @State private var animationSpeed: Double = 2.0  // frames per second
    @State private var currentFrameIndex: Int = 0
    @State private var viewingAngle: Double = 0.5  // 0.0 to 1.0
    @State private var animationTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Interlace Images")
                    .font(.title)
                Text("Generate the interlaced pattern based on your lens parameters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            if !project.isReadyForInterlace {
                // Not ready state
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundStyle(.orange)
                    Text("Not Ready to Interlace")
                        .font(.title2)
                    Text("Import at least 2 images with matching dimensions to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Ready state
                VStack(spacing: 16) {
                    // Output Dimensions Configuration
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Output Dimensions", systemImage: "ruler")
                                .font(.headline)
                            Spacer()
                            Button(action: {
                                project.updateOutputDimensionsFromSource()
                            }) {
                                Label("Reset to Source", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }

                        // Physical Size (Inches) - Primary controls
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Physical Print Size")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            HStack(spacing: 16) {
                                // Physical Width
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Width")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        TextField("Width", value: Binding(
                                            get: { project.physicalWidth },
                                            set: { project.setPhysicalWidth($0) }
                                        ), format: .number.precision(.fractionLength(2)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        Text("in")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                // Aspect Ratio Lock
                                Button(action: {
                                    project.aspectRatioLocked.toggle()
                                }) {
                                    Image(systemName: project.aspectRatioLocked ? "lock.fill" : "lock.open")
                                        .foregroundColor(project.aspectRatioLocked ? .blue : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(project.aspectRatioLocked ? "Aspect ratio locked" : "Aspect ratio unlocked")

                                // Physical Height
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Height")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        TextField("Height", value: Binding(
                                            get: { project.physicalHeight },
                                            set: { project.setPhysicalHeight($0) }
                                        ), format: .number.precision(.fractionLength(2)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        Text("in")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Divider()
                                    .frame(height: 40)

                                // DPI
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Resolution")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        TextField("DPI", value: Binding(
                                            get: { project.outputDPI },
                                            set: { project.setOutputDPI($0) }
                                        ), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 70)
                                        Text("dpi")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        Divider()

                        // Pixel Dimensions - Secondary info
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pixel Dimensions")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            HStack(spacing: 16) {
                                // Width in pixels
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Width")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        TextField("Width", value: Binding(
                                            get: { project.outputWidth },
                                            set: { project.setOutputWidth($0) }
                                        ), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        Text("px")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                // Height in pixels
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Height")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        TextField("Height", value: Binding(
                                            get: { project.outputHeight },
                                            set: { project.setOutputHeight($0) }
                                        ), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        Text("px")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        Text("Detected from source: \(Int(project.sourceImages.first?.dimensions?.width ?? 0))×\(Int(project.sourceImages.first?.dimensions?.height ?? 0)) px")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                    .padding(.top)

                    // Settings and Generate button
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lens:")
                                .font(.subheadline)
                            Text("\(String(format: "%.1f", project.lensParameters.lpi)) LPI")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Images:")
                                .font(.subheadline)
                            Text("\(project.sourceImages.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(action: {
                            Task {
                                await project.generateInterlacedImage()
                            }
                        }) {
                            Label("Generate Interlaced Image", systemImage: "wand.and.stars")
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(project.isProcessing)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)

                    // Progress indicator
                    if project.isProcessing {
                        VStack(spacing: 12) {
                            ProgressView(value: project.processingProgress)
                                .progressViewStyle(.linear)
                            Text("Processing: \(Int(project.processingProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    // Preview
                    if let interlacedImage = project.interlacedImage {
                        VStack(spacing: 0) {
                            // Preview Mode Picker
                            HStack {
                                Picker("Preview Mode", selection: $previewMode) {
                                    ForEach(PreviewMode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 400)

                                Spacer()

                                // Grid overlay toggle
                                if previewMode == .interlaced {
                                    Toggle(isOn: $showGrid) {
                                        Label("Grid", systemImage: "grid")
                                            .font(.caption)
                                    }
                                    .toggleStyle(.button)
                                }

                                // Export button
                                Button(action: { exportInterlacedImage() }) {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.05))

                            Divider()

                            // Preview Content
                            ScrollView([.horizontal, .vertical]) {
                                ZStack {
                                    // Main preview based on mode
                                    Group {
                                        switch previewMode {
                                        case .interlaced:
                                            Image(nsImage: interlacedImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                        case .animated:
                                            if !project.sourceImages.isEmpty {
                                                animatedPreview
                                            }
                                        case .sourceComparison:
                                            sourceComparisonView
                                        }
                                    }
                                    .scaleEffect(zoomScale)

                                    // Grid overlay
                                    if showGrid && previewMode == .interlaced {
                                        lenticuleGridOverlay(imageSize: interlacedImage.size)
                                            .scaleEffect(zoomScale)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.gray.opacity(0.1))

                            Divider()

                            // Preview Controls
                            VStack(spacing: 8) {
                                // Zoom controls
                                HStack {
                                    Text("Zoom:")
                                        .font(.subheadline)
                                    Button(action: { zoomScale = max(0.1, zoomScale - 0.25) }) {
                                        Image(systemName: "minus.magnifyingglass")
                                    }
                                    Text("\(Int(zoomScale * 100))%")
                                        .font(.caption)
                                        .frame(width: 50)
                                    Button(action: { zoomScale = min(4.0, zoomScale + 0.25) }) {
                                        Image(systemName: "plus.magnifyingglass")
                                    }
                                    Button(action: { zoomScale = 1.0 }) {
                                        Text("100%")
                                            .font(.caption)
                                    }

                                    Spacer()
                                }

                                // Animation controls
                                if previewMode == .animated {
                                    Divider()

                                    HStack(spacing: 16) {
                                        // Play/Pause
                                        Button(action: { toggleAnimation() }) {
                                            Image(systemName: isAnimating ? "pause.circle.fill" : "play.circle.fill")
                                                .font(.title2)
                                        }
                                        .buttonStyle(.borderless)

                                        // Viewing angle slider
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Viewing Angle")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Slider(value: $viewingAngle, in: 0...1) { editing in
                                                if !editing {
                                                    updateFrameFromAngle()
                                                }
                                            }
                                            .disabled(isAnimating)
                                        }
                                        .frame(maxWidth: 300)

                                        // Speed control
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Speed: \(String(format: "%.1f", animationSpeed)) fps")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Slider(value: $animationSpeed, in: 0.5...10, step: 0.5)
                                                .frame(width: 150)
                                        }
                                    }
                                }
                            }
                            .padding()
                        }
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                            Text("No Interlaced Image Yet")
                                .font(.title3)
                            Text("Click 'Generate Interlaced Image' to create the output.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Helper Views

    private var animatedPreview: some View {
        Group {
            if currentFrameIndex < project.sourceImages.count {
                let sourceImage = project.sourceImages[currentFrameIndex]
                if let thumbnail = sourceImage.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
        }
        .onChange(of: viewingAngle) { _, _ in
            updateFrameFromAngle()
        }
    }

    private var sourceComparisonView: some View {
        HStack(spacing: 8) {
            ForEach(project.sourceImages.prefix(4)) { sourceImage in
                VStack {
                    if let thumbnail = sourceImage.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 200)
                    }
                    Text("Image \(sourceImage.order + 1)")
                        .font(.caption)
                }
            }
        }
    }

    private func lenticuleGridOverlay(imageSize: CGSize) -> some View {
        Canvas { context, size in
            // Calculate lenticule width in points
            let pixelsPerLenticule = Double(project.outputDPI) / project.lensParameters.lpi
            let pointsPerPixel = imageSize.width / CGFloat(project.outputWidth)
            let lenticuleWidth = CGFloat(pixelsPerLenticule) * pointsPerPixel

            // Draw vertical lines at lenticule boundaries
            var path = Path()
            var x: CGFloat = 0
            while x < imageSize.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: imageSize.height))
                x += lenticuleWidth
            }

            context.stroke(path, with: .color(.blue.opacity(0.5)), lineWidth: 1)
        }
        .frame(width: imageSize.width, height: imageSize.height)
    }

    // MARK: - Helper Functions

    private func toggleAnimation() {
        isAnimating.toggle()

        if isAnimating {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    private func startAnimation() {
        stopAnimation()  // Clear any existing timer

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / animationSpeed, repeats: true) { _ in
            currentFrameIndex = (currentFrameIndex + 1) % project.sourceImages.count
            viewingAngle = Double(currentFrameIndex) / Double(max(1, project.sourceImages.count - 1))
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func updateFrameFromAngle() {
        let maxIndex = max(0, project.sourceImages.count - 1)
        currentFrameIndex = Int(viewingAngle * Double(maxIndex))
    }

    private func exportInterlacedImage() {
        print("🔵 Export button clicked")

        guard let image = project.interlacedImage else {
            print("❌ No interlaced image to export")
            return
        }

        print("✅ Image found, showing save panel...")

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "interlaced_output.png"
        savePanel.title = "Export Interlaced Image"
        savePanel.message = "Choose where to save your interlaced image"

        print("🟡 Calling runModal()...")
        let response = savePanel.runModal()
        print("🟢 runModal returned: \(response.rawValue)")

        guard response == .OK, let url = savePanel.url else {
            print("⚠️ Export cancelled or no URL")
            return
        }

        print("💾 Saving to: \(url.path)")

        // Export in background
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("❌ Failed to get CGImage")
                return
            }

            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                print("❌ Failed to create PNG data")
                return
            }

            do {
                try pngData.write(to: url)
                print("✅ Successfully exported to: \(url.path)")
            } catch {
                print("❌ Export error: \(error.localizedDescription)")
            }
        }
    }
}
