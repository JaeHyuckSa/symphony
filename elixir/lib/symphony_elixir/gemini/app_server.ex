defmodule SymphonyElixir.Gemini.AppServer do
  @moduledoc """
  Gemini CLI adapter that implements the agent backend interface.

  Spawns `gemini` CLI as a subprocess for each turn. Gemini CLI supports:
  - `gemini -p "<prompt>"` for non-interactive mode
  - `--model` for model selection (e.g., gemini-2.5-pro)
  - `--sandbox` for sandbox mode

  Configure in WORKFLOW.md:
      agent:
        backend: gemini
      gemini:
        model : gemini-2.5-pro
        extra_flags: "--sandbox"
        turn_timeout_ms: 3600000
  """

  require Logger
  alias SymphonyElixir.Config

  @max_stream_log_bytes 1_000

  @type session :: %{
          workspace: Path.t(),
          model: String.t() | nil,
          extra_flags: String.t() | nil,
          turn_timeout_ms: pos_integer(),
          metadata: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace) do
      expanded_workspace = Path.expand(workspace)

      {:ok,
       %{
         workspace: expanded_workspace,
         model: Config.gemini_model(),
         extra_flags: Config.gemini_extra_flags(),
         turn_timeout_ms: Config.gemini_turn_timeout_ms(),
         metadata: %{}
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          workspace: workspace,
          model: model,
          extra_flags: extra_flags,
          turn_timeout_ms: turn_timeout_ms
        } = _session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = generate_session_id()
    turn_id = generate_turn_id()

    Logger.info("Gemini CLI session started for #{issue_context(issue)} session_id=#{session_id}")

    emit_message(on_message, :session_started, %{
      session_id: session_id,
      thread_id: session_id,
      turn_id: turn_id
    })

    cmd = build_command(prompt, model, extra_flags)

    case run_gemini_process(cmd, workspace, turn_timeout_ms, on_message) do
      {:ok, output} ->
        emit_message(on_message, :turn_completed, %{
          session_id: session_id,
          output: output,
          payload: %{"method" => "turn/completed"},
          raw: output,
          details: %{}
        })

        Logger.info("Gemini CLI session completed for #{issue_context(issue)} session_id=#{session_id}")

        {:ok,
         %{
           result: :turn_completed,
           session_id: session_id,
           thread_id: session_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        emit_message(on_message, :turn_ended_with_error, %{
          session_id: session_id,
          reason: reason
        })

        Logger.warning(
          "Gemini CLI session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # -- Private --

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp build_command(prompt, model, extra_flags) do
    # Gemini CLI: gemini -p "prompt"
    cmd = ["gemini", "-p", prompt]

    cmd =
      if is_binary(model) and model != "" do
        cmd ++ ["--model", model]
      else
        cmd
      end

    cmd =
      if is_binary(extra_flags) and extra_flags != "" do
        cmd ++ String.split(extra_flags)
      else
        cmd
      end

    cmd
  end

  defp run_gemini_process(cmd, workspace, timeout_ms, on_message) do
    [executable | args] = cmd
    exe_path = System.find_executable(executable)

    if is_nil(exe_path) do
      {:error, {:gemini_not_found, executable}}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(exe_path)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1),
            cd: String.to_charlist(workspace)
          ]
        )

      collect_output(port, timeout_ms, on_message, "")
    end
  end

  defp collect_output(port, timeout_ms, on_message, acc) do
    receive do
      {^port, {:data, data}} ->
        chunk = to_string(data)

        emit_message(on_message, :notification, %{
          payload: %{"method" => "streaming", "data" => String.slice(chunk, 0, 200)},
          raw: String.slice(chunk, 0, @max_stream_log_bytes)
        })

        collect_output(port, timeout_ms, on_message, acc <> chunk)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, status}} ->
        Logger.error("Gemini CLI exited with status #{status}: #{String.slice(acc, 0, 500)}")
        {:error, {:gemini_exit, status, String.slice(acc, 0, 500)}}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :turn_timeout}
    end
  end

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message =
      details
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp generate_session_id do
    "gemini-#{:crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)}"
  end

  defp generate_turn_id do
    "turn-#{:crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)}"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
