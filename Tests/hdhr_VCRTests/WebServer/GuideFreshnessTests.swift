import Testing
import Foundation
@testable import hdhr_VCR

// 2026-10-05 triage T17 (web guide stale-grid cluster): guide.js ordering guard + selector escaping, and the
// server-side rebuild when the 30-minute guide window moves on. The JS pieces are single dependency-free
// functions extracted from the real guide.js by regex and run in `node` (same technique as GuideJSEscapingTests;
// skipped if node isn't installed).
@Suite("Web guide freshness (T17)")
struct GuideFreshnessTests {

    private func nodeIsAvailable() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["node", "--version"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    private func guideJS() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/guide.js")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func extract(_ pattern: String, from source: String) -> String {
        guard let r = source.range(of: pattern, options: .regularExpression) else {
            Issue.record("could not find \(pattern) in guide.js — extraction pattern needs updating")
            return ""
        }
        return String(source[r])
    }

    private func runNode(_ script: String) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["node", "-e", script]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @Test func olderResultArrivingLate_isDropped_newerStaysApplied() throws {
        guard nodeIsAvailable() else { return }
        let src = try guideJS()
        let block = extract(#"var _evtSeq=0[\s\S]*?function applyGuidePayloadSeq\(seq,d,selOverride\)\{[\s\S]*?\n\}"#, from: src)
        try #require(!block.isEmpty)
        let out = try runNode("""
        var applied=[]; function applyGuidePayload(d){applied.push(d.id);}
        \(block)
        var a=nextEvtSeq(), b=nextEvtSeq(), c=nextEvtSeq();   // three requests/events, in arrival order
        var r1=applyGuidePayloadSeq(c,{id:'C'});              // the newest finishes first
        var r2=applyGuidePayloadSeq(a,{id:'A'});              // the oldest (slow decode / slow fetch) finishes last
        var r3=applyGuidePayloadSeq(b,{id:'B'});
        process.stdout.write(JSON.stringify({applied:applied,r:[r1,r2,r3]}));
        """)
        #expect(out == #"{"applied":["C"],"r":[true,false,false]}"#)
    }

    @Test func inOrderResults_areAllApplied() throws {
        guard nodeIsAvailable() else { return }
        let block = extract(#"var _evtSeq=0[\s\S]*?function applyGuidePayloadSeq\(seq,d,selOverride\)\{[\s\S]*?\n\}"#, from: try guideJS())
        try #require(!block.isEmpty)
        let out = try runNode("""
        var applied=[]; function applyGuidePayload(d){applied.push(d.id);}
        \(block)
        applyGuidePayloadSeq(nextEvtSeq(),{id:'1'}); applyGuidePayloadSeq(nextEvtSeq(),{id:'2'}); applyGuidePayloadSeq(nextEvtSeq(),{id:'3'});
        process.stdout.write(applied.join(','));
        """)
        #expect(out == "1,2,3")
    }

    @Test func staleGridPayload_stillAppliesNewerPartialTunerDropdownFragments() throws {
        guard nodeIsAvailable() else { return }
        let block = extract(#"var _evtSeq=0[\s\S]*?function applyGuidePayloadSeq\(seq,d,selOverride\)\{[\s\S]*?\n\}"#, from: try guideJS())
        try #require(!block.isEmpty)
        // Event B (dev2 pause) arrives first, event A (dev1 add) second; A's grid is applied first, so B is stale for the
        // grid — but B's dev2 dropdown fragment must still land, and an older fragment must never overwrite a newer one.
        let out = try runNode("""
        var bodies={'tdrop-body-d1':{innerHTML:''},'tdrop-body-d2':{innerHTML:''}};
        var document={getElementById:function(id){return bodies[id]||null;}};
        var gridApplied=[]; function applyGuidePayload(d){gridApplied.push(d.id+':'+Object.keys(d.tdrop).join('+'));
          Object.keys(d.tdrop).forEach(function(k){bodies['tdrop-body-'+k].innerHTML=d.tdrop[k];});}
        \(block)
        var b=nextEvtSeq(), a=nextEvtSeq();
        applyGuidePayloadSeq(a,{id:'A',tdrop:{d1:'a-d1'}});
        var rb=applyGuidePayloadSeq(b,{id:'B',tdrop:{d2:'b-d2'}});
        var stale=applyGuidePayloadSeq(b,{id:'B2',tdrop:{d1:'old-d1'}});   // older than A for d1: must not overwrite
        process.stdout.write(JSON.stringify({grid:gridApplied,rb:rb,stale:stale,d1:bodies['tdrop-body-d1'].innerHTML,d2:bodies['tdrop-body-d2'].innerHTML}));
        """)
        #expect(out == #"{"grid":["A:d1"],"rb":false,"stale":false,"d1":"a-d1","d2":"b-d2"}"#)
    }

    @Test func cq_escapesQuotesAndBackslashes_whenCSSEscapeIsMissing() throws {
        guard nodeIsAvailable() else { return }
        let fn = extract(#"function cq\(v\)\{[^\n]*\}"#, from: try guideJS())
        try #require(!fn.isEmpty)
        // `var window={}` (a browser always has one) leaves CSS undefined, so this exercises the fallback branch.
        let out = try runNode("var window={};\n\(fn)\nprocess.stdout.write([cq('5.1'),cq('a\"b'),cq('a\\\\b'),cq(null),cq(7)].join('|'));")
        #expect(out == #"5.1|a\"b|a\\b||7"#)
    }

    @Test func guideJS_stillParses() throws {
        guard nodeIsAvailable() else { return }
        let src = try guideJS().replacingOccurrences(of: #"\{\{[A-Z_]+\}\}"#, with: "0", options: .regularExpression)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString).js")
        try src.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["node", "--check", tmp.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test @MainActor func staleGridCache_isRebuiltWhenTheGuideWindowMovesOn() {
        let state = makeTestAppState(devices: [HDHRDevice.test(id: "AABBCCDD")])
        let ws = WebServer()
        ws.prebuildPageHTML(state: state)
        let builtFor = ws.cachedGridWinStart
        #expect(builtFor != nil)

        ws.refreshCachesIfGuideWindowMoved(state: state)          // same window → nothing to do
        #expect(ws.cachedGridWinStart == builtFor)

        ws.cachedGridWinStart = (builtFor ?? 0) - 1800            // pretend the cache was built a window ago
        ws.refreshCachesIfGuideWindowMoved(state: state)
        #expect(ws.cachedGridWinStart == builtFor)                // rebuilt against the current window
    }

    @Test @MainActor func coldCache_isLeftToTheLiveBuildFallback() {
        let state = makeTestAppState(devices: [HDHRDevice.test(id: "AABBCCDD")])
        let ws = WebServer()
        ws.refreshCachesIfGuideWindowMoved(state: state)          // nothing cached yet → no forced build
        #expect(ws.cachedGridWinStart == nil)
    }
}
