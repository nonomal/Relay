//
//  MacToast.swift
//  RelayMac
//

import SwiftUI

struct MacToast: View {
    @EnvironmentObject var toastManager: ToastManager

    var body: some View {
        ZStack {
            if let loading = toastManager.loadingMessage {
                loadingPill(loading)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if toastManager.isShowing {
                toastPill(toastManager.message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastManager.isShowing)
        .animation(.easeInOut(duration: 0.25), value: toastManager.loadingMessage)
    }

    private func toastPill(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(background)
    }

    private func loadingPill(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(background)
    }

    @ViewBuilder
    private var background: some View {
        // `glassEffect` only exists in the macOS 26 SDK (Xcode 26 / Swift 6.2), so it
        // needs the compile-time guard in addition to the runtime `#available`.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            legacyCapsule
                .glassEffect(.regular, in: .capsule)
        } else {
            legacyCapsule
        }
        #else
        legacyCapsule
        #endif
    }

    private var legacyCapsule: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.15), radius: 16, y: 4)
    }
}
