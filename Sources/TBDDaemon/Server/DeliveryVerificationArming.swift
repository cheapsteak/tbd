import Foundation

/// The hand-off from a dispatched send to the observation that will establish
/// whether it landed — the second rung of the record's ladder handing to the
/// third (fleet-supervision design §12).
///
/// The send path deliberately owns none of the observation. It knows only that
/// it typed something, which is precisely the claim §12 forbids conflating with
/// delivery, so the whole of "did it land" lives behind this one method: the
/// one-minute re-check, the transcript tail read, the four-result mapping, the
/// evidence-bounded single retry, and the startup replay.
///
/// **Contract.**
/// - Called **exactly once** per send, and only for a send that was
///   `.dispatched`, carried a non-empty **text** payload, and whose caller
///   armed `--verify` while `delivery_verification_enabled` was on. Never for
///   a verify-less send, a refused send, a transport failure, or a `--keys`
///   payload (keys reach no transcript, so there is nothing to observe).
/// - `deliveredPayload` is the bytes that actually reached the pane —
///   **envelope line included** — so a retry re-delivers byte-identically and
///   still joins on the original row. The envelope's id *is* `actuationID`;
///   there is no second identifier namespace.
/// - Implementations must not block the send: the RPC response is the caller's
///   synchronous result, and the observation happens a minute later.
///
/// **Unimplemented on purpose.** Nothing conforms to this yet. The conforming
/// type is `DeliveryVerifier` — the re-check actor, the retry, the anomaly, and
/// the startup replay — which lands beside this and is wired onto
/// `RPCRouter.deliveryVerifier` in `Daemon.swift` next to
/// `performStartupReconciliation`. Until then `deliveryVerifier` is nil, an
/// armed send is simply never observed, and `DeliveryRecord.statuses` renders
/// it `unconfirmed` — the fail-closed answer, and the reason no repair row is
/// ever written to say so.
protocol DeliveryVerificationArming: Sendable {
    func armVerification(
        actuationID: String,
        terminalID: UUID,
        deliveredPayload: String,
        submit: Bool
    ) async
}
