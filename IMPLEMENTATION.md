# Lenticular Fancy Printer - Implementation Guide

**Version:** 1.0
**Date:** October 27, 2025

---

## Architecture Overview

### SwiftUI App Structure

```
Lenticular Fancy Printer/
├── Models/
│   ├── LensParameters.swift      # Lens geometry data
│   ├── Project.swift              # Project state
│   ├── SourceImage.swift          # Image metadata
│   └── TileConfiguration.swift   # Tiling settings
├── ViewModels/
│   ├── ProjectViewModel.swift    # Main app state
│   ├── InterlaceViewModel.swift  # Interlacing logic
│   └── LensModelViewModel.swift  # 3D generation logic
├── Views/
│   ├── ContentView.swift         # Main layout
│   ├── ImportView.swift          # Image import UI
│   ├── LensConfigView.swift      # Parameter controls
│   ├── PreviewView.swift         # Image preview
│   ├── TilingView.swift          # Tile grid UI
│   └── ExportView.swift          # Export controls
├── Services/
│   ├── InterlaceEngine.swift     # Core interlacing
│   ├── LensModelGenerator.swift  # STL/OBJ generation
│   ├── TileGenerator.swift       # Image subdivision
│   ├── ImageProcessor.swift      # Image utilities
│   └── ExportService.swift       # File export
└── Utilities/
    ├── GeometryHelpers.swift     # Math functions
    └── Extensions/               # Swift extensions
```

**Design Pattern:** MVVM (Model-View-ViewModel)
- Models: Pure data structures
- Views: SwiftUI declarative UI
- ViewModels: Business logic, ObservableObject

---

## Required Libraries & Frameworks

### Apple Frameworks (Built-in)

**CoreImage / CoreGraphics**
- Image loading, processing, manipulation
- Color space conversion
- High-quality scaling and interpolation
- Use for: All image operations

**AppKit / SwiftUI**
- User interface
- File pickers, drag-drop
- AirPrint integration
- Use for: Entire UI

**ModelIO**
- 3D mesh creation and manipulation
- Built-in STL/OBJ export
- Mesh validation
- **Use for: Primary 3D model generation**

**SceneKit**
- 3D preview rendering
- Scene graph management
- Camera controls for preview
- Use for: 3D lens preview in app

**Combine**
- Reactive programming
- Data binding between ViewModels and Views
- Use for: State management

---

### Third-Party Libraries (Recommended)

#### For 3D Model Generation:

**1. ModelIO (Built-in - RECOMMENDED)**
```swift
import ModelIO

// Create mesh programmatically
let allocator = MTKMeshBufferAllocator(device: device)
let mesh = MDLMesh(...)
let asset = MDLAsset()
asset.add(mesh)

// Export STL
try asset.export(to: url)
```
**Pros:** Native, no dependencies, official Apple support
**Cons:** Learning curve for mesh creation

**2. Swift-STL** (If needed for more control)
- GitHub: Search for "Swift STL" packages
- Direct binary STL writing
- Simpler than ModelIO for basic geometry
- Fallback if ModelIO is difficult

#### For Image Processing:

**CoreImage Filters:**
- CILanczosScaleTransform (high-quality scaling)
- CIColorControls (adjustments)
- Built-in, no external libraries needed

#### For Project Persistence:

**Codable (Built-in)**
- JSON encoding/decoding
- Native Swift serialization
- Use for: Project save/load

---

## Core Algorithms

### 1. Interlacing Algorithm

**Concept:**
Each lenticule shows a strip from each source image. As viewing angle changes, different strips become visible.

**Pseudocode:**
```swift
func interlaceImages(sources: [CGImage], params: LensParameters) -> CGImage {
    let dpi = 300.0
    let pixelsPerLenticule = (params.pitch / 25.4) * dpi
    let stripWidth = pixelsPerLenticule / Double(sources.count)

    let width = sources[0].width
    let height = sources[0].height

    // Create output bitmap
    let context = CGContext(...)

    for x in 0..<width {
        // Which lenticule?
        let lenticulePosition = Double(x).truncatingRemainder(dividingBy: pixelsPerLenticule)

        // Which source image?
        let imageIndex = Int(lenticulePosition / stripWidth)
        let sourceImage = sources[imageIndex]

        // Copy vertical strip from source to output
        for y in 0..<height {
            let color = sourceImage.pixel(at: x, y)
            context.setPixel(x, y, color)
        }
    }

    return context.makeImage()
}
```

