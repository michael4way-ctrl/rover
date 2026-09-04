import SwiftUI

struct ContentView: View {
    @StateObject private var rover = RoverController()
    @StateObject private var relay = RelayServer()

    var body: some View {
        TabView {
            NavigationStack {
                DriveScreen(rover: rover)
            }
            .tabItem { Label("Ехать", systemImage: "steeringwheel") }

            NavigationStack {
                SensorsScreen(rover: rover)
            }
            .tabItem { Label("Датчики", systemImage: "sensor.tag.radiowaves.forward") }

            NavigationStack {
                ToolsScreen(rover: rover)
            }
            .tabItem { Label("Настройка", systemImage: "slider.horizontal.3") }

            NavigationStack {
                BridgeScreen(rover: rover, relay: relay)
            }
            .tabItem { Label("Mac", systemImage: "cable.connector") }
        }
        .tint(.green)
        .task {
            relay.start()
            await rover.connect()
        }
    }
}

private struct DriveScreen: View {
    @ObservedObject var rover: RoverController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionCard(rover: rover)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Движение")
                                .font(.title2.bold())
                            Text("Держите кнопку, отпустите для остановки")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(rover.power))%")
                            .font(.title3.monospacedDigit().bold())
                            .foregroundStyle(.green)
                    }

                    drivePad

                    HStack(spacing: 12) {
                        HoldDriveButton(direction: .rotateLeft, active: rover.activeDirection == .rotateLeft, rover: rover)
                        HoldDriveButton(direction: .rotateRight, active: rover.activeDirection == .rotateRight, rover: rover)
                    }

                    Button(role: .destructive) {
                        rover.stopDriving()
                    } label: {
                        Label("Остановить моторы", systemImage: "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Мощность", value: "\(Int(rover.power))%")
                    Slider(value: $rover.power, in: 30...100, step: 1)
                        .disabled(rover.activeDirection != nil)
                    HStack {
                        Text("30% - тихий ход")
                        Spacer()
                        Text("100% - максимум")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    settingTitle("Автостоп", value: "\(Int(rover.timeout)) мс")
                    Slider(value: $rover.timeout, in: 150...1500, step: 50)
                        .disabled(rover.activeDirection != nil)
                    Text("Если связь пропадёт, ровер остановится после этого времени.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .cardStyle()
            }
            .padding(16)
        }
        .navigationTitle("Ровер")
        .onDisappear { rover.stopDriving() }
    }

    private var drivePad: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                pad(.forwardLeft)
                pad(.forward)
                pad(.forwardRight)
            }
            GridRow {
                pad(.left)
                Button(role: .destructive) { rover.stopDriving() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 62)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                pad(.right)
            }
            GridRow {
                pad(.backLeft)
                pad(.back)
                pad(.backRight)
            }
        }
    }

    private func pad(_ direction: DriveDirection) -> some View {
        HoldDriveButton(direction: direction, active: rover.activeDirection == direction, rover: rover)
    }

    private func settingTitle(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

private struct HoldDriveButton: View {
    let direction: DriveDirection
    let active: Bool
    @ObservedObject var rover: RoverController
    @State private var isHolding = false

    var body: some View {
        Image(systemName: direction.symbol)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, minHeight: 62)
            .foregroundStyle(active ? Color.black : Color.primary)
            .background(active ? Color.green : Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .accessibilityLabel(direction.title)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        rover.startDriving(direction)
                    }
                    .onEnded { _ in
                        isHolding = false
                        rover.stopDriving()
                    }
            )
    }
}

