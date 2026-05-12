defmodule Jido.Composer.OtelFanOutNodeSpanTest do
  @moduledoc """
  Tests that `FanOutNode.run/3` — invoked directly, outside the workflow
  DSL's `FanOutBranch` dispatch path — preserves the caller's OTel
  context so spans emitted inside each branch nest under the caller's
  parent span instead of rooting fresh traces.

  The complementary path through `execute_fan_out_branches/1` in
  `workflow/dsl.ex` is covered by `otel_fan_out_span_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.OtelTestHelper, as: OTH

  require OpenTelemetry.Tracer, as: Tracer

  @moduletag :capture_log

  # Minimal Node-shaped struct that emits a span in its run/3.
  # Deliberately bypasses ActionNode/Jido.Exec so the test exercises only
  # the FanOutNode → branch boundary, not the Jido.Exec child-task
  # boundary (which has its own propagation mechanism via
  # `:jido_action, :observability`).
  defmodule TracingBranch do
    @moduledoc false
    defstruct [:name]

    require OpenTelemetry.Tracer, as: Tracer

    @spec run(struct(), map(), keyword()) :: {:ok, map()}
    def run(%__MODULE__{name: name}, _context, _opts \\ []) do
      Tracer.with_span name do
        {:ok, %{branch: name}}
      end
    end
  end

  setup do
    handler_state = OTH.setup_otel_capture(self())
    on_exit(fn -> OTH.teardown_otel(handler_state) end)
    :ok
  end

  describe "FanOutNode.run/3 direct invocation" do
    test "branch spans nest under the caller's active span" do
      {:ok, fan_out} =
        FanOutNode.new(
          name: "direct_fan_out",
          branches: [
            {:one, %TracingBranch{name: "branch_one"}},
            {:two, %TracingBranch{name: "branch_two"}}
          ]
        )

      # Establish a parent span around the direct FanOutNode.run/3 call.
      # Without OTel propagation through the Task.async_stream inside
      # FanOutNode.run/3, spans emitted in each branch would root a new
      # trace instead of nesting under "parent_span".
      result =
        Tracer.with_span "parent_span" do
          FanOutNode.run(fan_out, %{})
        end

      assert {:ok, _merged} = result

      spans = OTH.collect_spans()

      parent = OTH.find_span(spans, "parent_span")
      branch_one = OTH.find_span(spans, "branch_one")
      branch_two = OTH.find_span(spans, "branch_two")

      assert parent != nil,
             "expected parent span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert branch_one != nil and branch_two != nil,
             "expected both branch spans, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      OTH.assert_same_trace([parent, branch_one, branch_two])
      OTH.assert_parent_child(parent, branch_one)
      OTH.assert_parent_child(parent, branch_two)
      OTH.assert_siblings(branch_one, branch_two)
    end
  end
end
