defmodule Forge.Screenshot do
  @moduledoc """
  Captures screenshots using headless Chromium.
  """
  require Logger

  @timeout_ms 15_000

  @doc "Capture a screenshot of the given URL. Returns {:ok, png_binary} or {:error, reason}."
  def capture(url, opts \\ []) do
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 800)

    case find_chrome() do
      nil ->
        {:error, "No Chrome/Chromium found on PATH"}

      chrome_path ->
        tmp_dir = System.tmp_dir!()
        output_path = Path.join(tmp_dir, "forge-screenshot-#{:erlang.unique_integer([:positive])}.png")

        args = [
          "--headless",
          "--disable-gpu",
          "--no-sandbox",
          "--disable-dev-shm-usage",
          "--window-size=#{width},#{height}",
          "--screenshot=#{output_path}",
          "--hide-scrollbars",
          url
        ]

        Logger.info("[Screenshot] Capturing #{url} with #{chrome_path}")

        try do
          case System.cmd(chrome_path, args,
                 stderr_to_stdout: true,
                 timeout: @timeout_ms
               ) do
            {_output, 0} ->
              if File.exists?(output_path) do
                data = File.read!(output_path)
                File.rm(output_path)
                {:ok, data}
              else
                {:error, "Screenshot file not created"}
              end

            {output, code} ->
              File.rm(output_path)
              {:error, "Chrome exited with code #{code}: #{String.slice(output, 0, 200)}"}
          end
        rescue
          e ->
            File.rm(output_path)
            {:error, "Screenshot failed: #{Exception.message(e)}"}
        end
    end
  end

  @doc "Check if headless Chrome is available."
  def available? do
    find_chrome() != nil
  end

  defp find_chrome do
    candidates = [
      "chromium",
      "chromium-browser",
      "google-chrome",
      "google-chrome-stable",
      "chrome"
    ]

    Enum.find_value(candidates, fn name ->
      case System.find_executable(name) do
        nil -> nil
        path -> path
      end
    end)
  end
end