private struct SensorsScreen: View {
    @ObservedObject var rover: RoverController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionCard(rover: rover)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Камера").font(.title2.bold())
                            Text("Один кадр меньше нагружает слабую сеть")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await rover.takeSnapshot() } } label: {
                            Label("Снять", systemImage: "camera")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Group {
                        if let snapshot = rover.snapshot {
                            Image(uiImage: snapshot)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ContentUnavailableView("Кадра пока нет", systemImage: "camera", description: Text("Нажмите «Снять»"))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 190)
                    .background(Color.black.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    labeledSlider("Поворот камеры", value: $rover.servoAngle, range: 0...180, suffix: "°") {
                        Task { await rover.setServo() }
                    }
                    labeledSlider("Подсветка", value: $rover.flashLevel, range: 0...255, suffix: "") {
                        Task { await rover.setFlash() }
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Датчики").font(.title2.bold())
                        Spacer()
                        Toggle("Обновлять", isOn: Binding(
                            get: { rover.automaticSensors },
                            set: { rover.setAutomaticSensors($0) }
                        ))
                        .labelsHidden()
                    }

                    HStack(spacing: 8) {
                        sensorButton("Сонар", path: "/sonar")
                        sensorButton("Линия", path: "/line")
                        sensorButton("Все", path: "/sensors")
                    }

                    HStack(spacing: 10) {
                        ReadingTile(title: "Сонар", value: sonarText, warning: false)
                        ReadingTile(title: "Состояние", value: sonarState, warning: !rover.sensors.sonarValid)
                    }

                    lineRow("Левый", value: rover.sensors.lineLeft)
                    lineRow("Средний", value: rover.sensors.lineMiddle)
                    lineRow("Правый", value: rover.sensors.lineRight)

                    HStack {
                        Text("Порог чёрного").font(.headline)
                        Spacer()
                        Text("\(Int(rover.lineThreshold))").monospacedDigit()
                    }
                    Slider(value: $rover.lineThreshold, in: 0...4095, step: 5)
                    Text("Значения сравниваются с порогом только на экране. Прошивка его не хранит.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .cardStyle()
            }
            .padding(16)
        }
        .navigationTitle("Камера и датчики")
    }

    private var sonarText: String {
        guard rover.sensors.sonarValid, let value = rover.sensors.sonarCM else { return "-" }
        return String(format: "%.1f см", value)
    }

    private var sonarState: String {
        rover.sensors.sonarValid ? "Эхо есть" : "Нет эха"
    }

    private func sensorButton(_ title: String, path: String) -> some View {
        Button(title) { Task { await rover.refreshSensors(path) } }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }

    private func lineRow(_ title: String, value: Int?) -> some View {
        let reading = value ?? 0
        return VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.map(String.init) ?? "-").monospacedDigit().bold()
                Text(value == nil ? "" : reading >= Int(rover.lineThreshold) ? "выше порога" : "ниже порога")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(reading), total: 4095)
        }
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(Int(value.wrappedValue))\(suffix)").monospacedDigit()
            }
            Slider(value: value, in: range, step: 1, onEditingChanged: { editing in
                if !editing { onCommit() }
            })
        }
    }
}

private struct ToolsScreen: View {
    @ObservedObject var rover: RoverController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Звук").font(.title2.bold())
                    HStack(spacing: 10) {
                        Button { Task { await rover.beep() } } label: {
                            Label("Короткий сигнал", systemImage: "speaker.wave.2")
                                .frame(maxWidth: .infinity)
                        }
                        Button { Task { await rover.playMelody() } } label: {
                            Label("Мелодия", systemImage: "music.note.list")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Колёса").font(.title2.bold())
                            Text("Поставьте ровер на подставку перед проверкой")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Сбросить") { rover.resetProfile() }
                    }

                    ForEach(["m1", "m2", "m3", "m4"], id: \.self) { motor in
                        VStack(spacing: 10) {
                            HStack {
                                Text(motor.uppercased()).font(.headline.monospaced())
                                Picker("Колесо", selection: Binding(
                                    get: { rover.position(for: motor) },
                                    set: { rover.setPosition($0, for: motor) }
                                )) {
                                    ForEach(WheelPosition.allCases) { position in
                                        Text(position.rawValue).tag(position)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            HStack(spacing: 8) {
                                Button("-45") { Task { await rover.testMotor(motor, power: -45) } }
                                Button("+45") { Task { await rover.testMotor(motor, power: 45) } }
                                Toggle("Инверсия", isOn: Binding(
                                    get: { rover.isInverted(motor) },
                                    set: { rover.setInverted($0, for: motor) }
                                ))
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(12)
                        .background(Color(uiColor: .tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .cardStyle()
            }
            .padding(16)
        }
        .navigationTitle("Настройка")
    }
}

private struct BridgeScreen: View {
    @ObservedObject var rover: RoverController
    @ObservedObject var relay: RelayServer

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionCard(rover: rover)

                VStack(alignment: .leading, spacing: 14) {
                    Label(relay.isListening ? "USB-шлюз готов" : relay.listenerStatus, systemImage: relay.isListening ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(relay.isListening ? .green : .orange)

                    Text("На Mac откройте веб-пульт. Его команды попадут в iPhone через кабель, затем уйдут роверу по Wi-Fi.")
                        .foregroundStyle(.secondary)

                    bridgeRow("Адрес на Mac", value: "http://127.0.0.1:17777")
                    bridgeRow("Шасси", value: "192.168.2.23")
                    bridgeRow("Камера", value: "192.168.2.24")
                    bridgeRow("Запросов с Mac", value: String(relay.requestCount))

                    Text(relay.lastEvent)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text("Держите приложение открытым. iOS может приостановить шлюз в фоне.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .cardStyle()
            }
            .padding(16)
        }
        .navigationTitle("Управление с Mac")
    }

    private func bridgeRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospaced())
        }
    }
}

private struct ConnectionCard: View {
    @ObservedObject var rover: RoverController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(rover.connected ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(rover.connectionText).font(.headline)
                Spacer()
                Button("Проверить связь") { Task { await rover.connect() } }
                    .buttonStyle(.bordered)
                    .disabled(rover.busy)
            }
            Text(rover.lastMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if rover.connected {
                HStack(spacing: 14) {
                    Label(rover.status.hostname, systemImage: "car.side")
                    if let rssi = rover.status.rssi {
                        Label("\(rssi) dBm", systemImage: "wifi")
                    }
                    Label("\(rover.commandCount)", systemImage: "paperplane")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }
}

private struct ReadingTile: View {
    let title: String
    let value: String
    let warning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(warning ? .orange : .primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
