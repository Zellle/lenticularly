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

**Document Status:** Ready for development
**Last Updated:** October 27, 2025
