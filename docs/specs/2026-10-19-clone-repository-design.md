# Clone a repository when adding it

"Add Repository" registers a git repository that is already on disk. To work
on a repository that is only on GitHub or another git host, a person must
first run `git clone` in a terminal and then add the folder. This design lets
TBD do both steps: it clones a remote repository into a folder the person
chooses, then registers that folder exactly as "Add Repository" does today.

The clone runs in the client, the app or the `tbd` CLI. When the clone is
done, the client calls the existing `repo.add` RPC with the new folder. There
is no daemon change, no RPC change, no migration and no feature flag.

## Principles

- **A clone is a means to a local repo.** After the clone, the repository is an
  ordinary local repository. Worktrees, terminals and PR status work on it as
  on any other. TBD keeps no record that it was cloned.
- **Nothing that works today changes.** The "Add Repository" click and
  `tbd repo add <path>` behave exactly as before for every path that exists.
- **git does the work, and its text is shown, not parsed.** TBD runs a plain
  `git clone` and shows git's own progress and error text. TBD draws no
  conclusions from that text.
- **TBD never deletes a folder it did not create.**

## Reading the argument

One parser, `RepoSource` in `TBDShared`, reads what the person typed. The app
and the CLI both use it. It is a pure function of the text and a "does this
path exist" check, and gives one of four results:

- **`.local(path)`** – add this folder, as today.
- **`.remote(url, folderName)`** – clone this URL.
- **`.githubShortForm(owner, repo)`** – clone this GitHub repository. The URL is
  chosen later (see "Turning a short form into a URL").
- **`.invalid(reason)`** – refuse, with the reason.

It applies these rules in order and stops at the first match:

1. **An existing local path → add.** This includes `.`, `~/code/foo`, and
   `foo/bar` when that folder exists. Because this rule comes first, a real
   local folder always wins over every reading below, and every argument that
   works today keeps working the same way.
2. **A full URL → clone.** That is `https://`, `http://`, `ssh://`, `git://`,
   `file://`, or git's scp-like form: a colon before the first slash, such as
   `git@github.com:owner/repo.git` or `github-work:org/repo` (an SSH host
   alias). This is the same test git uses to decide that a `git clone` argument
   is remote.
3. **`owner/repo` or `github.com/owner/repo`, with no such local folder →
   clone from GitHub.** The text must have this exact shape. The owner holds
   only letters, digits and hyphens. The repository name holds only letters,
   digits, `-`, `_` and `.`, and is not `.` or `..`. A trailing `.git` is
   dropped. Text that starts with `.`, `/` or `~` never matches this rule.
4. **Anything else → invalid.** For the CLI, the error is the same as today's
   "Not a git repository".

Two forms let a person override rule 1 and rule 3:

- **To clone when a local `foo/bar` exists**, type `github.com/foo/bar` or the
  full URL.
- **To force a local path**, type `./foo/bar`.

The **folder name** for a remote source is the last part of the URL path with
any `.git` suffix removed, which is the name git itself would pick.
`https://github.com/acme/widgets.git` gives `widgets`.

**`owner/repo` means github.com.** This is a choice, and a team on GitLab or
GitHub Enterprise would choose differently. That is why a full URL always
works. The short form is only a shortcut on top of it, for the host the most
people use.

## Turning a short form into a URL

For `.githubShortForm`, TBD picks the URL the way `gh repo clone` does. It runs
`gh config get git_protocol -h github.com`:

- **`ssh`** → `git@github.com:owner/repo.git`
- **`https`, empty output, any error, or no `gh` installed** →
  `https://github.com/owner/repo.git`

The `gh` call goes through an injected runner, like `PRStatusManager`'s
`ghRunner`, so tests do not depend on the machine's `gh`.

## Running the clone

`RepoCloner`, in `TBDShared`, runs one clone:

- **Finding git and gh.** It looks them up with `ExecutableSearchPath`. The app
  may start with launchd's bare `PATH`, and a lookup on that alone would miss a
  Homebrew git or gh.
- **The command.** `git clone --progress <url> <dest>`. This is a full clone:
  not shallow, and with no submodule recursion, which are git's defaults. A
  shallow clone would break the branch and PR features TBD depends on.
- **Progress (app mode).** Each line git writes to stderr goes to a callback.
  git ends a progress update with a carriage return, so the reader splits on
  both `\r` and `\n`.
- **Before starting.** `RepoCloner` claims `<dest>` by creating it as an empty
  folder with `mkdir`, after creating any missing parent folders. If `<dest>`
  already exists, `mkdir` fails and `RepoCloner` refuses without starting git.
  The claim is atomic: two clones aimed at the same path cannot both own it, so
  neither can later delete the other's folder. git then clones into the empty
  folder this run owns.
- **Cancel.** Cancel sends SIGTERM to git. git removes what it wrote but keeps
  the folder it was given. After git exits, `RepoCloner` deletes the claimed
  folder and anything left in it, because the person asked to stop.
