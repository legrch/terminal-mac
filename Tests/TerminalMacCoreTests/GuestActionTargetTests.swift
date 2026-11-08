import XCTest
@testable import TerminalMacCore

final class GuestActionTargetTests: XCTestCase {
    func testAmbiguousStatusCannotSelectDefaultPaste() {
        XCTAssertThrowsError(try GuestActionTarget(positionals: ["clipboard-paste", "status"]))
    }
    func testEveryVerbNamedMachineHasAnExplicitStatusRoute() throws {
        for name in GuestActionTarget.actions {
            let target = try GuestActionTarget(positionals: ["status"], explicitName: name)
            XCTAssertEqual(target.name, name)
            XCTAssertEqual(target.verb, "status")
            XCTAssertEqual(target.operands, [])
        }
    }
    func testEveryTwoVerbLegacyPrefixFailsClosed() {
        for name in GuestActionTarget.actions {
            for action in GuestActionTarget.actions {
                XCTAssertThrowsError(try GuestActionTarget(positionals: [name, action]))
            }
        }
    }
    func testExplicitTargetKeepsVerbLikeTextAsData() throws {
        for text in GuestActionTarget.actions {
            let target = try GuestActionTarget(positionals: ["clipboard-paste", text], explicitName: "farol")
            XCTAssertEqual(target.name, "farol")
            XCTAssertEqual(target.verb, "clipboard-paste")
            XCTAssertEqual(target.operands, [text])
        }
    }
    func testLegacyNamedTargetIsPreserved() throws {
        let target = try GuestActionTarget(positionals: ["farol", "type", "status"])
        XCTAssertEqual(target.name, "farol")
        XCTAssertEqual(target.verb, "type")
        XCTAssertEqual(target.operands, ["status"])
    }
    func testLegacyDefaultReadIsPreserved() throws {
        let target = try GuestActionTarget(positionals: ["status"])
        XCTAssertEqual(target.name, "default")
        XCTAssertEqual(target.verb, "status")
    }
    func testLegacyDefaultOrdinaryTextIsPreserved() throws {
        let target = try GuestActionTarget(positionals: ["type", "synthetic words"])
        XCTAssertEqual(target.name, "default")
        XCTAssertEqual(target.operands, ["synthetic words"])
    }
    func testExplicitTextOptionDisambiguatesDefault() throws {
        let args = try Arguments(["type", "--text", "status"], options: ["vm", "text"])
        let target = try GuestActionTarget(positionals: args.positionals, explicitName: args.options["vm"])
        XCTAssertEqual(target.name, "default")
        XCTAssertEqual(target.verb, "type")
        XCTAssertEqual(target.operands, [])
        XCTAssertEqual(args.options["text"], "status")
    }
    func testMissingOrInvalidTargetIsRejected() {
        for name in ["", "../host", "/tmp", "a b", String(repeating: "x", count: 49)] {
            XCTAssertThrowsError(try GuestActionTarget(positionals: ["status"], explicitName: name))
        }
        XCTAssertThrowsError(try GuestActionTarget(positionals: []))
    }
    func testMissingOrUnknownActionIsRejected() {
        XCTAssertThrowsError(try GuestActionTarget(positionals: [], explicitName: "farol"))
        XCTAssertThrowsError(try GuestActionTarget(positionals: ["unknown"], explicitName: "farol"))
        XCTAssertThrowsError(try GuestActionTarget(positionals: ["farol", "unknown"]))
    }
    func testMixedTargetFormsAndDuplicateOptionsAreRejected() {
        XCTAssertThrowsError(try GuestActionTarget(positionals: ["farol", "status"], explicitName: "default"))
        XCTAssertThrowsError(try Arguments(["--vm", "farol", "--vm", "default", "status"], options: ["vm"]))
        XCTAssertThrowsError(try Arguments(["--vm"], options: ["vm"]))
    }
    func testEndOfOptionsKeepsLiteralPayload() throws {
        let args = try Arguments(["--vm", "farol", "type", "--", "--vm"], options: ["vm"])
        let target = try GuestActionTarget(positionals: args.positionals, explicitName: args.options["vm"])
        XCTAssertEqual(target.name, "farol")
        XCTAssertEqual(target.operands, ["--vm"])
    }
}
