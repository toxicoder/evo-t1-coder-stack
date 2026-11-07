import type { ReactNode } from "react";

const LIST_SVG = (
  <svg className="ez-page-brief__icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <path d="M4 10.5c-.83 0-1.5.67-1.5 1.5s.67 1.5 1.5 1.5 1.5-.67 1.5-1.5-.67-1.5-1.5-1.5zm0-6c-.83 0-1.5.67-1.5 1.5S3.17 7.5 4 7.5 5.5 6.83 5.5 6 4.83 4.5 4 4.5zm0 12c-.83 0-1.5.68-1.5 1.5s.68 1.5 1.5 1.5 1.5-.68 1.5-1.5-.67-1.5-1.5-1.5zM7 19h14v-2H7v2zm0-6h14v-2H7v2zm0-8v2h14V5H7z" />
  </svg>
);

const CHECK_SVG = (
  <svg className="ez-page-brief__icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2m-2 15-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8z" />
  </svg>
);

/**
 * Two-column scan card for the required What's on this page / What this enables lists.
 *
 * Children are the original four markdown nodes (two strong paragraphs + two lists).
 */
export function PageBrief({ children }: { children: ReactNode }) {
  const items = Array.isArray(children) ? children : [children];
  const onPageTitle = items[0];
  const onPageList = items[1];
  const enablesTitle = items[2];
  const enablesList = items[3];
  return (
    <div className="ez-page-brief">
      <div className="ez-page-brief__col ez-page-brief__on-page">
        <p className="ez-page-brief__title">
          {LIST_SVG}
          <span className="ez-page-brief__label">{onPageTitle}</span>
        </p>
        {onPageList}
      </div>
      <div className="ez-page-brief__col ez-page-brief__enables">
        <p className="ez-page-brief__title">
          {CHECK_SVG}
          <span className="ez-page-brief__label">{enablesTitle}</span>
        </p>
        {enablesList}
      </div>
    </div>
  );
}
