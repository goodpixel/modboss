defmodule ModBoss.Telemetry do
  @moduledoc false
  @compile inline: [span: 3]

  if Code.ensure_loaded?(:telemetry) do
    defdelegate span(event_prefix, start_meta, span_fn), to: :telemetry
  else
    def span(_event_prefix, _start_meta, span_fn) do
      case span_fn.() do
        {result, _metadata} -> result
        {result, _extra_measurements, _metadata} -> result
      end
    end
  end
end
