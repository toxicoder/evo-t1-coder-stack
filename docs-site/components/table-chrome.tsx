"use client";

import { useEffect } from "react";

const TAIL_PREV_FRACTION = 0.25;
const TABLE_SEL = "article table:not([class])";

function navBottom(): number {
  const header = document.querySelector("header") ?? document.querySelector("[data-theme]");
  const nav = document.querySelector("header nav") ?? document.querySelector("header");
  const el = (nav as HTMLElement | null) ?? (header as HTMLElement | null);
  return el ? el.getBoundingClientRect().bottom : 0;
}

function scrollWrap(table: HTMLTableElement): Element {
  return table.parentElement ?? table;
}

function inStickyBand(rect: DOMRect, pin: number): boolean {
  return rect.bottom > pin && rect.top < window.innerHeight;
}

/**
 * Pin table headers under the docs navbar and mirror horizontal scroll.
 *
 * CSS `position: sticky` on `thead` is not the instrument here: fumadocs wraps each table in
 * an overflow container, so a sticky head scrolls out of view with the table it belongs to.
 * A detached clone under the navbar tracks it instead, and mirrors the container's scroll so
 * the clone's columns stay aligned with the body beneath it.
 */
export function TableChrome() {
  useEffect(() => {
    const overlays = new WeakMap<HTMLTableElement, HTMLDivElement>();
    const bars = new WeakMap<HTMLTableElement, HTMLDivElement>();
    let frame = 0;
    let syncing = false;

    const schedule = () => {
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        paint();
      });
    };

    function overlayFor(table: HTMLTableElement): HTMLDivElement {
      let el = overlays.get(table);
      if (el && el.isConnected) return el;
      el = document.createElement("div");
      el.className = "ez-table-pin";
      el.setAttribute("aria-hidden", "true");
      (table.closest("article") ?? document.body).appendChild(el);
      overlays.set(table, el);
      const wrap = scrollWrap(table);
      if (!wrap.getAttribute("data-ez-pin-scroll")) {
        wrap.setAttribute("data-ez-pin-scroll", "1");
        wrap.addEventListener("scroll", schedule, { passive: true });
      }
      return el;
    }

    function barFor(table: HTMLTableElement): HTMLDivElement {
      let el = bars.get(table);
      if (el && el.isConnected) return el;
      el = document.createElement("div");
      el.className = "ez-table-hscroll";
      el.setAttribute("aria-hidden", "true");
      const inner = document.createElement("div");
      inner.className = "ez-table-hscroll__inner";
      el.appendChild(inner);
      (table.closest("article") ?? document.body).appendChild(el);
      bars.set(table, el);
      el.addEventListener(
        "scroll",
        () => {
          if (syncing) return;
          syncing = true;
          (scrollWrap(table) as HTMLElement).scrollLeft = el!.scrollLeft;
          syncing = false;
        },
        { passive: true }
      );
      return el;
    }

    function paint() {
      const pin = navBottom();
      const tables = document.querySelectorAll<HTMLTableElement>(TABLE_SEL);
      tables.forEach((table) => {
        const thead = table.tHead;
        const overlay = overlayFor(table);
        if (!thead || !thead.rows.length) {
          overlay.hidden = true;
          return;
        }
        const tableRect = table.getBoundingClientRect();
        if (!inStickyBand(tableRect, pin)) {
          overlay.hidden = true;
        } else {
          const theadRect = thead.getBoundingClientRect();
          const bodies = table.tBodies;
          const body = bodies[bodies.length - 1];
          const rows = body ? body.rows : [];
          const last = rows[rows.length - 1];
          const prev = rows.length > 1 ? rows[rows.length - 2] : last;
          let desired = pin;
          if (last && prev) {
            const tail = last.getBoundingClientRect().height + TAIL_PREV_FRACTION * prev.getBoundingClientRect().height;
            const maxTop = tableRect.bottom - tail - theadRect.height;
            desired = Math.min(pin, maxTop);
          }
          const dy = desired - theadRect.top;
          if (dy <= 0.5 || desired + theadRect.height <= pin) {
            overlay.hidden = true;
          } else {
            const wrap = scrollWrap(table);
            const wrapRect = wrap.getBoundingClientRect();
            overlay.hidden = false;
            overlay.style.top = `${desired}px`;
            overlay.style.left = `${wrapRect.left}px`;
            overlay.style.width = `${Math.max(0, wrapRect.width)}px`;
            overlay.style.height = `${theadRect.height + 1}px`;
            const cloneTable = document.createElement("table");
            // The clone lives inside the article, so it has to carry a class: the selector
            // below measures content tables (`article table:not([class])`) and a classless
            // clone would be treated as one, gaining an overlay of its own on every repaint.
            cloneTable.className = "ez-table-pin__table";
            cloneTable.appendChild(thead.cloneNode(true));
            overlay.replaceChildren(cloneTable);
            const src = thead.rows[0]?.cells ?? [];
            const dst = overlay.querySelector("thead")?.rows[0]?.cells ?? [];
            const n = Math.min(src.length, dst.length);
            for (let i = 0; i < n; i += 1) {
              const dstCell = dst[i];
              const srcCell = src[i];
              if (dstCell && srcCell) {
                dstCell.style.width = `${srcCell.getBoundingClientRect().width}px`;
              }
            }
            const inner = overlay.querySelector("table");
            if (inner) {
              inner.style.transform = `translateX(${tableRect.left - wrapRect.left}px)`;
            }
          }
        }

        const wrap = scrollWrap(table) as HTMLElement;
        const bar = barFor(table);
        const wrapRect = wrap.getBoundingClientRect();
        const needs =
          wrap.scrollWidth > wrap.clientWidth + 1 &&
          inStickyBand(wrapRect, pin) &&
          !(wrapRect.bottom <= window.innerHeight && wrapRect.bottom > 0);
        if (!needs) {
          bar.hidden = true;
          return;
        }
        bar.hidden = false;
        bar.style.left = `${wrapRect.left}px`;
        bar.style.width = `${Math.max(0, wrapRect.width)}px`;
        bar.style.bottom = "0px";
        const inner = bar.querySelector(".ez-table-hscroll__inner") as HTMLElement | null;
        if (inner) inner.style.width = `${wrap.scrollWidth}px`;
        if (!syncing) {
          syncing = true;
          bar.scrollLeft = wrap.scrollLeft;
          syncing = false;
        }
      });
    }

    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    schedule();
    return () => {
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      if (frame) cancelAnimationFrame(frame);
      document.querySelectorAll(".ez-table-pin, .ez-table-hscroll").forEach((el) => el.remove());
    };
  }, []);
  return null;
}
