import SwiftUI

struct BroadcastBadgeTextRenderer: TextRenderer {
    var displayPadding: EdgeInsets {
        EdgeInsets()
    }

    func sizeThatFits(proposal: ProposedViewSize, text: TextProxy) -> CGSize {
        text.sizeThatFits(proposal)
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if let badge = run[BroadcastBadgeTextAttribute.self] {
                    let typographicRect = run.typographicBounds.rect
                    let badgeRect: CGRect
                    if badge.isSingleCharacter {
                        let side = floor(typographicRect.height * 0.82)
                        badgeRect = CGRect(
                            x: typographicRect.midX - side / 2,
                            y: typographicRect.midY - side / 2,
                            width: side,
                            height: side
                        )
                    } else {
                        let width = floor(typographicRect.width * 0.86)
                        let height = floor(typographicRect.height * 0.8)
                        badgeRect = CGRect(
                            x: typographicRect.midX - width / 2,
                            y: typographicRect.midY - height / 2,
                            width: width,
                            height: height
                        )
                    }

                    let path = Path(
                        roundedRect: badgeRect,
                        cornerRadius: min(2.4, badgeRect.height * 0.14),
                        style: .continuous
                    )
                    ctx.stroke(path, with: .color(.primary.opacity(0.62)), lineWidth: 0.9)

                    var badgeContext = ctx
                    let center = CGPoint(x: typographicRect.midX, y: typographicRect.midY)
                    let scale: CGFloat = badge.isSingleCharacter ? 0.78 : 0.74
                    badgeContext.translateBy(x: center.x, y: center.y)
                    badgeContext.scaleBy(x: scale, y: scale)
                    badgeContext.translateBy(x: -center.x, y: -center.y)
                    badgeContext.draw(run, options: .disablesSubpixelQuantization)
                    continue
                }

                ctx.draw(run, options: .disablesSubpixelQuantization)
            }
        }
    }
}
