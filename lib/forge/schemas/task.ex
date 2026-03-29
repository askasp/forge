defmodule Forge.Schemas.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tasks" do
    field(:role, Ecto.Enum, values: [:planner, :dev, :qa, :reviewer, :human])

    field(:state, Ecto.Enum,
      values: [:planned, :assigned, :in_progress, :done, :failed],
      default: :planned
    )

    field(:title, :string)
    field(:prompt, :string)
    field(:result, :map)
    field(:sort_order, :integer, default: 0)
    field(:iteration_count, :integer, default: 0)
    field(:acceptance_criteria, :string)

    belongs_to(:session, Forge.Schemas.Session)
    belongs_to(:parent_task, __MODULE__)
    belongs_to(:depends_on, __MODULE__)
    has_many(:child_tasks, __MODULE__, foreign_key: :parent_task_id)
    has_many(:agent_runs, Forge.Schemas.AgentRun)

    timestamps(type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :session_id,
      :parent_task_id,
      :depends_on_id,
      :role,
      :state,
      :title,
      :prompt,
      :result,
      :sort_order,
      :iteration_count,
      :acceptance_criteria
    ])
    |> validate_required([:session_id, :role, :title])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:parent_task_id)
    |> foreign_key_constraint(:depends_on_id)
  end

  def transition_changeset(task, new_state, result \\ nil) do
    attrs = %{state: new_state}
    attrs = if result, do: Map.put(attrs, :result, result), else: attrs

    task
    |> cast(attrs, [:state, :result])
    |> validate_transition(task.state, new_state)
  end

  defp validate_transition(changeset, from, to) do
    if valid_transition?(from, to) do
      changeset
    else
      add_error(changeset, :state, "invalid transition from #{from} to #{to}")
    end
  end

  defp valid_transition?(:planned, :assigned), do: true
  defp valid_transition?(:planned, :done), do: true
  defp valid_transition?(:planned, :failed), do: true
  defp valid_transition?(:assigned, :in_progress), do: true
  defp valid_transition?(:assigned, :done), do: true
  defp valid_transition?(:assigned, :failed), do: true
  defp valid_transition?(:in_progress, :done), do: true
  defp valid_transition?(:in_progress, :failed), do: true
  defp valid_transition?(:failed, :planned), do: true
  defp valid_transition?(:done, :planned), do: true
  defp valid_transition?(_, _), do: false
end
