import AppKit

@MainActor
private func runMembrow() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}

MainActor.assumeIsolated {
    runMembrow()
}
