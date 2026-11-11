# Codes for TBD's own refusals

When TBD refuses a request, the response carries a sentence in `RPCResponse.error`. Two clients
need to know more than the sentence: what kind of refusal it is, and whether TBD wrote it.

- **The phone service** (`Sources/TBDDaemon/PhoneBridge/App/`) passes a refusal on to a paired
  phone. On a remote session's path, the sentence can be the provider's own error message, and
  that message can quote a URL with an access token in it. So the phone may see a sentence only
  when TBD wrote it.
- **The laptop's prompt card** (`PromptAnswerController`) decides whether to offer "Try again"
  after an answer is refused. A retry cannot help when the answer does not fit the prompt or the
  setting for answering prompts is off.

This design gives each of TBD's own refusals on those paths a code in the existing
`RPCResponse.errorCode` field. Both clients decide from the code and never read the sentence to
decide anything. A sentence can then be reworded without breaking a client, and a provider's
message that happens to match TBD's words is never mistaken for TBD's.

## The rule

A refusal carries a code only when TBD wrote all of its text: TBD's fixed words, or the phone's
own text quoted back to it. A refusal that quotes a remote provider never carries a code. That
covers a provider's error message, the name of a question the provider wrote, and the refusals
TBD builds from a provider's details, such as a stale provider's or one for a verb the provider
does not declare.

A client may therefore show the text of a refusal that carries a code. The one exception is
`answerDoesNotFit`, whose text can name a question a remote provider wrote. Its doc comment says
so, and the phone shows its own sentence for it instead.

## The codes

Each kind of refusal gets its own case on `RPCErrorCode` (`Sources/TBDShared/RPCProtocol.swift`).
The value on the wire is the case name, as it is for the existing codes.

- **Remote gates** (`RemoteGateRefusal`)
  - `remoteBackendsOff` – "remote backends disabled".
  - `claudeCloudOff` – "claude cloud sessions disabled".
- **The phone message rule** (`PhoneMessageText`)
  - `messageEmpty` – "a phone message cannot be empty".
  - `messageControlCharacter` – "a phone message cannot contain control characters".
- **Creating a remote session** (`RemoteCreateRefusal`)
  - `remotePromptNotText` – the form's prompt is not a string.
  - `remoteFormNotWritable` – the form could not be written out again.
- **A remote session's state** (`RemoteSendMessageRefusal`, `RemoteTranscriptRefusal`)
  - `remoteSessionExited` – the session has exited. Sending a message and answering a prompt
    both use it.
  - `remoteSessionWaitingInput` – the agent is waiting on a prompt. It covers both sentences,
    the one that says to answer in the terminal and the one that says to answer on the card.
  - `remoteSessionDismissed` – the session is dismissed, so its transcript is no longer kept.
- **Remote transcript history** (`RemoteTranscriptRefusal`)
  - `loadEarlierOff` – loading earlier history is turned off.
  - `nothingEarlier` – there is no earlier history to load.
- **Answering a prompt** (`PromptAnswerRefusal`, `PromptAnswerValidation`)
  - `promptNotMirrored` – TBD holds no mirror row for the remote session.
  - `answerDoesNotFit` – every `PromptAnswerValidation` refusal: the answer's kind does not match
    the prompt, a question has no answer, the answer names a question the prompt does not have,
    or it asks for "allow always" when the prompt offered no suggestions. Local and remote answers
    both use it.
  - `promptAnswerOff` – the setting for answering prompts from the transcript is off.
  - `promptAnswerSettingUnread` – TBD could not read that setting.

## The daemon

- **Text and code are written once, together.** Each refusal type in `Sources/TBDDaemon/Base/`
  defines its refusals as a pair of text and code, and the pair builds its own error response. A
  handler sends the pair, so it cannot send the text without the code. A code never changes its
  refusal's words, so the CLI and the laptop app show the same text whether or not they read
  codes.
- **`PromptAnswerValidation`** (`Sources/TBDShared/PromptAnswer.swift`) has a code, always
  `answerDoesNotFit`. The local and remote answer handlers attach it to the response they build
  from a validation error.
- **A refusal made before its response** carries the pair, not bare text, until it becomes a
  response. The phone message rule is the case in point: `PhoneMessageText.Vetted.refused` holds
  the pair, so a refusal raised while a remote create is vetted reaches the response with its
  code.
- **Refusals that can hold a provider's words keep no code.** The existing codes and the CLI's
  handling of them do not change.

## The phone service

Every remote path reads a refusal through one helper, `remoteRefusal`, which decides from the
response's code:

- `answerDoesNotFit` gets the phone's sentence: "That answer no longer fits this prompt. Check the
  questions and try again."
- `promptAnswerOff` gets `PhoneSessionStatus.answerTurnedOffReason`, and
  `promptAnswerSettingUnread` gets `PhoneSessionStatus.answerSettingUnreadReason`, the sentences
  the phone's sessions list shows for the same two states.
- Any other code: the phone gets the response's text, cut to `refusalLimit`.
- No code: the phone gets `remoteRefusedReason`, "The remote provider refused this. Check the
  laptop.", and the text goes to the log as private data.

A local session's answer gets the same three sentences for the same three codes. Every other
local refusal reaches the phone as its text, since no provider can have written it.

The service keeps no list of sentences to match a refusal against, per path or otherwise. A
refusal with a code is shown on whichever path it arrives, which is safe because its text is
TBD's.

The phone web app needs nothing from this design: it receives a `refused` error with a
sentence, and the codes never leave the daemon.

## The laptop app

`PromptAnswerController.isRetryable` reads the code from `DaemonClientError.rpcError`, which
already carries it, and never reads the message:

- `answerDoesNotFit` and `promptAnswerOff` hide "Try again", since a retry cannot change them.
- Every other refusal keeps "Try again": `promptAnswerSettingUnread`, a refusal with no code, and
  a dropped connection.

## Compatibility

- **No new field.** `errorCode` is already optional, so every client decodes a response with or
  without it.
- **An older CLI** receives a code it does not know. `RPCErrorCode(rawValue:)` gives nil, and the
  CLI treats the refusal as it did before.
- **An older app with a newer daemon** reads the sentences, which have not changed.
- **A newer app with an older daemon,** such as a daemon still running after an update, receives
  no codes. Its prompt card then offers "Try again" for an answer that does not fit, and the retry
  is refused again. That is harmless, so the app keeps no fallback that reads the message.
- **No feature flag and no migration.** The codes change how existing refusals are reported,
  not what TBD refuses. The one thing a user sees is the phone's own sentence for an answer that
  does not fit, on both the local and the remote path, where a daemon without codes sent TBD's
  `invalid_params` text.

## Testing

- **The daemon:** for each code, a test drives the handler that refuses and checks that the
  response carries the code alongside its text.
- **The phone service:**
  - A remote refusal with a code shows its text.
  - A remote refusal with TBD's exact words but no code gets `remoteRefusedReason`. This test
    fails for any service that matches words.
  - `answerDoesNotFit`, `promptAnswerOff` and `promptAnswerSettingUnread` get the phone's
    sentences, on the local and the remote path.
- **The laptop app:** `isRetryable` is checked for each answer code and for a refusal with no
  code.

## Rejected alternatives

- **A second optional field beside `errorCode`,** holding the kind of refusal and a "safe to show"
  flag. It separates the two questions, but it gives the response two ways to report an error,
  which every client and handler would have to keep in step, while the app and the CLI already
  read `errorCode`.
- **A typed Swift error handed to the phone service in-process.** The phone service runs inside
  the daemon, so its refusals need not cross the socket. The laptop's prompt card does need the
  codes over the socket, so this would serve only the phone.
