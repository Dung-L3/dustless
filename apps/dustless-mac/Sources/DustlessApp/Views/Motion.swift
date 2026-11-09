import SwiftUI

enum Motion {
    static let micro = Animation.easeOut(duration: 0.14)
    static let control = Animation.spring(response: 0.26, dampingFraction: 0.86)
    static let section = Animation.spring(response: 0.34, dampingFraction: 0.88)
    static let sheet = Animation.easeOut(duration: 0.3)
    static let fade = Animation.easeOut(duration: 0.16)
    static let staggerStep = 0.024
    static let staggerLimit = 8

    static func gated(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func content(_ reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .identity : .opacity
    }

    static func stagger(_ index: Int) -> Double {
        Double(min(max(index, 0), staggerLimit - 1)) * staggerStep
    }
}
