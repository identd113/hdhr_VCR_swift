import Testing
import Foundation
@testable import hdhr_VCR

// Coverage for AppState.byteOffset(forTargetSeconds:elapsedSeconds:fileSizeBytes:) — the pure
// arithmetic extracted from recordingByteOffset(for:atSeconds:) (Watch Now) so the FEED local disk
// cache's own feedCacheByteOffset(for:atSeconds:) can share one implementation instead of two
// copies that could drift. Raw MPEG-TS has no index, so this estimates a byte offset from a
// constant-bitrate assumption (bytes written so far / seconds recorded so far), aligned to a
// 188-byte TS packet boundary — approximate, not frame-accurate.
@Suite("AppState.byteOffset")
struct AppStateByteOffsetTests {

    @Test func zeroFileSize_returnsZero() {
        #expect(AppState.byteOffset(forTargetSeconds: 30, elapsedSeconds: 60, fileSizeBytes: 0) == 0)
    }

    @Test func zeroElapsedSeconds_returnsZero() {
        #expect(AppState.byteOffset(forTargetSeconds: 30, elapsedSeconds: 0, fileSizeBytes: 1_000_000) == 0)
    }

    @Test func negativeFileSize_returnsZero() {
        #expect(AppState.byteOffset(forTargetSeconds: 30, elapsedSeconds: 60, fileSizeBytes: -1) == 0)
    }

    @Test func targetZero_returnsZero() {
        // 60s elapsed, 6,000,000 bytes written → 100,000 bytes/sec; target 0s → byte 0 (already 188-aligned).
        #expect(AppState.byteOffset(forTargetSeconds: 0, elapsedSeconds: 60, fileSizeBytes: 6_000_000) == 0)
    }

    @Test func targetPastElapsed_clampsToElapsed() {
        // Requesting a target beyond how far the recording has actually gotten must clamp to
        // `elapsedSeconds`, not extrapolate past the file's own real size.
        let atElapsed  = AppState.byteOffset(forTargetSeconds: 60,  elapsedSeconds: 60, fileSizeBytes: 6_000_000)
        let pastElapsed = AppState.byteOffset(forTargetSeconds: 600, elapsedSeconds: 60, fileSizeBytes: 6_000_000)
        #expect(pastElapsed == atElapsed)
    }

    @Test func negativeTarget_clampsToZero() {
        #expect(AppState.byteOffset(forTargetSeconds: -30, elapsedSeconds: 60, fileSizeBytes: 6_000_000) == 0)
    }

    @Test func midpointTarget_scalesLinearlyWithConstantBitrateAssumption() {
        // 100,000 bytes/sec (6,000,000 / 60s); target 30s → ~3,000,000 bytes, 188-aligned.
        let offset = AppState.byteOffset(forTargetSeconds: 30, elapsedSeconds: 60, fileSizeBytes: 6_000_000)
        let expected = 3_000_000 - 3_000_000 % 188
        #expect(offset == expected)
    }

    @Test func result_isAlwaysAlignedToA188ByteTSPacketBoundary() {
        for (target, elapsed, size) in [(17.3, 60.0, 6_123_457), (1.0, 3.7, 999_999), (45.0, 90.0, 12_345_678)] {
            let offset = AppState.byteOffset(forTargetSeconds: target, elapsedSeconds: elapsed, fileSizeBytes: size)
            #expect(offset % 188 == 0, "target=\(target) elapsed=\(elapsed) size=\(size) → offset \(offset) not 188-aligned")
        }
    }

    @Test func result_isNeverNegative() {
        for (target, elapsed, size) in [(-100.0, 60.0, 6_000_000), (0.0, 0.001, 1), (5.0, 5.0, 1)] {
            #expect(AppState.byteOffset(forTargetSeconds: target, elapsedSeconds: elapsed, fileSizeBytes: size) >= 0)
        }
    }
}
