import SwiftUI

struct StarRatingView: View {
    @Binding var rating: Int
    var interactive: Bool = true
    private let max = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...max, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(star <= rating ? .yellow : .secondary.opacity(0.4))
                    .onTapGesture {
                        guard interactive else { return }
                        rating = star == rating ? 0 : star
                    }
            }
        }
    }
}
