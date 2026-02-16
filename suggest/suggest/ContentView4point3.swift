//
//  ContentView4point3.swift
//  suggest
//
//  Created by Rookly on 15.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Модель

/// Модель одного чипа-подсказки
struct Chip4p3: Identifiable {
    /// Уникальный идентификатор (текст + индекс, чтобы повторы не конфликтовали)
    let id: String
    /// Отображаемый текст чипа
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Target (слабая ссылка разрывает retain cycle CADisplayLink)

/// Прокси-объект для CADisplayLink.
/// CADisplayLink сильно удерживает свой target — если передать self напрямую,
/// возникает retain cycle. Этот объект держит weak-ссылку на behavior.
private class DisplayLinkTarget4p3 {
    /// Слабая ссылка на координатор скролла
    weak var behavior: ChipInfiniteScrollBehavior?

    /// Вызывается каждый кадр экрана (~60-120 FPS)
    @objc func tick() {
        behavior?.onFrame()
    }
}

// MARK: - Поведение бесконечного скролла чипов

/// Координирует авто-скролл, синхронизацию строк, бесконечный скролл (репозиционирование)
/// и обработку пользовательских жестов для всех строк чипов.
class ChipInfiniteScrollBehavior: NSObject, UIScrollViewDelegate, ObservableObject {

    /// Зарегистрированные scroll view по индексу строки
    private var scrollViews: [Int: UIScrollView] = [:]
    /// Флаг блокировки — предотвращает бесконечную рекурсию при программном изменении offset
    private var isSyncing = false

    // -- Состояние перетаскивания --

    /// Начальная позиция X активной (перетаскиваемой) строки в момент начала drag
    private var dragOriginX: CGFloat = 0
    /// Начальные позиции X всех строк в момент начала drag (для расчёта дельты)
    private var allDragOrigins: [Int: CGFloat] = [:]
    /// Индекс строки, которую пользователь сейчас тянет
    private var draggedRowIndex: Int?

    // -- Фильтрация тапов --

    /// Время последней остановки скролла тапом (чтобы не срабатывал onTapGesture на чипе)
    private var lastTapStopTime: CFTimeInterval = 0
    /// Минимальный интервал после остановки скролла, в течение которого тапы игнорируются
    private let tapIgnoreWindow: CFTimeInterval = 0.3

    // -- Авто-скролл --

    /// CADisplayLink для покадровой анимации авто-скролла
    private var displayLink: CADisplayLink?
    /// Скорость авто-скролла для каждой строки (отрицательная = влево)
    private var rowSpeeds: [Int: CGFloat] = [:]
    /// Флаг: пользователь сейчас взаимодействует со скроллом (авто-скролл приостановлен)
    private var isUserScrolling = false
    /// Задача отложенного возобновления авто-скролла (2 сек после окончания взаимодействия)
    private var resumeTask: Task<Void, Never>?
    /// Флаг: нужно отцентрировать строки при первом появлении
    private var needsCentering = true

    // -- Бесконечный скролл --

    /// Сколько раз повторяется набор чипов в каждой строке
    private var repeatCount = 5
    /// Расстояние между чипами (нужно для расчёта ширины одного периода)
    private var chipSpacing: CGFloat = 10

    deinit {
        stop()
    }

    // MARK: - Публичный API

    /// Регистрирует UIScrollView для конкретной строки.
    /// Вызывается из Introspect при первом появлении каждой строки.
    func register(_ scrollView: UIScrollView, rowIndex: Int) {
        guard scrollViews[rowIndex] !== scrollView else { return }
        scrollViews[rowIndex] = scrollView
        scrollView.delegate = self
        scrollView.tag = rowIndex
    }

    /// Запускает авто-скролл: настраивает скорости строк и создаёт CADisplayLink.
    func start(rowCount: Int, repeatCount: Int, chipSpacing: CGFloat) {
        self.repeatCount = repeatCount
        self.chipSpacing = chipSpacing
        configureRowSpeeds(rowCount: rowCount)
        startDisplayLink()
    }

    /// Останавливает авто-скролл и отменяет задачу возобновления.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resumeTask?.cancel()
    }

    /// Проверяет, можно ли обработать тап по чипу.
    /// Возвращает false если скролл был только что остановлен тапом (защита от ложных срабатываний).
    func shouldHandleTap() -> Bool {
        CACurrentMediaTime() - lastTapStopTime > tapIgnoreWindow
    }

    // MARK: - Конфигурация

    /// Задаёт скорости авто-скролла для каждой строки.
    /// Нижние строки скроллятся быстрее для визуального эффекта глубины.
    private func configureRowSpeeds(rowCount: Int) {
        if rowCount == 2 {
            rowSpeeds = [0: -0.5, 1: -0.8]
        } else {
            rowSpeeds = [0: -0.4, 1: -0.6, 2: -0.9]
        }
    }

