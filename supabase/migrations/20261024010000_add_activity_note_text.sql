ALTER TABLE public.user_activity_notes
  ADD COLUMN note_text text NOT NULL DEFAULT '';

ALTER TABLE public.user_activity_notes
  ADD CONSTRAINT user_activity_notes_note_text_length
    CHECK (char_length(note_text) <= 1000);
