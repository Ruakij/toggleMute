import Foundation

/// Settings read outside the popover. The popover binds the rest directly
/// via @AppStorage.
struct Preferences {

    var pushToTalkEnabled: Bool {
        UserDefaults.standard.bool(forKey: #function)
    }

}
