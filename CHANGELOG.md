# Changelog

All notable changes to this project will be documented in this file.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: Train Tracks on 6×6 to 10×10 grids, Easy / Medium / Hard.
- Generator with a tiered deductive solver; every puzzle has exactly one
  solution, checked again by an exhaustive count before it is shown.
- Tap-to-select, tap-a-neighbour to lay or lift rails; hold to mark a cell
  empty. Given pieces are locked.
- Hint (two taps), Undo, Clear, Show / Hide solution, timer, auto-save.
- Fast generation: under 0.1 s worst case at 10×10 Hard on a desktop (trials
  resume where the last one paid off and skip repeats, the solve picks up
  from the stuck position when a given is added, and the uniqueness count has
  a node budget). A progress bar shows when generation takes longer.
- Generation is a pure function of the random seed (no clock-based limits),
  so the Daily Challenge is the same everywhere.
- English, French, Spanish and German strings.
