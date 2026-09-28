import CoreGraphics
import Foundation
import Testing
@testable import ScreenSwapMac

@Test
@MainActor
func auxiliaryWindowsCenterInTheMainDisplayVisibleArea() {
    let origin = AuxiliaryWindowPresenter.centeredOrigin(
        windowSize: CGSize(width: 300, height: 200),
        in: CGRect(x: 50, y: 30, width: 1_000, height: 700)
    )
    #expect(origin == CGPoint(x: 400, y: 280))
}

@Test
@MainActor
func aboutWindowExposesProjectAndKoFiLinks() {
    #expect(AboutWindowController.githubURL == URL(string: "https://github.com/nguyen113/ScreenSwap-Gpt")!)
    #expect(AboutWindowController.supportURL == URL(string: "https://ko-fi.com/C3N027TX55")!)
}
