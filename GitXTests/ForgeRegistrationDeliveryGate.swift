import XCTest

actor ForgeRegistrationDeliveryGate {
    private let entered: XCTestExpectation
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var admissionCount = 0

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func hold() async {
        admissionCount += 1
        if admissionCount == 1 {
            entered.fulfill()
        }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func release() {
        released = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}
