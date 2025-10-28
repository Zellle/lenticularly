# Lenticular Fancy Printer - Specification

**Version:** 1.0
**Date:** October 27, 2025

---

## Project Purpose

A macOS app for creating custom lenticular prints by:
1. Interlacing multiple images based on adjustable lens parameters
2. Subdividing large images into letter/A4-size printable sections
3. Generating 3D lens models (STL/OBJ) that match the interlacing pattern

**Key Innovation:** 3D printing the lens directly onto sublimation-printed images.

---

## Use Case

Experimental art installation work requiring maximum adjustability for iterative testing and calibration.

**Print Sizes:**
- Small: Single prints under 14" square (one 3D print)
- Medium: ~2' x 3' (multiple tiles)
- Large: Up to 6' x 5' (many tiles, edge case)

**Hardware:**
- Sublimation: Letter/A4 size prints
- 3D Printer: Prusa XL (~14" bed), clear PETG via PrusaSlicer

---

## Core Features

### 1. Image Import
- Import 2-20 images (PNG, JPEG, TIFF)
- Drag-drop or file browser
- Reorder, remove, replace images
- Validate matching dimensions

### 2. Lens Parameter Configuration
Adjustable parameters for experimental calibration:

| Parameter | Range | Purpose |
|-----------|-------|---------|
| LPI (Lines Per Inch) | 10-100 | Lenticule density |
| Lens Pitch | 0.1-5.0 mm | Spacing between lenticules |
| Lens Radius | 0.1-10.0 mm | Curvature |
| Lens Height | 0.5-5.0 mm | Thickness |
| Viewing Angle | 20-60° | Effect visibility range |

**UI:** Sliders with numeric inputs, tooltips, LPI↔Pitch converter, save/load presets

### 3. Lenticular Effect Types

**Supported:**
- 2-image flip (A/B alternating)
- Multi-frame animation (3-20 frames)

**Not Supported (initially):**
- Stereoscopic 3D

### 4. Image Interlacing
- Generate interlaced image from source images + lens parameters
- High-quality interpolation (bicubic/lanczos)
- Output: 300-600 DPI, PNG or TIFF
- Handle up to 6' x 5' final size

### 5. Image Subdivision (Tiling)

**Tile Sizes:** Letter (8.5" x 11"), A4, or custom

**Modes:**
- **Edge-to-edge** (default): No overlap, manual alignment
- **With bleed**: 0.125"-0.5" extension for trim
- **With registration marks**: Corner marks, crosshairs, tile numbering

**Output:**
- Grid preview
- Export individual or all tiles
- Naming: `ProjectName_Tile_R01_C01.png`
- Tiles align with lenticule boundaries

### 6. 3D Lens Model Generation
- Generate STL/OBJ matching interlaced image dimensions
- Cylindrical lenticule array based on lens parameters
- Flat backing, lenticular surface on top
- Output for PrusaSlicer
- Option: Per-tile models or single large model

### 7. Preview System
- Zoomable interlaced image preview
- Before/after comparison
- 3D lens cross-section view
- Simulated viewing angle animation
- Tile grid overlay

### 8. Export & Print
**Images:**
- Formats: PNG, TIFF, JPEG
- DPI: 300, 600, custom
- Batch export all tiles

**3D Models:**
- Formats: STL (binary/ASCII), OBJ
- Export for PrusaSlicer

**Printing:**
- AirPrint support (convenience feature)
- Direct print individual tiles

### 9. Project Management
- Save/load projects (JSON + images)
- Auto-save every 5 minutes
- Recent projects list
- Preset management (lens parameters)

---

## Technical Requirements

**Platform:**
- macOS 14.0+
- Swift + SwiftUI
- Native macOS app

**Performance:**
- UI remains responsive during processing
- Progress indicators for long operations
- Background processing for heavy tasks

**Quality:**
- High-resolution output (300-600 DPI)
- Precise alignment (sub-pixel accuracy)
- Color profile support (sRGB, Adobe RGB)

---

## User Interface

**Layout:**
```
Sidebar Navigation:
  1. Import
  2. Lens Config
  3. Interlace
  4. Tiles
  5. 3D Model
  6. Export/Print

Main Canvas: Preview area
Parameter Panel: Adjustable controls
```

**Design Principles:**
- Power user focused (all parameters visible)
- Technical tooltips with formulas
- Keyboard shortcuts
- Dark/light mode support

---

## Success Criteria

**MVP (Minimum Viable Product):**
- Import images
- Configure lens parameters
- Generate interlaced image (2-flip)
- Export PNG
- Generate basic STL

**V1.0 Complete:**
- All core features working
- Successful physical test print
- Lens aligns correctly with print
- App is stable and documented

---

## Future Enhancements

- Stereoscopic 3D mode
- Depth map conversion
- Video frame extraction
- Batch processing
- Non-cylindrical lens shapes
- Variable pitch lenticules

---

## Glossary

**LPI:** Lines Per Inch - density of lenticules
**Lenticule:** Individual cylindrical lens element
**Interlacing:** Slicing and interleaving multiple images
**Pitch:** Physical spacing between lenticules (mm)
**Manifold Mesh:** Watertight 3D geometry suitable for printing
