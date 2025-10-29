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
import ModelIO
import SceneKit

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

/// Tile configuration
struct TileConfiguration: Codable, Equatable {
    var tileWidth: Double = 8.5  // inches
    var tileHeight: Double = 11.0  // inches
    var mode: TileMode = .edgeToEdge
    var bleedAmount: Double = 0.125  // inches (for bleed mode)
    var showRegistrationMarks: Bool = false

    enum TileMode: String, Codable, CaseIterable {
        case edgeToEdge = "Edge-to-Edge"
        case withBleed = "With Bleed"
        case withRegistration = "With Registration Marks"
    }

    // Common presets
    static let letter = TileConfiguration(tileWidth: 8.5, tileHeight: 11.0)
    static let a4 = TileConfiguration(tileWidth: 8.27, tileHeight: 11.69)
    static let square8 = TileConfiguration(tileWidth: 8.0, tileHeight: 8.0)
}

/// Layout strategy for tiling
enum TileLayoutStrategy: String, Codable, CaseIterable {
    case portraitRemainderRight = "Portrait, Remainder Right"
    case portraitRemainderLeft = "Portrait, Remainder Left"
    case landscapeRemainderBottom = "Landscape, Remainder Bottom"
    case landscapeRemainderTop = "Landscape, Remainder Top"
}

/// Printer bed region groups image tiles that will be assembled and printed together
struct PrinterBedRegion: Codable, Equatable {
    var columnStart: Int  // Starting column index
    var columnEnd: Int    // Ending column index (exclusive)
    var rowStart: Int     // Starting row index
    var rowEnd: Int       // Ending row index (exclusive)
}

/// Custom tile layout with boundary positions
struct TileLayout: Codable, Equatable {
    var verticalBoundaries: [Double] = []  // X positions in pixels
    var horizontalBoundaries: [Double] = []  // Y positions in pixels
    var paperWidth: Double = 8.5  // inches
    var paperHeight: Double = 11.0  // inches
    var maxBedSize: Double = 14.0  // inches (Prusa XL with margin)
    var strategy: TileLayoutStrategy = .portraitRemainderRight
    var printerBedRegions: [PrinterBedRegion] = []  // Groups of tiles for 3D printing

    // Calculate optimal layout for given image dimensions
    static func calculateOptimal(
        imageWidth: Int,
        imageHeight: Int,
        dpi: Int,
        lpi: Double,
        paperWidth: Double = 8.5,
        paperHeight: Double = 11.0,
        maxBedSize: Double = 14.0,
        strategy: TileLayoutStrategy? = nil
    ) -> TileLayout {
        let widthInches = Double(imageWidth) / Double(dpi)
        let heightInches = Double(imageHeight) / Double(dpi)
        let pixelsPerLenticule = Double(dpi) / lpi

        // Determine strategy if not provided
        let selectedStrategy: TileLayoutStrategy
        if let strategy = strategy {
            selectedStrategy = strategy
        } else {
            // Auto-select best strategy based on fewest cuts
            let portraitScore = calculateLayoutScore(
                imageWidth: widthInches,
                imageHeight: heightInches,
                paperWidth: paperWidth,
                paperHeight: paperHeight,
                maxBedSize: maxBedSize
            )
            let landscapeScore = calculateLayoutScore(
                imageWidth: widthInches,
                imageHeight: heightInches,
                paperWidth: paperHeight,
                paperHeight: paperWidth,
                maxBedSize: maxBedSize
            )
            selectedStrategy = portraitScore.cuts <= landscapeScore.cuts ? .portraitRemainderRight : .landscapeRemainderBottom
        }

        var layout = TileLayout(
            paperWidth: paperWidth,
            paperHeight: paperHeight,
            maxBedSize: maxBedSize,
            strategy: selectedStrategy
        )

        // Determine paper orientation based on strategy
        let isPortrait = selectedStrategy == .portraitRemainderRight || selectedStrategy == .portraitRemainderLeft
        let effectivePaperWidth = isPortrait ? paperWidth : paperHeight
        let effectivePaperHeight = isPortrait ? paperHeight : paperWidth

        // Generate vertical boundaries (columns)
        var columnBoundaries: [Double] = []

        let minTileWidthInches = 0.5  // Don't create tiles smaller than 0.5 inches

        if selectedStrategy == .portraitRemainderLeft || selectedStrategy == .landscapeRemainderTop {
            // Generate from right to left (remainder on left)
            var x: Double = widthInches
            var iterationCount = 0
            let maxIterations = 100  // Safety limit

            while x > minTileWidthInches && iterationCount < maxIterations {
                iterationCount += 1
                let nextX = max(x - effectivePaperWidth, 0)
                let pixelX = nextX * Double(dpi)

                // Snap to lenticule boundary
                let lenticuleCount = round(pixelX / pixelsPerLenticule)
                let snappedPixelX = lenticuleCount * pixelsPerLenticule
                let snappedInches = snappedPixelX / Double(dpi)

                // Only add boundary if it leaves at least minTileWidthInches on the left
                if snappedInches >= minTileWidthInches && snappedPixelX < Double(imageWidth) {
                    columnBoundaries.insert(snappedPixelX, at: 0)
                }

                // Make sure we're making progress
                let newX = snappedPixelX / Double(dpi)
                if newX >= x {
                    break  // Prevent infinite loop
                }
                x = newX
            }
        } else {
            // Generate from left to right (remainder on right)
            var x: Double = 0
            var iterationCount = 0
            let maxIterations = 100  // Safety limit

            while x < widthInches - minTileWidthInches && iterationCount < maxIterations {
                iterationCount += 1
                let nextX = min(x + effectivePaperWidth, widthInches)
                let pixelX = nextX * Double(dpi)

                // Snap to lenticule boundary
                let lenticuleCount = round(pixelX / pixelsPerLenticule)
                let snappedPixelX = lenticuleCount * pixelsPerLenticule

                // Check if remaining space would be too small
                let remainingInches = widthInches - (snappedPixelX / Double(dpi))

                // Only add boundary if it leaves at least minTileWidthInches remaining OR we're at the end
                if remainingInches >= minTileWidthInches && snappedPixelX < Double(imageWidth) {
                    columnBoundaries.append(snappedPixelX)
                }

                let newX = snappedPixelX / Double(dpi)
                if newX <= x {
                    break  // Prevent infinite loop
                }
                x = newX
            }
        }

        layout.verticalBoundaries = columnBoundaries

        // Generate horizontal boundaries (rows)
        let minTileHeightInches = 0.5  // Don't create tiles smaller than 0.5 inches
        var y: Double = 0
        while y < heightInches - minTileHeightInches {
            let nextY = min(y + effectivePaperHeight, heightInches)
            let pixelY = nextY * Double(dpi)

            // Check if remaining space would be too small
            let remainingInches = heightInches - (pixelY / Double(dpi))

            // Only add boundary if it leaves at least minTileHeightInches remaining
            if remainingInches >= minTileHeightInches && pixelY < Double(imageHeight) {
                layout.horizontalBoundaries.append(pixelY)
            }

            y = nextY
        }

        // Calculate printer bed regions
        layout.printerBedRegions = calculatePrinterBedRegions(
            verticalBoundaries: layout.verticalBoundaries,
            horizontalBoundaries: layout.horizontalBoundaries,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            dpi: dpi,
            maxBedSize: maxBedSize
        )

        return layout
    }

