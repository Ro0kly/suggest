//
//  ContentView4point3.swift
//  suggest
//
//  Created by Rookly on 15.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Модель

struct Chip4p3: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Target (weak proxy разрывает retain cycle CADisplayLink)

private class DisplayLinkTarget4p3 {
    weak var behavior: ChipInfiniteScrollBehavior?

    @objc func tick() {
        behavior?.onFrame()
    }
}

// MARK: - Поведение бесконечного скролла чипов

/// Координирует авто-скролл, синхронизацию строк, бесконечный скролл
/// и обработку пользовательских жестов для всех строк чипов.
/// ObservableObject без @Published — намеренно: нужен для @StateObject,
/// но SwiftUI state system не используется (всё через Core Animation).
class ChipInfiniteScrollBehavior: NSObject, UIScrollViewDelegate, ObservableObject {

    private var scrollViews: [Int: UIScrollView] = [:]
    private var isSyncing = false

    /// Начальные позиции X всех строк в момент начала drag (для дельта-синхронизации).
    /// Пустой = нет активного drag/deceleration.
    private var allDragOrigins: [Int: CGFloat] = [:]

    private var lastTapStopTime: CFTimeInterval = 0
    private let tapIgnoreWindow: CFTimeInterval = 0.3

    private var displayLink: CADisplayLink?
    private var rowSpeeds: [Int: CGFloat] = [:]
    private var isUserScrolling = false
    private var resumeTask: Task<Void, Never>?
    private var needsCentering = true

    private var repeatCount = 0
    private var chipSpacing: CGFloat = 0

    deinit { stop() }

    // MARK: - Публичный API

    func register(_ scrollView: UIScrollView, rowIndex: Int) {
        guard scrollViews[rowIndex] !== scrollView else { return }
        scrollViews[rowIndex] = scrollView
        scrollView.delegate = self
        scrollView.tag = rowIndex
    }

    func start(rowCount: Int, repeatCount: Int, chipSpacing: CGFloat) {
        self.repeatCount = repeatCount
        self.chipSpacing = chipSpacing
        rowSpeeds = rowCount == 2
            ? [0: -0.5, 1: -0.8]
            : [0: -0.4, 1: -0.6, 2: -0.9]

        guard displayLink == nil else { return }
        let target = DisplayLinkTarget4p3()
        target.behavior = self
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget4p3.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resumeTask?.cancel()
    }

    /// Возвращает false если скролл был только что остановлен тапом (защита от ложных срабатываний).
    func shouldHandleTap() -> Bool {
        CACurrentMediaTime() - lastTapStopTime > tapIgnoreWindow
    }

    // MARK: - Per-frame

    func onFrame() {
        centerRowsIfNeeded()
        repositionForInfiniteScroll()

        guard !isUserScrolling else { return }
        advanceAutoScroll()
    }

    /// Один раз при старте ставит все строки в центр контента.
    private func centerRowsIfNeeded() {
        guard needsCentering else { return }

        let allReady = !scrollViews.isEmpty && scrollViews.values.allSatisfy {
            $0.contentSize.width > $0.bounds.width
        }
        guard allReady else { return }

        for sv in scrollViews.values {
            sv.contentOffset.x = (sv.contentSize.width - sv.bounds.width) / 2
        }
        needsCentering = false
    }

    /// Если offset строки ушёл далеко — прыгает на ±1 период. Контент повторяется, прыжок незаметен.
    private func repositionForInfiniteScroll() {
        isSyncing = true
        for (index, sv) in scrollViews {
            guard !sv.isTracking else { continue }

            let period = (sv.contentSize.width + chipSpacing) / CGFloat(repeatCount)
            let maxOffset = sv.contentSize.width - sv.bounds.width
            guard period > 0, maxOffset > period else { continue }

            var adjustment: CGFloat = 0
            if sv.contentOffset.x > maxOffset - period / 2 {
                adjustment = -period
            } else if sv.contentOffset.x < period / 2 {
                adjustment = period
            }

            if adjustment != 0 {
                sv.contentOffset.x += adjustment
                allDragOrigins[index]? += adjustment
            }
        }
        isSyncing = false
    }

    private func advanceAutoScroll() {
        isSyncing = true
        for (index, sv) in scrollViews {
            guard let speed = rowSpeeds[index] else { continue }
            sv.contentOffset.x -= speed
        }
        isSyncing = false
    }

    // MARK: - Хелперы

