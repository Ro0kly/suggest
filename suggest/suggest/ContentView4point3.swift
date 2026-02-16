//
//  ContentView4point3.swift
//  suggest
//
//  Created by Rookly on 15.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Model

struct Chip4p3: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Proxy (breaks CADisplayLink → Coordinator retain cycle)

private class DisplayLinkProxy {
    weak var coordinator: ScrollCoordinator4p3?

    @objc func tick() {
        coordinator?.displayLinkTick()
    }
}

// MARK: - Scroll Coordinator

class ScrollCoordinator4p3: NSObject, UIScrollViewDelegate, ObservableObject {
    private var scrollViews: [Int: UIScrollView] = [:]
    private var isSyncing = false
    private var dragStartOffsets: [Int: CGFloat] = [:]
    private var dragStartOffset: CGFloat = 0
    private var activeIndex: Int?

    // Tap filtering — timestamp instead of stale boolean flag
    private var lastScrollStopTime: CFTimeInterval = 0
    private let tapIgnoreThreshold: CFTimeInterval = 0.3

    // Auto-scroll
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var speeds: [Int: CGFloat] = [:]
    private var isUserInteracting = false
    private var resumeTask: Task<Void, Never>?
    private var needsInitialCenter = true

    // Infinite scroll
    private var repeatCount = 5
    private var chipSpacing: CGFloat = 10

    deinit {
        stopAutoScroll()
        resumeTask?.cancel()
    }

    // MARK: - Registration

    func register(_ scrollView: UIScrollView, index: Int) {
        guard scrollViews[index] !== scrollView else { return }
        scrollViews[index] = scrollView
        scrollView.delegate = self
        scrollView.tag = index
    }

    // MARK: - Configuration

    func configure(rowCount: Int, repeatCount: Int, chipSpacing: CGFloat) {
        self.repeatCount = repeatCount
        self.chipSpacing = chipSpacing
        if rowCount == 2 {
            speeds = [0: -0.5, 1: -0.8]
        } else {
            speeds = [0: -0.4, 1: -0.6, 2: -0.9]
        }
    }

    // MARK: - Auto-scroll

    func startAutoScroll() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy()
        proxy.coordinator = self
        displayLinkProxy = proxy
        displayLink = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
    }

    func displayLinkTick() {
        // Center all rows once layout is ready
        if needsInitialCenter {
            let allReady = !scrollViews.isEmpty && scrollViews.values.allSatisfy {
                $0.contentSize.width > $0.bounds.width
            }
            if allReady {
                for sv in scrollViews.values {
                    sv.contentOffset.x = (sv.contentSize.width - sv.bounds.width) / 2
                }
                needsInitialCenter = false
            }
        }

        // Reposition for infinite scroll — runs every frame, skips actively dragged row
        isSyncing = true
        for (index, scrollView) in scrollViews {
            // Don't reposition the scroll view the user's finger is on
            guard !scrollView.isTracking else { continue }

            let period = (scrollView.contentSize.width + chipSpacing) / CGFloat(repeatCount)
            let maxOffset = scrollView.contentSize.width - scrollView.bounds.width
            guard period > 0, maxOffset > period else { continue }

            let upperThreshold = maxOffset - period / 2
            let lowerThreshold = period / 2

            var x = scrollView.contentOffset.x
            var adjustment: CGFloat = 0
            if x > upperThreshold { adjustment = -period }
            else if x < lowerThreshold { adjustment = period }

            if adjustment != 0 {
                scrollView.contentOffset.x += adjustment

                // Keep drag tracking in sync so delta calculation stays correct
                if let start = dragStartOffsets[index] {
                    dragStartOffsets[index] = start + adjustment
                }
                if index == activeIndex {
                    dragStartOffset += adjustment
                }
            }
        }
        isSyncing = false

        // Auto-scroll movement — only when user is not interacting
        guard !isUserInteracting else { return }

        isSyncing = true
        for (index, scrollView) in scrollViews {
            guard let speed = speeds[index] else { continue }
            scrollView.contentOffset.x -= speed
        }
        isSyncing = false
    }

    // MARK: - Tap handling

    func shouldHandleTap() -> Bool {
        CACurrentMediaTime() - lastScrollStopTime > tapIgnoreThreshold
    }

    // MARK: - Resume logic

    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            let anyScrolling = scrollViews.values.contains {
                $0.isDragging || $0.isDecelerating
            }
            if !anyScrolling {
                isUserInteracting = false
            }
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resumeTask?.cancel()
        isUserInteracting = true
        activeIndex = scrollView.tag

        // Kill deceleration on all other scroll views
        for (_, sv) in scrollViews where sv !== scrollView {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }

        dragStartOffset = scrollView.contentOffset.x
        dragStartOffsets = scrollViews.mapValues { $0.contentOffset.x }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleResume()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing else { return }
        guard !dragStartOffsets.isEmpty else { return }

        // Detect tap-to-stop on another row
        for (_, sv) in scrollViews where sv !== scrollView {
            if sv.isTracking {
                isSyncing = true
                lastScrollStopTime = CACurrentMediaTime()
                for (_, otherSV) in scrollViews {
                    otherSV.setContentOffset(otherSV.contentOffset, animated: false)
                }
                isSyncing = false
                scheduleResume()
                return
            }
        }

        // Delta-based sync
        isSyncing = true
        let delta = scrollView.contentOffset.x - dragStartOffset

        for (index, sv) in scrollViews where sv !== scrollView {
            guard let startX = dragStartOffsets[index] else { continue }
            let newX = startX + delta
            let maxX = sv.contentSize.width - sv.bounds.width
            if newX >= 0 && newX <= maxX {
                sv.contentOffset.x = newX
            }
        }
        isSyncing = false
    }
}

