# Commit recovery discard at AppKit termination

Menu Quit can collect consent and suspend an editor while AppKit waits for sheets. Keep the recovery session intact until the final affirmative termination decision so a delayed or cancelled Quit remains reversible. An admitted local fetch drains during termination; reserving a fetch behind an in-flight Forge request preserves the existing remote Wait and Quit Anyway choices.
