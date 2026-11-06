import Foundation

/// A tiny greeter used to show Swift highlighting.
struct Greeter {
    let name: String

    func greet(times: Int = 1) -> String {
        (0..<times).map { _ in "Hello, \(name)!" }.joined(separator: "\n")
    }
}

/* Multi-line
   comment */
print(Greeter(name: "Grizzly").greet(times: 2))