    // Calculate which image tile columns/rows combine into printer bed regions
    private static func calculatePrinterBedRegions(
        verticalBoundaries: [Double],
        horizontalBoundaries: [Double],
        imageWidth: Int,
        imageHeight: Int,
        dpi: Int,
        maxBedSize: Double
    ) -> [PrinterBedRegion] {
        let xBoundaries = [0.0] + verticalBoundaries + [Double(imageWidth)]
        let yBoundaries = [0.0] + horizontalBoundaries + [Double(imageHeight)]

        var regions: [PrinterBedRegion] = []
        let maxBedPixels = maxBedSize * Double(dpi)

        // Safety check
        guard xBoundaries.count >= 2 && yBoundaries.count >= 2 else {
            return []
        }

        // Group columns that fit together on one printer bed
        var colStart = 0
        var colIterations = 0
        while colStart < xBoundaries.count - 1 && colIterations < 100 {
            colIterations += 1
            var colEnd = colStart + 1

            // Try to add more columns while they fit on the bed
            while colEnd < xBoundaries.count - 1 {
                let totalWidth = xBoundaries[colEnd + 1] - xBoundaries[colStart]
                if totalWidth <= maxBedPixels {
                    colEnd += 1
                } else {
                    break
                }
            }

            // For this column group, check if all rows fit or need to be split
            let totalHeight = Double(imageHeight)
            if totalHeight <= maxBedPixels {
                // All rows fit on one bed
                regions.append(PrinterBedRegion(
                    columnStart: colStart,
                    columnEnd: colEnd,
                    rowStart: 0,
                    rowEnd: yBoundaries.count - 1
                ))
            } else {
                // Split into multiple row groups
                var rowStart = 0
                var rowIterations = 0
                while rowStart < yBoundaries.count - 1 && rowIterations < 100 {
                    rowIterations += 1
                    var rowEnd = rowStart + 1

                    while rowEnd < yBoundaries.count - 1 {
                        let totalRowHeight = yBoundaries[rowEnd + 1] - yBoundaries[rowStart]
                        if totalRowHeight <= maxBedPixels {
                            rowEnd += 1
                        } else {
                            break
                        }
                    }

                    regions.append(PrinterBedRegion(
                        columnStart: colStart,
                        columnEnd: colEnd,
                        rowStart: rowStart,
                        rowEnd: rowEnd
                    ))

                    rowStart = rowEnd
                }
            }

            colStart = colEnd
        }

        return regions
    }

    private static func calculateLayoutScore(
        imageWidth: Double,
        imageHeight: Double,
        paperWidth: Double,
        paperHeight: Double,
        maxBedSize: Double
    ) -> (cuts: Int, tiles: Int, papers: Int) {
        let cols = Int(ceil(imageWidth / paperWidth))
        let rows = Int(ceil(imageHeight / paperHeight))

        // Calculate cuts needed
        var cuts = 0
        if imageWidth.truncatingRemainder(dividingBy: paperWidth) > 0.1 {
            cuts += rows  // Vertical cuts for remainder column
        }
        if imageHeight.truncatingRemainder(dividingBy: paperHeight) > 0.1 {
            cuts += cols  // Horizontal cuts for remainder row
        }

        let totalPapers = cols * rows
        let tiles = cols  // Stacks combine vertically or horizontally

        return (cuts, tiles, totalPapers)
    }
}

/// Information about a single tile
struct TileInfo: Identifiable, Equatable {
    let id = UUID()
    let row: Int
    let col: Int
    let rect: CGRect  // Position in pixels in the full interlaced image
    var image: NSImage?  // The actual tile image data

    var name: String {
        return "Tile_R\(String(format: "%02d", row + 1))_C\(String(format: "%02d", col + 1))"
    }

    func filename(projectName: String) -> String {
        return "\(projectName)_\(name).png"
    }

    // Custom Equatable implementation that ignores image comparison
    static func == (lhs: TileInfo, rhs: TileInfo) -> Bool {
        return lhs.id == rhs.id
    }
}

/// Information about a single lens tile
struct LensTileInfo: Identifiable, Equatable {
    let id = UUID()
    let row: Int
    let col: Int
    let widthMM: Double
    let heightMM: Double
    var model: MDLAsset?  // The 3D model for this tile
    let regionIndex: Int?  // Printer bed region index (if using regions)
    var alignmentFrame: MDLAsset?  // Optional alignment frame for paper positioning

    var name: String {
        if let regionIndex = regionIndex {
            return "Lens_Bed\(String(format: "%02d", regionIndex + 1))"
        }
        return "Lens_R\(String(format: "%02d", row + 1))_C\(String(format: "%02d", col + 1))"
    }

    var frameName: String {
        if let regionIndex = regionIndex {
            return "AlignmentFrame_Bed\(String(format: "%02d", regionIndex + 1))"
        }
        return "AlignmentFrame_R\(String(format: "%02d", row + 1))_C\(String(format: "%02d", col + 1))"
    }

    func filename(projectName: String) -> String {
        return "\(projectName)_\(name).stl"
    }

    func frameFilename(projectName: String) -> String {
        return "\(projectName)_\(frameName).stl"
    }

