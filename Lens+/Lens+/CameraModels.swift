import SwiftUI

enum CameraMode: String, CaseIterable, Identifiable {
    case photo = "사진"
    case video = "비디오"

    var id: String { rawValue }
}

enum CameraFlashMode: String, CaseIterable, Identifiable {
    case auto = "자동"
    case on = "켬"
    case off = "끔"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .auto:
            "bolt.badge.a"
        case .on:
            "bolt.fill"
        case .off:
            "bolt.slash.fill"
        }
    }
}

enum CameraPosition: Equatable, Sendable {
    case front
    case back
}

enum CameraPermissionState: Equatable {
    case unknown
    case authorized
    case denied(String)
}

enum RecentMediaKind {
    case photo
    case video
}

struct RecentMedia: Identifiable {
    let id = UUID()
    let kind: RecentMediaKind
    let assetIdentifier: String
    let thumbnail: UIImage
}

struct FocusIndicator: Identifiable {
    let id = UUID()
    let point: CGPoint
}
