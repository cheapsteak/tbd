// The tbd plugin's contract: the session values its hooks module keeps in
// $.state, which survive a hot reload of the module.
declare module 'claude-code' {
  interface PluginState {
    tbd: {
      /** The incarnation whose composer-draft restore is settled in this process. */
      composerDraftRestoredIncarnation: string
      /**
       * The restore notice the band above the prompt shows: `restored` for a
       * draft whose text held all of it, `restoredWithoutPaste` for a draft
       * marked not restorable, `hidden` for none.
       */
      composerDraftNotice: 'hidden' | 'restored' | 'restoredWithoutPaste'
      /**
       * Whether the box's text holds all of the draft: false once a change the
       * mod cannot read (a collapsed paste, an image) left the box non-empty,
       * true again once the box empties.
       */
      composerDraftRestorable: boolean
    }
  }
}
