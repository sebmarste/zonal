import Foundation

enum DefaultProfiles {
    static let main = DisplayProfile(
        id: "main",
        name: "Main",
        mainZoneID: .main,
        zones: [
            Zone(
                id: .main,
                name: "Main",
                frame: .full
            )
        ]
    )
}
