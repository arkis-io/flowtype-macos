import Foundation

struct ProcessResult {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

final class ProcessRunner {
    func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        let processBox = ProcessBox()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()

                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.terminationHandler = { finishedProcess in
                    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: ProcessResult(
                        terminationStatus: finishedProcess.terminationStatus,
                        standardOutput: output,
                        standardError: error
                    ))
                }

                guard processBox.store(process) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                    processBox.processDidStart()
                } catch {
                    processBox.clear()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            processBox.cancel()
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func store(_ process: Process) -> Bool {
        lock.lock()
        if !cancelled {
            self.process = process
        }
        let shouldStart = !cancelled
        lock.unlock()
        return shouldStart
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func processDidStart() {
        lock.lock()
        let shouldCancel = cancelled
        let process = self.process
        lock.unlock()

        if shouldCancel, let process, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }
    }
}
