import AppKit
// Stand-in for the app's Motion helpers: Ink.swift references them for its
// drawing-on animation, which the icon renderer never uses.
enum Motion {
    static var enabled = false
    static let inOut = CAMediaTimingFunction(name: .easeInEaseOut)
    static func anim(_ key: String, from: Any?, to: Any?, dur: Double, delay: Double = 0, timing: CAMediaTimingFunction? = nil) -> CABasicAnimation { CABasicAnimation(keyPath: key) }
    static func after(_ s: Double, _ f: @escaping () -> Void) {}
}
