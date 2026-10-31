-- Resets the activity a hook wrote on every live terminal row.
--
-- The agent's own OSC 7501 report is the only writer of `activityState` and
-- the wait-reason columns, and no hook writes them any more. A value a hook
-- wrote before this build would therefore stand forever: a `working` would
-- block every auto-park, and a `waiting_for_user` would keep a prompt on
-- screen that is long gone. Such a row reads `unknown` instead, which is what
-- TBD knows about it, until the session is relaunched or woken and reports.
--
-- Two kinds of row keep their values:
--
-- - Rows the program status store wrote. Their source is
--   `FactColumnJSON.encode(FactSource.programStatus)`, exactly
--   `{"kind":"program-status"}`, the only form that writer produces. A NULL
--   source is a row no writer stamped, and is reset.
-- - Parked rows, hibernated or legacy-suspended. Their `idle` is the park's own
--   record, and the wake resets it for the new incarnation.
--
-- The source, the observation stamps and the wait reason go to NULL, so a
-- reset row claims no provenance and reads as no report.
UPDATE terminal
SET activityState = 'unknown', activityStateSource = NULL, activityStateObservedAt = NULL,
    activityStateOrderObservedAt = NULL, awaitingInputReason = NULL, awaitingInputObservedAt = NULL
WHERE hibernatedAt IS NULL AND suspendedAt IS NULL
  AND (activityStateSource IS NULL OR activityStateSource <> '{"kind":"program-status"}');
