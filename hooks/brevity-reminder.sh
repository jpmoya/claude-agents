#!/bin/bash
# UserPromptSubmit: remind Claude of JP's hard brevity rule on every prompt. Interactive sessions only.
[ -n "${PIPELINE_AGENT:-}" ] && exit 0
echo "JP HARD RULE: when working on a goal, work silently until done or truly blocked. Final reply: 1-2 short lines, the so-what and the single decision/action needed from JP. No technical detail, lists, CI/PR/check narration or mid-goal status unless JP asks."
