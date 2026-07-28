//
//  RTSPConnection+IO.swift
//  VigilTransport
//
//  The socket halves: read backpressure, the read loop, and the write path.
//  macOS-only. Split from RTSPConnection.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Dispatch
import Foundation
import Network
import VigilProtocols
import VigilRTSP

// MARK: - Reading and writing

/// ⚠️ Members here are `internal`, not `private`: Swift scopes `private` to one file, so anything
/// the rest of the actor calls would become invisible. `Scripts/lint.py`'s `split-access` rule
/// fails the build if one is left behind.
extension RTSPConnection {

    // MARK: - Read backpressure

    /// Stops issuing new receives.
    ///
    /// One receive may already be outstanding and will still complete — this is not a guarantee that
    /// no more bytes arrive, it is a guarantee that no more are asked for. That is what makes the
    /// camera feel the TCP window close, which is the only flow control `Rate-Control: no` playback
    /// has (API_CONTRACT §4.7).
    public func pauseReads() {
        guard !isReadPaused else { return }
        isReadPaused = true
        logger.debug(.transport, "reads paused")
    }

    /// Resumes issuing receives.
    public func resumeReads() {
        guard isReadPaused else { return }
        isReadPaused = false
        logger.debug(.transport, "reads resumed")
        wakeReadLoop()
    }

    // MARK: - Reading

    func startReadLoop() {
        readTask = Task { await self.runReadLoop() }
    }

    /// Feeds every received byte into the machine, in arrival order.
    ///
    /// Order is guaranteed by construction: exactly one `receive` is outstanding at a time, because
    /// the next one is only issued after the previous chunk has been ingested. Issuing several and
    /// hopping each onto the actor separately would deliver them in whatever order the actor
    /// scheduled, which for a byte stream is corruption.
    private func runReadLoop() async {
        var consecutiveEmpty = 0

        while lifecycle == .running {
            while lifecycle == .running, isReadPaused {
                await waitForReadResume()
            }
            guard lifecycle == .running, let socket else { return }

            let outcome = await receiveOnce(socket)

            // The socket may have been torn down while this loop was suspended. A completion
            // handler that fires after cancellation must not restart a session that is over.
            guard lifecycle == .running else { return }

            switch outcome {
            case .bytes(let chunk):
                if chunk.isEmpty {
                    // `receive(minimumIncompleteLength:maximumLength:)` can call back with zero
                    // bytes and `isComplete == false`. Treating that as EOF closes healthy
                    // connections, so it is not an ending — it is another receive. The counter is
                    // only a governor against spinning at full speed if it never stops.
                    consecutiveEmpty += 1
                    guard consecutiveEmpty <= Self.maxConsecutiveEmptyReceives else {
                        deliverFailure(.transport(.network(
                            "receive delivered no bytes \(consecutiveEmpty) times in a row")))
                        return
                    }
                    continue
                }
                consecutiveEmpty = 0
                let actions = machine.ingest(chunk, now: clock.now())
                execute(actions)

            case .endOfStream:
                // The machine is told first here, deliberately, and it is the one case where that
                // is right: a FIN that arrives while `TEARDOWN` is outstanding is a **normal**
                // close, and only the machine knows that. It answers a FIN in any other state with
                // a failure of its own.
                logger.info(.transport, "peer closed the connection")
                feedConnectionClosed(reason: nil)
                // Unconditional, and not redundant: a machine that has already terminated returns
                // no actions at all, and the socket would otherwise stay open with nobody reading.
                beginClose()
                return

            case .failed(let error):
                // The socket's own error is reported first, and `deliverFailure` latches, so the
                // machine's consequent `.fail` does not overwrite it. `RTSPError` has no
                // `transportClosed` member, so the machine answers a dead socket with the closest
                // retryable timeout — accurate about the policy, useless about the cause. The
                // cause is `ECONNRESET`, and that is what the user's bug report needs.
                deliverFailure(error)
                // `describe(_:)` takes an `NWError`; by this point the platform error has already
                // been mapped, so the machine is told the diagnostic code — which is the stable,
                // greppable form and is what a bug report quotes. (This line read
                // `Self.describe(error)` and did not compile: the read loop's `.failed` carries a
                // `VigilError`, not an `NWError`. Found by shadow-compiling this file on Linux
                // against a stub of Network.framework, which is the only compiler it gets here.)
                feedConnectionClosed(reason: error.diagnosticCode)
                return

            case .torndown:
                return
            }
        }
    }

