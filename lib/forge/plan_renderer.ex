defmodule Forge.PlanRenderer do
  @moduledoc "Converts plan Markdown to safe HTML via Earmark."

  def render(nil), do: nil
  def render(""), do: nil

  def render(markdown) do
    case Earmark.as_html(markdown, %Earmark.Options{smartypants: false, code_class_prefix: "language-"}) do
      {:ok, html, _warnings} -> sanitize(html)
      {:error, _, _} -> nil
    end
  end

  defp sanitize(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/s, "")
    |> String.replace(~r/<iframe[^>]*>.*?<\/iframe>/s, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/s, "")
    |> String.replace(~r/\s+on\w+="[^"]*"/, "")
  end
end
