# Changelog

All notable changes to this project will be documented in this file.

## [1.1.1] - 2026-11-12

### Changed
- Picks up game-common 1.16.0: games for two readers (new Two readers
  category) and the shared Start / Join dialog.

## [1.1.0] - 2026-11-05

### Changed
- Hard no longer needs trial and error. It used to need one-step "what
  if" trials at a loose end (assume a rail, see it break), which is
  guessing. Hard now uses the same reasoning as Medium (piece rules, line
  counts, no closed loop), only much more of the loop reasoning: on 100
  grids per size, 3.3 such steps on average at 6×6 (Medium: 1), 6.0 at
  10×10 (Medium: 2.2). Medium now has a ceiling on those steps, so the
  two levels no longer overlap.
- 10×10 Hard builds much faster: under 0.03 s on a desktop at worst (about
  0.6 s on a Kobo), from up to 0.27 s (about 7 s on a Kobo).
- Medium and Hard grids differ from those of earlier versions, so the
  Daily Challenge puzzle changes once for those levels.

## [1.0.5] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.0.4] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

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
