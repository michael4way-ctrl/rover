import Foundation

final class RoverRequestGate: @unchecked Sendable {
    static let shared = RoverRequestGate()

    private let lock = NSLock()
    private var nextRequestAt = Date.distantPast

    private init() {}

    func waitForTurn() {
        lock.lock()
        let reserved = max(Date(), nextRequestAt)
        nextRequestAt = reserved.addingTimeInterval(0.055)
        lock.unlock()

        let delay = reserved.timeIntervalSinceNow
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
    }
}

enum DriveDirection: String, CaseIterable, Identifiable, Sendable {
    case forwardLeft
    case forward
    case forwardRight
    case left
    case right
    case backLeft
    case back
    case backRight
    case rotateLeft
    case rotateRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forwardLeft: "Вперёд влево"
        case .forward: "Вперёд"
        case .forwardRight: "Вперёд вправо"
        case .left: "Влево"
        case .right: "Вправо"
        case .backLeft: "Назад влево"
        case .back: "Назад"
        case .backRight: "Назад вправо"
        case .rotateLeft: "Разворот влево"
        case .rotateRight: "Разворот вправо"
        }
    }

    var symbol: String {
        switch self {
        case .forwardLeft: "arrow.up.left"
        case .forward: "arrow.up"
        case .forwardRight: "arrow.up.right"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .backLeft: "arrow.down.left"
        case .back: "arrow.down"
        case .backRight: "arrow.down.right"
        case .rotateLeft: "arrow.counterclockwise"
        case .rotateRight: "arrow.clockwise"
        }
    }

    var vector: (x: Double, y: Double, rotation: Double) {
        switch self {
        case .forwardLeft: (-1, 1, 0)
        case .forward: (0, 1, 0)
        case .forwardRight: (1, 1, 0)
        case .left: (-1, 0, 0)
        case .right: (1, 0, 0)
        case .backLeft: (-1, -1, 0)
        case .back: (0, -1, 0)
        case .backRight: (1, -1, 0)
        case .rotateLeft: (0, 0, -1)
        case .rotateRight: (0, 0, 1)
        }
    }
}

enum WheelPosition: String, CaseIterable, Codable, Identifiable, Sendable {
    case frontLeft = "FL"
    case frontRight = "FR"
    case backLeft = "BL"
    case backRight = "BR"

    var id: String { rawValue }
}

enum CalibrationSource: String, Codable, Sendable {
    case unverified
    case manual
    case observed
}

struct CalibrationObservation: Equatable, Sendable {
    let position: WheelPosition
    let movesForward: Bool
}

struct MotorValues: Equatable, Sendable {
    let m1: Int
    let m2: Int
    let m3: Int
    let m4: Int

    static let stopped = MotorValues(m1: 0, m2: 0, m3: 0, m4: 0)

    var query: [String: String] {
        ["m1": String(m1), "m2": String(m2), "m3": String(m3), "m4": String(m4)]
    }
}

struct WheelProfile: Codable, Equatable, Sendable {
    var positions: [String: WheelPosition]
    var inverted: [String: Bool]
    var source: CalibrationSource

    static let standard = WheelProfile(
        positions: ["m1": .frontLeft, "m2": .frontRight, "m3": .backLeft, "m4": .backRight],
        inverted: ["m1": false, "m2": false, "m3": false, "m4": false],
        source: .unverified
    )

    func motors(for direction: DriveDirection, power: Int) -> MotorValues {
        let vector = direction.vector
        let magnitude = max(1, abs(vector.x) + abs(vector.y) + abs(vector.rotation))
        let x = vector.x / magnitude
        let y = vector.y / magnitude
        let rotation = vector.rotation / magnitude
        let limitedPower = Double(min(100, max(0, power)))

        let positionValues: [WheelPosition: Int] = [
            .frontLeft: Int(((y + x + rotation) * limitedPower).rounded()),
            .frontRight: Int(((y - x - rotation) * limitedPower).rounded()),
            .backLeft: Int(((y - x + rotation) * limitedPower).rounded()),
            .backRight: Int(((y + x - rotation) * limitedPower).rounded()),
        ]

        func value(_ motor: String) -> Int {
            let position = positions[motor] ?? WheelProfile.standard.positions[motor]!
            let value = positionValues[position] ?? 0
            return inverted[motor] == true ? -value : value
        }

        return MotorValues(m1: value("m1"), m2: value("m2"), m3: value("m3"), m4: value("m4"))
    }
}

struct RoverStatus: Equatable, Sendable {
    var hostname = "car-02"
    var ip = "192.168.2.23"
    var camera = "192.168.2.24"
    var rssi: Int?
    var moving = false
    var firmware = ""
}

struct RoverSensors: Equatable, Sendable {
    var sonarCM: Double?
    var sonarValid = false
    var lineLeft: Int?
    var lineMiddle: Int?
    var lineRight: Int?
}
