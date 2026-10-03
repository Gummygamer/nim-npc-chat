# Changelog

## Unreleased

### Added

- FireRed and LeafGreen support (`"games": ["gen1", "frlg"]`). The Gen 3 arm
  (`gen3_chat.lua`) claims the A press through `world.talk`, reads the NPC's own
  script and only takes over plain small talk (lock / faceplayer / message
  boxes / release); trainers, shops, gifts, branching story scripts and
  anything else run the original script. It types through `input.key`,
  `input.gamepad` and `render.hud` and shows the reply in the engine's own
  field message box.

### Changed

- Default `NVIDIA_NIM_MODEL` to `minimaxai/minimax-m3`. Both earlier defaults
  fail at the hosted NVIDIA NIM API before any reply is generated:
  `meta/llama-3.1-8b-instruct` reached end of life on 2026-08-26 and answers
  `410 Gone`, while `mistralai/mistral-7b-instruct-v0.3`, although still
  listed by `/v1/models`, answers `404 Function ... Not found for account`
  because its backing function is gone. The replacement is a non-reasoning
  instruct model served at the same endpoint with the same request shape that
  returns plain content inside the 60-second worker budget, and the override
  variable is unchanged.

## 1.0.0

### Added

- NVIDIA NIM chat-completions integration using `NVIDIA_API_KEY`.
- Keyboard and controller-friendly free-form NPC prompt.
- Per-NPC in-memory conversation history and vanilla-line persona grounding.
- Safe vanilla fallthrough for gameplay-bearing NPC interactions.
