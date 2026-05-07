import SwiftUI

@main
struct RefVaultApp: App {
    var body: some Scene {
        WindowGroup("RefVault") {
            MainWindow()
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
