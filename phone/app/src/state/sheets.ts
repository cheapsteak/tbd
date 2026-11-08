// Filled by plan 6 part 6d
//
// The sheet slice of `AppState`: what the account and model menus and the sheets load from the
// laptop or wait on. That is the profiles (`profiles.list`), a repo's remote providers
// (`remote.providers`), and the New sheet's progress and refusal while a create runs. Part 6d
// fills it, and its actions in `actions/sheets.ts` write it, so their outcomes land in the
// store as every action's do. Which sheet or menu shows stays in `ui.sheet` and `ui.menu`, and
// a refused switch or model change goes to `ui.refusal`, as the composer's refusal does.
//
// Contract, once filled:
// - `emptySheets()`: the slice with nothing loaded and nothing running.
//
// The stub: an empty slice.

// Empty until part 6d gives it fields.
export interface SheetsState {}

export function emptySheets(): SheetsState {
  return {};
}
