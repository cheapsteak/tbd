-- Which transport carries this terminal's session, recorded at creation and
-- kept for life. NULL means the row predates the holder transport and is
-- therefore tmux; Terminal.transport resolves NULL — and any value a future
-- daemon writes that this one does not recognise — to .tmux.
ALTER TABLE terminal ADD COLUMN transport TEXT;

-- Holder identity, NULL for tmux-transport rows. tmuxWindowID/tmuxPaneID are
-- NOT NULL from the v1 schema and cannot be relaxed, so holder rows write the
-- empty string there and are discriminated by transport, never by those values.
ALTER TABLE terminal ADD COLUMN holder_pid INTEGER;
ALTER TABLE terminal ADD COLUMN child_pid INTEGER;
