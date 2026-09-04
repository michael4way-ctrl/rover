import Foundation
import UIKit

enum RoverError: LocalizedError {
    case invalidResponse
    case robot(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Ровер вернул непонятный ответ"
        case .robot(let message): message
        }
    }
}

private final class URLSessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func install(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private actor RoverAPI {
    private let chassis = URL(string: "http://192.168.2.23")!
    private let camera = URL(string: "http://192.168.2.24")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.2
        configuration.timeoutIntervalForResource = 2.5
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func status() async throws -> [String: Any] {
        try await json(path: "/status")
    }

    func sensors(path: String = "/sensors") async throws -> [String: Any] {
        try await json(path: path)
    }

    func wheels(_ motors: MotorValues, timeout: Int, sonarControlToken: UUID? = nil) async throws {
        var query = motors.query
        query["timeout"] = String(timeout)
        _ = try await json(path: "/wheels", query: query, sonarControlToken: sonarControlToken)
    }

    func stop() async throws {
        _ = try await json(path: "/stop")
    }

    func servo(angle: Int) async throws -> Int {
        let response = try await json(path: "/servo", query: ["cam": String(angle)])
        return Self.integer(response["cam"]) ?? angle
    }

    func beep(frequency: Int, duration: Int) async throws {
        _ = try await json(path: "/buzzer", query: ["freq": String(frequency), "duration": String(duration)])
    }

    func melody(_ notes: String) async throws {
        _ = try await json(path: "/buzzer", query: ["melody": notes])
    }

    func flash(_ value: Int) async throws {
        _ = try await data(base: camera, path: "/flash", query: ["v": String(value)])
    }

    func snapshot() async throws -> Data {
        try await data(base: camera, path: "/snapshot", query: ["t": String(Int(Date().timeIntervalSince1970 * 1000))])
    }

    private func json(path: String, query: [String: String] = [:], sonarControlToken: UUID? = nil) async throws -> [String: Any] {
        let body = try await data(base: chassis, path: path, query: query, sonarControlToken: sonarControlToken)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw RoverError.invalidResponse
        }
        if object["ok"] as? Bool == false {
            throw RoverError.robot(object["error"] as? String ?? "Ровер отклонил команду")
        }
        return object
    }

    private func data(base: URL, path: String, query: [String: String], sonarControlToken: UUID? = nil) async throws -> Data {
        if let sonarControlToken {
            guard RoverRequestGate.shared.waitForSonarTurn(sonarControlToken) else {
                throw CancellationError()
            }
        } else {
            RoverRequestGate.shared.waitForTurn()
        }
        try Task.checkCancellation()

        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = path == "/snapshot" ? 3 : 1.2
        let result: (Data, URLResponse)
        if path == "/wheels", let sonarControlToken {
            result = try await sonarMovementData(for: request, token: sonarControlToken)
        } else {
            result = try await session.data(for: request)
        }
        let (body, response) = result
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RoverError.invalidResponse
        }
        return body
    }

    private func sonarMovementData(for request: URLRequest, token: UUID) async throws -> (Data, URLResponse) {
        let taskID = UUID()
        let taskBox = URLSessionTaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    RoverRequestGate.shared.finishSonarMovementTask(id: taskID)
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: RoverError.invalidResponse)
                    }
                }

                guard RoverRequestGate.shared.registerSonarMovementTask(task, id: taskID, token: token) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                taskBox.install(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

@MainActor
final class RoverController: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var connectionText = "Ищу ровер в Wi-Fi-сети"
    @Published private(set) var lastMessage = "Откройте приложение и подключитесь к сети ровера"
    @Published private(set) var status = RoverStatus()
    @Published private(set) var sensors = RoverSensors()
    @Published private(set) var snapshot: UIImage?
    @Published private(set) var activeDirection: DriveDirection?
    @Published private(set) var commandCount = 0
    @Published private(set) var busy = false
    @Published var power = 55.0
    @Published var timeout = 450.0
    @Published var lineThreshold = 2000.0
    @Published var servoAngle = 90.0
    @Published var flashLevel = 0.0
    @Published var automaticSensors = false
    @Published private(set) var wheelProfile: WheelProfile
    @Published private(set) var sonarFollowEnabled = false
    @Published private(set) var sonarFollowState: SonarFollowState = .idle
    @Published var sonarTargetDistance = 30.0
    @Published var sonarFollowPower = 40.0

    private let api = RoverAPI()
    private var driveTask: Task<Void, Never>?
    private var sensorTask: Task<Void, Never>?
    private var sonarFollowTask: Task<Void, Never>?
    private var sonarRunID: UUID?
    private var stopTask: Task<Void, Never>?
    private var stopTaskID: UUID?
    private let profileKey = "rover-wheel-profile"

    init() {
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let profile = try? JSONDecoder().decode(WheelProfile.self, from: data) {
            wheelProfile = profile
        } else {
            wheelProfile = .standard
        }
    }

    func connect() async {
        let wasConnected = connected
        busy = true
        connectionText = "Проверяю 192.168.2.23"
        defer { busy = false }
        for attempt in 1...3 {
            do {
                let value = try await api.status()
                status = RoverStatus(
                    hostname: value["hostname"] as? String ?? "car-02",
                    ip: value["ip"] as? String ?? "192.168.2.23",
                    camera: (value["camera"] as? String).flatMap { URL(string: $0)?.host } ?? "192.168.2.24",
                    rssi: RoverAPI.integer(value["rssi"]),
                    moving: value["moving"] as? Bool ?? false,
                    firmware: value["firmware"] as? String ?? ""
                )
                connected = true
                connectionText = "Ровер на связи"
                lastMessage = "\(status.hostname) отвечает по Wi-Fi"
                return
            } catch {
                if attempt < 3 {
                    connectionText = "Связь нестабильна · попытка \(attempt + 1) из 3"
                    try? await Task.sleep(for: .milliseconds(250))
                } else {
                    if wasConnected,
                       let urlError = error as? URLError,
                       urlError.code == .timedOut {
                        connected = true
                        connectionText = "Связь нестабильна"
                        lastMessage = "Ровер отвечает с задержкой — управление остаётся доступно"
                    } else {
                        connected = false
                        connectionText = "Нет связи с ровером"
                        lastMessage = readable(error)
                    }
                }
            }
        }
    }

    func startDriving(_ direction: DriveDirection) {
        guard connected else {
            lastMessage = "Сначала нажмите «Проверить связь»"
            return
        }
        guard activeDirection != direction else { return }
        cancelSonarFollowing()
        driveTask?.cancel()
        activeDirection = direction
        lastMessage = direction.title
        let profile = wheelProfile
        let motors = profile.motors(for: direction, power: Int(power))
        let pulse = Int(timeout)
        let repeatDelay = min(240, max(90, pulse / 2))
        let pendingStop = stopTask

        driveTask = Task { [weak self] in
            guard let self else { return }
            if let pendingStop { await pendingStop.value }
            guard !Task.isCancelled, self.activeDirection == direction else { return }
            var consecutiveNetworkFailures = 0
            while !Task.isCancelled {
                do {
                    try await self.api.wheels(motors, timeout: pulse)
                    self.commandCount += 1
                    consecutiveNetworkFailures = 0
                } catch is CancellationError {
                    return
                } catch {
                    if let urlError = error as? URLError, urlError.code == .cancelled {
                        return
                    }
                    if let urlError = error as? URLError, urlError.code == .timedOut {
                        self.lastMessage = "Ответ задержался — повторяю команду"
                        try? await Task.sleep(for: .milliseconds(180))
                        continue
                    }
                    if error is URLError {
                        consecutiveNetworkFailures += 1
                        if consecutiveNetworkFailures < 3 {
                            self.lastMessage = "Связь прервалась — повторяю"
                            try? await Task.sleep(for: .milliseconds(250))
                            continue
                        }
                    }
                    self.connected = false
                    self.connectionText = "Управление остановлено"
                    self.lastMessage = self.readable(error)
                    self.activeDirection = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(repeatDelay))
            }
        }
    }

    func stopDriving() {
        driveTask?.cancel()
        driveTask = nil
        cancelSonarFollowing()
        activeDirection = nil
        lastMessage = "Останавливаю"
        scheduleStop(successMessage: "Моторы остановлены")
    }

    func refreshSensors(_ path: String = "/sensors") async {
        guard activeDirection == nil, !sonarFollowEnabled else { return }
        do {
            let value = try await api.sensors(path: path)
            applySensors(value)
            connected = true
            connectionText = "Ровер на связи"
            lastMessage = path == "/sonar" ? "Сонар обновлён" : path == "/line" ? "Датчики линии обновлены" : "Все датчики обновлены"
        } catch {
            lastMessage = readable(error)
        }
    }

    func setAutomaticSensors(_ enabled: Bool) {
        automaticSensors = enabled
        sensorTask?.cancel()
        sensorTask = nil
        guard enabled else { return }
        sensorTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.activeDirection == nil {
                    await self.refreshSensors()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func setSonarFollowing(_ enabled: Bool) {
        if enabled {
            startSonarFollowing()
        } else {
            stopSonarFollowing()
        }
    }

    private func startSonarFollowing() {
        guard connected else {
            lastMessage = "Сначала нажмите «Проверить связь»"
            return
        }

        driveTask?.cancel()
        driveTask = nil
        activeDirection = nil
        sensorTask?.cancel()
        sensorTask = nil
        automaticSensors = false
        cancelSonarFollowing()
        sonarFollowEnabled = true
        sonarFollowState = .waiting
        lastMessage = "Жду руку перед сонаром"

        let runID = RoverRequestGate.shared.beginSonarControl()
        sonarRunID = runID

        let policy = SonarFollowPolicy(
            targetCM: sonarTargetDistance,
            toleranceCM: 5,
            trackingRangeCM: 5...120
        )
        let maximumPower = Int(sonarFollowPower)
        let profile = wheelProfile
        let pendingStop = stopTask

        sonarFollowTask = Task { [weak self] in
            guard let self else { return }
            var wasMoving = false
            var consecutiveFailures = 0
            func makeTargetTracker() -> SonarTargetTracker {
                SonarTargetTracker(
                    acquisitionRangeCM: 5...80,
                    trackingRangeCM: 5...120,
                    maximumAcquisitionDeltaCM: 12,
                    maximumJumpCM: 60,
                    allowedMissingSamples: 2
                )
            }
            var targetTracker = makeTargetTracker()

            if let pendingStop { await pendingStop.value }
            guard self.isCurrentSonarRun(runID) else { return }

            do {
                try await self.api.stop()
                guard self.isCurrentSonarRun(runID) else { return }
                self.commandCount += 1
            } catch {
                guard self.isCurrentSonarRun(runID) else { return }
                self.lastMessage = "Не удалось подтвердить STOP · проверяю сонар"
            }

            while !Task.isCancelled {
                guard self.isCurrentSonarRun(runID), RoverRequestGate.shared.ownsSonarControl(runID) else {
                    self.finishSonarFollowingStoppedExternally(runID)
                    return
                }
                var currentOperation = "Сонар"
                do {
                    let value = try await self.api.sensors(path: "/sonar")
                    guard self.isCurrentSonarRun(runID), RoverRequestGate.shared.ownsSonarControl(runID) else {
                        self.finishSonarFollowingStoppedExternally(runID)
                        return
                    }
                    self.applySensors(value)
                    let target = targetTracker.observe(
                        distanceCM: self.sensors.sonarCM,
                        valid: self.sensors.sonarValid
                    )

                    switch target {
                    case .acquiring:
                        consecutiveFailures = 0
                        self.sonarFollowState = .waiting
                        self.lastMessage = "Держите руку перед сонаром"
                        try? await Task.sleep(for: .milliseconds(120))
                        continue
                    case .recovering:
                        if wasMoving { try await self.stopAfterSonarMovement() }
                        wasMoving = false
                        self.sonarFollowState = .waiting
                        self.lastMessage = "Проверяю цель — стою"
                        try? await Task.sleep(for: .milliseconds(120))
                        continue
                    case .lost:
                        if wasMoving { try await self.stopAfterSonarMovement() }
                        wasMoving = false
                        targetTracker = makeTargetTracker()
                        self.sonarFollowState = .waiting
                        self.lastMessage = "Цель потеряна — стою и ищу снова"
                        try? await Task.sleep(for: .milliseconds(180))
                        continue
                    case .tracked:
                        break
                    }

                    currentOperation = "Команда движения"
                    let decision = policy.decision(
                        distanceCM: self.sensors.sonarCM,
                        valid: self.sensors.sonarValid,
                        maxPower: maximumPower
                    )

                    switch decision {
                    case .advance(let power):
                        let motors = profile.motors(for: .forward, power: power)
                        try await self.api.wheels(motors, timeout: 300, sonarControlToken: runID)
                        guard RoverRequestGate.shared.ownsSonarControl(runID) else {
                            try? await self.api.stop()
                            self.finishSonarFollowingStoppedExternally(runID)
                            return
                        }
                        self.commandCount += 1
                        self.sonarFollowState = .following
                        self.lastMessage = "Еду к руке · \(power)%"
                        wasMoving = true
                    case .retreat(let power):
                        let motors = profile.motors(for: .back, power: power)
                        try await self.api.wheels(motors, timeout: 300, sonarControlToken: runID)
                        guard RoverRequestGate.shared.ownsSonarControl(runID) else {
                            try? await self.api.stop()
                            self.finishSonarFollowingStoppedExternally(runID)
                            return
                        }
                        self.commandCount += 1
                        self.sonarFollowState = .backing
                        self.lastMessage = "Отъезжаю от руки · \(power)%"
                        wasMoving = true
                    case .holding:
                        if wasMoving { try await self.stopAfterSonarMovement() }
                        self.sonarFollowState = .holding
                        self.lastMessage = "Держу заданное расстояние"
                        wasMoving = false
                    case .tooClose:
                        if wasMoving { try await self.stopAfterSonarMovement() }
                        self.sonarFollowState = .tooClose
                        self.lastMessage = "Рука близко — стою"
                        wasMoving = false
                    case .lost:
                        if wasMoving { try await self.stopAfterSonarMovement() }
                        wasMoving = false
                        targetTracker = makeTargetTracker()
                        self.sonarFollowState = .waiting
                        self.lastMessage = "Цель потеряна — стою и ищу снова"
                    }
                    consecutiveFailures = 0
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrentSonarRun(runID) else { return }
                    if let urlError = error as? URLError, urlError.code == .cancelled {
                        return
                    }
                    try? await self.api.stop()
                    wasMoving = false
                    if let urlError = error as? URLError, urlError.code == .timedOut {
                        let targetStatus = targetTracker.observe(distanceCM: nil, valid: false)
                        if targetStatus == .lost {
                            targetTracker = makeTargetTracker()
                        }
                        self.sonarFollowState = .waiting
                        self.lastMessage = "Ответ сонара задержался — стою и пробую снова"
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    consecutiveFailures += 1
                    if consecutiveFailures < 3 {
                        self.sonarFollowState = .waiting
                        self.lastMessage = "\(currentOperation) не прошла — стою и пробую снова"
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    self.finishSonarFollowingWithError(error, runID: runID)
                    return
                }

                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopSonarFollowing() {
        guard sonarFollowEnabled else { return }
        cancelSonarFollowing()
        lastMessage = "Следование выключено"
        scheduleStop(successMessage: "Следование выключено · моторы остановлены")
    }

    private func cancelSonarFollowing() {
        if let sonarRunID {
            RoverRequestGate.shared.endSonarControl(sonarRunID)
        }
        sonarRunID = nil
        sonarFollowTask?.cancel()
        sonarFollowTask = nil
        sonarFollowEnabled = false
        sonarFollowState = .idle
    }

    private func stopAfterSonarMovement() async throws {
        try await api.stop()
        commandCount += 1
    }

    private func scheduleStop(successMessage: String) {
        let previousStop = stopTask
        let taskID = UUID()
        stopTaskID = taskID
        stopTask = Task { [weak self] in
            if let previousStop { await previousStop.value }
            guard let self else { return }
            do {
                try await self.api.stop()
                self.commandCount += 1
                guard self.stopTaskID == taskID else { return }
                self.stopTask = nil
                self.stopTaskID = nil
                if self.activeDirection == nil, !self.sonarFollowEnabled {
                    self.lastMessage = successMessage
                }
            } catch {
                guard self.stopTaskID == taskID else { return }
                self.stopTask = nil
                self.stopTaskID = nil
                if self.activeDirection == nil, !self.sonarFollowEnabled {
                    self.lastMessage = self.readable(error)
                }
            }
        }
    }

    private func finishSonarFollowingWithError(_ error: Error, runID: UUID? = nil) {
        if let runID, !isCurrentSonarRun(runID) { return }
        cancelSonarFollowing()
        sonarFollowState = .error
        connected = false
        connectionText = "Следование остановлено"
        lastMessage = readable(error)
    }

    private func finishSonarFollowingStoppedExternally(_ runID: UUID) {
        guard isCurrentSonarRun(runID) else { return }
        sonarRunID = nil
        sonarFollowTask = nil
        sonarFollowEnabled = false
        sonarFollowState = .idle
        lastMessage = "Следование остановлено командой с Mac"
    }

    private func isCurrentSonarRun(_ runID: UUID) -> Bool {
        sonarRunID == runID && !Task.isCancelled
    }

    func takeSnapshot() async {
        guard activeDirection == nil, !sonarFollowEnabled else {
            lastMessage = "Сначала остановите ровер"
            return
        }
        do {
            let data = try await api.snapshot()
            guard let image = UIImage(data: data) else { throw RoverError.invalidResponse }
            snapshot = image
            lastMessage = "Получен новый кадр"
        } catch {
            lastMessage = readable(error)
        }
    }

    func setServo() async {
        guard activeDirection == nil, !sonarFollowEnabled else { return }
        do {
            servoAngle = Double(try await api.servo(angle: Int(servoAngle)))
            lastMessage = "Камера повёрнута на \(Int(servoAngle))°"
        } catch {
            lastMessage = readable(error)
        }
    }

    func setFlash() async {
        guard activeDirection == nil, !sonarFollowEnabled else { return }
        do {
            try await api.flash(Int(flashLevel))
            lastMessage = flashLevel == 0 ? "Подсветка выключена" : "Подсветка: \(Int(flashLevel))"
        } catch {
            lastMessage = readable(error)
        }
    }

    func beep(frequency: Int = 880, duration: Int = 200) async {
        guard activeDirection == nil, !sonarFollowEnabled else { return }
        do {
            try await api.beep(frequency: frequency, duration: duration)
            lastMessage = "Сигнал отправлен"
        } catch {
            lastMessage = readable(error)
        }
    }

    func playMelody() async {
        guard activeDirection == nil, !sonarFollowEnabled else { return }
        do {
            try await api.melody("440:150,0:50,660:300")
            lastMessage = "Мелодия отправлена"
        } catch {
            lastMessage = readable(error)
        }
    }

    func testMotor(_ motor: String, power: Int) async {
        guard activeDirection == nil, !sonarFollowEnabled else { return }
        var values = ["m1": 0, "m2": 0, "m3": 0, "m4": 0]
        values[motor] = power
        do {
            try await api.wheels(
                MotorValues(m1: values["m1"]!, m2: values["m2"]!, m3: values["m3"]!, m4: values["m4"]!),
                timeout: 350
            )
            lastMessage = "\(motor.uppercased()): \(power)"
        } catch {
            lastMessage = readable(error)
        }
    }

    func position(for motor: String) -> WheelPosition {
        wheelProfile.positions[motor] ?? WheelProfile.standard.positions[motor]!
    }

    func setPosition(_ position: WheelPosition, for motor: String) {
        let previous = wheelProfile.positions[motor]
        if let other = wheelProfile.positions.first(where: { $0.key != motor && $0.value == position })?.key,
           let previous {
            wheelProfile.positions[other] = previous
        }
        wheelProfile.positions[motor] = position
        wheelProfile.source = .manual
        saveProfile()
    }

    func isInverted(_ motor: String) -> Bool {
        wheelProfile.inverted[motor] == true
    }

    func setInverted(_ value: Bool, for motor: String) {
        wheelProfile.inverted[motor] = value
        wheelProfile.source = .manual
        saveProfile()
    }

    func applyCalibration(_ observations: [String: CalibrationObservation]) throws {
        let motors = ["m1", "m2", "m3", "m4"]
        guard observations.count == motors.count else {
            throw RoverError.robot("Проверьте все четыре мотора")
        }
        let positions = Set(observations.values.map(\.position))
        guard positions.count == motors.count else {
            throw RoverError.robot("Каждому мотору нужно отдельное колесо")
        }
        wheelProfile = WheelProfile(
            positions: Dictionary(uniqueKeysWithValues: motors.map { ($0, observations[$0]!.position) }),
            inverted: Dictionary(uniqueKeysWithValues: motors.map { ($0, !observations[$0]!.movesForward) }),
            source: .observed
        )
        saveProfile()
        lastMessage = "Карта колёс сохранена по наблюдениям"
    }

    func resetProfile() {
        wheelProfile = .standard
        saveProfile()
        lastMessage = "Карта колёс сброшена"
    }

    private func saveProfile() {
        if let data = try? JSONEncoder().encode(wheelProfile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    private func applySensors(_ value: [String: Any]) {
        let sonar = value["sonar"] as? [String: Any] ?? value
        let line = value["line"] as? [String: Any] ?? value
        sensors = RoverSensors(
            sonarCM: RoverAPI.double(sonar["cm"]),
            sonarValid: (sonar["valid"] as? Bool) ?? (RoverAPI.double(sonar["cm"]) != nil),
            lineLeft: RoverAPI.integer(line["l"]),
            lineMiddle: RoverAPI.integer(line["m"]),
            lineRight: RoverAPI.integer(line["r"])
        )
    }

    private func readable(_ error: Error) -> String {
        if error is URLError {
            return "Ровер не ответил. Проверьте Wi-Fi и питание"
        }
        return error.localizedDescription
    }
}
