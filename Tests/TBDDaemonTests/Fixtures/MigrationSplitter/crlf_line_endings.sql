-- crlf_line_endings: every newline in this file is CRLF.
CREATE TABLE IF NOT EXISTS crlf_demo (id INTEGER PRIMARY KEY);

-- A comment attached to a statement that has no trailing semicolon.
ALTER TABLE crlf_demo ADD COLUMN note TEXT