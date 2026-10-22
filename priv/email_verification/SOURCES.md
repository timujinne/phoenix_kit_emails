# Verification dictionaries: sources

Fetched 2026-10-19. Format of every list: one lowercase entry per line, `#` starts a comment.
Loaded by `PhoenixKit.Modules.Emails.Verification.Dictionaries`; the lists are shipped in the
hex package (`priv` is in the package files).

| File | Source | Licence | Lines in file | Entries |
|------|--------|---------|---------------|---------|
| `disposable.txt` | https://github.com/disposable-email-domains/disposable-email-domains, `disposable_email_blocklist.conf` (raw: https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/main/disposable_email_blocklist.conf), upstream 9913 lines, copied unchanged under a 6-line comment header | CC0 1.0 (public-domain dedication) | 9919 | 9913 |
| `tlds.txt` | https://data.iana.org/TLD/tlds-alpha-by-domain.txt (IANA root zone database), version 2026101900, lowercased, IANA's own `# Version ...` line replaced by our header | public data, published by IANA for general use | 1441 | 1437 |
| `free.txt` | curated by hand for this module; no third-party list was copied | MIT (this package) | 136 | 124 |
| `role_prefixes.txt` | curated by hand for this module; no third-party list was copied | MIT (this package) | 82 | 79 |
| `not_fake.txt` | empty whitelist; entries are added by the host | - | 3 | 0 |
| `smtp_user_unknown.txt` | written for this module from generic SMTP wording (the exception list of the reply classifier: texts that say the mailbox does not exist). Only `user unknown`, `5.1.1` and `invalid recipient` come from the original analysis; the other nine were chosen here | MIT (this package) | 20 | 12 |
| `typos.txt`, `fake.txt`, `curse.txt`, `smtp_greylist.txt`, `smtp_quota.txt`, `smtp_block.txt` | empty; entries are added by the host | - | 2-3 each | 0 |

Counts were taken on 2026-10-19 with `wc -l` (lines) and `grep -vc '^#\|^$'` (entries).

## Refreshing

`disposable.txt` and `tlds.txt` go stale. Until there is a scheduled refresh (a later stage), re-fetch
the two URLs above, keep the comment header, update the counts and the date here.

## Private lists

A host can merge its own lists on top of these without committing them: point the application env
`config :phoenix_kit_emails, :verification_lists_dir, "/path"` (or the setting
`email_verify_lists_dir`) at a directory holding files with the names above. They are unioned with the
shipped ones, never replacing them. The directory may also hold the original LetsExtract/Kellerman
files under their own names (`DEA_Sorted.txt`, `FreeEmail_Sorted.txt`, `TopLevelDomains.txt`,
`Typos_Sorted.txt`, `FakeAddresses_Sorted.txt`, `CurseWords_Sorted.txt`, `Greylisting_Sorted.txt`,
`MailboxQuota_Sorted.txt`, `Blocking_Sorted.txt`), CRLF and leading dots included. Those lists are not
redistributable and must never be committed.
