import SwiftUI

/// Settings ▸ Server: this Mac, as a machine sessions run on.
///
/// The same `DevicePane` a remote host pushes, rendered at the top level because
/// there is only ever one of these and a list of one is a door with nothing
/// behind it. That is the whole difference between the two entrances; everything
/// a machine *is* stays described in one place.
///
/// What this promotion actually fixed is the daemon. `DevicePane` spent its local
/// branch on the `termio` command-line tool, so the one `termiod` the user could
/// watch running was the only one whose version the app never showed — and the
/// only one no button could bring current, since every remote is reconciled
/// before each terminal opens and this Mac was reached only by the launch pass.
/// `Set Up` now runs the same lifecycle loop here (`TermioStore.localReadyCheck`).
struct ServerSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        DevicePane(
            machine: .thisMac,
            // All four are the route half, and this machine has no route: there
            // is no `~/.ssh/config` block naming the box you are sitting at, so
            // the pane's "Reached by" section does not render and nothing below
            // can reach these. They are passed rather than defaulted so the
            // remote path can never acquire a silent no-op by accident.
            host: nil,
            settings: settings,
            keyToInstall: nil,
            onConnect: { _ in },
            onSetUpKey: { _, _ in },
            onEditConfig: {}
        )
    }
}