**Key Considerations:**
- Sub-pixel accuracy critical for sharp results
- Use high-quality interpolation (Lanczos resampling)
- Handle fractional pixels at lenticule boundaries
- Consider gamma correction for color accuracy

---

### 2. Lenticule Geometry

**Cross-section:**
```
    /‾‾‾\     /‾‾‾\     /‾‾‾\
   |     |   |     |   |     |
   |_____|   |_____|   |_____|
   <-p->     <-p->     <-p->

p = pitch (spacing)
Curve = circular arc with radius r
```

**Parametric Cylinder Equation:**
```swift
// For lenticule at position x with length L
func lenticulePoint(u: Double, v: Double) -> SIMD3<Float> {
    let x = Float(lenticuleX + v * length)
    let y = Float(radius * sin(u * .pi))
    let z = Float(radius * cos(u * .pi) - radius + height)
    return SIMD3(x, y, z)
}
```

Where:
- u ∈ [0, 1] traces around the cylinder curve
- v ∈ [0, 1] runs along the length

---

### 3. 3D Mesh Generation

**Approach:**
1. Generate individual lenticule meshes
2. Combine into single mesh
3. Add flat base plate
4. Validate manifold geometry
5. Export as STL/OBJ

**Using ModelIO:**
```swift
func generateLensMesh(dimensions: CGSize, params: LensParameters) -> MDLMesh {
    let numLenticules = Int(dimensions.width / params.pitch)
    var vertices: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    for i in 0..<numLenticules {
        let xPos = Float(i) * Float(params.pitch)

        // Generate cylinder strips
        let resolution = 20 // segments around curve
        for u in 0...resolution {
            for v in 0...1 {
                let point = lenticulePoint(
                    u: Double(u) / Double(resolution),
                    v: Double(v),
                    xPos: xPos,
                    params: params
                )
                vertices.append(point)
            }
        }

        // Generate triangle indices...
    }

    // Create MDLMesh from vertices
    let vertexBuffer = MDLMeshBufferData(...)
    let submesh = MDLSubmesh(...)
    let mesh = MDLMesh(vertexBuffer: vertexBuffer, ...)

    return mesh
}
```

**STL Export:**
```swift
func exportSTL(mesh: MDLMesh, to url: URL) throws {
    let asset = MDLAsset()
    asset.add(mesh)
    try asset.export(to: url)
}
```

---

### 4. Tiling Algorithm

**Requirements:**
- Tiles must align with lenticule boundaries
- Avoid splitting lenticules across tiles

**Algorithm:**
```swift
func generateTiles(image: CGImage, tileSize: CGSize, params: LensParameters) -> [TileInfo] {
    let pixelsPerLenticule = (params.pitch / 25.4) * dpi

    // Calculate tile dimensions in lenticules
    let lenticulesPerTile = Int(tileSize.width * dpi / 25.4 / params.pitch)
    let adjustedTileWidth = lenticulesPerTile * pixelsPerLenticule

    let cols = Int(ceil(Double(image.width) / adjustedTileWidth))
    let rows = Int(ceil(Double(image.height) / tileHeight))

    var tiles: [TileInfo] = []

    for row in 0..<rows {
        for col in 0..<cols {
            let rect = CGRect(
                x: col * adjustedTileWidth,
                y: row * tileHeight,
                width: adjustedTileWidth,
                height: tileHeight
            )

            let tileImage = image.cropping(to: rect)
            tiles.append(TileInfo(
                image: tileImage,
                row: row,
                col: col,
                name: "Tile_R\(row+1)_C\(col+1)"
            ))
        }
    }

    return tiles
}
```

---

## Workflow Improvements

### Suggested Workflow Enhancements

**1. Iterative Calibration Loop**
```
Import → Configure → Preview → Adjust → Re-preview
                ↑__________________|
```
- Real-time preview updates as parameters change
- Side-by-side comparison with reference
- Quick preset switching for comparison

