import Foundation

func expect(_ actual: MotorValues, _ expected: MotorValues, _ label: String) {
    guard actual == expected else {
        fputs("FAIL \(label): \(actual) != \(expected)\n", stderr)
        exit(1)
    }
}

func expectFollow(_ actual: SonarFollowDecision, _ expected: SonarFollowDecision, _ label: String) {
    guard actual == expected else {
        fputs("FAIL \(label): \(actual) != \(expected)\n", stderr)
        exit(1)
    }
}

func expectTarget(_ actual: SonarTargetObservation, _ expected: SonarTargetObservation, _ label: String) {
    guard actual == expected else {
        fputs("FAIL \(label): \(actual) != \(expected)\n", stderr)
        exit(1)
    }
}

let profile = WheelProfile.standard

expect(
    profile.motors(for: .forward, power: 55),
    MotorValues(m1: 55, m2: 55, m3: 55, m4: 55),
    "forward"
)
expect(
    profile.motors(for: .rotateLeft, power: 55),
    MotorValues(m1: -55, m2: 55, m3: -55, m4: 55),
    "rotate left"
)
expect(
    profile.motors(for: .rotateRight, power: 55),
    MotorValues(m1: 55, m2: -55, m3: 55, m4: -55),
    "rotate right"
)
expect(
    profile.motors(for: .forwardLeft, power: 55),
    MotorValues(m1: 0, m2: 55, m3: 55, m4: 0),
    "forward left"
)
expect(
    profile.motors(for: .right, power: 120),
    MotorValues(m1: 100, m2: -100, m3: -100, m4: 100),
    "clamp power"
)

var inverted = WheelProfile.standard
inverted.inverted["m1"] = true
expect(
    inverted.motors(for: .forward, power: 40),
    MotorValues(m1: -40, m2: 40, m3: 40, m4: 40),
    "motor inversion"
)

let observed = WheelProfile(
    positions: ["m1": .backRight, "m2": .frontRight, "m3": .backLeft, "m4": .frontLeft],
    inverted: ["m1": true, "m2": false, "m3": true, "m4": false],
    source: .observed
)
expect(
    observed.motors(for: .rotateRight, power: 55),
    MotorValues(m1: 55, m2: -55, m3: -55, m4: 55),
    "observed turn calibration"
)

let follower = SonarFollowPolicy(targetCM: 30, toleranceCM: 5, trackingRangeCM: 5...120)

expectFollow(
    follower.decision(distanceCM: nil, valid: false, maxPower: 45),
    .lost,
    "missing hand stops"
)
expectFollow(
    follower.decision(distanceCM: 130, valid: true, maxPower: 45),
    .lost,
    "object outside tracking range stops"
)
expectFollow(
    follower.decision(distanceCM: 22, valid: true, maxPower: 45),
    .retreat(power: 35),
    "close hand moves rover back"
)
expectFollow(
    follower.decision(distanceCM: 3, valid: true, maxPower: 45),
    .tooClose,
    "distance below sensor range stops"
)
expectFollow(
    follower.decision(distanceCM: 32, valid: true, maxPower: 45),
    .holding,
    "target corridor holds"
)
expectFollow(
    follower.decision(distanceCM: 38, valid: true, maxPower: 45),
    .advance(power: 35),
    "small gap uses minimum moving power"
)
expectFollow(
    follower.decision(distanceCM: 80, valid: true, maxPower: 45),
    .advance(power: 45),
    "large gap respects power limit"
)

var tracker = SonarTargetTracker(
    acquisitionRangeCM: 5...80,
    trackingRangeCM: 5...120,
    maximumAcquisitionDeltaCM: 12,
    maximumJumpCM: 60,
    allowedMissingSamples: 2
)
expectTarget(tracker.observe(distanceCM: 42, valid: true), .acquiring, "first echo does not move")
expectTarget(tracker.observe(distanceCM: 40, valid: true), .tracked(distanceCM: 40), "second stable echo captures target")
expectTarget(tracker.observe(distanceCM: 70, valid: true), .tracked(distanceCM: 70), "fast hand movement stays captured")
expectTarget(tracker.observe(distanceCM: nil, valid: false), .recovering, "one missed echo pauses without disabling")
expectTarget(tracker.observe(distanceCM: 16, valid: true), .tracked(distanceCM: 16), "close hand is recovered")
expectTarget(tracker.observe(distanceCM: nil, valid: false), .recovering, "first consecutive miss pauses")
expectTarget(tracker.observe(distanceCM: nil, valid: false), .recovering, "second consecutive miss pauses")
expectTarget(tracker.observe(distanceCM: nil, valid: false), .lost, "third consecutive miss loses target")

var missingTracker = SonarTargetTracker(
    acquisitionRangeCM: 5...80,
    trackingRangeCM: 5...120,
    maximumAcquisitionDeltaCM: 12,
    maximumJumpCM: 60,
    allowedMissingSamples: 2
)
expectTarget(missingTracker.observe(distanceCM: nil, valid: false), .acquiring, "missing echo waits without moving")

let gate = RoverRequestGate.shared
let sonarToken = gate.beginSonarControl()
guard !gate.waitForRelayedTurn(target: "/wheels?m1=40") else {
    fputs("FAIL relay wheel command must be blocked during sonar following\n", stderr)
    exit(1)
}
guard gate.waitForSonarTurn(sonarToken) else {
    fputs("FAIL current sonar run must own wheel commands\n", stderr)
    exit(1)
}
guard gate.waitForRelayedTurn(target: "/stop"), !gate.ownsSonarControl(sonarToken) else {
    fputs("FAIL relayed STOP must revoke sonar following\n", stderr)
    exit(1)
}
guard !gate.waitForSonarTurn(sonarToken) else {
    fputs("FAIL revoked sonar run must not resume\n", stderr)
    exit(1)
}

print("PASS rover wheel vectors and sonar following policy")
