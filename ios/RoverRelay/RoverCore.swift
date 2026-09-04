import Foundation

final class RoverRequestGate: @unchecked Sendable {
    static let shared = RoverRequestGate()

    private let lock = NSLock()
    private var nextRequestAt = Date.distantPast
    private var sonarControlToken: UUID?
    private var relayedMovementTasks: [UUID: URLSessionDataTask] = [:]

    private init() {}

    func waitForTurn() {
        lock.lock()
        let reserved = reserveTurn()
        lock.unlock()

        wait(until: reserved)
    }

    func beginSonarControl() -> UUID {
        lock.lock()
        let token = UUID()
        sonarControlToken = token
        let tasksToCancel = Array(relayedMovementTasks.values)
        relayedMovementTasks.removeAll()
        lock.unlock()

        tasksToCancel.forEach { $0.cancel() }
        return token
    }

    func endSonarControl(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if sonarControlToken == token {
            sonarControlToken = nil
        }
    }

    func ownsSonarControl(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sonarControlToken == token
    }

    func waitForSonarTurn(_ token: UUID) -> Bool {
        lock.lock()
        guard sonarControlToken == token else {
            lock.unlock()
            return false
        }
        let reserved = reserveTurn()
        lock.unlock()

        wait(until: reserved)
        lock.lock()
        let stillOwned = sonarControlToken == token
        lock.unlock()
        return stillOwned
    }

    func waitForRelayedTurn(target: String) -> Bool {
        let isWheelCommand = target == "/wheels" || target.hasPrefix("/wheels?")
        let isStopCommand = target == "/stop" || target.hasPrefix("/stop?")

        lock.lock()
        if isWheelCommand, sonarControlToken != nil {
            lock.unlock()
            return false
        }
        if isStopCommand {
            sonarControlToken = nil
        }
        let reserved = reserveTurn()
        lock.unlock()

        wait(until: reserved)
        return true
    }

    func registerRelayedMovementTask(_ task: URLSessionDataTask, id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sonarControlToken == nil else { return false }
        relayedMovementTasks[id] = task
        return true
    }

    func finishRelayedMovementTask(id: UUID) {
        lock.lock()
        relayedMovementTasks[id] = nil
        lock.unlock()
    }

    private func reserveTurn() -> Date {
        let reserved = max(Date(), nextRequestAt)
        nextRequestAt = reserved.addingTimeInterval(0.055)
        return reserved
    }

    private func wait(until reserved: Date) {
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

enum SonarFollowDecision: Equatable, Sendable {
    case lost
    case tooClose
    case holding
    case advance(power: Int)
    case retreat(power: Int)
}

enum SonarFollowState: Equatable, Sendable {
    case idle
    case waiting
    case following
    case backing
    case holding
    case tooClose
    case lost
    case error
}

enum SonarTargetObservation: Equatable, Sendable {
    case acquiring
    case tracked(distanceCM: Double)
    case lost
}

struct SonarTargetTracker: Sendable {
    let acquisitionRangeCM: ClosedRange<Double>
    let trackingRangeCM: ClosedRange<Double>
    let maximumAcquisitionDeltaCM: Double
    let maximumJumpCM: Double

    private enum State: Sendable {
        case waiting(candidateCM: Double?)
        case tracking(lastCM: Double)
        case lost
    }

    private var state: State = .waiting(candidateCM: nil)

    init(
        acquisitionRangeCM: ClosedRange<Double>,
        trackingRangeCM: ClosedRange<Double>,
        maximumAcquisitionDeltaCM: Double,
        maximumJumpCM: Double
    ) {
        self.acquisitionRangeCM = acquisitionRangeCM
        self.trackingRangeCM = trackingRangeCM
        self.maximumAcquisitionDeltaCM = maximumAcquisitionDeltaCM
        self.maximumJumpCM = maximumJumpCM
    }

    mutating func observe(distanceCM: Double?, valid: Bool) -> SonarTargetObservation {
        switch state {
        case .lost:
            return .lost
        case .waiting(let candidateCM):
            guard valid,
                  let distanceCM,
                  distanceCM.isFinite,
                  acquisitionRangeCM.contains(distanceCM) else {
                state = .waiting(candidateCM: nil)
                return .acquiring
            }

            if let candidateCM, abs(distanceCM - candidateCM) <= maximumAcquisitionDeltaCM {
                state = .tracking(lastCM: distanceCM)
                return .tracked(distanceCM: distanceCM)
            }
            state = .waiting(candidateCM: distanceCM)
            return .acquiring
        case .tracking(let lastCM):
            guard valid,
                  let distanceCM,
                  distanceCM.isFinite,
                  trackingRangeCM.contains(distanceCM),
                  abs(distanceCM - lastCM) <= maximumJumpCM else {
                state = .lost
                return .lost
            }
            state = .tracking(lastCM: distanceCM)
            return .tracked(distanceCM: distanceCM)
        }
    }
}

struct SonarFollowPolicy: Sendable {
    let targetCM: Double
    let toleranceCM: Double
    let trackingRangeCM: ClosedRange<Double>

    func decision(distanceCM: Double?, valid: Bool, maxPower: Int) -> SonarFollowDecision {
        guard valid, let distanceCM, distanceCM.isFinite else {
            return .lost
        }

        if distanceCM < trackingRangeCM.lowerBound {
            return .tooClose
        }
        guard distanceCM <= trackingRangeCM.upperBound else { return .lost }

        if distanceCM < targetCM - toleranceCM {
            return .retreat(power: power(forErrorCM: targetCM - distanceCM, maxPower: maxPower))
        }
        if distanceCM <= targetCM + toleranceCM {
            return .holding
        }

        return .advance(power: power(forErrorCM: distanceCM - targetCM, maxPower: maxPower))
    }

    private func power(forErrorCM errorCM: Double, maxPower: Int) -> Int {
        let requestedPower = Int((errorCM * 1.2).rounded())
        let limitedMaximum = min(60, max(35, maxPower))
        return min(limitedMaximum, max(35, requestedPower))
    }
}