**2. Test Print Workflow**
```
1. Create small test (2" x 2")
2. Print single tile
3. 3D print small lens section
4. Evaluate result
5. Adjust parameters
6. Repeat until satisfied
7. Scale up to full project
```

**Implementation:**
- "Test Mode" that generates small output
- Parameter adjustment history (undo/redo)
- Notes field to document what worked

**3. Tile Assembly Guide**
- Generate PDF showing tile layout
- Include dimensions, numbering
- Alignment marks if enabled
- Print alongside tiles

**4. Lens Section Testing**
- For large projects: print individual lens sections first
- Verify dimensions match before printing all sections
- Test fit on substrate

**5. Parameter Library**
- Share successful parameters between projects
- Tag presets by material, printer settings
- Export/import preset files
- Community preset sharing (future)

---

## Development Phases

### Phase 1: Foundation
**Goal:** Basic structure, image import

**Tasks:**
- Set up Xcode project structure
- Create data models
- Implement image import (drag-drop, file picker)
- Basic SwiftUI layout with sidebar navigation
- Display imported images

---

### Phase 2: Lens Parameters UI
**Goal:** Configuration interface

**Tasks:**
- Build lens parameter controls
- Implement parameter validation
- LPI ↔ Pitch conversion
- Preset save/load system
- Cross-section visualization

---

### Phase 3: Interlacing Engine
**Goal:** Core algorithm

**Tasks:**
- Implement interlacing algorithm
- 2-image flip mode
- Multi-frame animation mode
- High-quality interpolation
- Progress indicator
- Basic preview

---

### Phase 4: Advanced Preview
**Goal:** Visualization system

**Tasks:**
- Zoomable image viewer
- Pan controls
- Before/after comparison
- Simulated viewing angle animation
- Performance optimization

---

### Phase 5: Tiling System
**Goal:** Image subdivision

**Tasks:**
- Tile generation algorithm
- Grid preview UI
- Edge/bleed/registration modes
- Batch export
- Lenticule alignment validation

---

### Phase 6: 3D Model Generation
**Goal:** STL/OBJ export

**Tasks:**
- Learn ModelIO mesh generation
- Implement lenticule geometry
- Generate mesh array
- STL/OBJ export
- 3D preview in app
- Dimension validation

---

### Phase 7: Export & Print
**Goal:** File output

**Tasks:**
- Image export (PNG, TIFF, JPEG)
- Model export (STL, OBJ)
- AirPrint integration
- Batch operations
- File naming system

---

### Phase 8: Project Management
**Goal:** Persistence

**Tasks:**
- Project save/load (JSON)
- Auto-save implementation
- Recent projects list
- Project validation

---

### Phase 9: Polish
**Goal:** UX refinement

**Tasks:**
- Keyboard shortcuts
- Tooltips and help text
- Error handling
- Performance optimization
- Documentation

---

### Phase 10: Real-World Testing
**Goal:** Physical validation

**Tasks:**
- Print test images
- 3D print lenses on Prusa XL
- Calibrate parameters
- Document optimal settings
- Refine algorithms based on results

---

## Technical Challenges & Solutions

### Challenge 1: Large Image Processing
**Problem:** 6' x 5' @ 300 DPI = ~21,600 x 18,000 pixels (390 megapixels)

**Solutions:**
- Process tiles individually (streaming approach)
- Use lower resolution for preview
- Background processing with progress
- Memory-mapped files for large images
- Consider Metal acceleration for critical operations

---

### Challenge 2: 3D Mesh Complexity
**Problem:** High-resolution lenticules create huge meshes

**Solutions:**
- Balance resolution vs file size
- Use curve subdivision only where needed
- Binary STL format (smaller than ASCII)
- Segment meshes for large prints (per-tile models)
- Test what resolution is "good enough"

---

### Challenge 3: Precise Alignment
**Problem:** Lens must align perfectly with interlacing

**Solutions:**
- Sub-pixel accuracy in interlacing
- Coordinate system consistency (same units, origin)
- Validation: visual overlay of lens pattern on interlaced image
- Include alignment markers in both image and 3D model
- Document exact print DPI for reproducibility

---

