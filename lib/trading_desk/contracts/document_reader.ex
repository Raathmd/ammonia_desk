defmodule TradingDesk.Contracts.DocumentReader do
  @moduledoc """
  Extracts raw text from PDF, DOCX, DOCM, and TXT files using local-only tools.
  No data leaves the network. All processing is on-machine.

  Handles real-world contract formats:
    - PDF:  `pdftotext` (from poppler-utils)
    - DOCX: pure Elixir (unzip + XML parse, no external dependency)
    - DOCM: same as DOCX (macro-enabled DOCX, identical ZIP+XML structure)
    - TXT:  direct file read (for testing and plain-text contracts)

  Special handling:
    - Tables (<w:tbl>) are extracted and rendered as "col1 | col2 | col3" rows
    - Paragraphs and tables are interleaved in document order
    - Section headings are preserved on separate lines for parser consumption
  """

  require Logger

  @type read_result :: {:ok, String.t()} | {:error, atom() | String.t()}

  @doc """
  Read a contract document and return its text content.
  Detects format from file extension.
  """
  @spec read(String.t()) :: read_result()
  def read(path) do
    unless File.exists?(path) do
      {:error, :file_not_found}
    else
      path
      |> detect_format()
      |> do_read(path)
    end
  end

  @doc "Detect document format from file extension"
  def detect_format(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> case do
      ".pdf" -> :pdf
      ".docx" -> :docx
      ".docm" -> :docm
      ".doc" -> :doc_legacy
      ".txt" -> :txt
      ext -> {:unknown, ext}
    end
  end

  # --- PDF extraction via pdftotext (poppler-utils) ---

  defp do_read(:pdf, path) do
    case System.find_executable("pdftotext") do
      nil ->
        Logger.error("pdftotext not found. Install poppler-utils: apt install poppler-utils")
        {:error, :pdftotext_not_installed}

      pdftotext ->
        # -layout preserves table structure, "-" outputs to stdout
        case System.cmd(pdftotext, ["-layout", path, "-"],
               stderr_to_stdout: true,
               env: [{"LC_ALL", "C.UTF-8"}]
             ) do
          {text, 0} when byte_size(text) > 0 ->
            {:ok, text}

          {_, 0} ->
            {:error, :empty_document}

          {err, code} ->
            Logger.error("pdftotext failed (exit #{code}): #{err}")
            {:error, :extraction_failed}
        end
    end
  end

  # --- DOCX/DOCM extraction (pure Elixir, no external tools) ---
  # Both DOCX and DOCM are ZIP files containing XML.
  # DOCM additionally contains VBA macros in vbaProject.bin, which we skip.
  # Main content is in word/document.xml.

  defp do_read(:docx, path), do: read_office_xml(path)
  defp do_read(:docm, path), do: read_office_xml(path)

  defp read_office_xml(path) do
    with {:ok, zip_handle} <- :zip.zip_open(String.to_charlist(path), [:memory]),
         {:ok, {_, xml_bytes}} <- :zip.zip_get(~c"word/document.xml", zip_handle),
         :ok <- :zip.zip_close(zip_handle) do
      xml = to_binary(xml_bytes)
      text = extract_office_xml_text(xml)

      if String.trim(text) == "" do
        {:error, :empty_document}
      else
        {:ok, text}
      end
    else
      {:error, reason} ->
        Logger.error("DOCX/DOCM extraction failed: #{inspect(reason)}")
        {:error, :extraction_failed}
    end
  end

  # --- TXT extraction (direct file read) ---

  defp do_read(:txt, path) do
    case File.read(path) do
      {:ok, text} when byte_size(text) > 0 -> {:ok, text}
      {:ok, _} -> {:error, :empty_document}
      {:error, reason} ->
        Logger.error("TXT read failed: #{inspect(reason)}")
        {:error, :extraction_failed}
    end
  end

  defp do_read(:doc_legacy, _path) do
    {:error, :legacy_doc_not_supported}
  end

  defp do_read({:unknown, ext}, _path) do
    {:error, {:unsupported_format, ext}}
  end

  # --- Office XML text extraction (shared by DOCX and DOCM) ---
  #
  # Strategy: Walk the XML body in document order. Both <w:p> (paragraphs)
  # and <w:tbl> (tables) are top-level children of <w:body>.
  # We extract them in order, rendering tables as pipe-delimited rows.
  # This preserves the interleaving so the parser sees table content
  # inline where it appears in the document.

  defp extract_office_xml_text(xml) do
    # Extract the body content between <w:body> and </w:body>
    body =
      case Regex.run(~r/<w:body[^>]*>(.*)<\/w:body>/s, xml) do
        [_, body_content] -> body_content
        _ -> xml
      end

    # Split body into top-level elements: paragraphs and tables
    # We process them in document order
    extract_body_elements(body)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # Parse top-level body elements in order: <w:tbl> and <w:p>
  defp extract_body_elements(body) do
    # Find all top-level <w:tbl> blocks and their positions
    table_ranges = find_element_ranges(body, "w:tbl")

    # Build output by walking through the body
    # First, get text segments between (and around) tables
    build_ordered_output(body, table_ranges, 0, [])
  end

  defp find_element_ranges(xml, tag) do
    # Find opening and closing positions of top-level elements
    # We need to handle nesting (tables can contain paragraphs)
    open_pattern = Regex.compile!("<#{tag}[ >]")

    Regex.scan(open_pattern, xml, return: :index)
    |> Enum.map(fn [{start, _len}] ->
      # Find matching close tag, accounting for nesting
      close_tag = "</#{tag}>"
      end_pos = find_matching_close(xml, start, tag, close_tag)
      {start, end_pos}
    end)
  end

  defp find_matching_close(xml, start, tag, close_tag) do
    open_re = Regex.compile!("<#{tag}[ >]")
    # Search from after the opening tag
    search_from = start + String.length(tag) + 2
    remaining = String.slice(xml, search_from, String.length(xml))

    # Simple approach: find the first close tag that isn't matched by a nested open
    do_find_close(remaining, open_re, close_tag, search_from, 1)
  end

  defp do_find_close(_remaining, _open_re, _close_tag, current_pos, 0) do
    current_pos
  end

  defp do_find_close("", _open_re, _close_tag, current_pos, _depth) do
    current_pos
  end

  defp do_find_close(remaining, open_re, close_tag, current_pos, depth) do
    # Find next open or close tag
    next_open = Regex.run(open_re, remaining, return: :index)
    next_close_idx = :binary.match(remaining, close_tag)

    case {next_open, next_close_idx} do
      {nil, :nomatch} ->
        current_pos + String.length(remaining)

      {nil, {close_start, close_len}} ->
        if depth == 1 do
          current_pos + close_start + close_len
        else
          after_close = close_start + close_len
          rest = String.slice(remaining, after_close, String.length(remaining))
          do_find_close(rest, open_re, close_tag, current_pos + after_close, depth - 1)
        end

      {[{open_start, _}], :nomatch} ->
        after_open = open_start + 1
        rest = String.slice(remaining, after_open, String.length(remaining))
        do_find_close(rest, open_re, close_tag, current_pos + after_open, depth + 1)

      {[{open_start, _}], {close_start, close_len}} ->
        if open_start < close_start do
          # Open tag comes first — increase depth
          after_open = open_start + 1
          rest = String.slice(remaining, after_open, String.length(remaining))
          do_find_close(rest, open_re, close_tag, current_pos + after_open, depth + 1)
        else
          # Close tag comes first — decrease depth
          if depth == 1 do
            current_pos + close_start + close_len
          else
            after_close = close_start + close_len
            rest = String.slice(remaining, after_close, String.length(remaining))
            do_find_close(rest, open_re, close_tag, current_pos + after_close, depth - 1)
          end
        end
    end
  end

  defp build_ordered_output(body, [], pos, acc) do
    # No more tables, extract remaining paragraphs
    remaining = String.slice(body, pos, String.length(body))
    paras = extract_paragraphs_from_xml(remaining)
    Enum.reverse(acc) ++ paras
  end

  defp build_ordered_output(body, [{tbl_start, tbl_end} | rest], pos, acc) do
    # Extract paragraphs before this table
    before = String.slice(body, pos, max(tbl_start - pos, 0))
    paras = extract_paragraphs_from_xml(before)

    # Extract table content
    tbl_xml = String.slice(body, tbl_start, tbl_end - tbl_start)
    table_rows = extract_table_text(tbl_xml)

    build_ordered_output(body, rest, tbl_end, Enum.reverse(table_rows) ++ Enum.reverse(paras) ++ acc)
  end

  # --- Paragraph extraction from XML fragments ---

  defp extract_paragraphs_from_xml(xml_fragment) do
    xml_fragment
    |> String.split(~r/<w:p[ >]/)
    |> Enum.map(&extract_paragraph_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_paragraph_text(fragment) do
    # Extract all <w:t ...>text</w:t> content within this paragraph
    Regex.scan(~r/<w:t[^>]*>([^<]*)<\/w:t>/, fragment)
    |> Enum.map(fn [_, text] -> text end)
    |> Enum.join("")
    |> String.trim()
  end

  # --- Table extraction ---
  # Converts <w:tbl> XML into pipe-delimited text rows.
  # Each <w:tr> becomes a row, each <w:tc> becomes a column.
  # Output: "Col1 | Col2 | Col3"

  defp extract_table_text(tbl_xml) do
    # Split into rows
    tbl_xml
    |> String.split(~r/<w:tr[ >]/)
    |> tl_safe()
    |> Enum.map(fn row_fragment ->
      # Split into cells
      cells =
        row_fragment
        |> String.split(~r/<w:tc[ >]/)
        |> tl_safe()
        |> Enum.map(fn cell_fragment ->
          # Extract text from all paragraphs within the cell
          cell_fragment
          |> String.split(~r/<w:p[ >]/)
          |> Enum.map(&extract_paragraph_text/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" ")
          |> String.trim()
        end)

      case cells do
        [] -> ""
        _ -> Enum.join(cells, " | ")
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # --- Helpers ---

  defp to_binary(data) when is_binary(data), do: data
  defp to_binary(data) when is_list(data), do: IO.iodata_to_binary(data)

  defp tl_safe([]), do: []
  defp tl_safe([_ | rest]), do: rest
end