    // Custom Equatable implementation
    static func == (lhs: LensTileInfo, rhs: LensTileInfo) -> Bool {
        return lhs.id == rhs.id
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
    @Published var tileConfiguration = TileConfiguration()
    @Published var tileLayout: TileLayout?
    @Published var tiles: [TileInfo] = []
    @Published var lensModel: MDLAsset?
    @Published var lensTiles: [LensTileInfo] = []

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

    // MARK: - Tiling

    func calculateOptimalLayout(strategy: TileLayoutStrategy? = nil) {
        guard outputWidth > 0 && outputHeight > 0 else { return }

        tileLayout = TileLayout.calculateOptimal(
            imageWidth: outputWidth,
            imageHeight: outputHeight,
            dpi: outputDPI,
            lpi: lensParameters.lpi,
            paperWidth: tileConfiguration.tileWidth,
            paperHeight: tileConfiguration.tileHeight,
            maxBedSize: 14.0,
            strategy: strategy
        )
    }

    func calculateNextLayoutStrategy() {
        guard let currentLayout = tileLayout else { return }
        let currentStrategy = currentLayout.strategy
        let allStrategies = TileLayoutStrategy.allCases
        let currentIndex = allStrategies.firstIndex(of: currentStrategy) ?? 0
        let nextIndex = (currentIndex + 1) % allStrategies.count
        let nextStrategy = allStrategies[nextIndex]

        calculateOptimalLayout(strategy: nextStrategy)
    }

    func generateTiles() async {
        guard let interlacedImage = interlacedImage else { return }

        await MainActor.run {
            isProcessing = true
            processingProgress = 0.0
        }

        let result = await TileGenerator.generateTiles(
            from: interlacedImage,
            layout: tileLayout,
            config: tileConfiguration,
            lensParameters: lensParameters,
            dpi: outputDPI,
            projectName: name,
            progressCallback: { progress in
                Task { @MainActor in
                    self.processingProgress = progress
                }
            }
        )

        await MainActor.run {
            tiles = result
            isProcessing = false
            processingProgress = 1.0
        }
    }

    // MARK: - 3D Model Generation

    func generate3DModel() async {
        await MainActor.run {
            isProcessing = true
            processingProgress = 0.0
        }

        // Calculate physical dimensions in millimeters
        let widthMM = physicalWidth * 25.4  // inches to mm
        let heightMM = physicalHeight * 25.4  // inches to mm

        let result = await LensModelGenerator.generateLensModel(
            dimensions: CGSize(width: widthMM, height: heightMM),
            lensParameters: lensParameters,
            progressCallback: { progress in
                Task { @MainActor in
                    self.processingProgress = progress
                }
            }
        )

        await MainActor.run {
            lensModel = result
            isProcessing = false
            processingProgress = 1.0
        }
    }

    func generateLensTiles() async {
        // Must have image tiles and layout generated first
        guard !tiles.isEmpty else { return }
        guard let layout = tileLayout else { return }

        await MainActor.run {
            isProcessing = true
            processingProgress = 0.0
        }

        var generatedTiles: [LensTileInfo] = []

        // Generate one lens tile for each PRINTER BED REGION (not per image tile)
        // Each region combines multiple image tiles that will be assembled together
        for (regionIndex, region) in layout.printerBedRegions.enumerated() {
            // Calculate the pixel boundaries for this region
            let xBoundaries = [0.0] + layout.verticalBoundaries + [Double(outputWidth)]
            let yBoundaries = [0.0] + layout.horizontalBoundaries + [Double(outputHeight)]

            let regionX1 = xBoundaries[region.columnStart]
            let regionX2 = xBoundaries[region.columnEnd]
            let regionY1 = yBoundaries[region.rowStart]
            let regionY2 = yBoundaries[region.rowEnd]

            let regionWidthPixels = regionX2 - regionX1
            let regionHeightPixels = regionY2 - regionY1

            // Convert to physical dimensions in millimeters
            let regionWidthInches = regionWidthPixels / Double(outputDPI)
            let regionHeightInches = regionHeightPixels / Double(outputDPI)
            let regionWidthMM = regionWidthInches * 25.4
            let regionHeightMM = regionHeightInches * 25.4

            // Generate lens model for this entire printer bed region
            let model = await LensModelGenerator.generateLensModel(
                dimensions: CGSize(width: regionWidthMM, height: regionHeightMM),
                lensParameters: lensParameters,
                progressCallback: { regionProgress in
                    Task { @MainActor in
                        // Overall progress: current region + progress within region (50% for lens, 50% for frame)
                        let overallProgress = (Double(regionIndex) + regionProgress * 0.5) / Double(layout.printerBedRegions.count)
                        self.processingProgress = overallProgress
                    }
                }
            )

            // Generate alignment frame for this region
            let alignmentFrame = LensModelGenerator.generateAlignmentFrame(
                dimensions: CGSize(width: regionWidthMM, height: regionHeightMM),
                frameWidth: 2.5,  // 2.5mm wide frame strips
                frameHeight: 0.3  // 0.3mm tall (one layer)
            )

            await MainActor.run {
                // Update progress after frame generation
                let overallProgress = (Double(regionIndex) + 1.0) / Double(layout.printerBedRegions.count)
                self.processingProgress = overallProgress
            }

            let lensTile = LensTileInfo(
                row: region.rowStart,
                col: region.columnStart,
                widthMM: regionWidthMM,
                heightMM: regionHeightMM,
                model: model,
                regionIndex: regionIndex,
                alignmentFrame: alignmentFrame
            )

            generatedTiles.append(lensTile)
        }

        await MainActor.run {
            lensTiles = generatedTiles
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
        // Run on background thread to avoid blocking UI
        return await Task.detached(priority: .userInitiated) {
            return await Self.performInterlace(
                sourceImages: sourceImages,
                lensParameters: lensParameters,
                dpi: dpi,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                progressCallback: progressCallback
            )
        }.value
    }

    private static func performInterlace(
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

        // Create output bitmap buffer
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = outputWidth * bytesPerPixel
        let bufferSize = bytesPerRow * outputHeight

        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)

        // Scale and get CGImages from NSImages, extract bitmap data
        var bitmapDatas: [[UInt8]] = []
        var bytesPerRows: [Int] = []

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

            // Create a bitmap context with known format to extract pixels
            let sourceBytesPerRow = outputWidth * bytesPerPixel
            let sourceBufferSize = sourceBytesPerRow * outputHeight
            var sourceBuffer = [UInt8](repeating: 0, count: sourceBufferSize)

            guard let sourceContext = CGContext(
                data: &sourceBuffer,
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: sourceBytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }

            // Draw the image into our known-format buffer
            sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

            bitmapDatas.append(sourceBuffer)
            bytesPerRows.append(sourceBytesPerRow)
        }

        // Interlace column by column - write directly to output buffer
        for x in 0..<outputWidth {
            // Calculate which lenticule and position within lenticule
            let lenticulePosition = Double(x).truncatingRemainder(dividingBy: pixelsPerLenticule)

            // Determine which source image this strip comes from
            let imageIndex = Int((lenticulePosition / pixelsPerLenticule) * numImages)
            let clampedIndex = min(imageIndex, bitmapDatas.count - 1)

            let sourceBitmap = bitmapDatas[clampedIndex]
            let sourceBytesPerRow = bytesPerRows[clampedIndex]

            // Copy this column from source to output
            for y in 0..<outputHeight {
                let sourceIndex = (y * sourceBytesPerRow) + (x * bytesPerPixel)
                let outputIndex = (y * bytesPerRow) + (x * bytesPerPixel)

                // Check bounds
                guard sourceIndex + 3 < sourceBitmap.count,
                      outputIndex + 3 < outputBuffer.count else { continue }

                // Copy RGBA bytes directly
                outputBuffer[outputIndex] = sourceBitmap[sourceIndex]
                outputBuffer[outputIndex + 1] = sourceBitmap[sourceIndex + 1]
                outputBuffer[outputIndex + 2] = sourceBitmap[sourceIndex + 2]
                outputBuffer[outputIndex + 3] = sourceBitmap[sourceIndex + 3]
            }

            // Update progress and yield every 50 columns to keep UI responsive
            if x % 50 == 0 {
                let progress = Double(x) / Double(outputWidth)
                progressCallback(progress)
                await Task.yield()
            }
        }

        progressCallback(1.0)

        // Create CGImage from output buffer
        guard let context = CGContext(
            data: &outputBuffer,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let cgImage = context.makeImage() else { return nil }
        let outputImage = NSImage(cgImage: cgImage, size: CGSize(width: outputWidth, height: outputHeight))

        return outputImage
    }
}

// MARK: - Tile Generator

class TileGenerator {
    /// Generate tiles from an interlaced image with proper lenticule alignment
    static func generateTiles(
        from image: NSImage,
        layout: TileLayout? = nil,
        config: TileConfiguration,
        lensParameters: LensParameters,
        dpi: Int,
        projectName: String,
        progressCallback: @escaping (Double) -> Void
    ) async -> [TileInfo] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height

        var tiles: [TileInfo] = []

