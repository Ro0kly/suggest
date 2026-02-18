# Suggestions Chips - Scrolling Implementation

## Project Overview

SwiftUI app with horizontally scrolling chip suggestions, featuring:
- Multiple rows of chips (2-3 rows based on chip count)
- Auto-scroll at different speeds per row
- User can manually scroll all rows together (synchronized)
- Infinite scroll effect using repeated content

## Current Implementation: ContentView4point2.swift

### Architecture Decision

**Chosen approach:** Multiple UIScrollView instances (one per row) with UIScrollViewDelegate synchronization

**Why not single ScrollView:**
- Tried ContentView3: Single ScrollView + `.offset()` for rows
- Problem: Need different auto-scroll speeds per row
- Offset + ScrollView interaction is complex for this use case
- Multiple ScrollViews = cleaner separation of concerns

### Key Components

#### 1. ScrollCoordinator4p2 (NSObject, UIScrollViewDelegate, ObservableObject)

**Responsibilities:**
- Registers UIScrollView instances via Introspect
- Syncs scroll between rows during user interaction
- Manages auto-scroll via CADisplayLink
- Handles pause/resume logic

**Key Properties:**
```swift
var scrollViews: [UIScrollView] = []           // All registered scroll views
private var isSyncing = false                  // Prevents infinite loops
private var dragStartOffsets: [CGFloat] = []   // For delta-based sync
private var dragStartOffset: CGFloat = 0       // Drag start position
var justStoppedScroll = false                  // Prevents accidental chip taps
private var displayLink: CADisplayLink?        // Auto-scroll timer (60-120 FPS)
private var speeds: [CGFloat] = []             // Per-row speeds
private var isUserInteracting = false          // Pauses auto-scroll
private var resumeTask: Task<Void, Never>?     // Delayed resume task
```

#### 2. Synchronization Strategy: Delta-Based

**How it works:**
1. User starts dragging Row 1
2. Store starting offsets: `dragStartOffset = Row1.x`, `dragStartOffsets = [Row1.x, Row2.x]`
3. User moves finger by +50px → delta = 50
4. Apply same delta to all rows: `Row2.x = Row2Start + 50`

**Why delta-based:**
- Preserves offset differences created by different auto-scroll speeds
- Smooth, no jumps
- Industry standard (used by App Store, etc.)

**Alternative rejected:**
- Relative position sync (`offset / maxOffset`) → jumps when content widths differ

#### 3. Auto-Scroll Implementation

**CADisplayLink:**
- Synced with screen refresh (60-120 FPS)
- Callback: `autoScrollTick()` moves each row by its speed
- Why not Timer/Task: CADisplayLink guarantees frame-perfect animation for UIKit

**Speeds:**
```swift
2 rows: [-0.5, -0.8]           // Row 0 slower, Row 1 faster
3 rows: [-0.4, -0.6, -0.9]     // Progressive speeds
```
Negative = scroll left

**Pause/Resume Logic:**
- `isUserInteracting = true` → auto-scroll pauses
- After scroll fully stops → wait 2 seconds → resume
- Structured concurrency: `Task.sleep(nanoseconds: 2_000_000_000)`

#### 4. Edge Cases Solved

**Problem 1: User can't stop scroll by tapping non-dragged row**

Original issue:
```
1. User scrolls Row 1, releases → deceleration
2. User taps Row 2 to stop
3. Row 1 still decelerating → calls scrollViewDidScroll
4. Moves Row 2 → Row 2 starts moving again!
```

Solution:
```swift
func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // Check if user is touching another scroll view
    for sv in scrollViews where sv !== scrollView {
        if sv.isTracking {
            // Stop all scroll views immediately
            for otherSV in scrollViews {
                otherSV.setContentOffset(otherSV.contentOffset, animated: false)
            }
            scheduleResume()
            return
        }
    }
    // Normal sync...
}
```

**Problem 2: When user starts dragging Row 2 while Row 1 decelerating → "fighting"**

Solution:
```swift
func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    // Kill deceleration of all other scroll views
    for sv in scrollViews where sv !== scrollView {
        sv.setContentOffset(sv.contentOffset, animated: false)
    }
}
```

**Problem 3: Accidental chip tap when stopping scroll**

When user taps to stop scroll → `onTapGesture` fires on chip.

Solution:
```swift
var justStoppedScroll = false

// In scrollViewDidScroll when detecting stop:
justStoppedScroll = true

// In onTapGesture:
guard !coordinator.justStoppedScroll else {
    coordinator.justStoppedScroll = false
    return
}
```

### Data Flow

#### Row Distribution
```swift
backendChips = ["Chip1", "Chip2", ..., "Chip10"]
rowCount = backendChips.count < 15 ? 2 : 3

// Sequential distribution (NOT modulo):
// 1-5 → Row 0
// 6-10 → Row 1
```

#### Infinite Scroll
```swift
repeatCount = 30
// Each row's chips repeated 30 times
// Provides ~30x content width for pseudo-infinite scroll
```

## File Structure

```
ContentView.swift         - Original offset-based approach (deprecated)
ContentView2.swift        - Early nested ScrollView attempt
ContentView3.swift        - Single ScrollView + offset + DragGesture
ContentView4.swift        - Multiple ScrollViews (working but has edge cases)
ContentView4point2.swift  - ✅ CURRENT: Refined version with all fixes
ContentView5.swift        - Attempted true infinite scroll with repositioning (jerky)
```

## Known Limitations

1. **Not true infinite scroll:** Uses 30 repeats instead of repositioning
   - Why: Repositioning during scroll causes visible jerks
   - Trade-off: Large dataset (30x) works smoothly

2. **Edge cases may exist:** Complex interaction between:
   - User dragging
   - Deceleration
   - Auto-scroll
   - Multiple scroll views
   - Tap gestures

## Next Steps / Potential Improvements

1. **Center scroll on start:** Add `scrollToCenter()` method (was removed earlier)
2. **Test edge cases:**
   - Rapid tap-scroll-tap sequences
   - Multi-finger gestures
   - Accessibility (VoiceOver compatibility)
3. **Performance:** Profile with Instruments for 3+ rows
4. **Refactor:** Consider extracting chip tap logic to separate coordinator method

## Technical Decisions Log

| Decision | Rationale |
|----------|-----------|
| Multiple ScrollViews vs Single | Different auto-scroll speeds per row |
| Delta-based sync | Preserves offset character, no jumps |
| CADisplayLink | Frame-perfect animation for UIKit |
| Task.sleep() for resume | Structured concurrency, cancellable |
| 30 repeats vs repositioning | Smooth vs jerky trade-off |
| `isTracking` for tap-stop | Native UIKit property, reliable |
| `justStoppedScroll` flag | Prevent accidental chip taps |

## Dependencies

- SwiftUI
- SwiftUIIntrospect (for accessing UIScrollView)
- UIKit (UIScrollViewDelegate, CADisplayLink)

## Testing Checklist

- [x] Basic scroll sync works
- [x] Auto-scroll at different speeds
- [x] Auto-scroll pauses on user interaction
- [x] Auto-scroll resumes 2 seconds after stop
- [x] Tap to stop works (any row)
- [x] New drag while decelerating works
- [x] Accidental chip taps prevented
- [ ] Center scroll on start (not implemented yet)
- [ ] Edge case: Very rapid interactions
- [ ] Accessibility testing
