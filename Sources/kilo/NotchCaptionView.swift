import SwiftUI

/// 瀏海字幕：瀏海正下方一條，單行，final 白 / volatile 灰。
struct NotchCaptionView: View {
    let model: CaptionModel

    var body: some View {
        HStack(spacing: 0) {
            Text(model.finalized).foregroundStyle(.white)
            Text(model.volatile).foregroundStyle(.gray)
        }
        .font(.system(size: 15, weight: .medium))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)  // 靠瀏海下緣
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(.black)
        .clipShape(.rect(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
    }
}
