#ifndef COMRAK_FFI_H
#define COMRAK_FFI_H

/// Render markdown to HTML in comrak safe mode.
/// Returns a NUL-terminated UTF-8 buffer owned by the caller, or NULL on
/// invalid input. Release with tbd_markdown_free.
char *tbd_markdown_to_html(const char *input);

/// Release a buffer returned by tbd_markdown_to_html.
void tbd_markdown_free(char *buffer);

#endif /* COMRAK_FFI_H */
