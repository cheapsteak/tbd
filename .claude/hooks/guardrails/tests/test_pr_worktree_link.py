import os
import sys
import tempfile
import threading
import unittest
from unittest import mock

_HOOKS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.pr_worktree_link import (  # noqa: E402
    _MAX_BODY_BYTES,
    PRWorktreeLinkRule,
    _file_has_link,
)

_TBD_HOME = "/tmp/pr-worktree-link-tests/tbd"
_IN_WORKTREE = os.path.join(_TBD_HOME, "worktrees", "tbd", "some-branch")
_OUTSIDE = "/tmp/pr-worktree-link-tests/elsewhere"
_LINK = "https://cheapsteak.github.io/tbd/open/?worktree=abc"


# The rule reads TBD_WORKTREE_ID / TBD_HOME inside check(), so patch.dict here
# actually takes effect; a module-level constant would be frozen at import.
def _env(worktree_id=None, tbd_home=_TBD_HOME):
    values = {"TBD_HOME": tbd_home}
    if worktree_id is not None:
        values["TBD_WORKTREE_ID"] = worktree_id
    patcher = mock.patch.dict(os.environ, values, clear=False)
    return patcher


def _check(command, cwd=_IN_WORKTREE, worktree_id=None, tbd_home=_TBD_HOME):
    with _env(worktree_id=worktree_id, tbd_home=tbd_home):
        # A real TBD_WORKTREE_ID in the developer's shell would mask the
        # cwd-based branch, so drop it unless the case supplies one.
        if worktree_id is None:
            os.environ.pop("TBD_WORKTREE_ID", None)
        return PRWorktreeLinkRule().check({"command": command}, {"cwd": cwd})


def _informs(testcase, command, **kwargs):
    decision = _check(command, **kwargs)
    assert decision is not None, command
    testcase.assertEqual(decision.action, "info", command)
    return decision


