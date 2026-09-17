---
name: clip-automation
description: Create and edit Clippy's scripts and AI actions - the shell snippets and one-click prompts the user runs on their clips. Use when the user says things like "add a script that...", "make a Clippy action for...", "fix that script", "I keep doing X to my clipboard by hand", or asks to change an existing script or AI action.
---

# Clip Automation

Clippy has two kinds of automation attached to clips, and picking the right one
is most of the job:

- **Scripts** run code (`zsh`, `python3`, `node`, ...) on the user's Mac. Use one
  when the task is deterministic: reformat JSON, strip tracking parameters from a
  URL, convert a timestamp, run a CLI tool over the clip.
- **AI actions** run a prompt against the user's configured model and appear on a
  clip's right-click menu. Use one when the task needs judgment: summarize,
  rewrite for a different audience, extract the useful part of a messy paste.

If the user's request is "reformat this exactly like so", write a script. If it
is "make this sound better", write an AI action.

## Scripts

1. **Look first.** `clippy_list_scripts`, then `clippy_get_script` on anything
   close. Extending an existing script beats adding a fourth near-duplicate.
2. **Write it.** `clippy_create_script` with a real name ("Strip URL tracking
   params", not "script 4"). Set `feedsClipboard: true` when the script should
   read the current clip - it arrives on stdin and in `$CLIPPY_CLIP`. Set
   `outputToClipboard: true` when its stdout should be offered back as a clip.
   Keep the body short and readable; the user has to review it.
3. **Tell them it is disabled.** Every script created or edited over MCP lands
   disabled, and Clippy refuses to run it until a human opens Settings >
   Scripts, reads the body, and enables it. This is deliberate - Clippy executes
   these, so a tool that could both write and enable one would be a way to run
   arbitrary shell on the machine. Always close by naming the script and telling
   the user where to enable it. There is no way to enable it from here, so do
   not imply otherwise or offer to try.
4. **Editing re-disables.** `clippy_update_script` turns the flag back off,
   because the user's approval was for the old body. Say so again after an edit.

## AI actions

1. **Look first.** `clippy_list_ai_actions`, then `clippy_get_ai_action` to read
   a prompt before changing it.
2. **Write the prompt.** It must contain `{clip}` where the clip's text belongs;
   without it the action never sees the clip and the tool rejects it. Put the
   instruction first and `{clip}` last, on its own line.
3. **Choose the disposition deliberately.** `proposeEdit` shows the user a diff
   to accept or reject and is the right default for anything that rewrites their
   content. `copyToClipboard` overwrites the clipboard. `newClip` saves the
   answer alongside the original. When in doubt, `proposeEdit`.
4. **Tune for the job.** Low temperature (0.0-0.3) for extraction and
   formatting; higher (0.5-0.8) for drafting. Set `maxTokens` to fit the output
   you expect, not to the maximum.

Built-in actions can be edited but not deleted. AI actions are live as soon as
they are created - unlike scripts, they run a prompt rather than code.

## Rules

- Confirm before deleting a script or action; there is no undo.
- Never put a secret in a script body. If the script needs a key, have it read
  one from the environment or the keychain and say so.
- Report back with what you made, what it does in one line, and the exact next
  step the user has to take.
