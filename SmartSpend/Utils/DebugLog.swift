import Foundation

/// Prints only in Debug builds so release builds never log user data to the console.
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