    private func scheduleAutoScrollResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }

            let stillScrolling = scrollViews.values.contains {
                $0.isDragging || $0.isDecelerating
            }
            if !stillScrolling {
                isUserScrolling = false
            }
        }
    }

    /// Останавливает инерцию scroll view. Без параметра — все строки, с параметром — все кроме указанной.
    private func stopRows(except scrollView: UIScrollView? = nil) {
        isSyncing = true
        for (_, sv) in scrollViews where sv !== scrollView {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }
        isSyncing = false
    }

    /// Синхронизирует остальные строки с активной по дельте от начальных позиций.
    private func syncOtherRows(to scrollView: UIScrollView) {
        guard let originX = allDragOrigins[scrollView.tag] else { return }
        let delta = scrollView.contentOffset.x - originX

        for (index, sv) in scrollViews where sv !== scrollView {
            guard let startX = allDragOrigins[index] else { continue }
            let newX = startX + delta
            let maxX = sv.contentSize.width - sv.bounds.width
            if newX >= 0 && newX <= maxX {
                sv.contentOffset.x = newX
            }
        }
    }

    private func anotherRowIsTracking(except scrollView: UIScrollView) -> Bool {
        scrollViews.values.contains { $0 !== scrollView && $0.isTracking }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resumeTask?.cancel()
        isUserScrolling = true
        stopRows(except: scrollView)
        allDragOrigins = scrollViews.mapValues { $0.contentOffset.x }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            allDragOrigins = [:]
            scheduleAutoScrollResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        allDragOrigins = [:]
        scheduleAutoScrollResume()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing, !allDragOrigins.isEmpty else { return }

        isSyncing = true
        syncOtherRows(to: scrollView)
        isSyncing = false

        if anotherRowIsTracking(except: scrollView) {
            lastTapStopTime = CACurrentMediaTime()
            stopRows()
            allDragOrigins = [:]
            scheduleAutoScrollResume()
        }
    }
}

// MARK: - Вью чипа

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

// MARK: - Вью строки чипов

struct ChipRowView4p3: View {
    let chips: [Chip4p3]
    let rowIndex: Int
    let behavior: ChipInfiniteScrollBehavior
    let onTap: (Chip4p3) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView4p3(chip: chip)
                        .onTapGesture {
                            guard behavior.shouldHandleTap() else { return }
                            onTap(chip)
                        }
                }
            }
        }
        .frame(height: 52)
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            behavior.register(scrollView, rowIndex: rowIndex)
        }
    }
}

// MARK: - Главная вью

struct ContentView4point3: View {
    private let repeatCount = 3

//    private let backendChips = [
//        "Check balance",
//        "Recent transactions",
//        "Transfer money",
//        "Pay bills",
//        "Card limits",
//        "Open account",
//        "Exchange rates",
//        "Find ATM",
//        "Block card",
//        "Loan calculator"
//    ]
    
    private let backendChips = (1...21).map { String($0) }

    @State private var rows: [[Chip4p3]] = []
    @StateObject private var behavior = ChipInfiniteScrollBehavior()

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
                    ChipRowView4p3(chips: chips, rowIndex: index, behavior: behavior) { chip in
                        print("Tapped: \(chip.text)")
                    }
                }
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            setupRows()
            behavior.start(rowCount: rowCount, repeatCount: repeatCount, chipSpacing: 10)
        }
        .onDisappear {
            behavior.stop()
        }
    }

    private func setupRows() {
        var baseRows: [[String]] = []

        if backendChips.count <= 3 {
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

        // Во время drag (isTracking = true) repositionForInfiniteScroll пропускает
        // scroll view — пользователь может доскроллить до края контента пальцем.
        // Чтобы этого не случилось, period/2 должен превышать ширину экрана:
        // тогда даже из худшей позиции после репозиционирования (period/2 от края)
        // полный свайп через весь экран не достигнет границы контента.
        // period ≈ baseChips × (minChipWidth + spacing), отсюда:
        // baseChips > 2 × screenWidth / (minChipWidth + spacing).
        let screenWidth = UIScreen.main.bounds.width
        let minChipWidth: CGFloat = 35
        let chipSpacing: CGFloat = 10
        let minBaseChips = Int(ceil(2 * screenWidth / (minChipWidth + chipSpacing)))

        baseRows = baseRows.map { row in
            guard row.count < minBaseChips else { return row }
            let times = Int(ceil(Double(minBaseChips) / Double(row.count)))
            return (0..<times).flatMap { _ in row }
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
