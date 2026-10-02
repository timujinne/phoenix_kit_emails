defmodule PhoenixKit.Modules.Emails.TemplateExport.Body do
  @moduledoc """
  Turns a stored full-document `html_body` into the *body fragment* an
  `html.html` override file should hold.

  Core wraps an email built from a file in a shared layout
  (`PhoenixKit.Email.Layout`) and never wraps a part that is already a whole
  document. A seeded row is a whole document, so exporting it verbatim keeps
  its own chrome (container, header, footer, stylesheet) and the layout never
  applies. `extract/1` cuts that chrome off and keeps the content.

  ## Where the body is, in the shipped seeds

  All nine seeds put a `.header` block and a `.footer` block inside one
  container, and the body *between* them. Only five of the nine wrap that body
  in `.content`; the four auth templates (`magic_link`, `register`,
  `reset_password`, `update_email`) — the rows hosts actually edit — have the
  body directly between the two blocks. So the cut is made on the **boundary**:
  everything after the end of the `.header` element and before the start of the
  `.footer` element. A lone `.content` wrapper around that region is unwrapped.

  The `.header` is the first element carrying that class; the `.footer` is the
  **last** `.footer` element that is a sibling of it. The elements that wrap
  the header (the container) are dropped, and *everything else* in `<body>` is
  kept, in document order: a preheader before the header, an unsubscribe line
  after the footer, text after the container. Nothing outside the header and
  footer blocks is lost.

  ## What is kept of the header and footer, and why

  The seeds' `.header` and `.footer` are not pure decoration — dropping them
  whole would lose text a host translated and edited:

    * the `.header` holds the email's **title** (`<h1>Password Reset Request</h1>`,
      billing's `INVOICE` + number). A header holding a heading or a
      placeholder is kept as the first block of the body: its content, with
      only its `text-align` and margins — not its background, colour or the
      descendant rules written for that background;
    * the `.footer` holds the fallback link under a button (`{{reset_url}}`) and
      billing's company details (`{{company_name}}`, VAT). A footer containing a
      placeholder is kept as the last block of the body, with its own styling.

  A header or footer with neither is treated as decoration and dropped. What
  text it held is reported, so the operator can move it into their own layout.

  ## Styles

  The `<style>` block goes with the `<head>`, and with it every class the body
  relies on (`.button`, `.warning`, billing's tables). So the rules are
  **inlined**: each element in the fragment gets the declarations of the
  matching rules in its `style` attribute, and an existing inline `style` wins
  (a placeholder in it, such as `style="{{button_style}}"`, is kept as is).
  Supported selectors are `tag`, `.class`, `tag.class` and descendant chains of
  them, ordered by specificity (classes, then tags) and source order;
  anything else (`:hover`, `>`, ids, `*`, `@media`) is skipped — it was never
  reliable in email clients. `!important` is not honoured: it stays part of the
  value, and an inline declaration still wins by position.

  Known limitation: a raw-HTML variable such as `{{{line_items_html}}}` inserts
  markup built elsewhere whose cells and classes were styled by the removed
  `<style>`. That markup renders unstyled until the module producing it styles
  its own rows; the export task warns about it.

  ## When it falls back

  If the `.header`/`.footer` pair cannot be found as siblings (a host replaced
  the shell), `extract/1` returns everything inside `<body>`, still with the
  styles inlined, and says so. It never guesses a cut.

  A placeholder in the removed `<style>` that has no element to carry it (one
  standing between rules, or a `{{{extra_css}}}` inside a rule) is reported as
  `:style_placeholder` — it is gone from the output.

  ## Implementation

  No HTML parser is used: the structure is known, and all that is needed is a
  tag tokenizer with balanced-element search. Tokenizing, tracking ancestors and
  looking rules up are linear, and an unterminated tag, comment or `<style>`
  turns the rest of the input into text instead of being searched for again.
  Two pathological inputs stay super-linear — a great many `.footer` elements
  that are not siblings of the header, and a very large number of CSS rules
  (capped) — and are accepted as such.

  Content and attributes come through as they were, with these exceptions, all
  deliberate:

    * a `style` attribute that gains rules is rewritten, and a `"` inside one of
      its values becomes `'` (the attribute is double-quoted);
    * the indentation the seed's nesting added (ASCII spaces and tabs) and
      trailing ASCII whitespace are removed, a line ending `\r\n` becomes `\n`,
      and three or more consecutive line breaks collapse to two — none of that
      in a block that contains a `<pre>` or `<textarea>`, where only the edges of
      the block are trimmed (so the rest of that block keeps its indentation).
  """

  @type note :: {:body_fallback | :chrome_dropped | :style_placeholder, [String.t()]}

  @void ~w(area base br col embed hr img input link meta param source track wbr)

  # Tags whose nesting is checked when deciding that the header and footer are
  # siblings. `p`, `li` and friends may legally be left unclosed, so they are
  # not part of it.
  @strict ~w(div table thead tbody tfoot tr td th ul ol section article span a strong
             em b i u h1 h2 h3 h4 h5 h6 blockquote pre center font)

  @headings ~w(h1 h2 h3 h4 h5 h6)

  # The only declarations of a retained header's own box that make sense once
  # its background and colour are gone.
  @header_props ~w(text-align margin margin-top margin-bottom)

  # Bounds that keep hostile or broken input from costing more than a pass.
  @max_depth 256
  @pop_search 32
  @max_rules 20_000

  @doc """
  Whether `html` is a whole document — the test core's own layout applies.

  Delegates to `PhoenixKit.Email.Layout.document?/1` when the loaded core has
  it, so the answer is never different from what the send will do. On an older
  core it falls back to the same rule written out here: after a BOM,
  whitespace, comments and an `<?xml ?>` prolog, `<!doctype` or an `<html` tag.
  """
  @spec document?(String.t()) :: boolean()
  def document?(html) when is_binary(html) do
    # Called through a variable: this package accepts cores that predate the
    # layout, where a literal call would be a compile warning.
    layout = PhoenixKit.Email.Layout

    if Code.ensure_loaded?(layout) and function_exported?(layout, :document?, 1),
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      do: apply(layout, :document?, [html]),
      else: local_document?(html)
  end

  @doc false
  @spec local_document?(String.t()) :: boolean()
  def local_document?(html) when is_binary(html) do
    html |> skip_prolog() |> document_start?()
  end

  defp skip_prolog(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: skip_prolog(rest)

  defp skip_prolog(html) do
    case String.trim_leading(html) do
      "<!--" <> rest -> rest |> after_marker("-->") |> skip_prolog()
      "<?xml" <> rest -> rest |> after_marker("?>") |> skip_prolog()
      ^html -> html
      trimmed -> skip_prolog(trimmed)
    end
  end

  defp after_marker(rest, marker) do
    case :binary.match(rest, marker) do
      {at, size} -> binary_part(rest, at + size, byte_size(rest) - at - size)
      :nomatch -> ""
    end
  end

  defp document_start?(html) do
    lower = html |> :binary.part(0, min(byte_size(html), 16)) |> String.downcase(:ascii)
    String.starts_with?(lower, "<!doctype") or Regex.match?(~r/\A<html[\s>\/]/, lower)
  end

  @doc """
  Extracts the body fragment of `html`.

  Returns `{fragment, notes}`. A `html` that is not a whole document comes back
  unchanged with no notes. `notes` is a list of `{kind, texts}`:

    * `{:body_fallback, [reason]}` — the header/footer pair was not found as
      siblings, so the whole `<body>` was kept;
    * `{:chrome_dropped, ["header: …", "footer: …"]}` — decoration that held
      text and was left out.
  """
  @spec extract(String.t()) :: {String.t(), [note()]}
  def extract(html) when is_binary(html) do
    if document?(html), do: do_extract(html), else: {html, []}
  end

  defp do_extract(html) do
    tokens = tokenize(html)
    {fragment, notes} = cut(tokens)
    {fragment, notes ++ lost_style_placeholders(tokens, fragment)}
  end

  defp cut(tokens) do
    entries = annotate(tokens)
    ctx = %{rules: tokens |> style_texts() |> Enum.flat_map(&parse_css/1) |> build_index()}
    {first, last} = body_range(entries)
    inner = Enum.slice(entries, first..last//1)

    case boundary(inner) do
      {:ok, header, footer} ->
        inner |> pieces(header, footer, first) |> assemble(ctx)

      {:error, reason} ->
        {inner |> render(ctx) |> tidy(), [{:body_fallback, [reason]}]}
    end
  end

  # A placeholder in the removed `<style>` that did not end up in the fragment
  # (it stood between rules, or in a declaration that is not a `prop: value`).
  defp lost_style_placeholders(tokens, fragment) do
    kept = placeholder_names(fragment)

    lost =
      tokens
      |> style_texts()
      |> Enum.flat_map(&placeholder_names/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in kept))

    if lost == [], do: [], else: [{:style_placeholder, lost}]
  end

  defp placeholder_names(text) do
    ~r/\{\{\{?\s*([a-zA-Z_][a-zA-Z0-9_]*)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  # ── tokenizer ─────────────────────────────────────────────────────────

  # Tokens: {:text, s} | {:comment, s} | {:decl, s} | {:close, name, raw} |
  #         {:open | :void, name, attrs, raw, classes}
  # `attrs` is everything between the name and the closing `>`. Anything that
  # is never terminated turns the whole rest of the input into one text token,
  # so no later tag is scanned for again.
  defp tokenize(html), do: html |> tokenize([]) |> Enum.reverse()

  defp tokenize(<<>>, acc), do: acc

  defp tokenize(<<"<!--", rest::binary>> = html, acc) do
    case :binary.match(rest, "-->") do
      {at, 3} ->
        len = at + 3
        <<comment::binary-size(len), tail::binary>> = rest
        tokenize(tail, [{:comment, "<!--" <> comment} | acc])

      :nomatch ->
        [{:text, html} | acc]
    end
  end

  defp tokenize(<<"<!", rest::binary>> = html, acc) do
    case :binary.match(rest, ">") do
      {at, 1} ->
        <<decl::binary-size(at), ">", tail::binary>> = rest
        tokenize(tail, [{:decl, "<!" <> decl <> ">"} | acc])

      :nomatch ->
        [{:text, html} | acc]
    end
  end

  defp tokenize(<<"</", c, _::binary>> = html, acc) when c in ?a..?z or c in ?A..?Z do
    <<"</", rest::binary>> = html

    case :binary.match(rest, ">") do
      {at, 1} ->
        <<inner::binary-size(at), ">", tail::binary>> = rest
        name = inner |> String.trim() |> String.downcase(:ascii)
        tokenize(tail, [{:close, name, "</" <> inner <> ">"} | acc])

      :nomatch ->
        [{:text, html} | acc]
    end
  end

  defp tokenize(<<"<", c, _::binary>> = html, acc) when c in ?a..?z or c in ?A..?Z do
    <<"<", rest::binary>> = html
    name_len = name_length(rest, 0)
    <<name::binary-size(name_len), after_name::binary>> = rest

    case scan_attrs(after_name, 0, :norm) do
      {:ok, len} ->
        <<attrs::binary-size(len), ">", tail::binary>> = after_name
        lname = String.downcase(name, :ascii)
        kind = if lname in @void or self_closing?(attrs), do: :void, else: :open
        token = {kind, lname, attrs, "<" <> name <> attrs <> ">", parse_classes(attrs)}
        acc = [token | acc]

        if kind == :open and lname in ["style", "script"] do
          {body, tail} = take_raw_text(tail, lname)
          tokenize(tail, [{:text, body} | acc])
        else
          tokenize(tail, acc)
        end

      :error ->
        [{:text, html} | acc]
    end
  end

  defp tokenize(html, acc), do: tokenize_text(html, acc)

  # One byte is always consumed, so a stray `<` cannot loop.
  defp tokenize_text(<<c, rest::binary>>, acc) do
    {text, tail} =
      case :binary.match(rest, "<") do
        {at, 1} -> {binary_part(rest, 0, at), binary_part(rest, at, byte_size(rest) - at)}
        :nomatch -> {rest, <<>>}
      end

    tokenize(tail, [{:text, <<c>> <> text} | acc])
  end

  defp name_length(<<c, rest::binary>>, n)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"-:_",
       do: name_length(rest, n + 1)

  defp name_length(_rest, n), do: n

  # Bytes up to the first `>` that is not inside a quoted attribute value. A
  # quote only opens a value right after `=`, so an apostrophe elsewhere in the
  # tag does not swallow the rest of the document.
  defp scan_attrs(<<>>, _n, _state), do: :error
  defp scan_attrs(<<">", _::binary>>, n, state) when state in [:norm, :eq], do: {:ok, n}

  defp scan_attrs(<<"=", rest::binary>>, n, state) when state in [:norm, :eq],
    do: scan_attrs(rest, n + 1, :eq)

  defp scan_attrs(<<c, rest::binary>>, n, :eq) when c in ~c" \t\r\n",
    do: scan_attrs(rest, n + 1, :eq)

  defp scan_attrs(<<q, rest::binary>>, n, :eq) when q in ~c"\"'", do: scan_attrs(rest, n + 1, q)
  defp scan_attrs(<<_, rest::binary>>, n, :eq), do: scan_attrs(rest, n + 1, :norm)
  defp scan_attrs(<<q, rest::binary>>, n, q), do: scan_attrs(rest, n + 1, :norm)
  defp scan_attrs(<<_, rest::binary>>, n, state), do: scan_attrs(rest, n + 1, state)

  # The text of a `<style>`/`<script>`: up to the next closing tag of that
  # name, found without copying or lowercasing what follows it.
  defp take_raw_text(bin, "style"),
    do: split_at_close(bin, Regex.run(~r{</style}i, bin, return: :index))

  defp take_raw_text(bin, "script"),
    do: split_at_close(bin, Regex.run(~r{</script}i, bin, return: :index))

  defp split_at_close(bin, [{at, _}]),
    do: {binary_part(bin, 0, at), binary_part(bin, at, byte_size(bin) - at)}

  defp split_at_close(bin, nil), do: {bin, <<>>}

  # A trailing `/` closes the tag only when it is not the end of an unquoted
  # value: `<a href=https://x.com/>` is an open `<a>` with that whole URL.
  defp self_closing?(attrs) do
    trimmed = String.trim_trailing(attrs)

    String.ends_with?(trimmed, "/") and
      case List.last(attr_spans(attrs)) do
        {_, _, _, stop} -> stop < byte_size(trimmed)
        nil -> true
      end
  end

  defp parse_classes(attrs) do
    case attr_value(attrs, "class") do
      nil -> []
      value -> String.split(value)
    end
  end

  # ── attributes ────────────────────────────────────────────────────────

  # The value of the first attribute called `name` (lowercase), or nil. Written
  # by hand rather than with a regular expression: it runs for every tag, and a
  # literal regex is recompiled on every call under OTP 28.
  defp attr_value(attrs, name) do
    case Enum.find(attr_spans(attrs), &(elem(&1, 0) == name)) do
      {_, value, _, _} -> value
      nil -> nil
    end
  end

  # `{lowercase name, value | nil, start, stop}` for each attribute, with
  # offsets into `attrs`.
  defp attr_spans(attrs), do: attr_spans(attrs, attrs, 0, [])

  defp attr_spans(<<>>, _whole, _pos, acc), do: Enum.reverse(acc)

  defp attr_spans(<<c, rest::binary>>, whole, pos, acc) when c in ~c" \t\r\n/",
    do: attr_spans(rest, whole, pos + 1, acc)

  defp attr_spans(bin, whole, pos, acc) do
    case attr_name_length(bin, 0) do
      0 ->
        <<_, rest::binary>> = bin
        attr_spans(rest, whole, pos + 1, acc)

      len ->
        <<name::binary-size(len), rest::binary>> = bin
        {value, used} = take_attr_value(rest)
        <<_::binary-size(len), _::binary-size(used), tail::binary>> = bin
        span = {String.downcase(name, :ascii), value, pos, pos + len + used}
        attr_spans(tail, whole, pos + len + used, [span | acc])
    end
  end

  defp attr_name_length(<<c, _::binary>>, n) when c in ~c" \t\r\n/=", do: n
  defp attr_name_length(<<_, rest::binary>>, n), do: attr_name_length(rest, n + 1)
  defp attr_name_length(<<>>, n), do: n

  # After a name: `= value` (quoted or not) -> {value, bytes used}, else {nil, 0}.
  defp take_attr_value(bin) do
    blanks = leading_blanks(bin, ~c" \t\r\n")
    after_blanks = binary_part(bin, blanks, byte_size(bin) - blanks)

    case after_blanks do
      <<"=", rest::binary>> ->
        more = leading_blanks(rest, ~c" \t\r\n")
        value_part = binary_part(rest, more, byte_size(rest) - more)
        {value, value_used} = take_value(value_part)
        {value, blanks + 1 + more + value_used}

      _ ->
        {nil, 0}
    end
  end

  defp take_value(<<q, rest::binary>>) when q in ~c"\"'" do
    case :binary.match(rest, <<q>>) do
      {at, 1} -> {binary_part(rest, 0, at), at + 2}
      :nomatch -> {rest, byte_size(rest) + 1}
    end
  end

  defp take_value(bin) do
    len = unquoted_length(bin, 0)
    {binary_part(bin, 0, len), len}
  end

  defp unquoted_length(<<c, _::binary>>, n) when c in ~c" \t\r\n", do: n
  defp unquoted_length(<<_, rest::binary>>, n), do: unquoted_length(rest, n + 1)
  defp unquoted_length(<<>>, n), do: n

  # ── structure ─────────────────────────────────────────────────────────

  # Entries are {token, index, ancestors}; ancestors are the open elements
  # around the token, nearest first, as {name, classes, index}. One forward
  # pass, so no token is ever scanned for its ancestors again.
  defp annotate(tokens) do
    {entries, _state} =
      tokens
      |> Enum.with_index()
      |> Enum.map_reduce({[], 0, 0}, fn
        {{:open, name, _, _, classes} = token, i}, {stack, _, _} = state ->
          {{token, i, stack}, push(state, {name, classes, i})}

        {{:close, name, _} = token, i}, {stack, _, _} = state ->
          {{token, i, stack}, pop(state, name)}

        {token, i}, {stack, _, _} = state ->
          {{token, i, stack}, state}
      end)

    entries
  end

  # Past the depth cap an element is counted but not remembered as an ancestor.
  defp push({stack, depth, over}, _entry) when depth >= @max_depth, do: {stack, depth, over + 1}
  defp push({stack, depth, over}, entry), do: {[entry | stack], depth + 1, over}

  # A closing tag closes the nearest open element of its name — but only looks
  # a few levels up, so a run of stray closing tags stays cheap.
  defp pop({stack, depth, over}, _name) when over > 0, do: {stack, depth, over - 1}

  defp pop({stack, depth, over}, name) do
    case drop_through(stack, name, @pop_search, 0) do
      {rest, removed} -> {rest, depth - removed, over}
      :none -> {stack, depth, over}
    end
  end

  defp drop_through([], _name, _limit, _n), do: :none
  defp drop_through(_stack, _name, 0, _n), do: :none
  defp drop_through([{name, _, _} | rest], name, _limit, n), do: {rest, n + 1}
  defp drop_through([_ | rest], name, limit, n), do: drop_through(rest, name, limit - 1, n + 1)

  defp idx({_token, i, _ancestors}), do: i

  # Index range of what is inside <body>; with no body, after </head>.
  defp body_range(entries) do
    last_index = length(entries) - 1

    first =
      case Enum.find(entries, &open?(&1, "body")) do
        {_, i, _} -> i + 1
        nil -> head_end(entries)
      end

    last =
      case entries |> Enum.reverse() |> Enum.find(&close?(&1, "body")) do
        {_, i, _} -> i - 1
        nil -> closing_html(entries, last_index)
      end

    {first, last}
  end

  defp head_end(entries) do
    case Enum.find(entries, &close?(&1, "head")) do
      {_, i, _} -> i + 1
      nil -> 0
    end
  end

  defp closing_html(entries, last_index) do
    case entries |> Enum.reverse() |> Enum.find(&close?(&1, "html")) do
      {_, i, _} -> i - 1
      nil -> last_index
    end
  end

  defp open?({{:open, name, _, _, _}, _, _}, name), do: true
  defp open?(_, _), do: false
  defp close?({{:close, name, _}, _, _}, name), do: true
  defp close?(_, _), do: false

  # The header and footer as {open_index, close_index} pairs, only when both
  # exist and the region between them is balanced, i.e. they are siblings.
  defp boundary(inner) do
    case element_with_class(inner, "header") do
      :none -> {:error, "no .header element found"}
      :unclosed -> {:error, "the .header element is never closed"}
      {:ok, header} -> footer_after(inner, header)
    end
  end

  # The last `.footer` that is a sibling of the header: an earlier element that
  # merely carries the class (a "footer note" in the middle of the body) is
  # body, not the footer.
  defp footer_after(inner, {_, h_close} = header) do
    candidates =
      inner
      |> Enum.filter(fn
        {{:open, _, _, _, classes}, i, _} -> i > h_close and "footer" in classes
        _ -> false
      end)
      |> Enum.reverse()

    case candidates do
      [] ->
        {:error, "no .footer element found after the .header"}

      _ ->
        Enum.find_value(
          candidates,
          {:error, "the .header and .footer are not siblings"},
          fn {{:open, name, _, _, _}, i, _} ->
            with j when is_integer(j) <- matching_close(inner, i, name),
                 true <- balanced?(inner, h_close + 1, i - 1) do
              {:ok, header, {i, j}}
            else
              _ -> nil
            end
          end
        )
    end
  end

  defp element_with_class(inner, class) do
    found =
      Enum.find(inner, fn
        {{:open, _, _, _, classes}, _, _} -> class in classes
        _ -> false
      end)

    case found do
      {{:open, name, _, _, _}, i, _} ->
        case matching_close(inner, i, name) do
          nil -> :unclosed
          j -> {:ok, {i, j}}
        end

      nil ->
        :none
    end
  end

  defp matching_close(entries, open_index, name) do
    entries
    |> Enum.drop_while(&(idx(&1) <= open_index))
    |> Enum.reduce_while(1, fn
      {{:open, ^name, _, _, _}, _, _}, depth -> {:cont, depth + 1}
      {{:close, ^name, _}, i, _}, 1 -> {:halt, {:found, i}}
      {{:close, ^name, _}, _, _}, depth -> {:cont, depth - 1}
      _, depth -> {:cont, depth}
    end)
    |> case do
      {:found, i} -> i
      _ -> nil
    end
  end

  # Strict tags opened and closed in [from, to] must net to zero without ever
  # closing something this region did not open.
  defp balanced?(inner, from, to) do
    result =
      inner
      |> Enum.filter(fn {_, i, _} -> i >= from and i <= to end)
      |> Enum.reduce_while(%{}, fn
        {{:open, name, _, _, _}, _, _}, depths when name in @strict ->
          {:cont, Map.update(depths, name, 1, &(&1 + 1))}

        {{:close, name, _}, _, _}, depths when name in @strict ->
          case Map.get(depths, name, 0) do
            0 -> {:halt, :unbalanced}
            n -> {:cont, Map.put(depths, name, n - 1)}
          end

        _, depths ->
          {:cont, depths}
      end)

    result != :unbalanced and Enum.all?(result, fn {_, n} -> n == 0 end)
  end

  # The wrapper elements around the header (the container) are dropped, and
  # everything else in the body is kept, before the header and after the
  # footer included.
  defp pieces(inner, {h_open, h_close}, {f_open, f_close}, body_first) do
    {_, _, ancestors} = Enum.find(inner, &(idx(&1) == h_open))

    dropped =
      ancestors
      |> Enum.filter(fn {_, _, i} -> i >= body_first end)
      |> Enum.reduce(MapSet.new(), fn {name, _, i}, acc ->
        acc = MapSet.put(acc, i)

        case matching_close(inner, i, name) do
          nil -> acc
          j -> MapSet.put(acc, j)
        end
      end)

    kept = fn entries -> Enum.reject(entries, &MapSet.member?(dropped, idx(&1))) end
    slice = fn from, to -> Enum.filter(inner, fn {_, i, _} -> i >= from and i <= to end) end

    %{
      pre: kept.(slice.(0, h_open - 1)),
      header: slice.(h_open, h_close),
      middle: slice.(h_close + 1, f_open - 1),
      footer: slice.(f_open, f_close),
      post: kept.(slice.(f_close + 1, length(inner) + body_first))
    }
  end

  # ── assembly ──────────────────────────────────────────────────────────

  defp assemble(%{pre: pre, header: header, middle: middle, footer: footer, post: post}, ctx) do
    {header_part, header_note} = header_part(header, ctx)
    {footer_part, footer_note} = footer_part(footer, ctx)

    fragment =
      [
        render(pre, ctx),
        header_part,
        middle |> unwrap_content() |> render(ctx),
        footer_part,
        render(post, ctx)
      ]
      |> Enum.map(&tidy/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> Kernel.<>("\n")

    notes =
      case Enum.reject([header_note, footer_note], &is_nil/1) do
        [] -> []
        dropped -> [{:chrome_dropped, dropped}]
      end

    {fragment, notes}
  end

  # A header holding a heading (the email's title) or a placeholder is content.
  defp header_part([header_entry | rest], ctx) do
    interior = Enum.drop(rest, -1)

    if Enum.any?(interior, &(heading?(&1) or placeholder?(&1))) do
      {render_header(header_entry, interior, ctx), nil}
    else
      {"", dropped_text("header", interior)}
    end
  end

  defp heading?({{:open, name, _, _, _}, _, _}), do: name in @headings
  defp heading?(_), do: false

  defp footer_part(footer, ctx) do
    interior = footer |> Enum.drop(1) |> Enum.drop(-1)

    if Enum.any?(interior, &placeholder?/1) do
      {render(footer, ctx), nil}
    else
      {"", dropped_text("footer", interior)}
    end
  end

  defp placeholder?({{:text, text}, _, _}), do: String.contains?(text, "{{")

  defp placeholder?({{kind, _, attrs, _, _}, _, _}) when kind in [:open, :void],
    do: String.contains?(attrs, "{{")

  defp placeholder?(_), do: false

  defp dropped_text(label, interior) do
    text =
      interior
      |> Enum.flat_map(fn
        {{:text, t}, _, _} -> [t]
        _ -> []
      end)
      |> Enum.join()
      |> String.split()
      |> Enum.join(" ")

    if text == "", do: nil, else: "#{label}: #{text}"
  end

  # Header kept for its content: its own box reduced to alignment and margins
  # (its inline style winning over the stylesheet), and none of the rules
  # written for the header as a background reaching the children.
  defp render_header({{:open, _, attrs, _, _}, h_index, _} = entry, interior, ctx) do
    css = entry |> declarations(ctx, nil) |> Enum.filter(&header_prop?/1)

    inline =
      attrs |> inline_style() |> Enum.filter(&header_prop?/1)

    props = Enum.reduce(inline, css, fn {p, v}, acc -> List.keystore(acc, p, 0, {p, v}) end)
    body = interior |> render(ctx, h_index) |> tidy()

    case props do
      [] -> body
      _ -> ~s(<div style="#{format_decls(props)}">\n#{indent(body)}\n</div>)
    end
  end

  defp header_prop?({prop, _}) when is_binary(prop), do: prop in @header_props
  defp header_prop?(_), do: false

  defp indent(text), do: "  " <> String.replace(text, "\n", "\n  ")

  # A lone `.content` wrapper around the region is unwrapped.
  defp unwrap_content(middle) do
    case Enum.reject(middle, &blank?/1) do
      [{{:open, name, _, _, classes}, first, _} | _] = all ->
        {_, last, _} = List.last(all)

        if "content" in classes and matching_close(all, first, name) == last,
          do: Enum.filter(middle, fn {_, i, _} -> i > first and i < last end),
          else: middle

      _ ->
        middle
    end
  end

  defp blank?({{:text, t}, _, _}), do: String.trim(t) == ""
  defp blank?({{:comment, _}, _, _}), do: true
  defp blank?(_), do: false

  # ── rendering with inlined styles ─────────────────────────────────────

  # `exclude` is the index of an element whose own rules must not reach what is
  # rendered inside it (a kept header).
  defp render(entries, ctx, exclude \\ nil) do
    Enum.map_join(entries, fn
      {{kind, name, attrs, raw, _}, _, _} = entry when kind in [:open, :void] ->
        case declarations(entry, ctx, exclude) do
          [] -> raw
          decls -> rebuild(binary_part(raw, 1, byte_size(name)), attrs, decls)
        end

      {{:text, t}, _, _} ->
        t

      {{:comment, t}, _, _} ->
        t

      {{:decl, t}, _, _} ->
        t

      {{:close, _, raw}, _, _} ->
        raw
    end)
  end

  defp rebuild(name, attrs, css) do
    inline = inline_style(attrs)
    inline_props = for {prop, _} <- inline, is_binary(prop), do: prop
    own = Enum.reject(css, fn {prop, _} -> prop in inline_props end)

    {without_style, tail} = split_tail(strip_style(attrs))
    "<#{name}#{without_style} style=\"#{format_decls(own ++ inline)}\"#{tail}>"
  end

  defp split_tail(attrs) do
    trimmed = String.trim_trailing(attrs)

    if self_closing?(attrs) do
      {trimmed |> String.trim_trailing("/") |> String.trim_trailing(), " /"}
    else
      {trimmed, ""}
    end
  end

  defp format_decls(decls) do
    Enum.map_join(decls, " ", fn
      {:raw, text} -> text |> String.trim_trailing(";") |> Kernel.<>(";")
      {prop, val} -> "#{prop}: #{String.replace(val, "\"", "'")};"
    end)
  end

  defp strip_style(attrs) do
    case Enum.find(attr_spans(attrs), &(elem(&1, 0) == "style")) do
      {_, _, start, stop} ->
        rtrim(binary_part(attrs, 0, start), ~c" \t\r\n") <>
          binary_part(attrs, stop, byte_size(attrs) - stop)

      nil ->
        attrs
    end
  end

  # The element's own `style`: `{prop, value}` pairs, and `{:raw, text}` for
  # whatever is not one — a placeholder standing in for declarations.
  defp inline_style(attrs) do
    case attr_value(attrs, "style") do
      nil -> []
      value -> parse_declarations(value, true)
    end
  end

  # ── CSS ───────────────────────────────────────────────────────────────

  defp style_texts(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{:open, "style", _, _, _}, {:text, css}] -> [css]
      _ -> []
    end)
  end

  defp parse_css(css), do: css |> strip_comments([]) |> parse_rules([])

  # A comment that is never closed runs to the end, as in CSS itself.
  defp strip_comments(css, acc) do
    case :binary.match(css, "/*") do
      :nomatch ->
        [css | acc] |> Enum.reverse() |> IO.iodata_to_binary()

      {at, 2} ->
        before = binary_part(css, 0, at)
        rest = binary_part(css, at + 2, byte_size(css) - at - 2)

        case :binary.match(rest, "*/") do
          :nomatch ->
            [before | acc] |> Enum.reverse() |> IO.iodata_to_binary()

          {close, 2} ->
            strip_comments(binary_part(rest, close + 2, byte_size(rest) - close - 2), [
              before | acc
            ])
        end
    end
  end

  defp parse_rules(css, acc) do
    css = String.trim_leading(css)

    cond do
      css == "" -> Enum.reverse(acc)
      String.starts_with?(css, "@") -> skip_at_rule(css, acc)
      String.starts_with?(css, "{{") -> css |> skip_placeholder() |> parse_rules(acc)
      true -> parse_rule(css, acc)
    end
  end

  # `@charset "utf-8";` ends at its `;`, `@media … { … }` at its block's end.
  defp skip_at_rule(css, acc) do
    case :binary.match(css, [";", "{"]) do
      {at, 1} ->
        rest = binary_part(css, at + 1, byte_size(css) - at - 1)

        if binary_part(css, at, 1) == ";",
          do: parse_rules(rest, acc),
          else: rest |> skip_block(1) |> parse_rules(acc)

      :nomatch ->
        Enum.reverse(acc)
    end
  end

  defp parse_rule(css, acc) do
    with {at, 1} <- :binary.match(css, "{"),
         rest = binary_part(css, at + 1, byte_size(css) - at - 1),
         {:ok, close} <- rule_end(rest, 0) do
      selector = css |> binary_part(0, at) |> String.trim()
      body = binary_part(rest, 0, close)
      tail = binary_part(rest, close + 1, byte_size(rest) - close - 1)
      parse_rules(tail, rules_for(selector, parse_declarations(body, false)) ++ acc)
    else
      _ -> Enum.reverse(acc)
    end
  end

  # Offset of the `}` that ends a rule body: one inside a quoted string or a
  # `{{placeholder}}` / `{{{placeholder}}}` does not count.
  defp rule_end(<<>>, _n), do: :error
  defp rule_end(<<"}", _::binary>>, n), do: {:ok, n}

  defp rule_end(<<"{{{", rest::binary>>, n), do: skip_to(rest, "}}}", n + 3)
  defp rule_end(<<"{{", rest::binary>>, n), do: skip_to(rest, "}}", n + 2)

  defp rule_end(<<q, rest::binary>>, n) when q in ~c"\"'", do: skip_string(rest, q, n + 1)
  defp rule_end(<<_, rest::binary>>, n), do: rule_end(rest, n + 1)

  defp skip_to(bin, marker, n) do
    case :binary.match(bin, marker) do
      {at, size} ->
        len = at + size
        rule_end(binary_part(bin, len, byte_size(bin) - len), n + len)

      :nomatch ->
        :error
    end
  end

  defp skip_string(<<>>, _q, _n), do: :error
  defp skip_string(<<q, rest::binary>>, q, n), do: rule_end(rest, n + 1)
  defp skip_string(<<"\\", _, rest::binary>>, q, n), do: skip_string(rest, q, n + 2)
  defp skip_string(<<_, rest::binary>>, q, n), do: skip_string(rest, q, n + 1)

  # A placeholder standing between rules has no element to carry it.
  defp skip_placeholder(<<"{{{", rest::binary>>), do: after_marker(rest, "}}}")
  defp skip_placeholder(<<"{{", rest::binary>>), do: after_marker(rest, "}}")

  # Past the `}` that closes a block whose `{` was already consumed.
  defp skip_block(css, 0), do: css
  defp skip_block(<<>>, _depth), do: <<>>
  defp skip_block(<<"{", rest::binary>>, depth), do: skip_block(rest, depth + 1)
  defp skip_block(<<"}", rest::binary>>, depth), do: skip_block(rest, depth - 1)
  defp skip_block(<<_, rest::binary>>, depth), do: skip_block(rest, depth)

  defp rules_for(selector, decls) do
    selector
    |> String.split(",")
    |> Enum.flat_map(fn sel ->
      case parse_selector(String.trim(sel)) do
        nil -> []
        compounds -> [%{compounds: compounds, decls: decls, specificity: specificity(compounds)}]
      end
    end)
    |> Enum.reverse()
  end

  # [{tag | nil, [class]}] in source order, or nil for anything unsupported.
  defp parse_selector(""), do: nil

  defp parse_selector(selector) do
    parsed = selector |> String.split() |> Enum.map(&parse_compound/1)
    if Enum.any?(parsed, &is_nil/1), do: nil, else: parsed
  end

  defp parse_compound(part) do
    if part != "" and Regex.match?(~r/\A[a-zA-Z0-9]*(?:\.[a-zA-Z_][a-zA-Z0-9_-]*)*\z/, part) do
      [tag | classes] = String.split(part, ".")
      {if(tag == "", do: nil, else: String.downcase(tag, :ascii)), classes}
    end
  end

  # {classes, tags}: compared in that order, so no number of tag selectors
  # outweighs a class.
  defp specificity(compounds) do
    Enum.reduce(compounds, {0, 0}, fn {tag, classes}, {c, t} ->
      {c + length(classes), t + if(tag, do: 1, else: 0)}
    end)
  end

  # Rules by what the last compound asks for, so an element is only tested
  # against the few rules that could apply to it.
  defp build_index(rules) do
    rules
    |> Enum.take(@max_rules)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {rule, order}, acc ->
      rule = Map.put(rule, :order, order)
      Map.update(acc, index_key(rule.compounds), [rule], &[rule | &1])
    end)
  end

  defp index_key(compounds) do
    case List.last(compounds) do
      {_tag, [class | _]} -> {:class, class}
      {tag, []} -> {:tag, tag}
    end
  end

  # Declarations as {prop, value}; with `keep_raw?`, a chunk that is not one
  # (a placeholder, say) comes back as {:raw, text} instead of being lost.
  defp parse_declarations(body, keep_raw?) do
    body
    |> split_declarations()
    |> Enum.flat_map(fn chunk ->
      chunk = String.trim(chunk)

      case :binary.split(chunk, ":") do
        _ when chunk == "" ->
          []

        [prop, val] ->
          prop = prop |> String.trim() |> String.downcase(:ascii)
          val = String.trim(val)

          if prop == "" or val == "" or String.contains?(prop, "{"),
            do: raw(chunk, keep_raw?),
            else: [{prop, val}]

        _ ->
          raw(chunk, keep_raw?)
      end
    end)
  end

  defp raw(chunk, true), do: [{:raw, chunk}]
  defp raw(_chunk, false), do: []

  # Splits on `;` outside quotes and parentheses, so
  # `url('data:image/png;base64,…')` stays whole.
  defp split_declarations(bin), do: split_declarations(bin, bin, 0, 0, nil, 0, [])

  defp split_declarations(<<>>, whole, start, pos, _quote, _depth, acc),
    do: Enum.reverse([binary_part(whole, start, pos - start) | acc])

  defp split_declarations(<<";", rest::binary>>, whole, start, pos, nil, 0, acc),
    do:
      split_declarations(rest, whole, pos + 1, pos + 1, nil, 0, [
        binary_part(whole, start, pos - start) | acc
      ])

  defp split_declarations(<<q, rest::binary>>, whole, start, pos, nil, depth, acc)
       when q in ~c"\"'",
       do: split_declarations(rest, whole, start, pos + 1, q, depth, acc)

  defp split_declarations(<<q, rest::binary>>, whole, start, pos, q, depth, acc),
    do: split_declarations(rest, whole, start, pos + 1, nil, depth, acc)

  defp split_declarations(<<"(", rest::binary>>, whole, start, pos, nil, depth, acc),
    do: split_declarations(rest, whole, start, pos + 1, nil, depth + 1, acc)

  defp split_declarations(<<")", rest::binary>>, whole, start, pos, nil, depth, acc)
       when depth > 0,
       do: split_declarations(rest, whole, start, pos + 1, nil, depth - 1, acc)

  defp split_declarations(<<_, rest::binary>>, whole, start, pos, quote, depth, acc),
    do: split_declarations(rest, whole, start, pos + 1, quote, depth, acc)

  # The merged declarations of every rule matching the element, lowest
  # specificity first so the strongest wins.
  defp declarations({{kind, name, _, _, classes}, _, ancestors}, ctx, exclude)
       when kind in [:open, :void] do
    ancestors =
      if exclude, do: Enum.reject(ancestors, fn {_, _, i} -> i == exclude end), else: ancestors

    element = {name, classes}

    [
      Map.get(ctx.rules, {:tag, name}, [])
      | Enum.map(classes, &Map.get(ctx.rules, {:class, &1}, []))
    ]
    |> Enum.concat()
    |> Enum.uniq_by(& &1.order)
    |> Enum.filter(&matches?(&1.compounds, element, ancestors))
    |> Enum.sort_by(&{&1.specificity, &1.order})
    |> Enum.flat_map(& &1.decls)
    |> Enum.reduce([], fn {prop, val}, acc -> List.keystore(acc, prop, 0, {prop, val}) end)
  end

  defp matches?(compounds, element, ancestors) do
    [last | rest] = Enum.reverse(compounds)
    compound_matches?(last, element) and ancestors_match?(rest, ancestors)
  end

  defp ancestors_match?([], _ancestors), do: true
  defp ancestors_match?(_compounds, []), do: false

  defp ancestors_match?([compound | more] = compounds, [{name, classes, _} | up]) do
    if compound_matches?(compound, {name, classes}),
      do: ancestors_match?(more, up),
      else: ancestors_match?(compounds, up)
  end

  defp compound_matches?({tag, classes}, {name, element_classes}) do
    (tag == nil or tag == name) and Enum.all?(classes, &(&1 in element_classes))
  end

  # ── output tidy-up ────────────────────────────────────────────────────

  # Trim blank edges and remove the indentation the seed's nesting added. A
  # piece starts at a tag, so its first line carries none of that indentation:
  # it is the lines after it that say how deep the piece sat. Only ASCII spaces
  # and tabs are touched, and nothing inside `<pre>` or `<textarea>`.
  defp tidy(text) do
    if preformatted?(text), do: trim_edges(text), else: tidy_lines(text)
  end

  defp tidy_lines(text) do
    [first | rest] = text |> String.split("\n") |> Enum.map(&rtrim/1)

    indent =
      rest
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&leading_blanks/1)
      |> Enum.min(fn -> 0 end)

    [ltrim(first) | Enum.map(rest, &drop_blanks(&1, indent))]
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> trim_edges()
  end

  defp preformatted?(text), do: Regex.match?(~r/<(?:pre|textarea)[\s>]/i, text)

  defp trim_edges(text), do: text |> ltrim(~c" \t\r\n") |> rtrim(~c" \t\r\n")

  defp ltrim(bin, set \\ ~c" \t"), do: drop_blanks(bin, leading_blanks(bin, set))

  defp rtrim(bin, set \\ ~c" \t\r") do
    size = byte_size(bin)

    if size > 0 and :binary.last(bin) in set,
      do: rtrim(binary_part(bin, 0, size - 1), set),
      else: bin
  end

  defp leading_blanks(bin, set \\ ~c" \t"), do: leading_blanks(bin, set, 0)

  defp leading_blanks(<<c, rest::binary>>, set, n) do
    if c in set, do: leading_blanks(rest, set, n + 1), else: n
  end

  defp leading_blanks(<<>>, _set, n), do: n

  defp drop_blanks("", _n), do: ""
  defp drop_blanks(bin, n), do: binary_part(bin, n, byte_size(bin) - n)
end