        // Use custom layout if provided, otherwise fall back to uniform grid
        if let layout = layout {
            // Generate tiles based on custom boundaries
            let xBoundaries = [0.0] + layout.verticalBoundaries + [Double(imageWidth)]
            let yBoundaries = [0.0] + layout.horizontalBoundaries + [Double(imageHeight)]

            let totalTiles = (xBoundaries.count - 1) * (yBoundaries.count - 1)
            var tileIndex = 0

            for row in 0..<(yBoundaries.count - 1) {
                for col in 0..<(xBoundaries.count - 1) {
                    let x = Int(xBoundaries[col])
                    let y = Int(yBoundaries[row])
                    let width = Int(xBoundaries[col + 1]) - x
                    let height = Int(yBoundaries[row + 1]) - y

                    let rect = CGRect(x: x, y: y, width: width, height: height)

                    // Crop the tile from the image
                    if let croppedCGImage = cgImage.cropping(to: rect) {
                        let tileImage = NSImage(cgImage: croppedCGImage, size: CGSize(width: width, height: height))

                        // Add registration marks if needed
                        let finalImage: NSImage
                        if config.mode == .withRegistration {
                            finalImage = addRegistrationMarks(
                                to: tileImage,
                                row: row,
                                col: col,
                                totalRows: yBoundaries.count - 1,
                                totalCols: xBoundaries.count - 1,
                                dpi: dpi
                            )
                        } else {
                            finalImage = tileImage
                        }

                        let tileInfo = TileInfo(
                            row: row,
                            col: col,
                            rect: rect,
                            image: finalImage
                        )
                        tiles.append(tileInfo)
                    }

                    // Update progress
                    tileIndex += 1
                    let progress = Double(tileIndex) / Double(totalTiles)
                    progressCallback(progress)
                }
            }
        } else {
            // Fall back to uniform grid (original implementation)
            let pixelsPerLenticule = Double(dpi) / lensParameters.lpi

            var tileWidthPixels = Int(config.tileWidth * Double(dpi))
            let tileHeightPixels = Int(config.tileHeight * Double(dpi))

            // CRITICAL: Align tile width to lenticule boundaries
            let lenticulesPerTile = floor(Double(tileWidthPixels) / pixelsPerLenticule)
            tileWidthPixels = Int(lenticulesPerTile * pixelsPerLenticule)

            let cols = Int(ceil(Double(imageWidth) / Double(tileWidthPixels)))
            let rows = Int(ceil(Double(imageHeight) / Double(tileHeightPixels)))
            let totalTiles = rows * cols

            for row in 0..<rows {
                for col in 0..<cols {
                    let x = col * tileWidthPixels
                    let y = row * tileHeightPixels
                    let width = min(tileWidthPixels, imageWidth - x)
                    let height = min(tileHeightPixels, imageHeight - y)

                    let rect = CGRect(x: x, y: y, width: width, height: height)

                    // Crop the tile from the image
                    if let croppedCGImage = cgImage.cropping(to: rect) {
                        let tileImage = NSImage(cgImage: croppedCGImage, size: CGSize(width: width, height: height))

                        // Add registration marks if needed
                        let finalImage: NSImage
                        if config.mode == .withRegistration {
                            finalImage = addRegistrationMarks(
                                to: tileImage,
                                row: row,
                                col: col,
                                totalRows: rows,
                                totalCols: cols,
                                dpi: dpi
                            )
                        } else {
                            finalImage = tileImage
                        }

                        let tileInfo = TileInfo(
                            row: row,
                            col: col,
                            rect: rect,
                            image: finalImage
                        )
                        tiles.append(tileInfo)
                    }

                    // Update progress
                    let progress = Double(tiles.count) / Double(totalTiles)
                    progressCallback(progress)
                }
            }
        }

        progressCallback(1.0)
        return tiles
    }

    /// Add registration marks to a tile for alignment
    private static func addRegistrationMarks(
        to image: NSImage,
        row: Int,
        col: Int,
        totalRows: Int,
        totalCols: Int,
        dpi: Int
    ) -> NSImage {
        let markSize: CGFloat = CGFloat(dpi) * 0.25  // 0.25 inch marks
        let padding: CGFloat = CGFloat(dpi) * 0.1  // 0.1 inch from edge

        let newSize = NSSize(
            width: image.size.width + (padding + markSize) * 2,
            height: image.size.height + (padding + markSize) * 2
        )

        let markedImage = NSImage(size: newSize)
        markedImage.lockFocus()

        // White background
        NSColor.white.setFill()
        NSRect(origin: .zero, size: newSize).fill()

        // Draw original image centered
        image.draw(
            in: NSRect(
                x: padding + markSize,
                y: padding + markSize,
                width: image.size.width,
                height: image.size.height
            ),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )

        // Draw corner registration marks (crosshairs)
        NSColor.black.setStroke()
        let markPath = NSBezierPath()
        markPath.lineWidth = 2

        // Top-left crosshair
        markPath.move(to: NSPoint(x: padding, y: padding + markSize))
        markPath.line(to: NSPoint(x: padding + markSize, y: padding + markSize))
        markPath.move(to: NSPoint(x: padding + markSize/2, y: padding))
        markPath.line(to: NSPoint(x: padding + markSize/2, y: padding + markSize))

        // Top-right crosshair
        let topRightX = newSize.width - padding - markSize
        markPath.move(to: NSPoint(x: topRightX, y: padding + markSize))
        markPath.line(to: NSPoint(x: topRightX + markSize, y: padding + markSize))
        markPath.move(to: NSPoint(x: topRightX + markSize/2, y: padding))
        markPath.line(to: NSPoint(x: topRightX + markSize/2, y: padding + markSize))

        // Bottom-left crosshair
        let bottomY = newSize.height - padding - markSize
        markPath.move(to: NSPoint(x: padding, y: bottomY))
        markPath.line(to: NSPoint(x: padding + markSize, y: bottomY))
        markPath.move(to: NSPoint(x: padding + markSize/2, y: bottomY))
        markPath.line(to: NSPoint(x: padding + markSize/2, y: bottomY + markSize))

        // Bottom-right crosshair
        markPath.move(to: NSPoint(x: topRightX, y: bottomY))
        markPath.line(to: NSPoint(x: topRightX + markSize, y: bottomY))
        markPath.move(to: NSPoint(x: topRightX + markSize/2, y: bottomY))
        markPath.line(to: NSPoint(x: topRightX + markSize/2, y: bottomY + markSize))

        markPath.stroke()

        // Add tile numbering
        let tileLabel = "R\(row + 1)C\(col + 1)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let labelSize = (tileLabel as NSString).size(withAttributes: attributes)
        (tileLabel as NSString).draw(
            at: NSPoint(x: padding, y: padding),
            withAttributes: attributes
        )

        markedImage.unlockFocus()
        return markedImage
    }
}

// MARK: - Lens Model Generator

class LensModelGenerator {
    /// Generate a 3D lenticular lens model matching the interlaced image
    static func generateLensModel(
        dimensions: CGSize,  // Physical dimensions in mm
        lensParameters: LensParameters,
        progressCallback: @escaping (Double) -> Void
    ) async -> MDLAsset? {
        return await Task.detached(priority: .userInitiated) {
            return await Self.performGeneration(
                dimensions: dimensions,
                lensParameters: lensParameters,
                progressCallback: progressCallback
            )
        }.value
    }

