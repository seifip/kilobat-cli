import Foundation

/// Whether focus should be visible: only while the keyboard is being used to move focus, never after a click or
/// when a window opens. The same rule browsers call focus-visible.
public struct FocusVisibility: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        /// A key went down; `keyCode` is the hardware code (48 is Tab), `command` whether ⌘ was held.
        case key(keyCode: UInt16, command: Bool)
        /// A mouse or trackpad button went down.
        case pointer
    }
    public private(set) var keyboard = false
    public init() {}
    public static let tab: UInt16 = 48
    /// Tab and Shift-Tab turn it on; a click turns it off; every other key leaves it as it is, so typing in
    /// a field or pressing Space on a focused button changes nothing. ⌘-Tab (switching apps) is not navigation.
    public mutating func note(_ input: Input) {
        switch input {
        case .pointer: keyboard = false
        case .key(let keyCode, let command): if keyCode == Self.tab && !command { keyboard = true }
        }
    }
    /// A control shows that it has focus when it has it and the keyboard is in use.
    public func showsOutline(focused: Bool) -> Bool { focused && keyboard }
}
