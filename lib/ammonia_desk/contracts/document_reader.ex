defmodule AmmoniaDesk.Contracts.DocumentReader do
  @moduledoc """
  Extracts raw text from PDF and DOCX files using local-only tools.
  No data leaves the network. All processing is on-machine.

  Requirements:
    - PDF:  `pdftotext` (from poppler-utils)
    - DOCX: pure Elixir (unzip + XML parse, no external dependency)
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
      ".doc" -> :doc_legacy
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

  # --- DOCX extraction (pure Elixir, no external tools) ---
  # DOCX is a ZIP containing XML. Main content is in word/document.xml.

  defp do_read(:docx, path) do
    with {:ok, zip_handle} <- :zip.zip_open(String.to_charlist(path), [:memory]),
         {:ok, {_, xml_bytes}} <- :zip.zip_get(~c"word/document.xml", zip_handle),
         :ok <- :zip.zip_close(zip_handle) do
      text = extract_docx_text(xml_bytes)

      if String.trim(text) == "" do
        {:error, :empty_document}
      else
        {:ok, text}
      end
    else
      {:error, reason} ->
        Logger.error("DOCX extraction failed: #{inspect(reason)}")
        {:error, :extraction_failed}
    end
  end

  defp do_read(:doc_legacy, _path) do
    {:error, :legacy_doc_not_supported}
  end

  defp do_read({:unknown, ext}, _path) do
    {:error, {:unsupported_format, ext}}
  end

  # --- DOCX XML text extraction ---
  # Walks the XML, extracts text from <w:t> elements, preserves paragraph breaks.

  defp extract_docx_text(xml_bytes) when is_binary(xml_bytes) do
    extract_docx_text_from_binary(xml_bytes)
  end

  defp extract_docx_text(xml_bytes) when is_list(xml_bytes) do
    xml_bytes |> IO.iodata_to_binary() |> extract_docx_text_from_binary()
  end

  defp extract_docx_text_from_binary(xml) do
    # Split on paragraph boundaries, extract text runs within each
    xml
    |> String.split(~r/<w:p[ >]/)
    |> Enum.map(&extract_paragraph_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_paragraph_text(fragment) do
    # Extract all <w:t ...>text</w:t> content within this paragraph
    Regex.scan(~r/<w:t[^>]*>([^<]*)<\/w:t>/, fragment)
    |> Enum.map(fn [_, text] -> text end)
    |> Enum.join("")
    |> String.trim()
  end
end
