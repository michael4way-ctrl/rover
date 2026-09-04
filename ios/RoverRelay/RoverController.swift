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

    func wheels(_ motors: MotorValues, timeout: Int) async throws {
        var query = motors.query
        query["timeout"] = String(timeout)
        _ = try await json(path: "/wheels", query: query)
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

    private func json(path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        let body = try await data(base: chassis, path: path, query: query)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw RoverError.invalidResponse
        }
        if object["ok"] as? Bool == false {
            throw RoverError.robot(object["error"] as? String ?? "Ровер отклонил команду")
        }
        return object
    }

    private func data(base: URL, path: String, query: [String: String]) async throws -> Data {
        RoverRequestGate.shared.waitForTurn()
        try Task.checkCancellation()

        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = path == "/snapshot" ? 3 : 1.2
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RoverError.invalidResponse
        }
        return body
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

    private let api = RoverAPI()
    private var driveTask: Task<Void, Never>?
    private var sensorTask: Task<Void, Never>?
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
        busy = true
        connectionText = "Проверяю 192.168.2.23"
        defer { busy = false }
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
            lastMessage = "(status.hostname) отвечает по Wi-Fi"
        } catch {
            connected = false
            connectionText = "Нет связи с ровером"
            lastMessage = readable(error)
        }
    }

    func startDriving(_ direction: DriveDirection) {
        guard connected else {
            lastMessage = "Сначала нажмите «Проверить связь»"
            return
        }
        guard activeDirection != direction else { return }
        driveTask?.cancel()
        activeDirection = direction
        lastMessage = direction.title
        let profile = wheelProfile
        let motors = profile.motors(for: direction, power: Int(power))
        let pulse = Int(timeout)
        let repeatDelay = min(240, max(90, pulse / 2))

        driveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.api.wheels(motors, timeout: pulse)
                    self.commandCount += 1
                } catch is CancellationError {
                    return
                } catch {
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
        activeDirection = nil
        lastMessage = "Останавливаю"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.api.stop()
                self.commandCount += 1
                self.lastMessage = "Моторы остановлены"
            } catch {
                self.lastMessage = self.readable(error)
            }
        }
    }

    func refreshSensors(_ path: String = "/sensors") async {
        guard activeDirection == nil else { return }
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

    func takeSnapshot() async {
        guard activeDirection == nil else {
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
        guard activeDirection == nil else { return }
        do {
            servoAngle = Double(try await api.servo(angle: Int(servoAngle)))
            lastMessage = "Камера повёрнута на (Int(servoAngle))°"
        } catch {
            lastMessage = readable(error)
        }
    }

    func setFlash() async {
        guard activeDirection == nil else { return }
        do {
            try await api.flash(Int(flashLevel))
            lastMessage = flashLevel == 0 ? "Подсветка выключена" : "Подсветка: (Int(flashLevel))"
        } catch {
            lastMessage = readable(error)
        }
    }

    func beep(frequency: Int = 880, duration: Int = 200) async {
        guard activeDirection == nil else { return }
        do {
            try await api.beep(frequency: frequency, duration: duration)
            lastMessage = "Сигнал отправлен"
        } catch {
            lastMessage = readable(error)
        }
    }

    func playMelody() async {
        guard activeDirection == nil else { return }
        do {
            try await api.melody("440:150,0:50,660:300")
            lastMessage = "Мелодия отправлена"
        } catch {
            lastMessage = readable(error)
        }
    }

    func testMotor(_ motor: String, power: Int) async {
        guard activeDirection == nil else { return }
        var values = ["m1": 0, "m2": 0, "m3": 0, "m4": 0]
        values[motor] = power
        do {
            try await api.wheels(
                MotorValues(m1: values["m1"]!, m2: values["m2"]!, m3: values["m3"]!, m4: values["m4"]!),
                timeout: 350
            )
            lastMessage = "(motor.uppercased()): (power)"
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