### Challenge 4: PETG Clarity
**Problem:** 3D printed lens may not be perfectly clear

**Solutions:**
- Print settings optimization (layer height, temperature)
- Post-processing (vapor smoothing, sanding)
- Consider alternative: print negative mold, cast in resin
- This is a materials/hardware problem, not software
- Document successful print settings in app

---

## Data Structures

### LensParameters
```swift
struct LensParameters: Codable {
    var lpi: Double                 // Lines per inch
    var pitch: Double               // mm
    var radius: Double              // mm
    var height: Double              // mm
    var viewingAngle: Double        // degrees

    // Computed property
    var pitchFromLPI: Double {
        return 25.4 / lpi
    }
}
```

### Project
```swift
class Project: ObservableObject {
    @Published var name: String
    @Published var sourceImages: [SourceImage]
    @Published var lensParams: LensParameters
    @Published var effectType: EffectType
    @Published var tileConfig: TileConfiguration
    @Published var exportSettings: ExportSettings

    func save(to url: URL) throws { ... }
    static func load(from url: URL) throws -> Project { ... }
}
```

### TileInfo
```swift
struct TileInfo {
    let image: CGImage
    let row: Int
    let col: Int
    let rect: CGRect
    let name: String

    var filename: String {
        return "\(projectName)_\(name).png"
    }
}
```

---

## Testing Strategy

### Unit Tests
- LPI ↔ Pitch conversion
- Interlacing pixel calculations
- Tile boundary calculations
- Lenticule geometry math
- File export/import

### Integration Tests
- Full interlace generation
- Tile array generation
- 3D mesh generation
- Project save/load

### Manual Tests
- Import various image formats
- Extreme parameter values
- Very large images
- Performance profiling

### Physical Tests
- Print test patterns
- Measure printed dimensions
- Verify lens alignment
- Validate viewing angles

---

## Performance Optimization

### Image Processing
- Use CoreImage for GPU acceleration
- Process tiles in parallel (GCD)
- Cache preview at lower resolution
- Lazy generation (only when needed)

### 3D Generation
- Reuse geometry where possible
- LOD (Level of Detail) for preview vs export
- Background thread for mesh generation

### UI Responsiveness
- Debounce parameter changes
- Progressive rendering
- Async/await for long operations
- Progress feedback

---

## Known Limitations

1. **Stereoscopic 3D not supported** - Focus on flip/animation first
2. **No video import** - User extracts frames externally
3. **AirPrint only** - No direct printer control
4. **Cylindrical lenticules only** - No aspheric or custom shapes
5. **Fixed DPI per project** - No mixing resolutions

These may be addressed in future versions.

---

## Resources & References

### Lenticular Printing
- Research standard LPI values (20, 40, 60, 75, 100)
- Study interlacing techniques
- Review commercial lenticular software for UI patterns

### 3D Printing
- PETG printing guides for clarity
- Layer height recommendations for lenses
- Prusa XL best practices

### Apple Documentation
- ModelIO Programming Guide
- Core Image Programming Guide
- SwiftUI Tutorials

### Third-Party Libraries
- Search GitHub for "Swift STL"
- ModelIO examples and tutorials

---

## Next Steps

1. **Review this specification** - Confirm approach makes sense
2. **Start Phase 1** - Set up project structure
3. **Early prototype** - Get basic interlacing working ASAP
4. **Test with real hardware** - Print small test early
5. **Iterate** - Refine based on physical results

---

## Implementation Notes - Session October 27, 2025

### What We Actually Built

**Development Approach:** Single-file architecture
- All code consolidated into `ContentView.swift` (~1800 lines)
- Reason: Xcode file detection issues with separate Model/View files
- Works well for app of this complexity
- Future: Can refactor into modules if needed

**Phases Completed:**
- ✅ Phase 1: Image Import (working)
- ✅ Phase 2: Lens Configuration (working)
- ✅ Phase 3: Interlacing Engine (working)
- ✅ Phase 4: Enhanced Preview & Export (working)
- ⏳ Phase 5-10: Not yet started

---

### Critical Implementation Details

#### 1. Retina Display / Points vs Pixels Issue

**Problem:** On Retina displays, `NSImage.size` returns **points**, not **pixels**. At 2x scaling, this gives half the actual pixel dimensions, causing cropped output.

