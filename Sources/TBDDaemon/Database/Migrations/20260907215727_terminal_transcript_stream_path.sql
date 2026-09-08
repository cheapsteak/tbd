-- The absolute path of the model proxy's stream file for this terminal, or
-- NULL when the session was never routed through the proxy.
--
-- Recorded at spawn, because a session's base URL is fixed in its environment
-- at start: a terminal either has a stream file for life or never gets one, and
-- flipping the flags afterwards changes neither. The app registers a tail on
-- this path; a terminal with NULL here registers no stream and renders exactly
-- what it renders today.
ALTER TABLE terminal ADD COLUMN transcript_stream_path TEXT;
