// @vitest-environment jsdom
/**
 * Tests for the glossary trigger.
 *
 * The trigger sits on every abbreviation the remark plugin recognised, so it has to behave for
 * a reader who never reaches for the mouse: Enter and Space open the dialog, Escape closes it,
 * and focus returns to the word they left. jsdom ships no `HTMLDialogElement.showModal()` or
 * `close()`, which is exactly the environment the component's own guard was written for, so the
 * doubles installed here stand in for what a browser provides and the assertions check the
 * state transitions the component is responsible for.
 */

import { createElement, type ReactNode } from "react";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { EzTerm } from "../../components/ez-term";
import { interact, mount, settle, unmount } from "./helpers/dom-harness";

/** The abbreviation and its definition, as the plugin passes them. */
const TERM = "DinD";
const DEFINITION = "Docker inside Docker: a container that runs its own daemon.";

/** What a browser would do with the native dialog, recorded for the assertions. */
interface DialogDouble {
  showModal: () => void;
  close: () => void;
}

let dialogDouble: DialogDouble;

/** The trigger span the component rendered. */
function trigger(): HTMLElement {
  const el = document.querySelector<HTMLElement>("span.ez-term");
  if (!el) throw new Error("the trigger did not render");
  return el;
}

/** The dialog the component rendered. */
function dialog(): HTMLDialogElement {
  const el = document.querySelector<HTMLDialogElement>("dialog.ez-glossary-dialog");
  if (!el) throw new Error("the dialog did not render");
  return el;
}

/** Mount the trigger and give its dialog the browser methods jsdom lacks. */
async function mountTerm(children: ReactNode = TERM): Promise<void> {
  mount(createElement(EzTerm, { term: TERM, definition: DEFINITION, children }));
  const el = dialog();
  dialogDouble = {
    showModal: vi.fn(() => {
      el.open = true;
    }),
    close: vi.fn(() => {
      el.open = false;
      el.dispatchEvent(new Event("close"));
    })
  };
  el.showModal = dialogDouble.showModal;
  el.close = dialogDouble.close;
}

/** A keyboard event on the trigger, as the browser would deliver it. */
function key(keyName: string): KeyboardEvent {
  return new KeyboardEvent("keydown", { key: keyName, bubbles: true, cancelable: true });
}

beforeEach(() => {
  vi.restoreAllMocks();
});

afterEach(() => {
  unmount();
});

describe("EzTerm", () => {
  it("marks the trigger as a button that opens a dialog", async () => {
    await mountTerm();
    const el = trigger();
    expect(el.getAttribute("role")).toBe("button");
    expect(el.getAttribute("aria-haspopup")).toBe("dialog");
    expect(el.getAttribute("aria-expanded")).toBe("false");
    expect(el.tabIndex).toBe(0);
  });

  it("carries the definition in the attributes the hover bubble reads", async () => {
    await mountTerm();
    const el = trigger();
    expect(el.dataset["term"]).toBe(TERM);
    expect(el.dataset["short"]).toBe(DEFINITION);
    expect(el.title).toBe(DEFINITION);
    expect(el.textContent).toBe(TERM);
  });

  it("keeps the markup the plugin wrapped, so bold and code survive inside it", async () => {
    await mountTerm(createElement("strong", null, "DinD"));
    expect(trigger().innerHTML).toBe("<strong>DinD</strong>");
  });

  it("opens the dialog on a click", async () => {
    await mountTerm();
    await interact(() => {
      trigger().click();
    });
    expect(dialogDouble.showModal).toHaveBeenCalledTimes(1);
    expect(trigger().getAttribute("aria-expanded")).toBe("true");
  });

  it("moves focus into the dialog so Escape and Tab land on the close button", async () => {
    await mountTerm();
    await interact(() => {
      trigger().click();
    });
    await settle();
    const close = document.querySelector<HTMLButtonElement>("button.ez-glossary-dialog__close");
    expect(document.activeElement).toBe(close);
  });

  it("names the dialog by its heading", async () => {
    await mountTerm();
    const el = dialog();
    const heading = el.querySelector("h2.ez-glossary-dialog__title");
    expect(heading?.id).toBeTruthy();
    expect(el.getAttribute("aria-labelledby")).toBe(heading?.id);
    expect(heading?.textContent).toBe(TERM);
    expect(el.querySelector("p.ez-glossary-dialog__body")?.textContent).toBe(DEFINITION);
  });

  it("opens on Enter and swallows the key so the page does not scroll", async () => {
    await mountTerm();
    const event = key("Enter");
    const prevent = vi.spyOn(event, "preventDefault");
    await interact(() => {
      trigger().dispatchEvent(event);
    });
    expect(prevent).toHaveBeenCalled();
    expect(dialogDouble.showModal).toHaveBeenCalledTimes(1);
  });

  it("opens on Space and stops the page from scrolling away", async () => {
    await mountTerm();
    const event = key(" ");
    const prevent = vi.spyOn(event, "preventDefault");
    await interact(() => {
      trigger().dispatchEvent(event);
    });
    expect(prevent).toHaveBeenCalled();
    expect(dialogDouble.showModal).toHaveBeenCalledTimes(1);
  });

  it("ignores every other key", async () => {
    await mountTerm();
    await interact(() => {
      trigger().dispatchEvent(key("a"));
    });
    expect(dialogDouble.showModal).not.toHaveBeenCalled();
    expect(trigger().getAttribute("aria-expanded")).toBe("false");
  });

  it("leaves an already-open dialog alone when the trigger is clicked again", async () => {
    await mountTerm();
    await interact(() => {
      trigger().click();
    });
    await interact(() => {
      trigger().click();
    });
    expect(dialogDouble.showModal).toHaveBeenCalledTimes(1);
  });

  it("closes from the close button", async () => {
    await mountTerm();
    await interact(() => {
      trigger().click();
    });
    const close = document.querySelector<HTMLButtonElement>("button.ez-glossary-dialog__close");
    if (!close) throw new Error("the close button did not render");
    await interact(() => {
      close.click();
    });
    expect(dialogDouble.close).toHaveBeenCalledTimes(1);
    expect(trigger().getAttribute("aria-expanded")).toBe("false");
  });

  it("closes when the reader clicks the backdrop past the panel", async () => {
    await mountTerm();
    await interact(() => {
      trigger().click();
    });
    await interact(() => {
      dialog().dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(trigger().getAttribute("aria-expanded")).toBe("false");
    expect(dialogDouble.close).toHaveBeenCalledTimes(1);
  });

  it("stays open when the reader clicks inside the panel", async () => {
    await mountTerm();
    await interact(() => {
      trigger().click();
    });
    const panel = document.querySelector<HTMLDivElement>("div.ez-glossary-dialog__panel");
    if (!panel) throw new Error("the dialog panel did not render");
    await interact(() => {
      panel.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(trigger().getAttribute("aria-expanded")).toBe("true");
    expect(dialogDouble.close).not.toHaveBeenCalled();
  });

  it("puts focus back on the word when Escape closed the dialog", async () => {
    await mountTerm();
    await interact(() => {
      trigger().click();
    });
    await settle();
    await interact(() => {
      dialog().open = false;
      dialog().dispatchEvent(new Event("close"));
    });
    expect(document.activeElement).toBe(trigger());
    expect(trigger().getAttribute("aria-expanded")).toBe("false");
  });
});