**Solution:**
```swift
// WRONG - Returns points (half size on Retina)
let dimensions = image.size

// CORRECT - Returns actual pixel dimensions
guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
let dimensions = CGSize(width: cgImage.width, height: cgImage.height)
```

**Location:** `SourceImage.dimensions` property in ContentView.swift:92-107

**Impact:** Critical for interlacing - using wrong dimensions caused only corner of image to render.

---

#### 2. App Sandbox Entitlements

**Problem:** Export function couldn't display save panel. Console error:
```
Unable to display save panel: your app has the User Selected File Read
entitlement but it needs User Selected File Read/Write to display save panels.
```

**Solution:** Created `Lenticular Fancy Printer.entitlements` file:
```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

**Setup in Xcode:**
1. Add entitlements file to project
2. Build Settings → Code Signing Entitlements → set path
3. Or: Signing & Capabilities tab → add entitlements reference

**Critical:** Without read/write permission, NSSavePanel silently fails. No error in UI, only visible in Console.app.

**Location:** `Lenticular Fancy Printer/Lenticular Fancy Printer.entitlements`

---

#### 3. Image Scaling: Aspect-Fit vs Stretch/Crop

**Problem:** When user changes output dimensions to different aspect ratio than source images, initial implementation cropped or stretched images.

**Solution:** Implemented aspect-fit scaling with letterboxing:
```swift
// Calculate aspect ratios
let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
let targetAspect = Double(outputWidth) / Double(outputHeight)

// Scale to fit (maintains aspect ratio)
if sourceAspect > targetAspect {
    // Source is wider - fit to width
    destHeight = Int(Double(outputWidth) / sourceAspect)
    destY = (outputHeight - destHeight) / 2  // Center vertically
} else {
    // Source is taller - fit to height
    destWidth = Int(Double(outputHeight) * sourceAspect)
    destX = (outputWidth - destWidth) / 2  // Center horizontally
}

// Fill background with black, draw scaled image centered
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: outputWidth, height: outputHeight).fill()
nsImage.draw(in: NSRect(x: destX, y: destY, width: destWidth, height: destHeight), ...)
```

**Location:** InterlaceEngine.interlace() in ContentView.swift:307-353

**User Experience:** Entire source image always visible, letterboxed if aspect ratios don't match. Better than cropping for lenticular work where user needs full image control.

---

#### 4. Physical Dimensions System

**Architecture:**
- User thinks in **inches** (physical print size)
- Computer calculates in **pixels** (actual image data)
- **DPI** bridges the two: `pixels = inches × DPI`

**Implementation:**
```swift
// Published properties
@Published var outputDPI: Int = 300
@Published var outputWidth: Int = 0    // pixels
@Published var outputHeight: Int = 0   // pixels
@Published var aspectRatioLocked: Bool = true

// Computed properties
var physicalWidth: Double {
    return Double(outputWidth) / Double(outputDPI)
}

var physicalHeight: Double {
    return Double(outputHeight) / Double(outputDPI)
}

// Setters maintain relationships
func setPhysicalWidth(_ inches: Double) {
    let newWidth = Int(inches * Double(outputDPI))
    setOutputWidth(newWidth)  // Respects aspect ratio lock
}