- **Failure.** When a fetch fails, git removes what it wrote and leaves the
  claimed folder empty, and `RepoCloner` removes that empty folder. But git
  sometimes exits non-zero and keeps a complete repository on purpose: when
  the checkout fails (for example, a missing Git LFS filter) or a
  `post-checkout` hook fails, git tells the person to inspect it. So after a
  failure `RepoCloner` removes the claimed folder only if it is empty, and
  leaves a repository git kept.
- **What it never deletes.** It never deletes a folder it did not claim, and it
  deletes nothing when it cannot tell how git exited.
- **No timeout.** A large repository can take many minutes to clone, and only
  the person knows whether to wait. So there is no new timer and no clock seam.

The app and the CLI run git in two different modes:

- **App: git may never prompt.** Nobody could answer a password prompt from the
  app. So the app sets `GIT_TERMINAL_PROMPT=0`, gives git an empty stdin, and
  runs it with no controlling terminal. A clone that needs a login then fails
  fast with git's error, and does not hang.
- **CLI: git is attached to the terminal.** git inherits the terminal, so the
  person sees git's own progress and git can ask for a password in the normal
  way. While git runs, the CLI ignores SIGINT and SIGQUIT, as `system(3)`
  does. Ctrl-C still reaches git, which stops and cleans up; the CLI stays
  alive long enough for `RepoCloner` to remove the claimed folder, then exits
  non-zero. A Ctrl-C reaches git as a failure, not as a cancel, so the failure
  rule applies: a repository git kept, because the Ctrl-C came during the
  checkout, stays.

## The app

### Entry points

- **Sidebar footer.** "Add Repository" becomes a split button
  (`Menu(primaryAction:)`). A click on the label opens the folder picker, the
  same as today. The arrow opens a menu with "Local Folder…" (the same folder
  picker) and "Clone from URL…".
- **Empty start screen.** The "Add Repository" button stays as it is. A second
  button, "Clone Repository…", sits below it.

### The clone sheet

- **Repository.** One text field for a URL or `owner/repo`. `RepoSource` checks
  the text as the person types. The app has no working folder, so its "does
  this path exist" check always answers no, and text that starts with `/` or
  `~` is reported as "This is a local folder. Use Local Folder… instead."
  Other invalid text shows the parser's reason.
- **Clone into.** The parent folder, with a "Choose…" button. It starts as the
  last parent folder used for a clone, or the home folder the first time. The
  app keeps this in `UserDefaults`, because it is a per-person convenience and
  not state anyone else reads. Tests use
  `AppState(userDefaults: UserDefaults(suiteName:))`.
- **Folder name.** Filled in from the parser's folder name. The person can edit
  it.
- **Destination.** The full path, shown below the fields with `~` for the home
  folder, for example `~/code/widgets`.
- **"Clone" button.** Disabled until the repository text is valid and the
  destination does not exist.

### While cloning

The fields lock. A spinner shows, with git's most recent progress line, for
example `Receiving objects: 45% (1234/2700)`. "Cancel" stops the clone as
described above. If the app quits during a clone, it sends SIGTERM to git
first, so git can remove what it wrote. The app does not wait for git to
finish, so the empty claimed folder can stay behind (see "Who reclaims what").

### After the clone

- **Success.** The app calls `repo.add` with the destination, as "Local
  Folder…" does, and closes the sheet. Today `AppState.addRepo(path:)` logs a
  `repo.add` error and does not return it. The clone path needs the error to
  show it, so it uses a variant that returns the error to the sheet.
