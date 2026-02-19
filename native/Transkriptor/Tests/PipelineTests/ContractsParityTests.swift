import Domain
import Testing

@Test
func jobStatusStorageValuesMatchSharedContract() {
    let expected = [
        "queued",
        "preprocessing",
        "transcribing_openai",
        "transcribing_fallback",
        "merging",
        "ready",
        "paused_retry_openai",
        "failed",
    ]

    let actual = [
        JobStatus.queued,
        .preprocessing,
        .transcribingOpenAI,
        .transcribingFallback,
        .merging,
        .ready,
        .pausedRetryOpenAI,
        .failed,
    ].map(\.storageValue)

    #expect(actual == expected)
    #expect(expected.allSatisfy { JobStatus(storageValue: $0).storageValue == $0 })
}

@Test
func chunkStatusStorageValuesAreStable() {
    let expected = [
        "queued",
        "transcribing_openai",
        "transcribing_fallback",
        "done",
        "paused_retry_openai",
        "failed",
    ]

    let actual = [
        ChunkStatus.queued,
        .transcribingOpenAI,
        .transcribingFallback,
        .done,
        .pausedRetryOpenAI,
        .failed,
    ].map(\.storageValue)

    #expect(actual == expected)
    #expect(expected.allSatisfy { ChunkStatus(storageValue: $0).storageValue == $0 })
}