func setOutputDPI(_ newDPI: Int) {
    // CRITICAL: Maintain physical size when DPI changes
    let currentPhysicalWidth = physicalWidth
    let currentPhysicalHeight = physicalHeight
    outputDPI = newDPI
    outputWidth = Int(currentPhysicalWidth * Double(newDPI))
    outputHeight = Int(currentPhysicalHeight * Double(newDPI))
}
```

**User Workflow:**
1. Set physical size: "8 inches × 10 inches"
2. Set DPI: 300 (default)
3. App calculates: 2400×3000 pixels
4. Change DPI to 600 → auto-updates to 4800×6000 pixels (maintains 8"×10")

**Location:** Project class in ContentView.swift:118-156

---

#### 5. Export Debugging Journey

**Attempts that failed:**
1. ~~FileDocument with .fileExporter~~ → EXC_BREAKPOINT crash
2. ~~Sheet modal with custom ExportSheet~~ → Dark box appeared, no dialog
3. ~~Async Task with await savePanel.begin()~~ → No dialog appeared
4. ~~runModal() directly~~ → App froze (blocked main thread)

**What finally worked:**
```swift
private func exportInterlacedImage() {
    // Simple, synchronous approach
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.png]
    savePanel.canCreateDirectories = true
    savePanel.nameFieldStringValue = "interlaced_output.png"

    let response = savePanel.runModal()

    guard response == .OK, let url = savePanel.url else { return }

    // Write on background thread
    DispatchQueue.global(qos: .userInitiated).async {
        // ... write PNG data ...
    }
}
```

**Key lesson:** Sometimes simple synchronous code works better than complex async patterns. `runModal()` is fine for user-initiated actions like export.

**Location:** InterlaceView.exportInterlacedImage() in ContentView.swift:1741-1789

---

#### 6. Interlacing Algorithm Details

**Core concept:** Each vertical column in output comes from one source image, cycling through images across each lenticule.

**Implementation:**
```swift
// Calculate width of each lenticule in pixels
let pixelsPerLenticule = Double(dpi) / lensParameters.lpi

// For each output column
for x in 0..<outputWidth {
    // Position within current lenticule (0 to pixelsPerLenticule)
    let lenticulePosition = Double(x).truncatingRemainder(dividingBy: pixelsPerLenticule)

    // Which source image? (0 to numImages-1)
    let imageIndex = Int((lenticulePosition / pixelsPerLenticule) * numImages)
    let sourceImage = cgImages[imageIndex]

    // Copy entire vertical strip from source to output
    for y in 0..<outputHeight {
        // Sample pixel at (x, y) from source
        // Write to output at (x, y)
    }
}
```

**Performance:** ~2-3 seconds for 2400×3000 output with 2 images. Acceptable for user workflow.

**Potential optimizations (if needed):**
- Use Metal GPU processing
- Process multiple columns in parallel
- Cache scaled source images

**Location:** InterlaceEngine.interlace() in ContentView.swift:257-377

---

#### 7. Preview System Architecture

**Three modes implemented:**

**Interlaced Mode:**
- Shows actual interlaced output
- Optional lenticule grid overlay (vertical lines at lenticule boundaries)
- Zoom 10%-400%

**Animated Mode:**
- Cycles through source images to simulate lenticular effect
- Play/pause control
- Speed adjustment: 0.5-10 fps
- Manual scrubbing: slider to control viewing angle

**Source Images Mode:**
- Side-by-side comparison of all source images
- Shows up to 4 images simultaneously

**Implementation Note:** Animation uses Timer, not CADisplayLink (Timer is simpler and sufficient for this use case).

```swift
private func startAnimation() {
    animationTimer = Timer.scheduledTimer(
        withTimeInterval: 1.0 / animationSpeed,
        repeats: true
    ) { _ in
        currentFrameIndex = (currentFrameIndex + 1) % project.sourceImages.count
    }
}
```

**Location:** InterlaceView in ContentView.swift:1263-1790

---

### Lessons Learned

**1. Xcode Project Structure**
- Single-file approach avoided file detection issues
- For this app size (~1800 lines), single file is manageable
- Good naming conventions and MARK comments keep it organized

**2. Always Check Console.app**
- Critical errors (like entitlements) don't show in UI
- Console revealed the save panel permission issue immediately
- Debug with emoji print statements: 🔵 🟡 🟢 ✅ ❌ 💾

**3. Retina Display Testing**
- Test on actual hardware, not just simulator
- Points ≠ Pixels on Retina displays
- Always use CGImage dimensions for pixel-accurate work

**4. Sandboxing is Strict**
- Need explicit read-write entitlements for save dialogs
- Security-scoped resource access required for opening user-selected files
- Must call startAccessingSecurityScopedResource() / stopAccessingSecurityScopedResource()

**5. Simple Solutions Often Best**
- Tried many complex async approaches for export
- Simple synchronous runModal() worked perfectly
- Don't over-engineer

---

### Known Issues & Future Improvements

**Current Limitations:**
1. **No undo/redo** - User must manually revert parameter changes
2. **No project save/load** - Settings not persisted between sessions
3. **Preview performance** - Full-res preview can be slow for large images
4. **Memory usage** - Large images (6'×5') may cause issues

**Recommended Next Steps:**
1. **Phase 5: Tiling System**
   - Critical for large prints (>8.5"×11")
   - Must align tiles with lenticule boundaries
   - Generate assembly guide

2. **Phase 6: 3D Model Generation**
   - Use ModelIO to generate STL files
   - Match lenticule pitch exactly to interlacing
   - Include alignment markers

3. **Project Persistence**
   - Codable protocol for save/load
   - Store reference to source images (URLs)
   - Save lens parameters and custom presets

4. **Performance Optimization**
   - Lower-res preview with full-res export
   - Tile-based processing for large images
   - Consider Metal acceleration

---

### File Structure (Actual)

```
Lenticular Fancy Printer/
├── Lenticular Fancy Printer.xcodeproj/
├── Lenticular Fancy Printer/
│   ├── Assets.xcassets/
│   ├── ContentView.swift              # All code (1800 lines)
│   ├── Lenticular_Fancy_PrinterApp.swift
│   └── Lenticular Fancy Printer.entitlements  # CRITICAL for export
├── SPECIFICATION.md
├── IMPLEMENTATION.md                  # This file
└── .gitignore                         # Xcode-specific

