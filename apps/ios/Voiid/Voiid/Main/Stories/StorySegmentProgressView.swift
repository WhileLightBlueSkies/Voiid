//
//  StorySegmentProgressView.swift
//  Voiid
//
//  The segmented progress bar pinned to the top of the story viewer: one capsule per story
//  in the current context. Played = solid white; playing = white clipped to `progress`;
//  unplayed = dim. Driven by an explicit progress value (a 30 Hz tick in the viewer), NOT
//  by animation interpolation, so pause/resume is exact.
//

import SwiftUI

struct StorySegmentProgressView: View {
    let count: Int
    let currentIndex: Int
    /// 0...1 fill of the CURRENT segment. Segments before it are full, after it are empty.
    let progress: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.35))
                        Capsule().fill(Color.white)
                            .frame(width: geo.size.width * fill(for: i))
                    }
                }
                .frame(height: 2.5)
            }
        }
    }

    private func fill(for i: Int) -> Double {
        if i < currentIndex { return 1 }
        if i > currentIndex { return 0 }
        return min(max(progress, 0), 1)
    }
}