    private static func performGeneration(
        dimensions: CGSize,
        lensParameters: LensParameters,
        progressCallback: @escaping (Double) -> Void
    ) async -> MDLAsset? {
        let widthMM = Double(dimensions.width)
        let heightMM = Double(dimensions.height)

        progressCallback(0.1)

        // Calculate number of lenticules
        let numLenticules = Int(widthMM / lensParameters.pitch)

        // Create allocator
        let allocator = MDLMeshBufferDataAllocator()

        // Arrays to hold all vertices and indices
        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allIndices: [UInt32] = []

        progressCallback(0.2)

        // Generate lenticules
        let segmentsAround = 24  // Resolution around the cylinder arc
        let segmentsAlong = 2    // Just 2 segments along the length (start and end)

        for i in 0..<numLenticules {
            let xStart = Float(i) * Float(lensParameters.pitch)

            // Generate vertices for this lenticule (half-cylinder)
            let baseIndexOffset = UInt32(allVertices.count)

            for segAlong in 0...segmentsAlong {
                let z = Float(segAlong) * Float(heightMM) / Float(segmentsAlong)

                for segAround in 0...segmentsAround {
                    // Angle from -π/2 to π/2 (half cylinder facing up)
                    let angle = Float.pi * (Float(segAround) / Float(segmentsAround) - 0.5)

                    let x = xStart + Float(lensParameters.pitch / 2.0) + Float(lensParameters.radius) * sin(angle)
                    let y = Float(lensParameters.radius) * cos(angle) - Float(lensParameters.radius) + Float(lensParameters.height)

                    allVertices.append(SIMD3(x, y, z))

                    // Normal for curved surface
                    let normal = SIMD3(sin(angle), cos(angle), 0)
                    allNormals.append(normalize(normal))
                }
            }

            // Generate triangle indices for this lenticule
            for segAlong in 0..<segmentsAlong {
                for segAround in 0..<segmentsAround {
                    let verticesPerRing = UInt32(segmentsAround + 1)

                    let i0 = baseIndexOffset + UInt32(segAlong) * verticesPerRing + UInt32(segAround)
                    let i1 = i0 + 1
                    let i2 = i0 + verticesPerRing
                    let i3 = i2 + 1

                    // Two triangles per quad
                    allIndices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
                }
            }

            // Update progress
            if i % 10 == 0 {
                let progress = 0.2 + 0.6 * (Double(i) / Double(numLenticules))
                progressCallback(progress)
                await Task.yield()
            }
        }

        progressCallback(0.8)

        // Add flat base plate
        let baseY = Float(0)
        let baseVertexOffset = UInt32(allVertices.count)

        // Base corners
        let baseCorners: [SIMD3<Float>] = [
            SIMD3(0, baseY, 0),
            SIMD3(Float(widthMM), baseY, 0),
            SIMD3(Float(widthMM), baseY, Float(heightMM)),
            SIMD3(0, baseY, Float(heightMM))
        ]

        allVertices.append(contentsOf: baseCorners)
        let baseNormal = SIMD3<Float>(0, -1, 0)
        for _ in 0..<4 {
            allNormals.append(baseNormal)
        }

        // Base triangles
        allIndices.append(contentsOf: [
            baseVertexOffset, baseVertexOffset + 1, baseVertexOffset + 2,
            baseVertexOffset, baseVertexOffset + 2, baseVertexOffset + 3
        ])

        progressCallback(0.9)

        // Create MDLMesh from vertices and indices
        let vertexData = Data(bytes: allVertices, count: allVertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let normalData = Data(bytes: allNormals, count: allNormals.count * MemoryLayout<SIMD3<Float>>.stride)
        let indexData = Data(bytes: allIndices, count: allIndices.count * MemoryLayout<UInt32>.stride)

        let vertexBuffer = allocator.newBuffer(with: vertexData, type: MDLMeshBufferType.vertex)
        let normalBuffer = allocator.newBuffer(with: normalData, type: MDLMeshBufferType.vertex)
        let indexBuffer = allocator.newBuffer(with: indexData, type: MDLMeshBufferType.index)

        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        vertexDescriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: 0,
            bufferIndex: 1
        )
        vertexDescriptor.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: allIndices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )

        let mesh = MDLMesh(
            vertexBuffers: [vertexBuffer, normalBuffer],
            vertexCount: allVertices.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )

        // Create asset
        let asset = MDLAsset(bufferAllocator: allocator)
        asset.add(mesh)

        progressCallback(1.0)

