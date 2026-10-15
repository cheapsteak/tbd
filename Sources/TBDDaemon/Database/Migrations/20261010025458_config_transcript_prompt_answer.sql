-- Answering prompts from the transcript
-- (docs/specs/2026-10-09-transcript-prompt-answer-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.transcriptPromptAnswerDefault.
ALTER TABLE config ADD COLUMN transcript_prompt_answer_enabled INTEGER;