Notable: Simple structure, single file approach
```

---

### Code Reference Guide

**Key Sections in ContentView.swift:**

| Line Range | Section | Description |
|------------|---------|-------------|
| 15-61 | LensParameters | Lens geometry data structure |
| 62-108 | SourceImage | Image model with security-scoped access |
| 110-256 | Project | Main application state |
| 257-377 | InterlaceEngine | Core interlacing algorithm |
| 695-1218 | LensConfigView | Parameter UI with presets |
| 1067-1217 | LensCrossSectionView | 1-inch scale visualization |
| 1222-1259 | PreviewMode | Enum for preview types |
| 1263-1790 | InterlaceView | Preview & export UI |

**Search Tips:**
- Find by `// MARK: -` comments
- Key functions: `interlace()`, `exportInterlacedImage()`, `generateInterlacedImage()`
- Security-scoped access: search for `startAccessingSecurityScopedResource`

---

### Testing Notes

**What's Been Tested:**
- ✅ Import 2 landscape photos (1920×1080)
- ✅ Change lens parameters (16 LPI tested)
- ✅ Generate interlaced output at various sizes (3"×1.69", 8"×2")
- ✅ Aspect ratio lock/unlock functionality
- ✅ Export to PNG (successful writes)
- ✅ Zoom controls in preview
- ✅ Grid overlay display

**Not Yet Tested:**
- Extreme image sizes (>10,000 px)
- Many source images (>10)
- Very high LPI values (>100)
- Memory limits with multiple large projects
- Actual printing and physical lens alignment

**Recommended Physical Tests:**
1. Print interlaced output at 300 DPI
2. 3D print lens with matching LPI
3. Align lens to print
4. Evaluate viewing angle and clarity
5. Iterate parameters based on results

---

### Dependencies & Requirements

**Minimum System Requirements:**
- macOS 14.0+ (Sonnet)
- Xcode 15.0+
- Swift 5.9+

**Frameworks Used:**
- SwiftUI (UI)
- AppKit (NSImage, NSSavePanel)
- Combine (ObservableObject, @Published)
- CoreGraphics (CGContext, CGImage)
- UniformTypeIdentifiers (file types)

**No Third-Party Dependencies:** Entirely built with Apple frameworks.

---

### Git Repository

**GitHub:** https://github.com/Zellle/lenticularly

**Commit Structure:**
- Initial commit: Complete working app (Phases 1-4)
- Comprehensive commit message documenting all features
- Proper .gitignore for Xcode projects

**Branch Strategy:** Single `main` branch (for now)

**Future:** Consider feature branches for:
- Phase 5 (tiling)
- Phase 6 (3D models)
- Experimental features

---

**Document Status:** Implementation complete through Phase 4
**Last Updated:** October 27, 2025 (End of Session)
**Next Session:** Begin Phase 5 (Tiling) or Phase 6 (3D Models) per user preference