        return asset
    }

    /// Generate an alignment frame for paper positioning
    /// Creates a thin rectangular border that's printed first in a different color
    /// The frame is LARGER than the given dimensions so the lens fits inside it
    static func generateAlignmentFrame(
        dimensions: CGSize,  // LENS/paper dimensions in mm (the frame will be larger)
        frameWidth: Double = 2.5,  // Width of frame strips in mm
        frameHeight: Double = 0.3  // Height (one layer) in mm
    ) -> MDLAsset? {
        // The frame extends beyond the lens dimensions by frameWidth on all sides
        let lensWidthMM = Double(dimensions.width)
        let lensHeightMM = Double(dimensions.height)

        // Frame outer dimensions (larger than lens)
        let frameOuterWidth = lensWidthMM + (frameWidth * 2)
        let frameOuterHeight = lensHeightMM + (frameWidth * 2)

        let allocator = MDLMeshBufferDataAllocator()

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allIndices: [UInt32] = []

        let height = Float(frameHeight)
        let fw = Float(frameWidth)  // Frame width

        // Create 4 strips forming a rectangular frame
        // The inner opening is exactly lensWidthMM x lensHeightMM
        // The outer boundary extends by frameWidth on all sides

        // Bottom strip (front edge) - full width
        addFrameStrip(
            x1: 0, z1: 0,
            x2: Float(frameOuterWidth), z2: fw,
            height: height,
            vertices: &allVertices,
            normals: &allNormals,
            indices: &allIndices
        )

        // Top strip (back edge) - full width
        addFrameStrip(
            x1: 0, z1: Float(frameOuterHeight) - fw,
            x2: Float(frameOuterWidth), z2: Float(frameOuterHeight),
            height: height,
            vertices: &allVertices,
            normals: &allNormals,
            indices: &allIndices
        )

        // Left strip (excluding corners already covered)
        addFrameStrip(
            x1: 0, z1: fw,
            x2: fw, z2: Float(frameOuterHeight) - fw,
            height: height,
            vertices: &allVertices,
            normals: &allNormals,
            indices: &allIndices
        )

        // Right strip (excluding corners already covered)
        addFrameStrip(
            x1: Float(frameOuterWidth) - fw, z1: fw,
            x2: Float(frameOuterWidth), z2: Float(frameOuterHeight) - fw,
            height: height,
            vertices: &allVertices,
            normals: &allNormals,
            indices: &allIndices
        )

        // Create vertex buffers
        let vertexData = Data(bytes: allVertices, count: allVertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let vertexBuffer = allocator.newBuffer(with: vertexData, type: MDLMeshBufferType.vertex)

        let normalData = Data(bytes: allNormals, count: allNormals.count * MemoryLayout<SIMD3<Float>>.stride)
        let normalBuffer = allocator.newBuffer(with: normalData, type: MDLMeshBufferType.vertex)

        let indexData = Data(bytes: allIndices, count: allIndices.count * MemoryLayout<UInt32>.stride)
        let indexBuffer = allocator.newBuffer(with: indexData, type: MDLMeshBufferType.index)

        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        vertexDescriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: 0,
            bufferIndex: 1
        )
        vertexDescriptor.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: allIndices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )

        let mesh = MDLMesh(
            vertexBuffers: [vertexBuffer, normalBuffer],
            vertexCount: allVertices.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )

        let asset = MDLAsset(bufferAllocator: allocator)
        asset.add(mesh)

        return asset
    }

    /// Helper to add a rectangular strip to the frame
    private static func addFrameStrip(
        x1: Float, z1: Float,
        x2: Float, z2: Float,
        height: Float,
        vertices: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let baseOffset = UInt32(vertices.count)

        // 8 vertices for a rectangular box (4 bottom, 4 top)
        let bottomVertices: [SIMD3<Float>] = [
            SIMD3(x1, 0, z1),
            SIMD3(x2, 0, z1),
            SIMD3(x2, 0, z2),
            SIMD3(x1, 0, z2)
        ]

        let topVertices: [SIMD3<Float>] = [
            SIMD3(x1, height, z1),
            SIMD3(x2, height, z1),
            SIMD3(x2, height, z2),
            SIMD3(x1, height, z2)
        ]

        vertices.append(contentsOf: bottomVertices)
        vertices.append(contentsOf: topVertices)

        // Normals (simplified - pointing outward and up)
        for _ in 0..<8 {
            normals.append(SIMD3(0, 1, 0))
        }

        // Indices for 6 faces of the box
        // Bottom face
        indices.append(contentsOf: [
            baseOffset + 0, baseOffset + 2, baseOffset + 1,
            baseOffset + 0, baseOffset + 3, baseOffset + 2
        ])

        // Top face
        indices.append(contentsOf: [
            baseOffset + 4, baseOffset + 5, baseOffset + 6,
            baseOffset + 4, baseOffset + 6, baseOffset + 7
        ])

        // Side faces
        // Front
        indices.append(contentsOf: [
            baseOffset + 0, baseOffset + 1, baseOffset + 5,
            baseOffset + 0, baseOffset + 5, baseOffset + 4
        ])

        // Right
        indices.append(contentsOf: [
            baseOffset + 1, baseOffset + 2, baseOffset + 6,
            baseOffset + 1, baseOffset + 6, baseOffset + 5
        ])

        // Back
        indices.append(contentsOf: [
            baseOffset + 2, baseOffset + 3, baseOffset + 7,
            baseOffset + 2, baseOffset + 7, baseOffset + 6
        ])

        // Left
        indices.append(contentsOf: [
            baseOffset + 3, baseOffset + 0, baseOffset + 4,
            baseOffset + 3, baseOffset + 4, baseOffset + 7
        ])
    }

    /// Export asset to STL file
    static func exportSTL(asset: MDLAsset, to url: URL) throws {
        try asset.export(to: url)
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
                    TilingView(project: project)
                case .model3D:
                    Model3DView(project: project)
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

// MARK: - Tiling View

struct TilingView: View {
    @ObservedObject var project: Project
    @State private var selectedTilePreset: String = "Letter"
    @State private var showingExportDialog = false
    @State private var selectedTileForExport: TileInfo?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Tile Configuration")
                    .font(.title)
                Text("Subdivide large interlaced images into printable tiles, aligned to lenticule boundaries.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            if project.interlacedImage == nil {
                // No interlaced image yet
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundStyle(.orange)
                    Text("No Interlaced Image")
                        .font(.title2)
                    Text("Generate an interlaced image first in the Interlace section.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Main content
                ScrollView {
                    VStack(spacing: 20) {
                        // Tile Size Configuration
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Tile Size", systemImage: "rectangle.split.2x2")
                                .font(.headline)

                            // Preset picker
                            Picker("Preset", selection: $selectedTilePreset) {
                                Text("Letter (8.5\" × 11\")").tag("Letter")
                                Text("A4 (8.27\" × 11.69\")").tag("A4")
                                Text("Square 8\" × 8\"").tag("Square8")
                                Text("Custom").tag("Custom")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: selectedTilePreset) { _, newValue in
                                applyTilePreset(newValue)
                            }

                            // Custom size controls
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Width")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        TextField("Width", value: $project.tileConfiguration.tileWidth, format: .number.precision(.fractionLength(2)))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 80)
                                            .onChange(of: project.tileConfiguration.tileWidth) { _, _ in
                                                selectedTilePreset = "Custom"
                                            }
                                        Text("in")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Height")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        TextField("Height", value: $project.tileConfiguration.tileHeight, format: .number.precision(.fractionLength(2)))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 80)
                                            .onChange(of: project.tileConfiguration.tileHeight) { _, _ in
                                                selectedTilePreset = "Custom"
                                            }
                                        Text("in")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                        .padding(.top)

                        // Tile Mode Configuration
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Tile Mode", systemImage: "gearshape")
                                .font(.headline)

                            Picker("Mode", selection: $project.tileConfiguration.mode) {
                                ForEach(TileConfiguration.TileMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            // Mode descriptions
                            Text(tileModeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.gray.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)

                        // Calculate Layout Button
                        if project.tileLayout == nil {
                            VStack(spacing: 12) {
                                Text("Smart tiling optimizes for fewest cuts and 3D prints")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)

                                Button(action: {
                                    project.calculateOptimalLayout()
                                }) {
                                    Label("Calculate Optimal Layout", systemImage: "square.grid.3x3")
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                        }

                        // Layout Preview
                        if let layout = project.tileLayout, let interlacedImage = project.interlacedImage {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Label("Proposed Tile Layout", systemImage: "rectangle.split.3x3")
                                        .font(.headline)
                                    Spacer()
                                    Text(layout.strategy.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.2))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }

                                TileLayoutPreview(
                                    image: interlacedImage,
                                    layout: layout,
                                    dpi: project.outputDPI,
                                    lpi: project.lensParameters.lpi
                                )

                                HStack(spacing: 12) {
                                    Button(action: {
                                        project.calculateNextLayoutStrategy()
                                    }) {
                                        Label("Try Next Strategy", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    .disabled(project.isProcessing)

                                    Button(action: {
                                        project.tileLayout = nil
                                    }) {
                                        Label("Start Over", systemImage: "arrow.counterclockwise")
                                    }
                                    .disabled(project.isProcessing)

                                    Spacer()

                                    Button(action: {
                                        Task {
                                            await project.generateTiles()
                                        }
                                    }) {
                                        Label("Approve & Generate Tiles", systemImage: "checkmark.circle")
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                    .disabled(project.isProcessing)
                                }
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                        }

                        // Progress indicator
                        if project.isProcessing {
                            VStack(spacing: 12) {
                                ProgressView(value: project.processingProgress)
                                    .progressViewStyle(.linear)
                                Text("Generating tiles: \(Int(project.processingProgress * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }

                        // Tiles Grid Preview
                        if !project.tiles.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Label("\(project.tiles.count) Tiles Generated", systemImage: "checkmark.circle.fill")
                                        .font(.headline)
                                        .foregroundStyle(.green)

                                    Spacer()

                                    Button(action: { exportAllTiles() }) {
                                        Label("Export All Tiles", systemImage: "square.and.arrow.up")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(.horizontal)

                                // Tile grid
                                ScrollView {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                                        ForEach(project.tiles) { tile in
                                            TileThumbnailView(
                                                tile: tile,
                                                onExport: { exportSingleTile(tile) }
                                            )
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                                .frame(maxHeight: 400)
                            }
                            .padding(.vertical)
                        }
                    }
                }
            }
        }
    }

    private var tileModeDescription: String {
        switch project.tileConfiguration.mode {
        case .edgeToEdge:
            return "Tiles with no overlap or bleed. Requires precise manual alignment when assembling."
        case .withBleed:
            return "Tiles extend slightly beyond edges for trimming after assembly. Easier alignment but requires cutting."
        case .withRegistration:
            return "Tiles include corner crosshairs and tile numbers for easy alignment during assembly."
        }
    }

    private var estimatedGridSize: String {
        guard let image = project.interlacedImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Unknown"
        }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height

        // Calculate pixels per lenticule
        let pixelsPerLenticule = Double(project.outputDPI) / project.lensParameters.lpi

        // Calculate tile dimensions in pixels
        var tileWidthPixels = Int(project.tileConfiguration.tileWidth * Double(project.outputDPI))
        let tileHeightPixels = Int(project.tileConfiguration.tileHeight * Double(project.outputDPI))

        // Align to lenticule boundaries
        let lenticulesPerTile = floor(Double(tileWidthPixels) / pixelsPerLenticule)
        tileWidthPixels = Int(lenticulesPerTile * pixelsPerLenticule)

        let cols = Int(ceil(Double(imageWidth) / Double(tileWidthPixels)))
        let rows = Int(ceil(Double(imageHeight) / Double(tileHeightPixels)))

        return "\(rows) rows × \(cols) columns = \(rows * cols) tiles"
    }

    private func applyTilePreset(_ preset: String) {
        switch preset {
        case "Letter":
            project.tileConfiguration = .letter
        case "A4":
            project.tileConfiguration = .a4
        case "Square8":
            project.tileConfiguration = .square8
        default:
            break
        }
    }

    private func exportSingleTile(_ tile: TileInfo) {
        guard let image = tile.image else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = tile.filename(projectName: project.name)
        savePanel.title = "Export Tile"

        let response = savePanel.runModal()
        guard response == .OK, let url = savePanel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

            do {
                try pngData.write(to: url)
                print("✅ Exported tile to: \(url.path)")
            } catch {
                print("❌ Export error: \(error.localizedDescription)")
            }
        }
    }

    private func exportAllTiles() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.title = "Choose Export Folder"
        openPanel.message = "Select a folder to export all tiles"

        let response = openPanel.runModal()
        guard response == .OK, let folderURL = openPanel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            for tile in project.tiles {
                guard let image = tile.image else { continue }
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

                let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { continue }

                let fileURL = folderURL.appendingPathComponent(tile.filename(projectName: project.name))

                do {
                    try pngData.write(to: fileURL)
                    print("✅ Exported: \(tile.name)")
                } catch {
                    print("❌ Failed to export \(tile.name): \(error.localizedDescription)")
                }
            }

            print("✅ All tiles exported to: \(folderURL.path)")
        }
    }
}

// MARK: - Tile Thumbnail View

struct TileThumbnailView: View {
    let tile: TileInfo
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail
                Group {
                    if let image = tile.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .frame(height: 150)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Export button
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .blue)
                }
                .buttonStyle(.plain)
                .padding(8)
            }

            // Tile info
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.name)
                    .font(.caption)
                    .fontWeight(.medium)

                if let image = tile.image,
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    Text("\(cgImage.width) × \(cgImage.height) px")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 200)
    }
}

