//
//  ContentView2.swift
//  suggest
//
//  Created by Rookly on 14.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

struct Chip: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

struct ChipView2: View {
    let chip: Chip

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

struct ChipRowView2: View {
    let chips: [Chip]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
//            LazyHGrid(rows: [.init()]) {
                ForEach(chips) { chip in
                    ChipView2(chip: chip)
                        .onTapGesture {
                            print("ok")
                        }
                }
            }
//            .padding(.horizontal)
        }
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            scrollView.isScrollEnabled = false
        }
    }
}

struct ContentView2: View {
    private let repeatCount = 30
    private let baseRow1 = ["Check my balance", "Recent transactions", "Transfer money", "Pay bills", "Card limits"]
    private let baseRow2 = ["Open new account", "Exchange rates", "Find ATM nearby", "Block my card", "Loan calculator"]

    @State private var row1: [Chip] = []
    @State private var row2: [Chip] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 10) {
                    ChipRowView2(chips: row1)
                    ChipRowView2(chips: row2)
                }
            }
            .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
                DispatchQueue.main.async {
                    scrollView.contentOffset.x = (scrollView.contentSize.width - scrollView.bounds.width) / 2
                }
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            row1 = (0..<repeatCount).flatMap { repeatIndex in
                baseRow1.enumerated().map { index, text in
                    Chip(text, index: repeatIndex * baseRow1.count + index)
                }
            }
            row2 = (0..<repeatCount).flatMap { repeatIndex in
                baseRow2.enumerated().map { index, text in
                    Chip(text, index: repeatIndex * baseRow2.count + index)
                }
            }
        }
    }
}

#Preview {
    ContentView2()
}
