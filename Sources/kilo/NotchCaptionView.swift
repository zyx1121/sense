import SwiftUI

/// 瀏海字幕：瀏海正下方單行，逐字打字機；當前段白(final)/灰(volatile)，不累積。
/// 展開 / 收合用 scale（從瀏海被遮擋的大小擴增出去）+ opacity。
struct NotchCaptionView: View {
    let model: CaptionModel

    var body: some View {
        Text(model.shown)
            .foregroundStyle(model.isFinal ? .white : .gray)
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .background(.black)
            .clipShape(.rect(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            .scaleEffect(model.visible ? 1 : 0.5, anchor: .top)  // 從瀏海縮放出 / 收回
            .opacity(model.visible ? 1 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: model.visible)
    }
}