// MARK: - 3D Model View

struct Model3DView: View {
    @ObservedObject var project: Project

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("3D Lens Model")
                    .font(.title)
                Text("Generate a 3D-printable lenticular lens matching your interlaced image.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            if project.interlacedImage == nil {
                // No interlaced image yet
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundStyle(.orange)
                    Text("No Interlaced Image")
                        .font(.title2)
                    Text("Generate an interlaced image first in the Interlace section.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        // Physical dimensions info
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Physical Dimensions", systemImage: "ruler")
                                .font(.headline)

                            HStack(spacing: 40) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Print Size")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(String(format: "%.2f", project.physicalWidth))\" × \(String(format: "%.2f", project.physicalHeight))\"")
                                        .font(.body)
                                        .fontWeight(.medium)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Millimeters")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(String(format: "%.1f", project.physicalWidth * 25.4)) × \(String(format: "%.1f", project.physicalHeight * 25.4)) mm")
                                        .font(.body)
                                        .fontWeight(.medium)
                                }
                            }
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                        .padding(.top)

                        // Lens parameters summary
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Lens Parameters", systemImage: "camera.aperture")
                                .font(.headline)

                            VStack(spacing: 8) {
                                parameterRow(label: "LPI", value: String(format: "%.1f", project.lensParameters.lpi))
                                parameterRow(label: "Pitch", value: String(format: "%.3f mm", project.lensParameters.pitch))
                                parameterRow(label: "Radius", value: String(format: "%.2f mm", project.lensParameters.radius))
                                parameterRow(label: "Height", value: String(format: "%.1f mm", project.lensParameters.height))

                                Divider()

                                let widthMM = project.physicalWidth * 25.4
                                let numLenticules = Int(widthMM / project.lensParameters.pitch)
                                parameterRow(label: "Lenticules", value: "\(numLenticules)")
                            }
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)

                        // Tiling options
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Tiling Options", systemImage: "square.grid.3x3")
                                .font(.headline)

                            if project.tiles.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("For large prints, generate image tiles first in the Tiles section.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("Then return here to generate matching lens tiles.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Text("\(project.tiles.count) image tiles generated")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                    }

                                    Text("Generate matching lens tiles (1:1 correspondence with image tiles)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Button(action: {
                                        Task {
                                            await project.generateLensTiles()
                                        }
                                    }) {
                                        Label("Generate Lens Tiles", systemImage: "cube.stack")
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                    .disabled(project.isProcessing)
                                }
                            }
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)

                        // Progress indicator
                        if project.isProcessing {
                            VStack(spacing: 12) {
                                ProgressView(value: project.processingProgress)
                                    .progressViewStyle(.linear)
                                Text("Generating model: \(Int(project.processingProgress * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }

                        // Model info and preview
                        if let model = project.lensModel {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Label("Model Generated", systemImage: "checkmark.circle.fill")
                                        .font(.headline)
                                        .foregroundStyle(.green)

                                    Spacer()

                                    Button(action: { exportModel(model) }) {
                                        Label("Export STL", systemImage: "square.and.arrow.up")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                // Model stats
                                VStack(alignment: .leading, spacing: 8) {
                                    if let mesh = model.object(at: 0) as? MDLMesh {
                                        Text("Vertices: \(mesh.vertexCount)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        if let submesh = mesh.submeshes?.firstObject as? MDLSubmesh {
                                            Text("Triangles: \(submesh.indexCount / 3)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.gray.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                // 3D Preview placeholder
                                VStack(spacing: 12) {
                                    Image(systemName: "cube.fill")
                                        .font(.system(size: 80))
                                        .foregroundStyle(.blue.opacity(0.5))
                                    Text("3D Model Ready")
                                        .font(.title3)
                                        .fontWeight(.medium)
                                    Text("Export to STL to view in PrusaSlicer or other 3D software")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(height: 200)
                                .frame(maxWidth: .infinity)
                                .background(Color.gray.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                        }

                        // Lens Tiles Display
                        if !project.lensTiles.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Label("\(project.lensTiles.count) Lens Tiles Generated", systemImage: "checkmark.circle.fill")
                                        .font(.headline)
                                        .foregroundStyle(.green)

                                    Spacer()

                                    Button(action: { exportAllLensTiles() }) {
                                        Label("Export All Lens Tiles", systemImage: "square.and.arrow.up")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button(action: { exportAllAlignmentFrames() }) {
                                        Label("Export All Alignment Frames", systemImage: "square.dashed")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.orange)
                                }
                                .padding(.horizontal)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Each lens tile matches one printer bed region.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Alignment frames: Print these first in a different color, pause printer, align paper inside frame, then print lens on top.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal)

                                // Lens tiles grid
                                ScrollView {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                                        ForEach(project.lensTiles) { lensTile in
                                            LensTileThumbnailView(
                                                lensTile: lensTile,
                                                projectName: project.name,
                                                onExport: { exportSingleLensTile(lensTile) }
                                            )
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                                .frame(maxHeight: 400)
                            }
                            .padding(.vertical)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom)
                }
            }
        }
    }

    private func parameterRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }

    private func exportModel(_ model: MDLAsset) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "stl")!]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "\(project.name)_lens.stl"
        savePanel.title = "Export 3D Model"

        let response = savePanel.runModal()
        guard response == .OK, let url = savePanel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try LensModelGenerator.exportSTL(asset: model, to: url)
                print("✅ Successfully exported 3D model to: \(url.path)")
            } catch {
                print("❌ Export error: \(error.localizedDescription)")
            }
        }
    }

    private func exportSingleLensTile(_ lensTile: LensTileInfo) {
        guard let model = lensTile.model else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "stl")!]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = lensTile.filename(projectName: project.name)
        savePanel.title = "Export Lens Tile"

        let response = savePanel.runModal()
        guard response == .OK, let url = savePanel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try LensModelGenerator.exportSTL(asset: model, to: url)
                print("✅ Exported lens tile to: \(url.path)")
            } catch {
                print("❌ Export error: \(error.localizedDescription)")
            }
        }
    }

    private func exportAllLensTiles() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.title = "Choose Export Folder"
        openPanel.message = "Select a folder to export all lens tiles"

        let response = openPanel.runModal()
        guard response == .OK, let folderURL = openPanel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            for lensTile in project.lensTiles {
                guard let model = lensTile.model else { continue }

                let fileURL = folderURL.appendingPathComponent(lensTile.filename(projectName: project.name))

                do {
                    try LensModelGenerator.exportSTL(asset: model, to: fileURL)
                    print("✅ Exported: \(lensTile.name)")
                } catch {
                    print("❌ Failed to export \(lensTile.name): \(error.localizedDescription)")
                }
            }

            print("✅ All lens tiles exported to: \(folderURL.path)")
        }
    }

    private func exportAllAlignmentFrames() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.title = "Choose Export Folder"
        openPanel.message = "Select a folder to export all alignment frames"

        let response = openPanel.runModal()
        guard response == .OK, let folderURL = openPanel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            for lensTile in project.lensTiles {
                guard let frame = lensTile.alignmentFrame else { continue }

                let fileURL = folderURL.appendingPathComponent(lensTile.frameFilename(projectName: project.name))

                do {
                    try LensModelGenerator.exportSTL(asset: frame, to: fileURL)
                    print("✅ Exported: \(lensTile.frameName)")
                } catch {
                    print("❌ Failed to export \(lensTile.frameName): \(error.localizedDescription)")
                }
            }

            print("✅ All alignment frames exported to: \(folderURL.path)")
        }
    }
}

