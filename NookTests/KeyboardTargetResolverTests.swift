//  KeyboardTargetResolverTests.swift
//  Nook
//
//  Spec: docs/specs/2026-09-29-session-list-reply-shortcut-target-design.md §6

import XCTest
@testable import Nook

private func makeSession(_ id: String) -> SessionState {
    SessionState(sessionId: id, cwd: "/tmp/\(id)")
}

final class KeyboardTargetResolverTests: XCTestCase {

    func testZeroTargetsReturnsNilEvenWithHighlight() {
        let highlighted = makeSession("a")
        XCTAssertNil(KeyboardTargetResolver.resolve(from: [], highlighted: highlighted))
    }

    func testSingleTargetReturnedWhenHighlightIsNil() {
        // -1 / out-of-range index → highlighted == nil; 1-rule ignores highlight
        let only = makeSession("a")
        XCTAssertEqual(KeyboardTargetResolver.resolve(from: [only], highlighted: nil)?.sessionId, "a")
    }

    func testSingleTargetReturnedWhenHighlightIsDifferentSession() {
        let only = makeSession("a")
        let other = makeSession("b")
        XCTAssertEqual(KeyboardTargetResolver.resolve(from: [only], highlighted: other)?.sessionId, "a")
    }

    func testMultipleTargetsReturnHighlightedWhenItIsATarget() {
        let a = makeSession("a"), b = makeSession("b")
        XCTAssertEqual(KeyboardTargetResolver.resolve(from: [a, b], highlighted: b)?.sessionId, "b")
    }

    func testMultipleTargetsReturnNilWhenHighlightIsNotATarget() {
        let a = makeSession("a"), b = makeSession("b"), outsider = makeSession("c")
        XCTAssertNil(KeyboardTargetResolver.resolve(from: [a, b], highlighted: outsider))
    }

    func testMultipleTargetsReturnNilWhenHighlightIsNil() {
        let a = makeSession("a"), b = makeSession("b")
        XCTAssertNil(KeyboardTargetResolver.resolve(from: [a, b], highlighted: nil))
    }

    func testMultipleTargetsMatchBySessionIdNotByInstanceOrFields() {
        // Same sessionId, different content: must still hit by id — this pins
        // the sessionId-match decision (spec revision ②: no deep Equatable
        // compare over chatItems/toolTracker; no identity requirement).
        let inList = SessionState(sessionId: "a", cwd: "/tmp/a")
        let highlightedCopy = SessionState(sessionId: "a", cwd: "/tmp/a-copy", phase: .processing)
        let other = makeSession("b")
        let resolved = KeyboardTargetResolver.resolve(from: [inList, other], highlighted: highlightedCopy)
        XCTAssertEqual(resolved?.sessionId, "a")
    }
}
