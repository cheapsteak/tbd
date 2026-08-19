-- leading comment; with a semicolon
CREATE TABLE IF NOT EXISTS c (x TEXT);
/* block comment;
   still a comment; even here */
INSERT OR IGNORE INTO c (x) VALUES ('y');