// MARK: - Lens Tile Thumbnail View

struct LensTileThumbnailView: View {
    let lensTile: LensTileInfo
    let projectName: String
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail placeholder
                VStack(spacing: 12) {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue.opacity(0.5))
                    Text(lensTile.name)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Export button
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .blue)
                }
                .buttonStyle(.plain)
                .padding(8)
            }

            // Tile info
            VStack(alignment: .leading, spacing: 2) {
                Text(lensTile.name)
                    .font(.caption)
                    .fontWeight(.medium)

                Text("\(String(format: "%.1f", lensTile.widthMM)) × \(String(format: "%.1f", lensTile.heightMM)) mm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let model = lensTile.model, let mesh = model.object(at: 0) as? MDLMesh {
                    Text("\(mesh.vertexCount) vertices")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 200)
    }
}

// MARK: - Tile Layout Preview

struct TileLayoutPreview: View {
    let image: NSImage
    let layout: TileLayout
    let dpi: Int
    let lpi: Double

    var body: some View {
        VStack(spacing: 16) {
            // Statistics
            HStack(spacing: 40) {
                StatBox(label: "Paper Pieces", value: "\(paperPiecesCount)", color: .blue)
                StatBox(label: "Cuts Needed", value: "\(cutsNeeded)", color: .orange)
                StatBox(label: "3D Tiles", value: "\(lensTilesCount)", color: .green)
                StatBox(label: "Bed Size", value: "\(maxBedDimension)\"", color: .purple)
            }

            // Visual preview
            GeometryReader { geometry in
                let imageSize = image.size
                let aspectRatio = imageSize.width / imageSize.height
                let previewHeight = geometry.size.width / aspectRatio

                ZStack {
                    // Background image
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: previewHeight)

                    // Printer bed regions overlay
                    Canvas { context, size in
                        let scaleX = size.width / imageSize.width
                        let scaleY = size.height / imageSize.height

                        // Draw printer bed regions (alternating colors)
                        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]

                        // Get boundary arrays
                        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                        let xBoundaries = [0.0] + layout.verticalBoundaries + [Double(cgImage.width)]
                        let yBoundaries = [0.0] + layout.horizontalBoundaries + [Double(cgImage.height)]

                        for (index, region) in layout.printerBedRegions.enumerated() {
                            let x1 = xBoundaries[region.columnStart] * scaleX
                            let x2 = xBoundaries[region.columnEnd] * scaleX
                            let y1 = yBoundaries[region.rowStart] * scaleY
                            let y2 = yBoundaries[region.rowEnd] * scaleY

                            let rect = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)

                            context.fill(
                                Path(rect),
                                with: .color(colors[index % colors.count].opacity(0.15))
                            )
                        }

                        // Draw grid lines
                        context.stroke(
                            Path { path in
                                // Vertical lines
                                for boundary in layout.verticalBoundaries {
                                    let x = boundary * scaleX
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: size.height))
                                }

                                // Horizontal lines
                                for boundary in layout.horizontalBoundaries {
                                    let y = boundary * scaleY
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: size.width, y: y))
                                }
                            },
                            with: .color(.white),
                            lineWidth: 2
                        )
                    }
                    .frame(width: geometry.size.width, height: previewHeight)
                }
            }
            .frame(height: 400)
            .background(Color.black.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Legend
            Text("Each colored region = one 3D printer bed load")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var paperPiecesCount: Int {
        let cols = layout.verticalBoundaries.count + 1
        let rows = layout.horizontalBoundaries.count + 1
        return cols * rows
    }

    private var cutsNeeded: Int {
        // Estimate cuts based on remainder pieces
        let widthInches = Double(image.size.width) * 72.0 / Double(dpi)  // Convert to inches
        let heightInches = Double(image.size.height) * 72.0 / Double(dpi)

        var cuts = 0
        if widthInches.truncatingRemainder(dividingBy: layout.paperWidth) > 0.1 {
            cuts += (layout.horizontalBoundaries.count + 1)
        }
        if heightInches.truncatingRemainder(dividingBy: layout.paperHeight) > 0.1 {
            cuts += (layout.verticalBoundaries.count + 1)
        }
        return cuts
    }

    private var lensTilesCount: Int {
        return layout.printerBedRegions.count
    }

    private var maxBedDimension: String {
        return String(format: "%.1f", layout.maxBedSize)
    }
}

struct StatBox: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
        .padding(12)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
