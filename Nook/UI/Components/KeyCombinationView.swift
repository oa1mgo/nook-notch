//
//  KeyCombinationView.swift
//  Nook
//
//  Badge chip for a single key combination display
//

import SwiftUI

struct KeyCombinationView: View {
    let combination: KeyCombination
    var onRemove: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            Text(combination.displayString)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            if onRemove != nil {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Remove this shortcut")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(isHovered ? 0.15 : 0.1))
        )
        .onHover { isHovered = $0 }
    }
}
