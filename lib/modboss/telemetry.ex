defmodule ModBoss.Telemetry do
  @moduledoc false
  @compile inline: [execute: 3, span: 3]

  if Code.ensure_loaded?(:telemetry) do
    defdelegate execute(event, measurements, metadata), to: :telemetry
    defdelegate span(event_prefix, start_meta, span_fn), to: :telemetry
  else
    def execute(_event, _measurements, _metadata), do: :ok
    def span(_event_prefix, _start_meta, span_fn), do: elem(span_fn.(), 0)
  end
end
