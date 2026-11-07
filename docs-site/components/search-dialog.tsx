"use client";

import {
  SearchDialog as SearchDialogRoot,
  SearchDialogClose,
  SearchDialogContent,
  SearchDialogHeader,
  SearchDialogIcon,
  SearchDialogInput,
  SearchDialogList,
  SearchDialogOverlay,
  type SharedProps
} from "fumadocs-ui/components/dialog/search";
import { useDocsSearch } from "fumadocs-core/search/client";
import { staticClient } from "fumadocs-core/search/client/orama-static";
import { useI18n } from "fumadocs-ui/contexts/i18n";

import { useSearchFrom } from "@/components/search-from";

/**
 * Search over the exported index.
 *
 * The build is a static export, so there is no server to query at click time: the index
 * that `app/api/search/route.ts` writes out is fetched once and matched in the browser by
 * the Orama/ZBSearch static client.  The fetch path includes the published base path
 * (`useSearchFrom`); a root `/api/search` 404s on GitHub project Pages.  Results cover
 * titles, descriptions, headings, and (on authored pages) a bounded slice of body text,
 * plus `tags` from `buildSearchIndex`.
 * Generated encyclopedias are heading-only so `/api/search` stays under GitHub's 100 MiB
 * blob limit.
 */
export function SearchDialog(props: SharedProps) {
  const { locale } = useI18n();
  const from = useSearchFrom();
  // exactOptionalPropertyTypes: `locale` is genuinely absent when no locale is set, so
  // the two option shapes are written out instead of passing an explicit `undefined`.
  const { search, setSearch, query } = useDocsSearch({
    client: locale === undefined ? staticClient({ from }) : staticClient({ locale, from }),
  });

  return (
    <SearchDialogRoot search={search} onSearchChange={setSearch} isLoading={query.isLoading} {...props}>
      <SearchDialogOverlay />
      <SearchDialogContent>
        <SearchDialogHeader>
          <SearchDialogIcon />
          <SearchDialogInput />
          <SearchDialogClose />
        </SearchDialogHeader>
        <SearchDialogList items={query.data !== "empty" ? query.data : null} />
      </SearchDialogContent>
    </SearchDialogRoot>
  );
}
