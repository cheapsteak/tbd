// The tbd plugin's contract: the session values its hooks module keeps in
// $.state, which survive a hot reload of the module.
declare module 'claude-code' {
  interface PluginState {
    tbd: {
      /** The incarnation whose composer-draft restore is settled in this process. */
      composerDraftRestoredIncarnation: string
      /** Whether the band above the prompt shows the restore notice. */
      composerDraftNoticeVisible: boolean
    }
  }
}