    // MARK: - Display Link

    /// Создаёт и запускает CADisplayLink через прокси-объект (для избежания retain cycle).
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget4p3()
        target.behavior = self
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget4p3.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Вызывается каждый кадр. Последовательно:
    /// 1. Центрирует строки (один раз при первом появлении)
    /// 2. Репозиционирует для бесконечного скролла
    /// 3. Двигает авто-скролл (если пользователь не взаимодействует)
    func onFrame() {
        centerRowsIfNeeded()
        repositionForInfiniteScroll()

        guard !isUserScrolling else { return }
        advanceAutoScroll()
    }

    // MARK: - Центрирование

    /// При первом появлении ставит все строки в центр контента,
    /// чтобы бесконечный скролл работал в обе стороны.
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

    // MARK: - Репозиционирование (бесконечный скролл)

    /// Проверяет каждую строку: если offset ушёл слишком далеко вправо или влево,
    /// прыгает на один период назад/вперёд. Контент повторяется — прыжок незаметен.
    private func repositionForInfiniteScroll() {
        isSyncing = true
        for (index, scrollView) in scrollViews {
            // Не репозиционируем строку, которую пользователь держит пальцем
            guard !scrollView.isTracking else { continue }

            let period = (scrollView.contentSize.width + chipSpacing) / CGFloat(repeatCount)
            let maxOffset = scrollView.contentSize.width - scrollView.bounds.width
            guard period > 0, maxOffset > period else { continue }

            let adjustment = calculateRepositionAdjustment(
                offsetX: scrollView.contentOffset.x,
                maxOffset: maxOffset,
                period: period
            )

            if adjustment != 0 {
                scrollView.contentOffset.x += adjustment
                adjustDragOrigins(forRow: index, by: adjustment)
            }
        }
        isSyncing = false
    }

    /// Вычисляет на сколько нужно прыгнуть: -period (назад), +period (вперёд) или 0 (не нужно).
    /// Пороги: верхний = maxOffset - period/2, нижний = period/2.
    private func calculateRepositionAdjustment(offsetX: CGFloat, maxOffset: CGFloat, period: CGFloat) -> CGFloat {
        let upperThreshold = maxOffset - period / 2
        let lowerThreshold = period / 2

        if offsetX > upperThreshold { return -period }
        if offsetX < lowerThreshold { return period }
        return 0
    }

    /// После прыжка корректирует сохранённые начальные позиции drag,
    /// чтобы дельта-синхронизация не сломалась.
    private func adjustDragOrigins(forRow index: Int, by adjustment: CGFloat) {
        if let start = allDragOrigins[index] {
            allDragOrigins[index] = start + adjustment
        }
        if index == draggedRowIndex {
            dragOriginX += adjustment
        }
    }

    // MARK: - Авто-скролл

    /// Двигает каждую строку на её скорость (вызывается каждый кадр, когда пользователь не скроллит).
    private func advanceAutoScroll() {
        isSyncing = true
        for (index, scrollView) in scrollViews {
            guard let speed = rowSpeeds[index] else { continue }
            scrollView.contentOffset.x -= speed
        }
        isSyncing = false
    }

    // MARK: - Возобновление авто-скролла

    /// Через 2 секунды после окончания взаимодействия возобновляет авто-скролл.
    /// Если пользователь начнёт скроллить снова — задача отменится.
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

    // MARK: - Хелперы синхронизации скролла

    /// Останавливает все строки и запоминает время остановки (для фильтрации тапов).
    /// Используется когда пользователь тапает по другой строке чтобы остановить инерцию.
    private func stopAllRows() {
        isSyncing = true
        lastTapStopTime = CACurrentMediaTime()
        for (_, sv) in scrollViews {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }
        isSyncing = false
    }

    /// Останавливает инерцию всех строк кроме указанной.
    /// Вызывается в начале нового drag, чтобы другие строки не «боролись» с синхронизацией.
    private func stopOtherRows(except scrollView: UIScrollView) {
        for (_, sv) in scrollViews where sv !== scrollView {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }
    }

    /// Синхронизирует остальные строки с активной по дельте.
    /// Дельта = текущий offset активной строки - её начальный offset.
    /// Все остальные строки сдвигаются на ту же дельту от своих начальных позиций.
    private func syncOtherRows(to scrollView: UIScrollView) {
        let delta = scrollView.contentOffset.x - dragOriginX

        for (index, sv) in scrollViews where sv !== scrollView {
            guard let startX = allDragOrigins[index] else { continue }
            let newX = startX + delta
            let maxX = sv.contentSize.width - sv.bounds.width
            if newX >= 0 && newX <= maxX {
                sv.contentOffset.x = newX
            }
        }
    }

