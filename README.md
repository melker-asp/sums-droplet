# Sums

A notepad that does the math as you type, on the shelf of
[Droppy](https://getdroppy.app). Inspired by [Soulver](https://soulver.app) and
powered by [SoulverCore](https://github.com/soulverteam/SoulverCore).

Write notes in Markdown and mix in calculations in plain language. Every line
that holds math gets its answer in a column on the right.

```
# Budget september
income = 32 000 kr

Rent: 8 500 kr                     8 500 kr
Food: 3 200 kr                     3 200 kr
expenses = total                  11 700 kr

left = income - expenses          20 300 kr
```

## What it does

- **Sheets.** Keep as many as you like. The list shows each sheet's latest
  answer; open one, and the back arrow returns to the list. Rename, duplicate,
  pin and delete, with undo and 30 days in Recently deleted. Search with ⌘F.
- **Plain-language math.** Percentages and VAT (`1 250 kr is 25% on what`),
  variables (`vat rate = 25%`), units, dates and times (`08:15 to 16:40`),
  compound interest (`25 000 kr over 10 years at 7,5%`), rounding (`to 2 dp`),
  and live currency rates from the European Central Bank (`100 EUR in SEK`).
- **Totals, statistics and charts.** `total`, `sum`, `average`, `median`,
  `std dev`, `count`, `min` and `max` cover the lines above, back to a blank
  line or a heading. Assign them (`expenses = total`) and keep calculating.
  `chart above` or `sparkline` draws the lines above beside it.
- **Finance.** `pmt`, `fv`, `pv`, `npv` and `irr`, with `;` between arguments:
  `pmt(4% / 12; 30 × 12; 2 000 000 kr)`.
- **References.** End a line with `^rent` and use `@rent` anywhere; the link
  follows the line when lines move. ⌥-click an answer to create one. `prev` is
  the answer on the line above.
- **Tables.** Markdown tables whose `total`, `average`… rows summarise each
  column. Cells pasted from Excel or Numbers become a table with a total row.
- **Shared variables.** Share a sheet's variables, such as `hourly rate` or
  `vat`, with every other sheet; a sheet's own declaration still wins.
- **Direct manipulation.** ⌘-drag a number sideways to change it and watch
  everything follow. Hover an answer to copy it, copy it with its unit, name
  its line or refer to it; drag it into another app. Changed answers roll in.
- **Completion and hints.** Start typing a name and press Tab. A line that looks
  like math but has no answer shows a `?` that says why.
- **Quick stats.** Select a few lines to see their sum, average, median and
  standard deviation.
- **Inputs.** The sliders button turns a sheet into a form: every variable with
  a plain value becomes a field, and the answers that follow update as you type.
- **Templates.** Quick guide, VAT, price without VAT, discount, markup and
  margin, loan repayment, savings, break-even, growth rate (CAGR), percentage
  change, monthly budget and statistics.
- **Markdown.** Headings, lists, `- [ ]` tasks you can tick, bold, italics,
  `code`, `==highlights==`, quotes, code blocks and tables. List markers are never
  read as minus signs.
- **Copy and export.** Click an answer to copy it as a plain number, copy a
  whole sheet with its answers, or export it as Markdown, CSV or HTML.
- **Quick calc.** ⌃⌥Space opens a one-line calculator in the notch: ⏎ copies
  the answer, ⇥ adds the line to your last sheet, ↑ brings back earlier ones.
- **Full-sheet mode.** Expand a sheet to the whole notch, with your sheets in a
  sidebar beside it.
- **Everywhere in Droppy.** A compact card with the pinned sheet's answer, an
  optional lock screen row, and shortcuts you can rebind: Open Sums (⌃⌥S),
  New quick calc (⌃⌥N) and Quick calc in the notch (⌃⌥Space).
- **Settings.** Number format (system, `1 234,56` or `1,234.56`), decimal places,
  live currency rates, whether to open the last sheet, and the pinned sheet.

Sheets are plain Markdown files in the droplet's own folder; Settings has a
button that shows them in Finder.

## Developing

Needs Xcode 26, macOS 14 or later, and the
[DroppyKit SDK](https://gitlab.com/droppyformac1/droppykit) with its `Scripts`
on your `PATH`.

```bash
./Scripts/build-droplet.sh                             # build .build/Sums.droplet
droppykit validate                                     # the checks a submission runs
droppykit run                                          # open it in the harness
droppykit run -- --shots ./shots --report ./shots/report.json   # render every surface
swift test                                             # engine, templates, store
SUMS_RENDER_PATH=/tmp/editor.png swift test --filter EditorRenderTests   # draw the editor to a PNG
```

Build with `Scripts/build-droplet.sh` rather than `droppykit build`: it is the
SDK's build script extended to link SoulverCore and carry it inside the bundle.
To try a build on a real notch, copy `.build/Sums.droplet` to
`~/Library/Application Support/Droppy Playground/Droplets/sums/` and relaunch
[Droppy Playground](https://getdroppy.app/download/playground).

`AGENTS.md` is the brief for coding agents, with notes on how the engine and
the editor fit together.

## Licence

Sums is MIT licensed. SoulverCore is a separate, closed-source framework by
Acqualia Software, free for personal use; a public release of Sums needs a
SoulverCore licence from its authors.
