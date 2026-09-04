import Foundation

func expect(_ actual: MotorValues, _ expected: MotorValues, _ label: String) {
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

print("PASS rover wheel vectors")