class PRWorktreeLinkTests(unittest.TestCase):
    def test_informs_on_bare_gh_pr_create_in_worktree(self):
        d = _informs(self, "gh pr create --title 'feat: thing'")
        self.assertIn("?worktree=", d.reason)
        self.assertIn("tbd link", d.reason)

    def test_informs_when_only_env_marks_the_session(self):
        _informs(self, "gh pr create", cwd=_OUTSIDE, worktree_id="1234-abcd")

    def test_silent_when_inline_body_already_has_link(self):
        self.assertIsNone(_check(f"gh pr create --body 'Summary\n\n[my-worktree]({_LINK})'"))

    def test_informs_when_only_the_bare_scheme_is_in_the_body(self):
        # `tbd link` prints the `tbd://` form, and GitHub renders it as
        # unclickable text — a body carrying only that has no link a reader can
        # follow, which is precisely the case the nudge exists for. Pasting
        # `tbd link`'s stdout straight in is the easiest way to get there.
        _informs(self, "gh pr create --body 'see tbd://open?worktree=abc'")
        _informs(self, "gh pr create --body 'see tbd://open?worktree=abc&terminal=def'")

    def test_silent_when_the_body_carries_the_redirector_form(self):
        # The https redirector is the clickable form, bare or with the
        # `&terminal=<uuid>` anchor `tbd link --terminal` appends.
        self.assertIsNone(_check(f"gh pr create --body 'Summary\n\n{_LINK}'"))
        self.assertIsNone(_check(f"gh pr create --body 'Summary\n\n{_LINK}&terminal=def'"))

    def test_silent_when_the_redirector_link_is_markdown_wrapped(self):
        # The `)` that closes a markdown link must not break the match, and the
        # `(` that opens it must not stop the URL from being found.
        self.assertIsNone(_check(f"gh pr create --body 'see [my-worktree]({_LINK}) above'"))
        self.assertIsNone(
            _check(f"gh pr create --body 'see [my-worktree]({_LINK}&terminal=def) above'")
        )

    def test_silent_when_the_worktree_param_is_not_first(self):
        # `worktree` is a query parameter wherever it sits in the query string,
        # so a hand-ordered link with the terminal anchor first still counts.
        link = "https://cheapsteak.github.io/tbd/open/?terminal=def&worktree=abc"
        self.assertIsNone(_check(f"gh pr create --body '[my-worktree]({link})'"))

    def test_silent_for_a_fork_hosted_redirector(self):
        # The host is not part of the check, so a fork serving the redirector
        # from its own Pages domain counts.
        self.assertIsNone(
            _check("gh pr create --body '[wt](https://someone.github.io/tbd/open/?worktree=abc)'")
        )

    def test_informs_when_the_path_only_ends_in_the_redirector_segment(self):
        # `/tbd/open/` is a whole path segment, so a longer segment ending in
        # those characters is a different URL and reopens nothing.
        _informs(
            self,
            "gh pr create --body '[x](https://example.com/nottbd/open/?worktree=abc)'",
        )

    def test_informs_when_the_worktree_param_is_missing(self):
        # A redirector URL naming no worktree reopens nothing.
        _informs(self, "gh pr create --body '[wt](https://cheapsteak.github.io/tbd/open/)'")

    def test_silent_when_link_is_inside_a_heredoc_body(self):
        command = (
            "gh pr create --title x --body \"$(cat <<'EOF'\n"
            "Summary\n\n"
            f"[my-worktree]({_LINK})\n"
            "EOF\n"
            ')"'
        )
        self.assertIsNone(_check(command))

    def test_informs_when_the_heredoc_body_carries_no_link(self):
        # Discriminates the heredoc branch: heredoc prose counts as body text,
        # so a heredoc body *without* the link must still nudge.
        command = (
            "gh pr create --title x --body \"$(cat <<'EOF'\n"
            "Summary\n\n"
            "No link here.\n"
            "EOF\n"
            ')"'
        )
        _informs(self, command)

    def test_informs_when_a_link_sits_outside_the_body(self):
        # A link elsewhere in the invocation is not the body: neither an
        # earlier segment's grep pattern nor a later segment's echo is text the
        # PR will carry.
        _informs(
            self,
            f'git log --oneline --grep "{_LINK}" '
            '&& gh pr create --title x --body "no link in this body at all"',
        )
        _informs(
            self,
            'gh pr create --title x --body "no link" '
            f'&& echo "opened from {_LINK}"',
        )

    def test_informs_when_only_the_body_file_path_looks_like_the_redirector(self):
        # The link must be in the file's contents, not in its name.
        with tempfile.TemporaryDirectory() as tmp:
            directory = os.path.join(tmp, "tbd", "open")
            os.makedirs(directory)
            path = os.path.join(directory, "body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("Summary\n\nNo link here.\n")
            self.assertIn("tbd/open/", path)
            _informs(self, f"gh pr create --body-file {path}")
            # `--body-file=…` is a file target, never inline `--body` text.
            _informs(self, f'gh pr create --body-file="{path}"')

    def test_silent_when_link_only_appears_in_a_written_heredoc_body(self):
        # The body file is written by the heredoc in the same command, so the
        # only copy of the link lives in a heredoc body — invisible both to the
        # tokenizer, which drops heredoc bodies, and to the file read, which
        # finds nothing at that path.
        command = (
            "cat <<'EOF' > /nonexistent/pr-worktree-link-body.md\n"
            f"[my-worktree]({_LINK})\n"
            "EOF\n"
            "gh pr create --body-file /nonexistent/pr-worktree-link-body.md\n"
        )
        self.assertIsNone(_check(command))

    def test_silent_when_body_file_already_has_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(f"Summary\n\n[my-worktree]({_LINK})\n")
            self.assertIsNone(_check(f"gh pr create --body-file {path}"))
            self.assertIsNone(_check(f'gh pr create --body-file="{path}"'))
            self.assertIsNone(_check(f"gh pr create -F {path}"))
            self.assertIsNone(_check(f"gh pr create -F={path}"))

    def test_silent_when_body_file_path_contains_spaces(self):
        # A regex over the raw command truncates the path at the first space and
        # then nudges on a body that already has the link.
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "pr body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(f"[my-worktree]({_LINK})\n")
            self.assertIsNone(_check(f'gh pr create --body-file "{path}"'))
            self.assertIsNone(_check(f'gh pr create --body-file="{path}"'))

    def test_informs_when_body_file_lacks_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("Summary\n\nNo link here.\n")
            _informs(self, f"gh pr create --body-file {path}")

    def test_informs_when_body_file_is_unreadable(self):
        _informs(self, "gh pr create --body-file /nonexistent/definitely/not/here.md")

    def test_body_file_read_is_bounded(self):
        # The hook blocks the Bash call while it runs, so it reads a capped
        # prefix. A link past the cap is not seen, and the nudge still fires.
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "huge.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("x" * (_MAX_BODY_BYTES + 4096))
                handle.write(f"\n[my-worktree]({_LINK})\n")
            _informs(self, f"gh pr create --body-file {path}")

    def test_body_file_read_is_bounded_in_bytes_not_characters(self):
        # The cap is a byte cap. This body's link sits past the cap in bytes but
        # well inside it in characters, so a character-counting read would see
        # the link and go silent; the byte-counting read must still nudge.
        filler_characters = (_MAX_BODY_BYTES // 3) + 4096  # 3-byte characters
        self.assertLess(filler_characters, _MAX_BODY_BYTES)
        self.assertGreater(filler_characters * 3, _MAX_BODY_BYTES)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "multibyte.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("あ" * filler_characters)
                handle.write(f"\n[my-worktree]({_LINK})\n")
            self.assertGreater(os.path.getsize(path), _MAX_BODY_BYTES)
            _informs(self, f"gh pr create --body-file {path}")

    def test_non_regular_body_file_is_never_opened(self):
        # Opening a fifo with no writer blocks forever; the hook must not hang.
        if not hasattr(os, "mkfifo"):
            self.skipTest("no mkfifo on this platform")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.fifo")
            os.mkfifo(path)
            result = []
            worker = threading.Thread(target=lambda: result.append(_file_has_link(path)))
            worker.daemon = True
            worker.start()
            worker.join(5)
            self.assertFalse(worker.is_alive(), "reading a fifo hung the guardrail")
            self.assertEqual(result, [False])

    def test_fifo_contents_are_never_read(self):
        # Holding the fifo open read-write buffers the link with no risk of
        # blocking, so the only thing keeping it unread is the regular-file
        # check on the descriptor.
        if not hasattr(os, "mkfifo"):
            self.skipTest("no mkfifo on this platform")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.fifo")
            os.mkfifo(path)
            holder = os.open(path, os.O_RDWR | os.O_NONBLOCK)
            try:
                os.write(holder, f"[my-worktree]({_LINK})\n".encode("utf-8"))
                self.assertFalse(_file_has_link(path))
                _informs(self, f"gh pr create --body-file {path}")
            finally:
                os.close(holder)

    def test_silent_for_non_gh_pr_create_command(self):
        self.assertIsNone(_check("gh pr list"))
        self.assertIsNone(_check("gh pr view 12"))
        self.assertIsNone(_check("gh pr edit 12 --body x"))
        self.assertIsNone(_check("git commit -m 'feat: thing'"))
        self.assertIsNone(_check("echo gh-pr-create"))

    def test_informs_after_a_command_separator(self):
        _informs(self, "git push -u origin HEAD && gh pr create --fill")
        _informs(self, "cd /tmp && gh  pr   create -t x")

    def test_silent_for_a_quoted_mention(self):
        # A quoted mention (commit message, grep pattern) is an argument, not an
        # invocation — and a separator inside the quotes must not manufacture a
        # segment either.
        self.assertIsNone(_check("git commit -m 'docs: explain `gh pr create` usage'"))
        self.assertIsNone(_check('grep -rn "gh pr create" docs/'))
        self.assertIsNone(_check('echo "x && gh pr create"'))

    def test_silent_for_a_heredoc_body_mention(self):
        # Heredoc bodies are prose the command writes, not commands it runs.
        self.assertIsNone(
            _check("cat <<'EOF' | tee -a CONTRIBUTING.md\nTo open a PR:\ngh pr create --fill\nEOF")
        )
        self.assertIsNone(_check("cat <<EOF > docs/howto.md\ngh pr create --fill\nEOF"))
        self.assertIsNone(_check("cat <<-EOF > docs/howto.md\n\tgh pr create --fill\n\tEOF"))

    def test_informs_after_a_heredoc_terminator(self):
        # The real invocation on the far side of a heredoc still counts.
        command = (
            "cat <<'EOF' > /tmp/body.md\n"
            "Some body text mentioning gh pr create\n"
            "EOF\n"
            "gh pr create --title x\n"
        )
        _informs(self, command)

    def test_tolerates_global_flags_between_gh_and_pr(self):
        _informs(self, "gh --repo owner/name pr create --fill")
        # `-R` takes a value, so its argument must not be read as the subcommand.
        _informs(self, "gh -R owner/name pr create --fill")

    def test_informs_for_a_path_qualified_gh(self):
        # Homebrew's `gh` is regularly invoked by absolute path in this repo.
        _informs(self, "/opt/homebrew/bin/gh pr create --fill")

    def test_informs_for_glab_mr_create(self):
        _informs(self, "glab mr create --fill")
        _informs(self, "/opt/homebrew/bin/glab mr create --fill")

    def test_informs_for_gh_draft_flag_carrying_a_link_shaped_word(self):
        # `-d` is gh's `--draft`, a boolean that takes no value. The word after
        # it is a separate argument, never the body — so a link there is not in
        # the body gh will send, and the nudge must still fire.
        _informs(self, f"gh pr create -d '{_LINK}'")
        _informs(self, f"gh pr create --title x -d --body 'no link' {_LINK}")

    def test_informs_when_gh_is_given_glabs_description_flag(self):
        # `--description` is not a gh flag, so its value is not a gh body.
        _informs(self, f"gh pr create --description '[wt]({_LINK})'")

    def test_silent_for_glab_description_flags(self):
        # glab spells the body `--description`/`-d`; both are body text there.
        self.assertIsNone(_check(f"glab mr create --description '[wt]({_LINK})'"))
        self.assertIsNone(_check(f"glab mr create -d '[wt]({_LINK})'"))
        self.assertIsNone(_check(f"glab mr create --description='[wt]({_LINK})'"))

    def test_informs_when_glab_is_given_ghs_body_flags(self):
        # `--body`/`-b` are gh spellings; glab does not read a body from them.
        _informs(self, f"glab mr create --body '[wt]({_LINK})'")
        _informs(self, f"glab mr create -b '[wt]({_LINK})'")

    def test_informs_when_glab_is_given_ghs_body_file_flags(self):
        # No glab body-file spelling is claimed, so a gh-style file flag on glab
        # names nothing the rule will read — even when the file has the link.
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(f"[my-worktree]({_LINK})\n")
            _informs(self, f"glab mr create --body-file {path}")
            _informs(self, f"glab mr create -F {path}")

    def test_repeated_body_text_flags_take_the_last(self):
        # `gh`/`glab` send the final `--body`; an earlier one is discarded, so
        # only the last occurrence can silence the nudge.
        _informs(self, f"gh pr create --body '[wt]({_LINK})' --body 'no link here'")
        self.assertIsNone(_check(f"gh pr create --body 'no link here' --body '[wt]({_LINK})'"))
        # Spellings of one flag are aliases, so last-across-the-family wins.
        _informs(self, f"gh pr create -b '[wt]({_LINK})' --body 'no link here'")
        self.assertIsNone(_check(f"gh pr create --body 'no link here' -b '[wt]({_LINK})'"))
        _informs(self, f"glab mr create -d '[wt]({_LINK})' --description 'no link here'")

    def test_repeated_body_file_flags_take_the_last(self):
        with tempfile.TemporaryDirectory() as tmp:
            linked = os.path.join(tmp, "linked.md")
            with open(linked, "w", encoding="utf-8") as handle:
                handle.write(f"[my-worktree]({_LINK})\n")
            bare = os.path.join(tmp, "bare.md")
            with open(bare, "w", encoding="utf-8") as handle:
                handle.write("No link here.\n")
            _informs(self, f"gh pr create --body-file {linked} --body-file {bare}")
            self.assertIsNone(_check(f"gh pr create --body-file {bare} --body-file {linked}"))

    def test_silent_when_the_verb_belongs_to_the_other_cli(self):
        self.assertIsNone(_check("gh mr create"))
        self.assertIsNone(_check("glab pr create"))

    def test_silent_for_a_lookalike_subcommand(self):
        self.assertIsNone(_check("gh pr create-template"))

    def test_silent_outside_tbd(self):
        self.assertIsNone(_check("gh pr create", cwd=_OUTSIDE))
        self.assertIsNone(_check("glab mr create", cwd=_OUTSIDE))

    def test_never_denies(self):
        commands = (
            "gh pr create",
            "glab mr create",
            f"gh pr create --body 'has {_LINK}'",
            "gh pr create --body 'has tbd://open?worktree=abc'",
            "gh pr create --body-file /nonexistent/x.md",
            f"gh pr create -d '{_LINK}'",
            f"glab mr create -d '{_LINK}'",
            f"gh pr create --body '{_LINK}' --body 'no link'",
            "/opt/homebrew/bin/gh pr create",
            "cat <<'EOF' > x.md\ngh pr create\nEOF",
            "gh pr list",
        )
        for command in commands:
            for cwd in (_IN_WORKTREE, _OUTSIDE):
                d = _check(command, cwd=cwd)
                if d is not None:
                    self.assertNotEqual(d.action, "deny", command)


if __name__ == "__main__":
    unittest.main()
