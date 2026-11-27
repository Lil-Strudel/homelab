# Shelfmark Agent

These are instructions for an AI agent that downloads books through
[Shelfmark](./media.md). They are written for a small model, so every step is a command to
copy and the checks are done by the commands, not by judgement. Give the agent this page as
its instructions, and set `SHELFMARK_API_KEY` in its environment to the key of that name in
`media-api-keys` (`sops -d kubernetes/apps/media/api-keys.sops.yaml`). The agent must run
somewhere that reaches `shelfmark.lilstrudel.io`: the Home VLAN or WireGuard.

Step 7 writes each book's metadata into the epub in the library, so Kavita files it under
the right title, author and series. It needs more: run the agent from the root of this
repository, with `kubectl` working against the cluster (the `wg-management` WireGuard
tunnel), and set `KAVITA_API_KEY` to `KOMF_KAVITA_API_KEY` from
`kubernetes/apps/media/komf/secret.sops.yaml`. Without these the agent skips step 7.

---

# Downloading books with Shelfmark

Shelfmark finds books and downloads them into the library. You control it with `curl`
and read its answers with `jq`. Never open the web page.

Copy the commands below exactly. Only replace the words in CAPITALS.

Downloading the wrong book is worse than downloading nothing. When a step says to stop and
ask, stop and ask.

## Before you start

These environment variables must already be set:

- `SHELFMARK_URL` is `https://shelfmark.lilstrudel.io`
- `SHELFMARK_API_KEY` is the API key

Test them:

```bash
curl -sS -H "X-Api-Key: $SHELFMARK_API_KEY" "$SHELFMARK_URL/api/status" | jq -e 'has("queued")' >/dev/null && echo OK
```

If this does not print `OK`, stop and tell the user that Shelfmark is unreachable or the
key is wrong.

## Decide two things first

1. **Type.** If the user says "audiobook", "listen" or "audio", set `CT=audiobook`.
   Otherwise set `CT=ebook`.
2. **Language.** Set `WANT_LANG=en`, unless the user asked for another language. Then
   use its two-letter code (`de`, `fr`, `es`…).

```bash
CT=ebook
WANT_LANG=en
```

If the user asks for manga, comics or webtoons, do not use Shelfmark. Tell them to use
Suwayomi instead.

## Do these steps for each book, one book at a time

### Step 1: find the book

Search by the title only. This also finds other books with similar names, which step 2
uses to reject look-alikes.

```bash
curl -sS -G -H "X-Api-Key: $SHELFMARK_API_KEY" "$SHELFMARK_URL/api/metadata/search" \
  --data-urlencode "query=TITLE" -d content_type=$CT -d limit=10 \
  > /tmp/shelfmark-search.json
jq -r '.error // (.books[] | [.provider_id, .title, (.authors | join(", ")), (.publish_year // "-"), (.series_name // "-"), (.series_position // "-")] | @tsv)' /tmp/shelfmark-search.json
```

Each line is: `id  title  authors  year  series  number-in-series`.

Choose the line whose title **and** author match what the user asked for:

- Prefer the line whose title is exactly the requested title over a longer one. "Dune" is
  not "Dune Messiah" and not "Dune: The Graphic Novel".
- Never choose a summary, study guide, workbook, companion, graphic novel or box set
  unless the user asked for one.
- **The user gave no author, and two lines have the same title by different authors:**
  stop and ask the user which author they mean.
- **The right author is not listed:** run the search again with
  `query=TITLE AUTHOR` (same command, same file). Still no match: report "not found" and
  go to the next book.

Save the id: `BOOK_ID=THE_ID`

### Step 2: list the downloads and check them

This command can take up to 5 minutes. Run it once and wait. Do not run it twice at the
same time.

```bash
curl -sS -G --max-time 360 -H "X-Api-Key: $SHELFMARK_API_KEY" "$SHELFMARK_URL/api/releases" \
  -d provider=hardcover -d book_id="$BOOK_ID" -d content_type=$CT \
  > /tmp/shelfmark-releases.json
jq -r '.error // empty' /tmp/shelfmark-releases.json
```

If that printed an error, look it up in **Errors** below. Otherwise check the candidates:

```bash
jq -r --arg ct "$CT" --arg lang "$WANT_LANG" --slurpfile search /tmp/shelfmark-search.json '
  def norm: ascii_downcase | gsub("&amp;"; "&") | gsub("\\s*&\\s*"; " and ")
    | gsub("[àáâãäå]"; "a") | gsub("[èéêë]"; "e") | gsub("[ìíîï]"; "i") | gsub("[òóôõöø]"; "o") | gsub("[ùúûü]"; "u")
    | gsub("ñ"; "n") | gsub("ç"; "c") | gsub("\\\\?[\\x27’`]"; "") | gsub("[._\\s]+"; " ");
  def words: norm | gsub("[^a-z0-9]+"; " ") | split(" ") | map(select(length > 0));
  def stop: IN("the","a","an","of","and","to","in","on","for","by");
  def inlist($l): . as $x | any($l[]; . == $x);
  def allin($l): all(.[]; inlist($l));
  def tagged($w): test("(?:^|[-–—:()\\[\\]{}|,/~+]\\s*)\($w)\\b|\\b\($w)(?=\\s*(?:$|[-–—()\\[\\]{}|,/~+]|\\d"
    + "|(?:edition|version|ebook|epub|mobi|azw3|pdf|retail|translation|language|audiobook|m4b|mp3|unabridged)\\b))");
  def phrase: words | . as $w | [range(0; length) as $k | $w[$k]
    | if $k == ($w | length) - 1 then . elif stop then "(?:\(.)[^a-z0-9]+)?" else "\(.)[^a-z0-9]+" end] | join("");
  .book as $b
  | ($b.authors | map(words | map(select(length >= 3))) | map(select(length > 0))) as $authors
  | ($b.title | split(":")) as $split
  | ([$b.title] + (if ($split | length) == 2 and ($split[0] | words | length) > 0 and ($split[0] | words | allin($b.series_name // "" | words))
                   then [$split[1]] else [] end) | map(phrase) | map(select(length > 0))) as $phrases
  | ("(?:^|[-–—:()\\[\\]{}|,/~+]\\s*" + ([$authors[][] | "|\\b\(.)\\s+"] | join("")) + ")") as $before
  | ("(?=\\s*[-–—()\\[\\]{}|,/~+]|\\s*$|\\s*:\\s*(?:(?:book|bk|vol|volume|(?:an? )?(?:novel|novella|short story|fable|memoir))\\b|[(\\[])"
      + "|\\s+(?:by|epub|mobi|azw3|ebook|retail|unabridged|audiobook|m4b|mp3|\\d+ ?kbps|(?:19|20)\\d\\d)\\b"
      + ([$authors[][] | "|\\s+(?:and |& )?\(.)\\b"] | join("")) + ")") as $after
  | ([$b.title, ($b.series_name // ""), ($b.authors | join(" "))] | join(" ") | words) as $ours
  | ["edition","deluxe","illustrated","anniversary","annotated","novel","special","collector","collectors","unabridged","book","volume","vol","part"] as $generic
  | ([$search[0].books[]? | select(.provider_id != $b.provider_id) | {t: .title, w: (.title | words | map(select(stop | not)))}
      | select(any(.w[]; (inlist($ours) or inlist($generic)) | not))]) as $similar
  | ["collection","coleccion","omnibus","boxset","box","boxed","bundle","books","tomos","integrale","trilogy","duology","anthology","compendium"] as $packwords
  | ["sample","excerpt","preview","teaser","summary","sparknotes","cliffsnotes","workbook","guide","analysis",
     "abridged","condensed","dramatized","dramatised","dramatization","dramatisation","radio","bbc","cast",
     "graphic","graphicaudio","comic","comics","manga","adaptation","dcp","webp","ocr","scan","scanned",
     "discussion","720p","1080p","2160p","x264","x265","hevc","bluray","webrip","season"] as $badwords
  | {"en":["english","eng"],"de":["german","deutsch","ger"],"fr":["french","francais","vf"],
     "es":["spanish","espanol","espa","castellano","spa"],"it":["italian","italiano","ita"],"nl":["dutch","nederlands"],
     "pt":["portuguese","portugues"],"ru":["russian"],"pl":["polish","polski"],"ca":["catalan","catala","catal"],
     "sv":["swedish","svenska"],"da":["danish","dansk"],"no":["norwegian","norsk"],"fi":["finnish","suomi"],
     "cs":["czech","cesky"],"hu":["hungarian","magyar"],"tr":["turkish","turkce"]} as $langs
  | ([$langs | to_entries[] | select(.key != $lang) | .value[]]) as $foreign
  | (if $ct == "audiobook" then {"m4b":0,"mp3":1,"m4a":2} else {"epub":0} end) as $rank
  | [.releases | to_entries[] | .value + {i: .key}]
  | map(. + {fmt: (if $ct == "ebook" and (.title | ascii_downcase | test("\\bepub\\b")) then "epub"
      else .format // ([.title | ascii_downcase | scan("\\b(epub|azw3|mobi|pdf|m4b|mp3|m4a|cbz|cbr|djvu|fb2)\\b")] | first | .[0]?) end)})
  | map(. + {r: (if .fmt == null then 5 else $rank[.fmt | ascii_downcase] end)})
  | map(select(.r != null))
  | map(select(.protocol != "torrent" or (.seeders // 0) >= 1))
  | map(select(.language == null or .language == $lang))
  | map(
      ([.title, (.extra.book_title // "" | tostring), (.extra.author // "" | tostring)] | join(" ")) as $text
      | ([.title, (.extra.book_title // "" | tostring)]) as $names
      | ($text | words) as $hay
      | ($text | norm) as $raw
      | ([$raw | scan("(?:#|\\bbook ?|\\bbk ?|\\bvol(?:ume)? ?)(\\d+)") | .[0] | tonumber]
         + (if $b.series_name then [$raw | scan(($b.series_name | phrase) + " (\\d{1,2})\\b") | .[0] | tonumber] else [] end)) as $nums
      | . + {problems: (
          (if any($phrases[] as $p | $names[] | norm | test($before + $p + $after); .)
             then [] else ["title not in name"] end)
          + (if ($authors | length) == 0 or any($authors[]; allin($hay)) then [] else ["author not in name"] end)
          + [$similar[] | select(.w | allin($hay)) | "looks like \(.t)"]
          + (if $b.series_position != null and ($nums | length) > 0
                and (any($nums[]; . == ($b.series_position | floor)) | not)
             then ["series #\($nums | map(tostring) | join(",")), want #\($b.series_position | if . == floor then floor else . end)"] else [] end)
          + (if ($raw | test("(\\bbooks?|\\bvols?|\\bvolumes?|#) ?\\d+ ?(-|to|&|and) ?\\d+|complete (series|collection|saga|set)"))
                or any($packwords[]; inlist($hay) and (inlist($ours) | not))
             then ["several books"] else [] end)
          + [$badwords[] | select(inlist($hay) and (inlist($ours) | not)) | "bad copy: \(.)"]
          + (if any($foreign[] as $w | select($w | inlist($ours) | not) | $names[] | norm | tagged($w); .)
             then ["other language"] else [] end)
          + (if $ct == "ebook" and ((.extra.files // 0) | tonumber? // 0) > 3 then ["several books (\(.extra.files) files)"] else [] end)
          + (if (.extra.publisher // "" | tostring | ascii_downcase | test("royalroad|wattpad|archiveofourown|fanfiction|scribblehub"))
             then ["bad copy: web serial"] else [] end)
        )})
  | ([.[] | select((.problems | length) == 0) | .size_bytes | select(. != null and . > 0)] | sort) as $sizes
  | (if ($sizes | length) > 0 then $sizes[($sizes | length) / 2 | floor] else null end) as $median
  | (if $median then ([$sizes[] | select(. <= 2.5 * $median)] | max) else null end) as $ref
  | map(.problems += (
        if .size_bytes == null then []
        elif $ct == "ebook" and .size_bytes < 100000 then ["too small"]
        elif $ct == "ebook" and .size_bytes > 100000000 then ["too big for one ebook"]
        elif $ct == "audiobook" and .size_bytes < 100000000 then ["small for an audiobook"]
        elif $ct == "audiobook" and ($sizes | length) >= 2 and .size_bytes < 0.67 * $ref then ["smaller than other copies"]
        elif $ct == "audiobook" and ($sizes | length) >= 3 and .size_bytes > 3 * $median then ["much bigger than other copies"]
        else [] end))
  | sort_by((.problems | length > 0), .r, (if .protocol == "torrent" then 1 else 0 end), -(.seeders // 0), -(.extra.downloads // 0))
  | .[:10][]
  | [.i, (.fmt // "?"), .protocol, (.seeders // "-"), (.size // "?"),
     (if (.problems | length) == 0 then "OK" else (.problems | join("; ")) end), .title] | @tsv
' /tmp/shelfmark-releases.json
```

Each line is: `index  format  protocol  seeders  size  check  release-name`. Bad formats
(anything but epub for ebooks), dead torrents and releases tagged with another language are
already removed. The best lines come first.

The `check` column says what is wrong with a release:

| Check | Means |
| --- | --- |
| `OK` | Nothing wrong was found |
| `title not in name` | The release name does not contain this book's title on its own, so it is probably a different book ("Princess of Dune" is not "Dune") |
| `author not in name` | The release name does not contain the author's full name |
| `looks like <other title>` | The release is probably a different book with a similar name |
| `series #N, want #M` | The release is a different book of the same series |
| `several books` | A collection or box set, not one book, or an ebook download with more than 3 files |
| `bad copy: <word>` | A sample, summary, abridged or dramatized version, graphic novel, comic, film, or bad scan |
| `bad copy: web serial` | The original web-serial version (Royal Road, Wattpad, fan fiction sites), not the published book |
| `other language` | The release name is tagged with another language, like `(German Edition)` or `SWEDISH.RETAIL` |
| `too small` / `small for an audiobook` / `smaller than other copies` | Probably a sample, an ebook mislabelled as an audiobook, or a low-quality copy |
| `too big for one ebook` / `much bigger than other copies` | Probably several books, or not a book at all |

Choose the **first line whose check is exactly `OK`**. Also read its release name: if it
clearly names a different book, skip it and take the next `OK` line.

Never choose a line that is not `OK`. If there is no `OK` line, do not download. Tell the
user the book and the first three lines with their checks, and let them decide.

Save the first column: `I=THE_INDEX`

### Step 3: build the request and look inside the download

```bash
jq --argjson i "$I" --arg ct "$CT" '
  .book as $b | .releases[$i] + {
    title: $b.title,
    author: ($b.authors | join(", ")),
    year: ($b.publish_year | if . then tostring else null end),
    series_name: $b.series_name,
    series_position: $b.series_position,
    subtitle: $b.subtitle,
    preview: $b.cover_url,
    content_type: $ct
  }' /tmp/shelfmark-releases.json > /tmp/shelfmark-payload.json
ID=$(jq -r .source_id /tmp/shelfmark-payload.json)
curl -sS --max-time 120 -X POST -H "X-Api-Key: $SHELFMARK_API_KEY" -H "Content-Type: application/json" \
  --data @/tmp/shelfmark-payload.json "$SHELFMARK_URL/api/releases/inspect" \
  | jq -r --arg ct "$CT" '
  if .error then "error: \(.error)"
  elif .inspected != true then "UNCHECKED"
  else
    (if $ct == "audiobook" then ["m4b","mp3","m4a","mp4","flac","ogg","opus","aac","wma","wav"]
     else ["epub"] end) as $good
    | ["exe","msi","bat","cmd","scr","com","lnk","js","vbs","ps1","jar","apk","dll","iso","sh"] as $danger
    | [.files[].path | ascii_downcase | split(".") | if length > 1 then last else "" end] as $ext
    | ([$ext[] | select(IN($danger[]))] | unique) as $found
    | [ (if ($found | length) > 0 then "dangerous files: \($found | join(","))" else empty end),
        (if any($ext[]; IN($good[])) then empty else "no book file inside" end),
        (if .plan.is_pack and ($ct == "ebook" or ([.plan.books[].series_position | select(. != null)] | unique | length) >= 2)
         then "contains \(.plan.books | length) books" else empty end) ]
    | if length == 0 then "OK" else join("; ") end
  end'
```

The last line printed is the result:

| Result | What to do |
| --- | --- |
| `OK` | The files look right. Go to step 4. |
| `UNCHECKED` | This kind of download cannot be looked inside (usenet, magnet-link torrents, direct download). Go to step 4. |
| anything else | Do not download it. Go back to the list from step 2, choose the next `OK` line, and do step 3 again. |

The request copies the title, author, year and series from the book. Shelfmark uses them
to name the folder in the library. Without them the book is filed in the wrong folder, so
never send a release on its own.

### Step 4: queue the download

First check that this book is not already in the queue:

```bash
curl -sS -H "X-Api-Key: $SHELFMARK_API_KEY" "$SHELFMARK_URL/api/status" \
  | jq -r '[.queued, .resolving, .locating, .downloading, .complete][] | .[]? | .title'
```

If the book's title is listed, it is already downloading or done: do not queue it again.
Failed downloads are not listed, so retrying with another release is allowed. Otherwise:

```bash
curl -sS -X POST -H "X-Api-Key: $SHELFMARK_API_KEY" -H "Content-Type: application/json" \
  --data @/tmp/shelfmark-payload.json "$SHELFMARK_URL/api/releases/download"
```

Success prints `{"priority":0,"status":"queued"}`. Anything with `"error"` failed: see
**Errors**.

### Step 5: wait for it to finish

```bash
curl -sS -H "X-Api-Key: $SHELFMARK_API_KEY" "$SHELFMARK_URL/api/status" \
  | jq -r --arg id "$ID" 'to_entries[] | .key as $state | (.value[$id] // empty)
      | [$state, (.progress // 0), (.status_message // ""), (.download_path // "")] | @tsv'
```

It prints: `state  progress  message  path`. Run it every 30 seconds (`sleep 30`
between checks).

| State | What to do |
| --- | --- |
| `queued`, `resolving`, `locating`, `downloading` | Still working. Check again in 30 seconds. |
| `downloading`, the message says `0 seeds` and progress is still 0 after 10 minutes | The torrent is stuck: the seeder count in step 2 comes from the indexer and is often out of date. Cancel it (see **Rules**), then do what the `error` row says, and prefer a line whose protocol is not `torrent`. |
| `complete` | Go to step 6. |
| `error` | Read the message. Go back to the list from step 2, choose the next `OK` line, and do steps 3 to 5 again. After 3 failed releases, give up on this book and report the messages. |
| `cancelled` | Someone cancelled it. Do not retry. Report it. |
| nothing printed | The download is gone from the queue. Report that and do not retry. |

Torrents can take hours. If a download is still running after 30 minutes, stop
checking. Report "still downloading" with its progress. Shelfmark keeps downloading
without you, so skip steps 6 and 7 for this book.

When the state is `complete`, save the path: `BOOK_PATH="THE_PATH"`

### Step 6: check the downloaded file (epub only)

Only do this if the path from step 5 ends in `.epub`. For any other file, skip this step.

```bash
curl -sS -G -H "X-Api-Key: $SHELFMARK_API_KEY" "$SHELFMARK_URL/api/localdownload" \
  --data-urlencode "id=$ID" -o /tmp/shelfmark-book.epub
unzip -p /tmp/shelfmark-book.epub '*.opf' | grep -oE '<dc:(title|creator)[^>]*>[^<]*' | sed 's/<[^>]*>//'
rm -f /tmp/shelfmark-book.epub
```

It prints the title and author written inside the book. If `unzip` is missing or nothing
is printed, report "could not check the file" and continue.

If the title inside is a different book, or the author is a different person, **do not
delete anything, do not download again, and skip step 7**. Tell the user: "This may be the
wrong book: the file says TITLE by AUTHOR. It is at PATH." Small differences are fine,
like a subtitle, "The" at the start, or initials instead of a first name.

### Step 7: fix the metadata (epub only)

Only do this if the path from step 5 ends in `.epub` and step 6 found the right book.

Kavita reads the title, author, series and year from inside the epub, not from the folder,
and downloads often carry junk there: the release name as the title, narrators as authors,
a wrong series or none, the year of a reprint. This step writes the book database's details
into the file. First check that you can reach the library:

```bash
kubectl -n media get deploy shelfmark >/dev/null && test -f scripts/epub-metadata.py && echo OK
```

If this does not print `OK`, skip this step and report "metadata not fixed".

Write down the book's details:

```bash
jq --arg lang "$WANT_LANG" '.book | {title, authors, series: .series_name, position: .series_position,
  year: (.publish_year | if . then tostring else null end), description, language: $lang}' \
  /tmp/shelfmark-releases.json > /tmp/shelfmark-meta.json
jq . /tmp/shelfmark-meta.json
```

If the user gave a title, series, position or year for this book, use theirs instead of
the database's. A `null` series means the book is a standalone. Replace what the user gave
and run:

```bash
jq '.series = "SERIES" | .position = POSITION' /tmp/shelfmark-meta.json > /tmp/shelfmark-meta.new \
  && mv /tmp/shelfmark-meta.new /tmp/shelfmark-meta.json
```

Then fix the file in the library:

```bash
kubectl -n media exec -i deploy/shelfmark -- python3 - "$BOOK_PATH" "$(cat /tmp/shelfmark-meta.json)" \
  < scripts/epub-metadata.py
```

It prints the metadata the file now has: title, authors, series, year, language and
whether it has a description. The script:

- Sets the title, the year and the language.
- Sets the series and its number, or removes any series when the book has none. A series
  without a number is treated as no series, because Kavita needs both to group a book.
- Keeps only the database authors whose surname the file already has, spelled the
  database's way, because the database also lists audiobook narrators as authors. If none
  match, it keeps the first one.
- Adds the description only if the file has none.
- Repairs a cover entry that points at nothing, which makes Kavita skip the book.

If it prints an error instead, the file was not changed. Report "metadata not fixed" with
the last line of the error.

## Rules

- Queue only one download per book.
- Use only these endpoints: `GET /api/status`, `GET /api/metadata/search`,
  `GET /api/releases`, `POST /api/releases/inspect`, `POST /api/releases/download`,
  `GET /api/localdownload`, and the cancel below. The key has admin rights. Never call
  `/api/settings`, `/api/admin`, or anything else.
- Change files in the library only with step 7's command, and only the book you just
  downloaded. In Kavita, only run the scan under **When you are finished**.
- Cancel only when you queued the wrong book, a torrent is stuck at 0 seeds (step 5), or
  the user asks you to:
  `curl -sS -X DELETE -H "X-Api-Key: $SHELFMARK_API_KEY" "$SHELFMARK_URL/api/download/$(jq -rn --arg id "$ID" '$id|@uri')/cancel"`

## Errors

| You see | Meaning | Do |
| --- | --- | --- |
| `{"error": "Unauthorized"}` | The key is missing or wrong | Stop. Tell the user. |
| `No metadata provider configured` or `not available` | The book database is down | Stop. Tell the user. |
| An `error` from step 2 | The download search failed | Wait 60 seconds, then run step 2 once more. If it fails again, report the error and go to the next book. |
| `curl: (28)` | Timed out | Run the same command once more. |
| `Failed to queue release` or other `error` from step 4 | Shelfmark refused this release | Choose the next `OK` line from step 2 and do step 3 again. |
| `{"releases": [], ...}` | No downloads exist for this edition | Go back to step 1 and try the next matching line once. Otherwise report "no downloads found". |

## When you are finished

If step 7 fixed any book, have Kavita scan the Book library (ID `2`) so it picks up the new
metadata:

```bash
KAVITA_TOKEN=$(curl -sS -X POST "https://kavita.lilstrudel.io/api/Plugin/authenticate?apiKey=$KAVITA_API_KEY&pluginName=shelfmark-agent" | jq -r .token)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $KAVITA_TOKEN" \
  "https://kavita.lilstrudel.io/api/Library/scan?libraryId=2&force=true"
```

It prints `200`. Anything else: tell the user the scan did not start.

Give the user one line per book:

```
<title> by <author>: complete | still downloading (NN%) | failed (<reason>) | not found | needs your choice (<why>) | may be wrong (<what the file says>)
```

Add `metadata fixed` or `metadata not fixed (<reason>)` to each complete epub.

Also name the release you chose for every book that was queued.
