"use client";

import {
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode
} from "react";

interface EzTermProps {
  /** The matched text as the page wrote it, so the dialog can name it. */
  term: string;
  /** Definition from `docs/includes/abbreviations.md`. */
  definition: string;
  children: ReactNode;
}

/**
 * Glossary trigger over an abbreviation the remark plugin recognised.
 *
 * Hover or focus shows the definition in a speech bubble (`app/global.css` renders
 * `data-short` as a pseudo-element, so the bubble costs no extra node). Click or Enter opens
 * the same definition in a native `<dialog>` via `showModal()`: top-layer, viewport-centered,
 * and closed by Escape without any key handler of ours.
 */
export function EzTerm({ term, definition, children }: EzTermProps) {
  const [open, setOpen] = useState(false);
  const titleId = useId();
  const dialogRef = useRef<HTMLDialogElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const triggerRef = useRef<HTMLSpanElement>(null);

  const onKey = useCallback((event: KeyboardEvent<HTMLSpanElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      setOpen(true);
    }
  }, []);

  // showModal() is imperative, so it is driven from the open flag rather than called in the
  // click handler: Escape and the backdrop both clear the flag, and the dialog has to follow.
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) {
      return;
    }
    if (open) {
      if (!dialog.open && typeof dialog.showModal === "function") {
        dialog.showModal();
      }
      closeRef.current?.focus();
      return;
    }
    if (dialog.open) {
      dialog.close();
    }
  }, [open]);

  // Escape closes the dialog without touching our state, so the close event is what returns
  // focus to the trigger the reader opened it from.
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) {
      return;
    }
    const onClose = () => {
      setOpen(false);
      triggerRef.current?.focus();
    };
    dialog.addEventListener("close", onClose);
    return () => dialog.removeEventListener("close", onClose);
  }, []);

  return (
    <>
      <span
        ref={triggerRef}
        className="ez-term"
        tabIndex={0}
        role="button"
        aria-haspopup="dialog"
        aria-expanded={open}
        data-term={term}
        data-short={definition}
        title={definition}
        onClick={() => setOpen(true)}
        onKeyDown={onKey}
      >
        {children}
      </span>
      <dialog
        ref={dialogRef}
        className="ez-glossary-dialog"
        aria-labelledby={titleId}
        aria-modal="true"
        onClick={(event) => event.currentTarget === event.target && setOpen(false)}
      >
        <div className="ez-glossary-dialog__panel">
          <button ref={closeRef} type="button" className="ez-glossary-dialog__close" onClick={() => setOpen(false)}>
            Close
          </button>
          <h2 className="ez-glossary-dialog__title" id={titleId}>
            {term}
          </h2>
          <p className="ez-glossary-dialog__body">{definition}</p>
        </div>
      </dialog>
    </>
  );
}