    /// Проверяет, касается ли пользователь какой-либо другой строки (кроме указанной).
    /// Нужно для обнаружения «тап-остановки» — когда пользователь тапает по другой строке
    /// чтобы остановить инерцию.
    private func anotherRowIsTracking(except scrollView: UIScrollView) -> Bool {
        scrollViews.values.contains { $0 !== scrollView && $0.isTracking }
    }

    // MARK: - UIScrollViewDelegate

    /// Пользователь начал тянуть строку.
    /// Приостанавливаем авто-скролл, останавливаем инерцию других строк,
    /// запоминаем начальные позиции всех строк для дельта-синхронизации.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resumeTask?.cancel()
        isUserScrolling = true
        draggedRowIndex = scrollView.tag
        stopOtherRows(except: scrollView)

        dragOriginX = scrollView.contentOffset.x
        allDragOrigins = scrollViews.mapValues { $0.contentOffset.x }
    }

    /// Пользователь отпустил палец. Если инерции нет — планируем возобновление авто-скролла.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleAutoScrollResume()
        }
    }

    /// Инерция закончилась — планируем возобновление авто-скролла.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleAutoScrollResume()
    }

    /// Вызывается при каждом изменении offset (и при drag, и при инерции).
    /// Если другая строка отслеживается (тап-остановка) — останавливаем всё.
    /// Иначе — синхронизируем остальные строки по дельте.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing, !allDragOrigins.isEmpty else { return }

        if anotherRowIsTracking(except: scrollView) {
            stopAllRows()
            scheduleAutoScrollResume()
            return
        }

        isSyncing = true
        syncOtherRows(to: scrollView)
        isSyncing = false
    }
}

// MARK: - Вью чипа

/// Отображение одного чипа-подсказки (текст в закруглённом прямоугольнике)
struct ChipView4p3: View {
    /// Модель чипа
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

/// Горизонтальный ScrollView с чипами одной строки.
/// Через Introspect получает UIScrollView и регистрирует его в behavior.
struct ChipRowView4p3: View {
    /// Массив чипов для отображения (уже с повторами для бесконечного скролла)
    let chips: [Chip4p3]
    /// Индекс строки (0, 1 или 2)
    let rowIndex: Int
    /// Координатор скролла — управляет авто-скроллом, синхронизацией и репозиционированием
    let behavior: ChipInfiniteScrollBehavior
    /// Колбэк при тапе на чип
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

/// Экран с подсказками: заголовок + 2-3 строки горизонтально скроллящихся чипов.
/// Использует бесконечный скролл через репозиционирование (repeatCount = 5).
struct ContentView4point3: View {
    /// Сколько раз повторять набор чипов (5 достаточно при репозиционировании)
    private let repeatCount = 5

    /// Подсказки с бэкенда (банковская тематика)
    private let backendChips = [
        "Check balance",
        "Recent transactions",
        "Transfer money",
        "Pay bills",
        "Card limits",
        "Open account",
        "Exchange rates",
        "Find ATM",
        "Block card",
        "Loan calculator",
        "Savings goal",
        "Credit score",
        "Direct debit",
        "Standing order",
        "Travel insurance",
        "Cashback offers",
        "Overdraft limit",
        "Mortgage rates",
        "Investment plans",
        "Report fraud",
        "Close account"
    ]

    /// Готовые строки чипов (с повторами) для отображения
    @State private var rows: [[Chip4p3]] = []
    /// Координатор поведения скролла
    @StateObject private var behavior = ChipInfiniteScrollBehavior()

    /// Количество строк: 2 если чипов < 15, иначе 3
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

    /// Разбивает backendChips на строки и повторяет каждую repeatCount раз.
    /// Если чипов меньше чем строк — каждая строка получает все чипы.
    /// Иначе — чипы делятся последовательно (1-7 → строка 0, 8-14 → строка 1, 15-21 → строка 2).
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

// MARK: - Синхронизация по скоростям (альтернатива дельта-синхронизации в scrollViewDidScroll)
// Когда пользователь скроллит, каждая строка движется пропорционально своей скорости авто-скролла.
// Заменить вызов syncOtherRows(to:) в scrollViewDidScroll на это:
//
//        guard let dragIdx = draggedRowIndex,
//              let draggedSpeed = rowSpeeds[dragIdx],
//              draggedSpeed != 0 else { return }
//
//        isSyncing = true
//        let delta = scrollView.contentOffset.x - dragOriginX
//
//        for (index, sv) in scrollViews where sv !== scrollView {
//            guard let startX = allDragOrigins[index] else { continue }
//            guard let targetSpeed = rowSpeeds[index] else { continue }
//
//            let ratio = abs(targetSpeed) / abs(draggedSpeed)
//            let newX = startX + delta * ratio
//            let maxX = sv.contentSize.width - sv.bounds.width
//            if newX >= 0 && newX <= maxX {
//                sv.contentOffset.x = newX
//            }
//        }
//        isSyncing = false