- **git failed.** The sheet stays open. It shows git's last error lines and one
  fixed hint below them: "Private repo? Make sure git can log in: run `gh auth
  setup-git` for HTTPS URLs, or set up an SSH key for SSH URLs." The hint is
  the same for every failure. TBD does not try to read the cause out of git's
  text.
- **The clone worked but `repo.add` failed.** TBD keeps the clone. The sheet
  says "Cloned into `<path>`, but TBD could not add it: `<error>`. Use Local
  Folder… to add it."

## The CLI

`tbd repo add [<source>] [<dest>]`. `<source>` still defaults to `.`.

- **Local source.** Works exactly as today. Passing `<dest>` with a local
  source is an error: "A destination is only used when cloning."
- **Remote source.** `<dest>` defaults to `./<folderName>` in the current
  folder, as with `git clone`.
  - Before cloning, the CLI checks that the daemon answers. A person should not
    wait minutes for a clone and only then learn TBD is not running.
  - It prints `Cloning <url> into <dest>…` to **stderr**. A wrong reading of the
    argument is then visible at once and easy to stop with Ctrl-C. Because the
    line goes to stderr, `--json` output on stdout stays a single JSON
    document. git also writes its progress to stderr.
  - After the clone, it calls `repo.add` and prints the same "Added repository"
    text, or the same JSON, as today.
  - If git fails, the CLI exits non-zero. git has already printed its error.
    If git never started, for example because TBD could not create the
    destination folder, the CLI prints TBD's own reason to stderr first.
  - If the clone worked but `repo.add` failed, the CLI keeps the clone, prints
    "Cloned into `<dest>`, but TBD could not add it: `<error>`. Run `tbd repo
    add <dest>` to retry.", and exits non-zero.

## No feature flag

The change is additive. The "Add Repository" click does the same thing as
before, and `tbd repo add` gives the same result for every argument it accepted
before. The new behavior runs only on a person's gesture: the new menu item,
the new button, or a `tbd repo add` argument that was an error before. It
deletes nothing except a partial clone that it created a moment earlier.

## Who reclaims what

A clone creates a folder that outlives the request, so it needs an answer to
the reconciler question in `CLAUDE.md`. The answer is that no sweep covers it,
for these reasons:

- **The finished folder belongs to the person.** It is a repository in a
  location they chose. Once it is added, it is an ordinary local repository, and
  `repo.remove` does not delete a local repository's folder either.
- **A failed or cancelled clone cleans itself up.** On a failed fetch, and on
  SIGINT or SIGTERM before the checkout starts, git removes what it wrote.
  `RepoCloner` then deletes the folder, which it claimed itself.
- **A repository git kept is the person's to inspect.** After a failed checkout
  or `post-checkout` hook, git keeps a complete repository and says so. TBD
  leaves it, and does not register it.
- **The leaks are visible and bounded.** Two cases leave a folder at the chosen
  path. If the app quits during a clone, it does not wait for git, so the
  claimed folder can stay: empty, or holding the repository git kept if the
  quit came during the checkout. If git is killed with SIGKILL, or the machine
  loses power, a partial clone stays. Either way the person can see the folder
  there. The next clone to the same path refuses because the destination
  already exists, so a leftover cannot pile up unseen.
- **A sweep would be worse than the leak.** TBD keeps no record of a clone
  attempt, so a sweep would have to guess which of the person's own folders to
  delete.

## Testing

All tests run under `scripts/test.sh`, with temporary folders under
`TBD_TEST_SCRATCH_ROOT`, and need no network.

- **`RepoSource`.** One table test over: each URL scheme; the scp-like form,
  with and without a user; an existing folder named like `host:repo` (local
  wins); `.`; an existing `foo/bar` (local wins); a missing
  `foo/bar` (GitHub); `./foo/bar`; `github.com/owner/repo`; `~/x`; illegal
  owner and repository names; `owner/repo/extra`; a `.git` suffix; and the
  folder name each source gives.
- **Short-form URL.** Through the injected `gh` runner: `ssh` gives the SSH URL;
  `https` gives HTTPS; empty output, a failing `gh`, and no `gh` each give
  HTTPS.
- **`RepoCloner`, against a local bare repository over `file://`.**
  - A clone succeeds and the destination is a git repository.
  - A clone of a URL that does not exist fails and leaves no folder.
  - A destination that already exists is refused, and the folder is untouched.
  - The app-mode environment has `GIT_TERMINAL_PROMPT=0` and an empty stdin.
- **CLI.** `<dest>` with a local source is refused before any clone runs.
- **Sheet state.** "Clone" is disabled for invalid text, for a local-looking
  path, and for a destination that exists. The remembered parent folder is
  read from and written to the injected `UserDefaults` suite.

## Not in this version

- **Remote-only repositories** with no local copy, for use only with remote
  sessions.
- **Browsing a list** of the person's GitHub repositories with `gh repo list`.
- **Submodules** and **shallow clones**.
- **A short form for other hosts**, such as GitLab or GitHub Enterprise. A full
  URL covers them.

## Rejected alternatives

- **Clone in the daemon behind a new `repo.clone` RPC.** It would give one
  implementation for the app and the CLI. But a clone can run for many minutes,
  so it needs a long-running RPC, a cancel RPC and a new progress delta. It
  would also lose the CLI's attached terminal, which is how a person answers a
  password prompt. The client can do all of this with existing parts.
- **A plain menu in place of the "Add Repository" button.** It adds a click to
  an action people already use. Under `CLAUDE.md`, moving an existing action
  needs a default-off flag. The split button gives the same menu and keeps the
  old click.
- **A separate `tbd repo clone` command.** It would avoid the `owner/repo`
  versus local-folder question entirely. But one command is easier to find and
  remember, and "a real local folder always wins" keeps every existing use of
  `tbd repo add` unchanged.
- **Always HTTPS, or always SSH, for the short form.** Either one fails for
  private repositories for the people who set up only the other. `gh` already
  records which one the person uses.
- **A shallow clone to save time.** TBD's branch and PR features need full
  history, so a shallow clone would make the repository look broken later.
