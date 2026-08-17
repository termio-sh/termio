import Foundation

extension Notification.Name {
    /// ⌘F broadcast. Broadcast instead of the responder chain so the menu item stays enabled
    /// whenever an editor is on screen even if the terminal holds first responder.
    static let termioShowFindBar = Notification.Name("termio.showFindBar")
}