    /// One `receive`, reduced to a `ReceiveOutcome`.
    ///
    /// `NWConnection`:
    ///   `public func receive(minimumIncompleteLength: Int, maximumLength: Int,`
    ///   `                    completion: @escaping (Data?, NWConnection.ContentContext?, Bool,`
    ///   `                                          NWError?) -> Void)`
    /// The completion is called exactly once per call, on the connection's queue.
    private func receiveOnce(_ socket: NWConnection) async -> ReceiveOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ReceiveOutcome, Never>) in
                socket.receive(minimumIncompleteLength: 1,
                               maximumLength: Self.readChunkSize) { content, _, isComplete, error in
                    // GCD → actor. Resuming a continuation is safe from any thread; nothing else in
                    // this closure touches actor state, which is why there is no hop here.
                    if let error {
                        continuation.resume(returning: RTSPConnection.outcome(for: error))
                        return
                    }
                    if let content, !content.isEmpty {
                        continuation.resume(returning: .bytes(content))
                        return
                    }
                    // No error and no bytes. Only `isComplete` means end of stream; the other case
                    // is an empty delivery and the loop simply asks again.
                    continuation.resume(returning: isComplete ? .endOfStream : .bytes(Data()))
                }
            }
        } onCancel: {
            // Task cancellation has to reach the socket, or the receive above never completes and
            // this task leaks (API_CONTRACT §4.7). `cancel()` makes the completion fire with
            // `POSIXErrorCode.ECANCELED`.
            //
            // Routed through the actor rather than calling `socket.cancel()` here. `onCancel` is
            // `@Sendable`, so naming the socket in it captures an `NWConnection` across an
            // isolation boundary, and whether `NWConnection` is `Sendable` in the macOS 14/15 SDK
            // is the one thing this file could not check — shadow-compiling against a
            // non-`Sendable` stub gives "capture of 'socket' with non-sendable type 'NWConnection'
            // in a '@Sendable' closure" on exactly this line and on the same line in
            // `sendAtomically`, and nowhere else. Capturing the actor instead is correct either
            // way and needs no `@unchecked Sendable` box, which ruling R-52 forbids. The hop costs
            // one actor turn on a path that is already tearing down.
            Task { await self.cancelSocket() }
        }
    }

    /// Cancels the socket from the actor's own isolation.
    ///
    /// Exists only so the two `@Sendable` cancellation handlers never have to name an
    /// `NWConnection`. Reads `self.socket` rather than taking one: by the time a cancellation hop
    /// lands, `finishClose` may already have cancelled and cleared it, and a second cancel of a
    /// dead connection is a no-op.
    private func cancelSocket() {
        socket?.cancel()
    }

    /// Suspends the read loop while reads are paused.
    ///
    /// Safe against a missed wakeup: this runs on the actor and `withCheckedContinuation` installs
    /// the waiter before suspending, so `resumeReads()` cannot slip in between the check and the
    /// installation.
    private func waitForReadResume() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readResumeWaiter?.resume()
            readResumeWaiter = continuation
        }
    }

    func wakeReadLoop() {
        guard let waiter = readResumeWaiter else { return }
        readResumeWaiter = nil
        waiter.resume()
    }

    /// Tells the machine the connection went away, and executes what it decides.
    func feedConnectionClosed(reason: String?) {
        let actions = machine.connectionClosed(error: reason, now: clock.now())
        execute(actions)
    }

    // MARK: - Writing

    func startWriteDrain() {
        writeTask = Task { await self.runWriteDrain() }
    }

    /// Writes queued frames one at a time, in the order `execute(_:)` queued them.
    ///
    /// One `send` at a time, awaited: that is what makes each `.send` action a single atomic write
    /// and keeps two action batches from interleaving their bytes.
    private func runWriteDrain() async {
        while true {
            if writeQueue.isEmpty {
                if isWriteClosed || lifecycle == .closed { return }
                await waitForWrite()
                continue
            }
            guard let socket else { return }

            let data = writeQueue.removeFirst()
            writeQueueBytes -= data.count

            if let failure = await sendAtomically(data, on: socket) {
                // A send that failed after the socket was torn down locally is expected and is not
                // the session's cause of death.
                guard lifecycle == .running else { return }
                deliverFailure(failure)
                return
            }
        }
    }

    /// Queues one frame for writing. Never suspends, so a whole action batch is queued atomically.
    ///
    /// Overflow is terminal rather than silent. Dropping one request desynchronises `CSeq` for the
    /// rest of the session, and the failure would surface minutes later as an unanswered request
    /// pointing at the camera. A full queue means the socket has stopped draining, which the
    /// machine's own timers would find shortly anyway.
    func enqueueWrite(_ data: Data) {
        guard lifecycle == .connecting || lifecycle == .running, !isWriteClosed else { return }
        guard writeQueue.count < Self.maxQueuedWrites,
              writeQueueBytes + data.count <= Self.maxQueuedWriteBytes else {
            deliverFailure(.transport(.network(
                "outbound queue full at \(writeQueue.count) frames / \(writeQueueBytes) bytes")))
            return
        }
        writeQueue.append(data)
        writeQueueBytes += data.count
        wakeWriteDrain()
    }

    private func waitForWrite() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeWaiter?.resume()
            writeWaiter = continuation
        }
    }

    func wakeWriteDrain() {
        guard let waiter = writeWaiter else { return }
        writeWaiter = nil
        waiter.resume()
    }

    /// One frame, one write. Returns `nil` on success.
    ///
    /// `NWConnection`:
    ///   `public func send(content: Data?, contentContext: NWConnection.ContentContext = .defaultMessage,`
    ///   `                 isComplete: Bool = true, completion: NWConnection.SendCompletion)`
    /// `NWConnection.SendCompletion`:
    ///   `case idempotent`
    ///   `case contentProcessed(_ handler: @escaping (_ error: NWError?) -> Void)`
    ///
    /// `.contentProcessed`, not `.idempotent`: we need to know the write failed, and we need the
    /// completion as the signal to start the next one.
    private func sendAtomically(_ data: Data, on socket: NWConnection) async -> VigilError? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<VigilError?, Never>) in
                socket.send(content: data,
                            contentContext: .defaultMessage,
                            isComplete: true,
                            completion: .contentProcessed { error in
                    // GCD → actor. Only the continuation is touched, so no hop is needed.
                    guard let error else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: RTSPConnection.mapped(error))
                })
            }
        } onCancel: {
            // Through the actor, for the reason spelled out in `receiveOnce`.
            Task { await self.cancelSocket() }
        }
    }
}

#endif
