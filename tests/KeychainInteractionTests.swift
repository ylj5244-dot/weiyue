import Foundation
import Security

@main struct KeychainInteractionTests {
    static func main() throws {
        var ui = true, sets: [Bool] = [], operations = 0
        let result = try KeychainInteractionPolicy.perform(allowInteraction: false, get: { (errSecSuccess, ui) }, set: { ui = $0; sets.append($0); return errSecSuccess }) {
            precondition(!ui); operations += 1; return "fake-authorized-value"
        }
        precondition(result == "fake-authorized-value" && ui && sets == [false, true] && operations == 1)
        sets.removeAll()
        do {
            _ = try KeychainInteractionPolicy.perform(allowInteraction: false, get: { (errSecSuccess, ui) }, set: { ui = $0; sets.append($0); return errSecSuccess }) { () throws -> Bool in
                precondition(!ui); throw ReaderError.message("simulated authorization needed")
            }
            fatalError("throw lost")
        } catch { precondition(error.localizedDescription == "simulated authorization needed" && ui && sets == [false, true]) }
        ui = false; sets.removeAll()
        _ = try KeychainInteractionPolicy.perform(allowInteraction: true, get: { (errSecSuccess, ui) }, set: { ui = $0; sets.append($0); return errSecSuccess }) { precondition(ui); return true }
        precondition(!ui && sets == [true, false])
        do {
            _ = try KeychainInteractionPolicy.perform(allowInteraction: false, get: { (errSecAuthFailed, false) }, set: { _ in fatalError("set after failed get") }) { fatalError("read after failed get") }
            fatalError("failed get accepted")
        } catch {}
        var count = 0
        do {
            _ = try KeychainInteractionPolicy.perform(allowInteraction: false, get: { (errSecSuccess, true) }, set: { _ in count += 1; return errSecAuthFailed }) { fatalError("read after failed set") }
            fatalError("failed set accepted")
        } catch { precondition(count > 0) }
        count = 0
        do {
            _ = try KeychainInteractionPolicy.perform(allowInteraction: false, get: { (errSecSuccess, true) }, set: { _ in count += 1; return count == 1 ? errSecSuccess : errSecAuthFailed }) { true }
            fatalError("failed restore accepted")
        } catch { precondition(count == 2) }
        print("PASS: noninteractive scope, restoration after success/failure, explicit UI scope, failed get/set/restore gates; mock only")
    }
}