// MARK: - Chip View

struct ChipView4p3: View {
    let chip: Chip4p3

    var body: some View {
        Text(chip.text)
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.15))
            .foregroundColor(.blue)
            .cornerRadius(20)
    }
}

// MARK: - Chip Row View

struct ChipRowView4p3: View {
    let chips: [Chip4p3]
    let index: Int
    let coordinator: ScrollCoordinator4p3
    let onTap: (Chip4p3) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView4p3(chip: chip)
                        .onTapGesture {
                            guard coordinator.shouldHandleTap() else { return }
                            onTap(chip)
                        }
                }
            }
        }
        .frame(height: 52)
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            coordinator.register(scrollView, index: index)
        }
    }
}

// MARK: - Main View

struct ContentView4point3: View {
    private var repeatCount: Int {
        let chipsPerRow: Int
        if backendChips.count < rowCount {
            chipsPerRow = backendChips.count
        } else {
            chipsPerRow = Int(ceil(Double(backendChips.count) / Double(rowCount)))
        }
        let estimatedSetWidth = CGFloat(chipsPerRow) * 170
        let screenWidth = UIScreen.main.bounds.width
        // Need (R-1) * setWidth > screenWidth for repositioning to have room
        let minRepeats = Int(ceil(1 + screenWidth / estimatedSetWidth)) + 2
        return max(minRepeats, 5)
    }

    private let backendChips = [
        "Check my balance"
    ]

    @State private var rows: [[Chip4p3]] = []
    @StateObject private var coordinator = ScrollCoordinator4p3()

    private var rowCount: Int {
        backendChips.count < 15 ? 2 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, chips in
                    ChipRowView4p3(chips: chips, index: index, coordinator: coordinator) { chip in
                        print("Tapped: \(chip.text)")
                    }
                }
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            setupRows()
            coordinator.configure(rowCount: rowCount, repeatCount: repeatCount, chipSpacing: 10)
            coordinator.startAutoScroll()
        }
        .onDisappear {
            coordinator.stopAutoScroll()
        }
    }

    private func setupRows() {
        var baseRows: [[String]] = []

        if backendChips.count < rowCount {
            for _ in 0..<rowCount {
                baseRows.append(backendChips)
            }
        } else {
            let chipsPerRow = Int(ceil(Double(backendChips.count) / Double(rowCount)))
            for rowIndex in 0..<rowCount {
                let startIndex = rowIndex * chipsPerRow
                let endIndex = min(startIndex + chipsPerRow, backendChips.count)
                baseRows.append(Array(backendChips[startIndex..<endIndex]))
            }
        }

        rows = baseRows.map { baseChips in
            (0..<repeatCount).flatMap { repeatIndex in
                baseChips.enumerated().map { chipIndex, text in
                    Chip4p3(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}
