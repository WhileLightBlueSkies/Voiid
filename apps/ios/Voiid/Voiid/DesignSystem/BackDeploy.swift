//
//  BackDeploy.swift
//  Voiid
//
//  Shims for modern SwiftUI APIs so UI code compiles and runs cleanly on all target iOS versions.
//

import SwiftUI

extension View {

    /// The soft fade where content meets floating chrome.
    @ViewBuilder
    func softScrollEdge(_ edge: Edge.Set = .top) -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: edge)
        } else {
            self
        }
    }

    /// A translucent circular control.
    @ViewBuilder
    func glassCircle(size: CGFloat = 40) -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        } else {
            self
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    /// The screen's one primary button: Liquid Glass on iOS 26, the bordered-prominent capsule
    /// it replaced on 18. Tide either way.
    @ViewBuilder
    func prominentAction() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).controlSize(.large).tint(VoiidColor.accent)
        } else {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .controlSize(.large).tint(VoiidColor.accent)
        }
    }
}
